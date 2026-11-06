defmodule Veritas.Core.Test.FakeProcess do
  @moduledoc """
  A stand-in for the platform adapter.

  The process policy is decision-making, so it is proved against facts
  rather than against a host: this adapter holds the facts a test wants and
  answers the port's questions from them. The tests that use it therefore
  run unchanged on Windows and Linux, and on a machine with no `lsof` and
  no `tasklist`.
  """

  @behaviour Veritas.Dev.Process

  @doc "Replaces the facts."
  def put_listeners(listeners), do: Application.put_env(:veritas_core, :fake_listeners, listeners)

  @doc "The pids the fake was asked to stop."
  def stopped, do: Application.get_env(:veritas_core, :fake_stopped, [])

  @doc """
  The pids the fake will refuse to stop.

  A host that will not let this session signal a process — because it belongs
  to another session — refuses it, and the policy has to be able to say so.
  """
  def put_stopping_failures(pids) do
    Application.put_env(:veritas_core, :fake_stop_failures, pids)
  end

  @doc """
  The processes that hold no listening socket, as `%{pid => description}`.

  A bench or a worker holds no socket, and the registry is what covers it.
  """
  def put_processes(processes) do
    Application.put_env(:veritas_core, :fake_processes, processes)
  end

  @impl Veritas.Dev.Process
  def listeners do
    {:ok, Application.get_env(:veritas_core, :fake_listeners, [])}
  end

  @impl Veritas.Dev.Process
  def describe(pid) do
    case Enum.find(Application.get_env(:veritas_core, :fake_listeners, []), &(&1.pid == pid)) do
      nil ->
        case Map.get(Application.get_env(:veritas_core, :fake_processes, %{}), pid) do
          nil -> {:error, :not_found}
          description -> {:ok, description}
        end

      listener ->
        {:ok, %{pid: pid, executable: listener.executable, attachments: listener.attachments}}
    end
  end

  @impl Veritas.Dev.Process
  def alive?(pid) do
    Enum.any?(Application.get_env(:veritas_core, :fake_listeners, []), &(&1.pid == pid))
  end

  @impl Veritas.Dev.Process
  def stop(pid) do
    Application.put_env(
      :veritas_core,
      :fake_stopped,
      Application.get_env(:veritas_core, :fake_stopped, []) ++ [pid]
    )

    if pid in Application.get_env(:veritas_core, :fake_stop_failures, []) do
      {:error, :not_permitted}
    else
      :ok
    end
  end

  @impl Veritas.Dev.Process
  def started_at(_pid), do: {:ok, 1_000_000}

  @impl Veritas.Dev.Process
  def start(command, _opts) do
    Application.put_env(:veritas_core, :fake_started, command)
    {:ok, %{pid: 4242, log: "/tmp/veritas-launch.log"}}
  end

  @doc "The command the fake was asked to start."
  def started, do: Application.get_env(:veritas_core, :fake_started)
end
