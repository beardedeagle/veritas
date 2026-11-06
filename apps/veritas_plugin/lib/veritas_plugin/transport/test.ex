defmodule Veritas.Plugin.Transport.Test do
  @moduledoc """
  A transport that never opens a socket: the harness a Plugin author tests
  against.

  Plug ships `Plug.Test` for the same reason. A request model that needs no
  socket is what makes an adapter testable at all, because the alternative is
  a test that starts a process, waits for a port, and fails when the machine
  is busy. The plugin boundary has the same problem and the same answer.

  So this adapter holds two queues instead of a socket:

    * the frames the **peer** sent — pushed with `push/2`;
    * the frames the **host** sent — read with `sent/1`.

  A test drives the host API against it without a Plugin process, a port, a
  handshake or a timer.

      {:ok, transport} = Veritas.Plugin.Transport.Test.new()
      Veritas.Plugin.Transport.Test.push(transport, ~s({"jsonrpc":"2.0","result":"hello"}))

      assert {:ok, "hello"} =
               Veritas.Plugin.Transport.Test.receive_message(transport, 1_000)

  This module is **Default**: it is a harness, and a harness is substitutable
  without touching the boundary it exercises.
  """

  @behaviour Veritas.Plugin.Transport

  @type t :: %__MODULE__{agent: pid()}

  defstruct [:agent]

  @doc "Creates a transport with two empty queues."
  @spec new() :: {:ok, t()} | {:error, term()}
  def new do
    Agent.start_link(fn -> %{inbox: [], sent: []} end)
  end

  @doc """
  Queues a frame as if the peer had sent it.
  """
  @spec push(t(), binary()) :: :ok
  def push(%__MODULE__{agent: agent}, frame) when is_binary(frame) do
    Agent.update(agent, fn state -> %{state | inbox: state.inbox ++ [frame]} end)
  end

  @doc """
  The frames the host has sent, oldest first.
  """
  @spec sent(t()) :: [binary()]
  def sent(%__MODULE__{agent: agent}) do
    Agent.get(agent, fn state -> state.sent end)
  end

  @doc """
  Takes a frame the host sent, oldest first.

  Returns `{:error, :timeout}` when the host has sent nothing.
  """
  @spec take_sent(t()) :: {:ok, binary()} | {:error, :timeout}
  def take_sent(%__MODULE__{agent: agent}) do
    Agent.get_and_update(agent, fn state ->
      case state.sent do
        [frame | rest] -> {{:ok, frame}, %{state | sent: rest}}
        [] -> {{:error, :timeout}, state}
      end
    end)
  end

  @doc "Listening is a no-op: there is no socket to listen on."
  @impl true
  @spec listen(String.t()) :: {:ok, t()} | {:error, term()}
  def listen(_path), do: {:ok, %__MODULE__{agent: nil}}

  @doc "Accepting is a no-op: there is no peer to accept."
  @impl true
  @spec accept(t(), timeout()) :: {:ok, t()} | {:error, term()}
  def accept(%__MODULE__{} = transport, _timeout), do: {:ok, transport}

  @doc "Connecting is a no-op: there is no socket to connect to."
  @impl true
  @spec connect(String.t(), timeout()) :: {:ok, t()} | {:error, term()}
  def connect(_path, _timeout), do: {:ok, %__MODULE__{agent: nil}}

  @doc "Records the frame in the sent queue."
  @impl true
  @spec send_message(t(), binary()) :: :ok | {:error, term()}
  def send_message(%__MODULE__{agent: nil}, _frame), do: :ok

  def send_message(%__MODULE__{agent: agent}, frame) when is_binary(frame) do
    Agent.update(agent, fn state -> %{state | sent: state.sent ++ [frame]} end)
  end

  @doc "Takes a queued frame from the peer."
  @impl true
  @spec receive_message(t(), timeout()) :: {:ok, binary()} | {:error, term()}
  def receive_message(%__MODULE__{agent: nil}, _timeout), do: {:error, :closed}

  def receive_message(%__MODULE__{agent: agent}, _timeout) do
    Agent.get_and_update(agent, fn state ->
      case state.inbox do
        [frame | rest] -> {{:ok, frame}, %{state | inbox: rest}}
        [] -> {{:error, :timeout}, state}
      end
    end)
  end

  @doc "Closing is a no-op: there is nothing to close."
  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok
end
