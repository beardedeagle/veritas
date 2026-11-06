defmodule Veritas.Dev.Process.Unix do
  @moduledoc """
  The Unix adapter: the facts, gathered with `lsof`.

  `lsof` is the one tool that answers both questions on a Unix host — which
  processes hold a listening socket, and what a process is attached to — and
  it is present on macOS and on the Linux images the CI matrix builds.

  ## The attachments

  A Unix process is attached to its **working directory** and to the **files
  it has open**. Both are read from the file-descriptor table, and the
  working directory is read from the *fd table* rather than with
  `lsof -d cwd`: on this platform the filtered form reports every thread's
  cwd as `/`, which would make every process look like it lives at the root
  and would make the whole policy wrong.

  ## The liveness probe

  `kill -0` is the kernel's own answer to *does a process with this id
  exist?*: it sends no signal and consults only the process table. The probe
  fails in two different ways, and the difference is the whole answer:

    * "No such process" — the process is gone;
    * "Operation not permitted" — the process is there, and this session is
      not allowed to signal it.

  A session that may not signal a process still knows it is there. A probe
  that reads only the exit status calls such a process dead, and a liveness
  answer built on that is a false green: a leak check reports a clean host
  while a process is running.
  """

  @behaviour Veritas.Dev.Process

  # The liveness probe reads the wording of its own failure, so that wording
  # must not depend on the locale the host is set to: the probe is run in the
  # C locale, where the wording is the C library's. The environment is
  # **merged**, not replaced, so `PATH` still finds `kill`.
  @c_locale [{"LC_ALL", "C"}]

  @impl Veritas.Dev.Process
  def listeners do
    case run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"]) do
      {:ok, output} -> {:ok, parse_listeners(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def describe(pid) when is_integer(pid) do
    case run(["lsof", "-nP", "-p", Integer.to_string(pid)]) do
      {:ok, output} ->
        {:ok,
         %{
           pid: pid,
           executable: executable(output) || "",
           attachments: attachments(output)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def alive?(pid) when is_integer(pid) and pid > 0 do
    case run(["kill", "-0", Integer.to_string(pid)], env: @c_locale) do
      {:ok, _output} ->
        true

      {:error, {_command, _status, output}} ->
        # The probe failed. It failed either because the process is gone or
        # because this session may not signal it, and the wording is what
        # says which: only "No such process" means the process is gone.
        not process_absent?(output)

      {:error, _reason} ->
        # The probe could not be run at all — no `kill` on this host, say.
        # That is not evidence that a process has gone, so nothing is
        # called dead.
        true
    end
  end

  def alive?(pid) when is_integer(pid) do
    # Zero and the negative numbers are not process ids: `kill` reads them as
    # a process **group**, so the probe would answer about every process in
    # that group rather than about one process. There is no process with
    # this id.
    _ = pid
    false
  end

  @doc """
  Whether the probe's output reports that the process **does not exist**.

  `kill -0` asks the kernel a question without touching the process: *does a
  process with this id exist?* The question has three answers, and only two
  of them are failures:

    * the process exists and this session may signal it — the probe succeeds;
    * the process exists and this session may **not** signal it — the probe
      fails and says "Operation not permitted";
    * the process does not exist — the probe fails and says "No such process".

  The last two both fail, so the exit status alone cannot tell them apart:
  the wording is what says which one happened. This function is that
  distinction, and it is a function of its own so that it can be proved
  against the wording rather than against a host.

  The wording is compared in lower case, and `ESRCH` — the C library's name
  for the error — is accepted as well as the sentence, so the answer does
  not depend on how the `kill` that answered spelled it.
  """
  @spec process_absent?(String.t()) :: boolean()
  def process_absent?(output) when is_binary(output) do
    downcased = String.downcase(output)

    String.contains?(downcased, "no such process") or String.contains?(downcased, "esrch")
  end

  @impl Veritas.Dev.Process
  def stop(pid) when is_integer(pid) do
    case run(["kill", "-TERM", Integer.to_string(pid)]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def started_at(pid) when is_integer(pid) do
    case run(["ps", "-o", "etime=", "-p", Integer.to_string(pid)]) do
      {:ok, output} ->
        case parse_elapsed(String.trim(output)) do
          {:ok, elapsed} -> {:ok, System.system_time(:second) - elapsed}
          :error -> {:error, :unreadable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def start(command, opts) when is_list(command) do
    log = Keyword.get(opts, :log) || Path.join(System.tmp_dir!(), "veritas-launch.log")
    script = launch_script(command, log)

    # The child is started detached: it keeps running when the caller goes
    # away, and it writes to the log rather than to a pipe that would close.
    # The shell prints the child's pid, which is what the registry records.
    case run(["/bin/sh", "-c", script]) do
      {:ok, output} ->
        case to_pid(String.trim(output)) do
          nil -> {:error, {:no_pid, String.trim(output)}}
          pid -> {:ok, %{pid: pid, log: log}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The shell script that starts the command detached and prints its pid.

  Every word is **quoted**, because the script is a shell script: an argument
  with a space in it would otherwise be split into two words, and an argument
  with a `;` in it would run a second command. The command the caller named
  is the command that runs — nothing else.

  The quoting is POSIX single quoting: a word is wrapped in single quotes, and
  a single quote inside it is closed, escaped and opened again.
  """
  @spec launch_script([String.t()], String.t()) :: String.t()
  def launch_script(command, log) do
    words = Enum.map_join(command, " ", &shell_quote/1)

    "nohup " <> words <> " >> " <> shell_quote(log) <> " 2>&1 & echo $!"
  end

  # A word, quoted for the shell.
  defp shell_quote(word) do
    "'" <> String.replace(to_string(word), "'", "'\\''") <> "'"
  end

  # ── the parsing ────────────────────────────────────────────────────────────

  # `lsof`'s column count changes from line to line, so the port and the pid
  # are found by pattern and never by position.
  defp parse_listeners(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&listener_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp listener_row(line) do
    fields = String.split(line)

    with pid when is_integer(pid) <- to_pid(Enum.at(fields, 1)),
         port when is_integer(port) <- to_port(fields) do
      %{pid: pid, port: port, executable: "", attachments: []}
    else
      _ -> nil
    end
  end

  # The port is the last field that carries one, found by pattern and never
  # by position: `lsof` omits its size column on some lines, so the columns
  # are not in a fixed place.
  defp to_port(fields) do
    fields
    |> Enum.reverse()
    |> Enum.find_value(fn field ->
      case Regex.run(~r/:(\d+)$/, field) do
        [_, digits] -> String.to_integer(digits)
        _ -> nil
      end
    end)
  end

  defp attachments(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&attachment_paths/1)
    |> Enum.uniq()
  end

  # The working directory (the `cwd` row) and the open files, both taken from
  # the fd table.
  defp attachment_paths(line) do
    fields = String.split(line)

    # The file descriptor is the fourth column and the name is the last; the
    # columns in between come and go, so the ends are what are read.
    case Enum.at(fields, 3) do
      fd when fd in ["cwd", "REG", "DIR", "unix"] ->
        case List.last(fields) do
          name when is_binary(name) and name != "" -> [String.trim(name)]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp executable(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      fields = String.split(line)

      if Enum.at(fields, 3) == "txt", do: List.last(fields), else: nil
    end)
  end

  defp to_pid(value) do
    case Integer.parse(value || "") do
      {pid, _} -> pid
      :error -> nil
    end
  end

  # `etime` is the elapsed time since the process started, written as
  # `[[dd-]hh:]mm:ss`. It is the one field both macOS and Linux's `ps` agree
  # on, and it is a whole number of seconds — which is as precise as the
  # comparison needs to be.
  defp parse_elapsed(""), do: :error

  defp parse_elapsed(text) do
    {days, clock} =
      case String.split(text, "-", parts: 2) do
        [days, clock] -> {String.to_integer(days), clock}
        _ -> {0, text}
      end

    case String.split(clock, ":") do
      [hours, minutes, seconds] ->
        {:ok,
         days * 86_400 + String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
           String.to_integer(seconds)}

      [minutes, seconds] ->
        {:ok, days * 86_400 + String.to_integer(minutes) * 60 + String.to_integer(seconds)}

      _ ->
        :error
    end
  end

  defp run(command), do: run(command, [])

  defp run(command, opts) do
    options = [stderr_to_stdout: true] ++ Keyword.take(opts, [:env])

    case System.cmd(hd(command), tl(command), options) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {command, status, output}}
    end
  rescue
    error -> {:error, error}
  end
end
