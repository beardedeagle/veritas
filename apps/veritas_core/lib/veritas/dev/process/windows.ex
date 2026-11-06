defmodule Veritas.Dev.Process.Windows do
  @moduledoc """
  The Windows adapter: the same facts, gathered with the Windows tools.

  **This adapter has not been executed on Windows.** The CI matrix
  (`docs/11`) builds and tests on Windows, and that is where this adapter
  gets proven; until it has run there, treat it as written-and-unproven
  rather than as working.

  ## The attachments

  A Windows process is attached to its **executable's path** and to the
  **path-shaped tokens in its command line** — the arguments that name a
  path. The policy asks the same question of them as it asks of the Unix
  attachments: *is any of them under the project root?* The rule is not
  written twice.

  ## Why the tools are what they are

  The listener table comes from `netstat -ano`, which reports the pid of
  the owning process; the process table comes from the CIM query, which
  reports the executable path and the command line. Neither is a name-only
  rule: the executable's *path* and the command line's *paths* are what the
  policy reads.

  ## The launcher

  The detached start is PowerShell's `Start-Process`, because it is the
  Windows tool that reports the child's pid — and the registry needs the
  child's pid, not a wrapper's. `cmd`'s `start` does not report one, and a
  wrapper's pid would name a `cmd.exe`, which the policy would not recognise
  as a Veritas process to stop.

  Windows will not redirect two streams to one file, so the child's standard
  error goes to the log's `.err` sibling and its standard output goes to the
  log itself.
  """

  @behaviour Veritas.Dev.Process

  @impl Veritas.Dev.Process
  def listeners do
    case run(["netstat", "-ano", "-p", "TCP"]) do
      {:ok, output} -> {:ok, parse_listeners(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def describe(pid) when is_integer(pid) do
    case run([
           "powershell",
           "-NoProfile",
           "-Command",
           "Get-CimInstance Win32_Process -Filter \"ProcessId=#{pid}\" | " <>
             "ForEach-Object { $_.ExecutablePath + '|' + $_.CommandLine }"
         ]) do
      {:ok, output} ->
        {executable, command_line} = split_line(output)

        {:ok,
         %{
           pid: pid,
           executable: executable || "",
           attachments: [executable | path_tokens(command_line)]
         }
         |> Enum.map(fn
           %{attachments: attachments} = description ->
             %{description | attachments: attachments |> Enum.reject(&is_nil/1) |> Enum.uniq()}

           description ->
             description
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def alive?(pid) when is_integer(pid) do
    case run(["tasklist", "/FI", "PID eq #{pid}", "/NH"]) do
      {:ok, output} -> String.contains?(output, Integer.to_string(pid))
      {:error, _reason} -> false
    end
  end

  @impl Veritas.Dev.Process
  def stop(pid) when is_integer(pid) do
    case run(["taskkill", "/PID", Integer.to_string(pid), "/T"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def started_at(pid) when is_integer(pid) do
    script =
      "(Get-Process -Id #{pid}).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"

    case run(["powershell", "-NoProfile", "-Command", script]) do
      {:ok, output} ->
        case DateTime.from_iso8601(String.trim(output)) do
          {:ok, started_at, _offset} -> {:ok, DateTime.to_unix(started_at)}
          {:error, _reason} -> {:error, :unreadable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Veritas.Dev.Process
  def start(command, opts) when is_list(command) do
    log = Keyword.get(opts, :log) || Path.join(System.tmp_dir!(), "veritas-launch.log")
    {program, arguments} = split_command(command)

    # PowerShell's `Start-Process` is the Windows equivalent of the detached
    # start: it returns as soon as the child is running, it redirects the
    # child's output, and `-PassThru` prints the child's pid. `cmd`'s `start`
    # cannot print a pid, and the registry needs one, so it is not used here.
    #
    # Windows will not redirect two streams to one file, so the child's
    # standard error goes to the log's `.err` sibling.
    script =
      "$p = Start-Process -FilePath #{powershell_string(program)} " <>
        "-ArgumentList #{powershell_arguments(arguments)} " <>
        "-RedirectStandardOutput #{powershell_string(log)} " <>
        "-RedirectStandardError #{powershell_string(log <> ".err")} " <>
        "-WindowStyle Hidden -PassThru; $p.Id"

    case run(["powershell", "-NoProfile", "-Command", script]) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {pid, _rest} ->
            {:ok, %{pid: pid, log: log}}

          :error ->
            {:error, {:no_pid, String.trim(output)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the parsing ────────────────────────────────────────────────────────────

  defp parse_listeners(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&listener_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp listener_row(line) do
    fields = String.split(line, ~r/\s+/, trim: true)

    with true <- List.last(fields) |> is_binary(),
         {port, _} when port > 0 <- fields |> Enum.at(1) |> to_port(),
         {pid, _} when pid > 0 <- fields |> List.last() |> to_pid() do
      %{pid: pid, port: port, executable: "", attachments: []}
    else
      _ -> nil
    end
  end

  defp to_port(nil), do: :error
  defp to_port(value), do: Integer.parse(String.replace(value, ":", ""))

  defp to_pid(nil), do: :error
  defp to_pid(value), do: Integer.parse(value)

  defp split_line(output) do
    case String.split(String.trim(output), "|", parts: 2) do
      [executable, command_line] -> {blank_to_nil(executable), command_line}
      _ -> {nil, nil}
    end
  end

  # The path-shaped tokens of a command line: the arguments that name a
  # path. A token is a path when it carries a separator or a drive letter.
  defp path_tokens(nil), do: []

  defp path_tokens(command_line) do
    command_line
    |> String.split(~r/\s+/)
    |> Enum.filter(fn token ->
      String.contains?(token, "/") or String.contains?(token, "\\") or
        String.match?(token, ~r/^[A-Za-z]:/)
    end)
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp split_command([program | arguments]), do: {program, arguments}
  defp split_command([]), do: {"", []}

  # A PowerShell single-quoted string; a literal quote is doubled.
  #
  # Named `powershell_string/1` rather than `quote/1`, because `Kernel`
  # already has a `quote/1` macro and a local function of that name cannot
  # take its place.
  defp powershell_string(value) do
    "'" <> String.replace(to_string(value), "'", "''") <> "'"
  end

  # `Start-Process` joins the argument list with spaces, so an argument that
  # contains a space is quoted again for the command line it builds.
  defp powershell_arguments(arguments) do
    "@(" <> Enum.map_join(arguments, ",", &powershell_argument/1) <> ")"
  end

  defp powershell_argument(value) do
    string = to_string(value)

    if String.contains?(string, " ") do
      powershell_string("\"" <> String.replace(string, "\"", "\\\"") <> "\"")
    else
      powershell_string(string)
    end
  end

  defp run(command) do
    case System.cmd(hd(command), tl(command), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {command, status, output}}
    end
  rescue
    error -> {:error, error}
  end
end
