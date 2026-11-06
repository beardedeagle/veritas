defmodule Veritas.Core.WorkspaceLock do
  @moduledoc """
  The in-process half of the single-writer rule.

  Two things must not interleave inside one Workspace:

    * the **Audit Log chain** — each row links to the hash of the previous
      one, so two writers reading the same predecessor would fork the chain;
    * the **ordering sequence** — the value that orders the change stream.

  The free build is single-node per Datacenter, so the coordination layer
  (`docs/26`) already guarantees one writer per Workspace *across* Nodes. This
  process guarantees the same thing *within* a Node, where the LiveView, the
  GraphQL surface and the CLI all write.

  The lock is **not** a substitute for the coordination layer: it is the local
  half of the same rule, and it says so in the Audit Log's own terms — a
  writer that did not hold it would break the chain, and the chain is
  verifiable after the fact.
  """

  use GenServer

  @timeout 5_000

  @doc "Starts the lock server."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs `fun` with the Workspace locked.

  The lock is released whatever happens, including a raise.
  """
  @spec with_lock(String.t(), (-> result)) :: result when result: term()
  def with_lock(workspace, fun) when is_binary(workspace) do
    :ok = acquire(workspace, @timeout)

    try do
      fun.()
    after
      release(workspace)
    end
  end

  @doc "Acquires the lock, blocking until it is free."
  @spec acquire(String.t(), timeout()) :: :ok
  def acquire(workspace, timeout \\ @timeout) do
    request = make_ref()

    try do
      GenServer.call(__MODULE__, {:acquire, workspace, request}, timeout)
    catch
      :exit, {:timeout, _} = reason ->
        # Cancel synchronously: the grant may have raced the call timeout.
        GenServer.call(__MODULE__, {:cancel, workspace, request}, :infinity)
        exit(reason)
    end
  end

  @doc "Releases the lock."
  @spec release(String.t()) :: :ok | {:error, :not_owner}
  def release(workspace) do
    GenServer.call(__MODULE__, {:release, workspace})
  end

  @doc "Whether the Workspace is currently locked."
  @spec locked?(String.t()) :: boolean()
  def locked?(workspace), do: GenServer.call(__MODULE__, {:locked?, workspace})

  @impl true
  def init(_opts), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, workspace, request}, {pid, _tag} = from, state) do
    monitor = Process.monitor(pid)
    entry = %{from: from, monitor: monitor, request: request}
    queue = Map.get(state.locks, workspace, [])

    state = %{
      state
      | locks: Map.put(state.locks, workspace, queue ++ [entry]),
        monitors: Map.put(state.monitors, monitor, workspace)
    }

    if queue == [], do: GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_call({:cancel, workspace, request}, {pid, _tag}, state) do
    {:reply, :ok,
     remove(state, workspace, fn entry ->
       entry.request == request and elem(entry.from, 0) == pid
     end)}
  end

  def handle_call({:release, workspace}, {pid, _tag}, state) do
    case Map.get(state.locks, workspace, []) do
      [%{from: {^pid, _}, monitor: monitor} | _] ->
        {:reply, :ok, remove(state, workspace, &(&1.monitor == monitor))}

      [] ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:locked?, workspace}, _from, state) do
    {:reply, Map.has_key?(state.locks, workspace), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, workspace} -> {:noreply, remove(state, workspace, &(&1.monitor == monitor))}
      :error -> {:noreply, state}
    end
  end

  defp remove(state, workspace, matches?) do
    queue = Map.get(state.locks, workspace, [])
    {removed, remaining} = Enum.split_with(queue, matches?)

    monitors =
      Enum.reduce(removed, state.monitors, fn entry, monitors ->
        Process.demonitor(entry.monitor, [:flush])
        Map.delete(monitors, entry.monitor)
      end)

    if queue != [] and hd(queue) in removed and remaining != [] do
      GenServer.reply(hd(remaining).from, :ok)
    end

    locks =
      if remaining == [],
        do: Map.delete(state.locks, workspace),
        else: Map.put(state.locks, workspace, remaining)

    %{state | locks: locks, monitors: monitors}
  end
end
