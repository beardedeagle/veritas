defmodule Veritas.Store.Tx do
  @moduledoc """
  The transaction accumulator.

  A transaction handle is **opaque** to the domain (`docs/32`), and it has to
  be: the Adapter buffers writes while the transaction body runs, and only
  commits them at the end.

  A plain immutable value cannot do that — the Adapter's callbacks take a
  handle and return a *result*, not a new handle, so there is nowhere for a
  buffered write to go. The handle is therefore a process: a small Agent that
  collects the transaction's statements and the rows it has written.

  The Agent is linked to the caller, so a transaction that crashes takes its
  accumulator with it and leaves nothing behind.

  The handle's **type** belongs to the port (`{:veritas_store_tx, pid}`); its
  **content** belongs to the Adapter. The domain never looks inside either.
  """

  use Agent

  @type state :: %{
          workspace: String.t(),
          statements: [String.t()],
          safe_statements: [String.t()],
          ops: [term()],
          overlay: %{optional({atom(), String.t()}) => map()}
        }

  @doc "Starts an accumulator for a Workspace."
  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(workspace) do
    Agent.start_link(fn ->
      %{workspace: workspace, statements: [], safe_statements: [], ops: [], overlay: %{}}
    end)
  end

  @doc "Appends a statement to the transaction."
  @spec buffer(pid(), String.t()) :: :ok
  def buffer(pid, statement) do
    buffer(pid, statement, statement)
  end

  @doc """
  Appends a statement to the transaction, and the statement as it may be shown.

  The two are the same unless the statement carries a value that must not
  leave the host — a password hash, for instance. The **shown** statement is
  the one a failure names, so a diagnostic can say which statement failed
  without carrying a secret.
  """
  @spec buffer(pid(), String.t(), String.t()) :: :ok
  def buffer(pid, statement, shown) do
    Agent.update(pid, fn state ->
      %{
        state
        | statements: state.statements ++ [statement],
          safe_statements: state.safe_statements ++ [shown]
      }
    end)
  end

  @doc "The statements buffered so far, in order."
  @spec statements(pid()) :: [String.t()]
  def statements(pid), do: Agent.get(pid, & &1.statements)

  @doc """
  The statements as they may be shown, in order.

  The same list, in the same order, with every secret value replaced.
  """
  @spec safe_statements(pid()) :: [String.t()]
  def safe_statements(pid), do: Agent.get(pid, & &1.safe_statements)

  @doc """
  Appends an operation to the transaction.

  An Adapter whose buffer is not a list of statements — the in-memory Adapter
  applies operations rather than SQL — uses this instead.
  """
  @spec buffer_op(pid(), term()) :: :ok
  def buffer_op(pid, op) do
    Agent.update(pid, fn state -> %{state | ops: state.ops ++ [op]} end)
  end

  @doc "The operations buffered so far, in order."
  @spec ops(pid()) :: [term()]
  def ops(pid), do: Agent.get(pid, & &1.ops)

  @doc "The Workspace the transaction belongs to."
  @spec workspace(pid()) :: String.t()
  def workspace(pid), do: Agent.get(pid, & &1.workspace)

  @doc """
  Records a row the transaction has written, so a later read in the same
  transaction sees it (read-your-writes).
  """
  @spec put_overlay(pid(), atom(), String.t(), map()) :: :ok
  def put_overlay(pid, table, id, record) do
    Agent.update(pid, fn state ->
      %{state | overlay: Map.put(state.overlay, {table, id}, record)}
    end)
  end

  @doc "The row the transaction has written, if it has written one."
  @spec get_overlay(pid(), atom(), String.t()) :: {:ok, map()} | :error
  def get_overlay(pid, table, id) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.overlay, {table, id}) do
        {:ok, record} -> {:ok, record}
        :error -> :error
      end
    end)
  end

  @doc "Every row the transaction has written for a table."
  @spec overlay_rows(pid(), atom()) :: [map()]
  def overlay_rows(pid, table) do
    Agent.get(pid, fn state ->
      for {{^table, _id}, record} <- state.overlay, do: record
    end)
  end

  @doc "Stops the accumulator."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end
end
