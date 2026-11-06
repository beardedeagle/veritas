defmodule Veritas.Core.Test.StoreCase do
  @moduledoc """
  A case template for the domain tests.

  The domain runs against a store the suite starts itself, and every test
  gets its own Workspace. The Workspace is the isolation unit of the contract
  (`docs/32` O-4), so a fresh Workspace is a fresh world: no test can see
  another's rows, and no test has to clean up after itself. That is why the
  suite has no shared mutable state and no reset between tests.

  The tests are tagged `:needs_store`, so that a run without a datastore
  excludes them loudly rather than failing them obscurely.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Veritas.Core.Test.StoreCase

      @tag :needs_store
    end
  end

  setup do
    workspace = unique_workspace()
    pin_store_configuration()
    migrate(workspace)

    # The Workspace is removed when the test ends, whether it passed or
    # failed. A test run must leave the store as it found it: hundreds of
    # scratch namespaces in a store somebody actually runs against are
    # litter, not a side effect.
    on_exit(fn -> remove_workspace(workspace) end)

    {:ok, workspace: workspace}
  end

  @doc """
  Puts the suite's own store configuration back.

  The managed store publishes its URL into the application environment when it
  starts, and the Adapter reads that environment on every request. A test that
  starts a store of its own therefore redirects *every* test in the run for as
  long as it holds, and a test that is redirected reads a different transition
  table and a different Audit Log — which looks exactly like a property that
  is wrong.

  The suite captured its own configuration before any test ran, so this puts it
  back. It is isolation, not a retry: the property is still asserted on every
  case, against the store this suite migrated.
  """
  @spec pin_store_configuration() :: :ok
  def pin_store_configuration do
    case Application.get_env(:veritas_core, :test_store_configuration, :unset) do
      :unset ->
        :ok

      nil ->
        Application.delete_env(:veritas_core, :surreal)
        :ok

      configuration ->
        Application.put_env(:veritas_core, :surreal, configuration)
        :ok
    end
  end

  @doc "A Workspace name nobody else is using."
  @spec unique_workspace() :: String.t()
  def unique_workspace do
    "t_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  @doc "Brings a Workspace to the current schema, for the adapters that need it."
  @spec migrate(String.t()) :: :ok
  def migrate(workspace) do
    case Veritas.Store.adapter() do
      Veritas.Store.Surreal -> Veritas.Store.Surreal.migrate(workspace)
      _ -> :ok
    end
  end

  @doc """
  Opens an Incident through the domain, for a test that needs one.
  """
  @spec open_incident(String.t(), map()) :: map()
  def open_incident(workspace \\ "default", attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"title" => "Checkout is down", "requester" => "u1", "priority" => "high"},
        attrs
      )

    {:ok, ticket} =
      Veritas.Core.Tickets.open(workspace, "incident", attrs, %{type: "user", id: "u1"})

    ticket
  end

  @doc """
  Removes a scratch Workspace from the store.

  The suite writes to a Workspace of its own and cleans up after itself, so
  it is safe to run against a live store and leaves nothing behind.
  """
  @doc """
  Removes a scratch Workspace from the store.

  A no-op for an Adapter with no namespace to remove — the in-memory Adapter,
  for one — so the same suite runs against both without change. The removal
  is idempotent: removing a Workspace that is already gone is not an error.
  """
  @spec remove_workspace(String.t()) :: :ok
  def remove_workspace(workspace) do
    settings = Application.get_env(:veritas_core, :surreal, [])

    if surreal_adapter?() do
      case settings[:url] do
        url when is_binary(url) ->
          Veritas.Core.Test.SurrealServer.remove_workspace(url, workspace, settings)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  # The configured Adapter, without `Veritas.Store.adapter/0`, which raises for
  # an Adapter that does not implement the contract.
  defp surreal_adapter? do
    case Application.get_env(:veritas_core, :store) do
      {Veritas.Store.Surreal, _options} -> true
      Veritas.Store.Surreal -> true
      _ -> false
    end
  end

  @doc "The Audit Log events of a Workspace, oldest first."
  @spec audit_events(String.t()) :: [map()]
  def audit_events(workspace) do
    {:ok, events} = Veritas.Core.Audit.entries(workspace)
    events
  end

  @doc "The rows of a table in a Workspace."
  @spec rows(String.t(), atom()) :: [map()]
  def rows(workspace, table) do
    {:ok, listed} =
      Veritas.Store.transaction(workspace, fn tx ->
        Veritas.Store.list(tx, table, %{where: [], order_by: []})
      end)

    listed
  end
end
