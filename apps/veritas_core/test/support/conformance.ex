defmodule Veritas.Core.Store.Conformance do
  @moduledoc """
  The ExUnit harness around the store contract's conformance suite.

  The obligations themselves live in `Veritas.Store.Spec`
  (`apps/veritas_core/lib/veritas/store/spec.ex`), which is the normative
  implementation of `docs/32`: one place decides what an Adapter must hold,
  and the CLI (`mix veritas.store.spec`) and this harness both run it. This
  module does not re-implement an obligation — a second implementation of
  the contract is a second thing to keep correct, and it is the one that
  quietly drifts.

  What this harness adds is the part a library module cannot:

    * **per-obligation reporting.** A failing obligation is named, with the
      Adapter's own words, rather than a boolean.
    * **an explicit statement of what is not executable.** `docs/32` has
      fifteen obligations; the normative suite executes eleven of them. The
      other three are reported as *not executable* rather than passed in
      silence, and the set is asserted, so the gap cannot widen unnoticed.
    * **Workspace isolation.** Every run works in its own scratch Workspace
      and removes it afterwards, so the suite is safe to run against a live
      store and leaves nothing behind.
  """

  @doc """
  The obligations `docs/32` defines.

  The corpus numbers them O-1…O-15; this is the full set.
  """
  @contract_obligations ~w(O-1 O-2 O-3 O-4 O-5 O-6 O-7 O-8 O-9 O-10 O-11 O-12 O-13 O-14 O-15)

  @doc """
  The obligations the normative suite does not execute.

  `Veritas.Store.Spec` lists eleven obligations in its `@moduledoc`: O-1/O-2
  (atomicity), O-3 (ordering), O-4 (Workspace isolation), O-5 (durability),
  O-6 (the Audit Log chain), O-7 (one system of record), O-8 (depth-bounded
  traversal), O-9 (the relation vocabulary), O-13 (the change stream), O-14
  (loud failure) and O-15 (no internal retries). The vector (O-10),
  full-text (O-11) and time-series (O-12) obligations are not in that list.

  They are reported as not executable — with the reason — rather than passed
  in silence. A conformance suite that passes by construction is worse than
  no suite, because it is a false promise.
  """
  @not_executable [
    {"O-10", "the vector search contract is not executed by Veritas.Store.Spec"},
    {"O-11", "the full-text ranking contract is not executed by Veritas.Store.Spec"},
    {"O-12", "the time-series windowing contract is not executed by Veritas.Store.Spec"}
  ]

  @doc "Every obligation `docs/32` defines."
  @spec contract_obligations() :: [String.t()]
  def contract_obligations, do: @contract_obligations

  @doc "The obligations the normative suite does not execute, with the reason."
  @spec not_executable() :: [{String.t(), String.t()}]
  def not_executable, do: @not_executable

  @doc """
  Installs the Adapter and prepares a scratch Workspace.

  The Adapter is installed because the port's functions dispatch to the
  installed one: substituting the datastore is a configuration change
  (`docs/32`, ADR-033), and the conformance suite must be able to make that
  change for any Adapter an author brings.
  """
  @spec prepare(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(adapter, opts \\ []) do
    previous = Application.get_env(:veritas_core, :store)

    Veritas.Store.Config.configure({adapter, Keyword.get(opts, :adapter_options, [])})

    workspace = Keyword.get_lazy(opts, :workspace, &scratch_workspace/0)

    # An Adapter whose Workspace must exist in the engine needs it brought up
    # first. The contract does not require a migrator, so this is optional.
    case migrate(adapter, workspace) do
      :ok ->
        # An Adapter that needs a process of its own starts it here; one that
        # does not — the shipped one talks to a store that is already running
        # — is left alone. The port does not say which kind an Adapter is, so
        # both are allowed.
        {pid, started?} = start_adapter(adapter)

        {:ok,
         %{
           adapter: adapter,
           workspace: workspace,
           previous: previous,
           pid: pid,
           started?: started?
         }}

      {:error, reason} ->
        # The Adapter is already swapped; put it back before failing, so a
        # failed preparation cannot leak into the next module.
        restore(previous)
        {:error, reason}
    end
  end

  @doc "Restores whatever Adapter was installed before the run, and removes the scratch Workspace."
  @spec cleanup(map()) :: :ok
  def cleanup(ctx) do
    restore(Map.get(ctx, :previous))

    if workspace = Map.get(ctx, :workspace) do
      Veritas.Core.Test.StoreCase.remove_workspace(workspace)
    end

    case {Map.get(ctx, :started?), Map.get(ctx, :pid)} do
      {true, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)

      _ ->
        :ok
    end

    :ok
  end

  defp restore(nil), do: Application.delete_env(:veritas_core, :store)
  defp restore(previous), do: Application.put_env(:veritas_core, :store, previous)

  @doc """
  Runs the contract's obligations against an installed Adapter.

  Returns the list of results and whether every one of them holds.
  """
  @spec run(map()) :: {[map()], boolean()}
  def run(ctx) do
    Veritas.Store.Spec.run(adapter: ctx.adapter, workspace: ctx.workspace)
  end

  @doc """
  The obligation ids the normative suite covered in a set of results.

  The results name their obligations ("O-3 ordering"); this is the set of
  ids behind those names.
  """
  @spec covered_obligations([map()]) :: [String.t()]
  def covered_obligations(results) do
    results
    |> Enum.flat_map(fn result -> Regex.scan(~r/O-\d+/, result.obligation) end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort_by(&(String.replace_prefix(&1, "O-", "") |> String.to_integer()))
  end

  @doc """
  The obligations of `docs/32` that a set of results does not cover.

  O-1 and O-2 are checked together, so a result naming "O-1/O-2" covers
  both.
  """
  @spec uncovered_obligations([map()]) :: [String.t()]
  def uncovered_obligations(results) do
    covered = covered_obligations(results)
    @contract_obligations -- covered
  end

  @doc "A scratch Workspace name nobody else is using."
  @spec scratch_workspace() :: String.t()
  def scratch_workspace do
    "veritas_spec_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  # Brings a Workspace up, for the Adapters whose engine needs it.
  defp migrate(adapter, workspace) do
    # `function_exported?/3` answers false for a module that is not loaded
    # yet, so the module is loaded first.
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :migrate, 1) do
      case adapter.migrate(workspace) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # Starts an Adapter that needs a process of its own. Returns the pid and
  # whether this call started it, so the cleanup only stops what it owns.
  #
  # **The ownership is decided by evidence, not by the shape of the return
  # value.** An Adapter's `start_link/1` may be idempotent — the in-memory
  # Adapter's is, by its own promise — and an idempotent `start_link/1`
  # answers `{:ok, pid}` for a process that was **already running**. Taking
  # that at face value makes the harness a process killer: the process it
  # stops is the **application's** supervised child, and stopping it is a
  # restart. A supervisor allows three restarts in five seconds, and the
  # fourth takes the application down — and every test after it fails with a
  # store it cannot reach, which looks like a product fault and is not one.
  #
  # So the processes running before the call are remembered, and a pid that
  # was already among them is not this call's to stop. This holds for any
  # Adapter an author brings, whatever its `start_link/1` returns.
  defp start_adapter(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :start_link, 1) do
      running = MapSet.new(Process.list())

      case adapter.start_link([]) do
        {:ok, pid} -> {pid, not MapSet.member?(running, pid)}
        {:error, {:already_started, pid}} -> {pid, false}
        _ -> {nil, false}
      end
    else
      {nil, false}
    end
  end
end
