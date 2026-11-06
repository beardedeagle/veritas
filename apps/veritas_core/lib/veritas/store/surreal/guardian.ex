defmodule Veritas.Store.Surreal.Guardian do
  @moduledoc """
  The guardian: the program that holds the datastore and outlives the node.

  ## What it is for

  The datastore is a separate process (ADR-048) and the node is its parent.
  OTP's contract for a program a node starts is that the program notices
  that its parent is gone: the node closes the port, the program's standard
  input reaches its end. `surreal` does not read its standard input, so it
  does not notice, and a node that was killed outright — `kill -9`, a panic
  in the emulator, a machine that lost power — would leave the datastore
  running with nobody supervising it.

  The guardian closes that gap. It holds the datastore, and it watches for
  the node in two ways:

    * **the node's end of the guardian's standard input** — when the node
      dies, the kernel closes the pipe, the read ends, and the guardian
      stops the datastore. This is the portable signal: it needs no program
      on the host, no shell, and no platform's idea of a process id;
    * **the node's own process** — checked every second, as a belt to the
      channel, for a node whose channel did not end.

  When the node asks the guardian to stop — it writes `stop` to the
  guardian's standard input — the guardian stops the datastore and lets it
  flush its data directory, and the exit status the node sees is the
  datastore's.

  ## How it is started

  The node starts the guardian with **the emulator it is already running
  on**: `erts/bin/erl`, from `:code.root_dir/0`. So the guardian is the same
  program on every platform, it needs no interpreter the release does not
  already carry, and a development checkout and a release run the same code.
  There is no script, and nothing to keep in step with a script.

  The datastore's command arrives in the **environment** rather than in the
  arguments, because the emulator parses the arguments that follow `-run` as
  its own: `--no-banner` would be eaten by the emulator rather than passed
  to the datastore.

  ## The contract it keeps

    * the pidfile holds the datastore's own process id and its port, in
      that order, and the guardian removes it when it goes;
    * the exit status the node sees is the datastore's;
    * the datastore is stopped by a request, so it flushes its data
      directory on the way out.
  """

  alias Veritas.Dev.Process, as: OsProcess

  # The line the node writes to the guardian's standard input to ask it to
  # stop the datastore.
  @stop_command "stop"

  # How often the node's own process is checked, as a belt to the channel.
  @poll_interval_ms 1_000

  @command_var "VERITAS_STORE_COMMAND"
  @pidfile_var "VERITAS_STORE_PIDFILE"
  @port_var "VERITAS_STORE_PORT"
  @beam_pid_var "VERITAS_BEAM_PID"

  @doc """
  The command that starts the guardian: the emulator, and its arguments.

  The node starts the guardian with this command and the datastore's own
  command in the environment.
  """
  @spec command() :: {Path.t(), [String.t()]}
  def command do
    {emulator(), ["-noshell", "-pa", elixir_path(), "-pa", core_path(), "-run", module(), "main"]}
  end

  @doc """
  The entry point of the guardian program.

  The program halts with the datastore's status, which is what the node
  sees when the port closes.

  The emulator's `-run` calls the function with no arguments when there are
  none, so the entry point is `main/0`; `main/1` is here for the same
  program run as an escript, where the arguments arrive as a list.
  """
  @spec main() :: no_return()
  def main do
    System.halt(run([], System.get_env()))
  end

  @doc """
  The entry point of the guardian program, with arguments.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    System.halt(run(argv, System.get_env()))
  end

  @doc """
  Runs the guardian and returns the status it should exit with.

  `main/1` is the program's entry point and halts the emulator with this
  status. A test calls this instead, because a test cannot halt the VM it
  is running in.
  """
  @spec run([String.t()], map()) :: non_neg_integer()
  def run(_argv, env) do
    with {:ok, command} <- store_command(env),
         {:ok, port} <- start_store(command) do
      write_pidfile(env, port)
      watch()
      loop(port, env, false)
    else
      {:error, reason} ->
        write(:standard_io, "the guardian could not start the datastore: #{inspect(reason)}\n")
        1
    end
  end

  # ── the loop ───────────────────────────────────────────────────────────────

  # The loop ends when the datastore ends: the guardian's status is the
  # datastore's status, and the pidfile goes with it.
  defp loop(port, env, stopping?) do
    receive do
      {^port, {:data, data}} ->
        # The datastore's own output belongs to the node, which is where it
        # is read from.
        write(:standard_io, data)
        loop(port, env, stopping?)

      {^port, {:exit_status, status}} ->
        remove_pidfile(env)
        status

      # The node asked the guardian to stop the datastore.
      {:node, :stop} ->
        loop(port, env, stop_store(port, stopping?))

      # The node is gone: its end of the channel closed.
      {:node, :gone} ->
        loop(port, env, stop_store(port, stopping?))

      :poll ->
        loop(port, env, poll(port, env, stopping?))
    end
  end

  # The node's own process, checked as a belt to the channel.
  defp poll(port, env, stopping?) do
    case node_pid(env) do
      nil -> stopping?
      pid -> if OsProcess.alive?(pid), do: stopping?, else: stop_store(port, stopping?)
    end
  end

  # The datastore is asked to stop, once. It is asked rather than killed, so
  # that it flushes its data directory on the way out.
  defp stop_store(port, stopping?) do
    if stopping? do
      true
    else
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          _ = OsProcess.stop(pid)
          true

        nil ->
          true
      end
    end
  end

  # ── the watchers ───────────────────────────────────────────────────────────

  # The reader watches the node's end of the channel. It is a process of its
  # own because the read blocks, and the loop must keep answering the
  # datastore while it does.
  defp watch do
    parent = self()

    spawn(fn -> read_channel(parent) end)
    spawn(fn -> ticker(parent) end)
  end

  defp read_channel(parent) do
    case :io.get_line(:standard_io) do
      line when is_list(line) ->
        if String.trim(List.to_string(line)) == @stop_command do
          write(:standard_io, "the guardian: the node asked for the store to stop\n")
          send(parent, {:node, :stop})
        else
          read_channel(parent)
        end

      # The node's end of the channel closed: the node is gone.
      :eof ->
        write(:standard_io, "the guardian: the node's end of the channel closed\n")
        send(parent, {:node, :gone})

      {:error, _reason} ->
        write(:standard_io, "the guardian: the node's end of the channel failed\n")
        send(parent, {:node, :gone})
    end
  end

  defp ticker(parent) do
    Process.sleep(@poll_interval_ms)
    send(parent, :poll)
    ticker(parent)
  end

  # The datastore's own command, as the node wrote it into the environment.
  defp store_command(env) do
    case env[@command_var] do
      nil -> {:error, :no_command}
      "" -> {:error, :no_command}
      command -> {:ok, command}
    end
  end

  # ── the datastore ──────────────────────────────────────────────────────────

  # The datastore is started as the guardian's own child, so the guardian
  # holds it: the guardian is what stops it, and the guardian is what the
  # node's death takes away.
  defp start_store(command) do
    {program, arguments} = split_command(command)

    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, arguments}
      ])

    {:ok, port}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp split_command(command) do
    case String.split(command, "\n", trim: true) do
      [program | arguments] -> {program, arguments}
      [] -> raise ArgumentError, "the datastore's command is empty"
    end
  end

  # ── the pidfile ────────────────────────────────────────────────────────────

  # The pidfile holds the datastore's own process id and the port it is
  # reached on, in that order. It is the datastore's id and not the
  # guardian's, because it is what an operator needs, and what a test needs
  # to stop the datastore on its own.
  defp write_pidfile(env, port) do
    path = env[@pidfile_var]

    if path && path != "" do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          File.write(path, "#{pid} #{env[@port_var]}\n")

        nil ->
          :ok
      end
    end

    :ok
  end

  defp remove_pidfile(env) do
    path = env[@pidfile_var]

    if path && path != "" do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          write(:standard_io, "the guardian could not remove #{path}: #{inspect(reason)}\n")
          :ok
      end
    end

    :ok
  end

  # ── the node ───────────────────────────────────────────────────────────────

  defp node_pid(env) do
    case env[@beam_pid_var] do
      nil -> nil
      "" -> nil
      "0" -> nil
      value -> parse_pid(value)
    end
  end

  defp parse_pid(value) do
    case Integer.parse(String.trim(value)) do
      {pid, _rest} -> pid
      :error -> nil
    end
  end

  # ── the program ────────────────────────────────────────────────────────────

  # The emulator the node is running on. The guardian is started by the same
  # ERTS that runs the node, so a release needs nothing extra to run it.
  defp emulator do
    Path.join([List.to_string(:code.root_dir()), "bin", "erl"])
  end

  # The Elixir runtime, so the guardian's own code can be loaded. A release
  # carries it, and a checkout has it.
  #
  # `:code.lib_dir/1` answers with the application's own directory, and the
  # code is one level down in it.
  defp elixir_path do
    case :code.lib_dir(:elixir) do
      {:error, _reason} ->
        Path.join([List.to_string(:code.root_dir()), "lib", "elixir", "ebin"])

      path ->
        Path.join(List.to_string(path), "ebin")
    end
  end

  # This application's own code: the guardian is a module of it.
  defp core_path do
    Application.app_dir(:veritas_core, "ebin")
  end

  # The Erlang module name of the guardian's entry point.
  defp module do
    "Elixir.Veritas.Store.Surreal.Guardian"
  end

  defp write(device, data) do
    _ = :file.write(device, data)
    :ok
  end

  @doc """
  The environment the datastore's command is passed in.

  The command is one argument per line, because an argument may contain
  anything a path may contain and a line may not.
  """
  @spec command_line([String.t()]) :: String.t()
  def command_line(arguments) do
    Enum.join(arguments, "\n")
  end

  @doc """
  The name of the variable the datastore's command travels in.
  """
  @spec command_variable() :: String.t()
  def command_variable, do: @command_var
end
