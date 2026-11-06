defmodule Veritas.Core.Application do
  @moduledoc """
  Supervises the core application: the datastore's own server (when the node
  manages it), the HTTP client pool the store Adapter uses, the per-Workspace
  write lock, and the in-memory store when it is the installed Adapter.

  The boot check runs **before** the supervisor starts. A deployment whose
  datastore Adapter is missing, broken, or not an implementation of the
  `Veritas.Store` contract must fail here, loudly, rather than serve traffic
  that quietly stops persisting.

  ## The store is started first

  The datastore's server is the **first** child, and it is not "started"
  until it answers its readiness probe. The application therefore does not
  serve until the store is there: a half-started node, serving traffic
  against a store that is not up yet, is the failure this ordering exists to
  prevent.

  The store is a child in its own crash domain (ADR-048). It is not a NIF
  inside the BEAM, so a store that faults does not take the node with it; and
  it is not a service an operator has to start by hand, so a clean checkout
  runs with nothing started by hand.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # The check comes first on purpose: a broken Adapter is a deployment
    # error, and the loudest place to report it is the boot.
    :ok = Veritas.Store.Config.validate!()

    # The Audit Log's chain is the host's, and the Adapter stores it rather
    # than computing it (`docs/32`). The host registers its chain here, so
    # that a migration can give a legacy row a chain identity through the
    # seam instead of inventing one.
    :ok = Veritas.Store.Chain.register(&Veritas.Core.Audit.reconcile_chain/1)

    # The chain is **signed** with a key the host holds and the store never
    # sees. A deployment with no key is a deployment whose Audit Log can be
    # rewritten by whoever can write to the store, so the check is here, with
    # the datastore's own: in production it refuses to start, and elsewhere it
    # warns loudly.
    :ok = Veritas.Core.Audit.ChainKey.validate!()

    # The core tools are the product's own capabilities, and they are in the
    # registry before anything else asks for them: the Tool screen, the
    # agent's reach into the CMDB and the MCP server's projection all read
    # the same specs (`docs/15` §Tool Registry Ownership).
    :ok = Veritas.Agentic.Tool.Core.register()

    case store_children() do
      {:ok, store} ->
        children = store ++ pool_children()

        start_supervisor(children)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_supervisor(children) do
    case Supervisor.start_link(children, strategy: :one_for_one, name: Veritas.Core.Supervisor) do
      {:ok, supervisor} ->
        case bring_up_schema() do
          :ok ->
            {:ok, supervisor}

          {:error, reason} ->
            # A node that cannot bring its schema up must not serve. The
            # supervisor goes down with it, so the store is stopped with it
            # and no `surreal` is left running behind a node that failed.
            Process.unlink(supervisor)
            Supervisor.stop(supervisor)

            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The store's own server, when this node manages its datastore.
  #
  # It is first in the list on purpose: the supervisor starts its children in
  # order, and the child is not started until the store answers, so the rest
  # of the tree — and the application — come up after it.
  defp store_children do
    if Veritas.Store.Surreal.Server.managed?() do
      # The node resolves the store's settings and hands them to the child,
      # and tells the child to publish itself into the Adapter's
      # configuration: the Adapter has to be told where the store it started
      # is. A child started by anything else — a test, a tool — publishes
      # nothing, and so changes nothing the rest of the VM shares.
      case Veritas.Store.Surreal.Server.prepare() do
        {:ok, settings} ->
          {:ok, [{Veritas.Store.Surreal.Server, settings: settings, publish: true}]}

        {:error, :not_found} ->
          {:error, {:store_binary_missing, missing_binary_message()}}
      end
    else
      {:ok, []}
    end
  end

  # The node was asked to manage its own store and there is no binary to
  # manage it with. That is a broken installation, and the node says so and
  # stops: it does not fall back to whatever happens to be listening on the
  # default port, which would be a different deployment's data.
  defp missing_binary_message do
    """
    this node manages its own datastore, and there is no SurrealDB binary to \
    manage it with.

    Install the pinned binary with

        mix veritas.store.install

    or point the node at a store of your own with

        VERITAS_SURREAL_URL=http://host:port
    """
  end

  defp pool_children do
    [
      {Finch, name: :veritas_store_pool, pools: %{default: [size: 10]}},
      # The pool the directory Adapter uses, when a directory is configured.
      # It is started unconditionally, like the store's: an Adapter may be
      # configured after the application boots, and a pool that is missing is
      # a request that cannot be made at all.
      {Finch, name: :veritas_directory_pool, pools: %{default: [size: 5]}},
      Veritas.Core.WorkspaceLock,
      # The in-memory Adapter's process. It is started unconditionally: the
      # Adapter may be installed *after* the application boots — the
      # conformance suite does exactly that — and a store that only half
      # exists is worse than one that costs a process.
      Veritas.Store.Memory.Server
    ]
  end

  # The node that owns its store brings the schema up with it.
  #
  # A node pointed at somebody else's store does not write to that store's
  # schema at boot: the deployment owns that store, and the migration is its
  # step (`mix veritas.cli migrate`). The distinction is the difference
  # between a node that manages a datastore and a node that borrows one.
  defp bring_up_schema do
    if Veritas.Store.Surreal.Server.managed?() do
      workspace = Application.get_env(:veritas_core, :boot_workspace, "default")
      adapter = Veritas.Store.Config.adapter()

      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :migrate, 1) do
        case adapter.migrate(workspace) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, {:schema_failed, workspace, reason}}
        end
      else
        Logger.warning(
          "[veritas.store] the installed adapter #{inspect(adapter)} cannot migrate a " <>
            "workspace; the schema must be applied by the deployment"
        )

        :ok
      end
    else
      :ok
    end
  end
end
