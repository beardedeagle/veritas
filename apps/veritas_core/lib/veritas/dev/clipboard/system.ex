defmodule Veritas.Dev.Clipboard.System do
  @moduledoc """
  The clipboard, through whatever the host has.

  Candidates are tried in turn; a host with none refuses with
  `{:error, :clipboard_unavailable}`. A zero exit status means the tool
  accepted the bytes, not that another application has pasted them.

  Native stdin transport supplies bytes and EOF without putting the text
  in arguments, environment variables or logs. The temporary directory is
  owner-only (an explicit ACL on Windows); its exclusive file is restricted
  before writing, emptied after use and removed even when a tool fails.
  """

  @behaviour Veritas.Dev.Clipboard

  @candidates [
    {"pbcopy", []},
    {"clip.exe", []},
    {"xclip", ["-selection", "clipboard"]},
    {"wl-copy", []}
  ]

  @impl Veritas.Dev.Clipboard
  def copy(text) when is_binary(text) do
    candidates =
      for {command, arguments} <- @candidates,
          executable = System.find_executable(command),
          executable != nil,
          do: {executable, arguments}

    if candidates != [] and with_input(text, candidates),
      do: :ok,
      else: {:error, :clipboard_unavailable}
  rescue
    _error -> {:error, :clipboard_unavailable}
  end

  defp with_input(text, candidates) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "veritas-clipboard-#{Base.encode16(:crypto.strong_rand_bytes(16))}"
      )

    path = Path.join(directory, "input")

    # Never enter or clean up a directory we did not create exclusively.
    case File.mkdir(directory) do
      :ok ->
        try do
          with :ok <- restrict_directory(directory),
               {:ok, result} <-
                 File.open(path, [:write, :exclusive, :binary], fn file ->
                   try do
                     with :ok <- File.chmod(path, 0o600),
                          :ok <- IO.binwrite(file, text) do
                       Enum.any?(candidates, &try_candidate(&1, path))
                     else
                       _ -> false
                     end
                   after
                     # An unlink failure must not leave the plaintext behind.
                     {:ok, 0} = :file.position(file, :bof)
                     :ok = :file.truncate(file)
                   end
                 end) do
            result
          else
            _ -> false
          end
        after
          case File.rm(path) do
            :ok ->
              :ok

            {:error, :enoent} ->
              :ok

            {:error, reason} ->
              raise File.Error, reason: reason, action: "remove clipboard input", path: path
          end

          File.rmdir!(directory)
        end

      _ ->
        false
    end
  end

  defp restrict_directory(directory) do
    case :os.type() do
      {:win32, _} ->
        # chmod does not establish a Windows access-control boundary.
        script = """
        $ErrorActionPreference = 'Stop'
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $env:VERITAS_CLIPBOARD_DIRECTORY -AclObject $acl
        """

        case powershell(script, [{"VERITAS_CLIPBOARD_DIRECTORY", directory}]) do
          {_, 0} -> :ok
          _ -> {:error, :clipboard_unavailable}
        end

      _ ->
        File.chmod(directory, 0o700)
    end
  end

  defp try_candidate({executable, arguments}, path) do
    environment = [
      {"VERITAS_CLIPBOARD_INPUT", path},
      {"VERITAS_CLIPBOARD_EXECUTABLE", executable}
    ]

    result =
      case :os.type() do
        {:win32, _} ->
          # Stream bytes through .NET, avoiding cmd.exe's argument reparsing.
          script = """
          $ErrorActionPreference = 'Stop'
          $start = [System.Diagnostics.ProcessStartInfo]::new()
          $start.FileName = $env:VERITAS_CLIPBOARD_EXECUTABLE
          $start.Arguments = $env:VERITAS_CLIPBOARD_ARGUMENTS
          $start.UseShellExecute = $false
          $start.RedirectStandardInput = $true
          $start.RedirectStandardOutput = $true
          $start.RedirectStandardError = $true
          $process = [System.Diagnostics.Process]::Start($start)
          $stdout = $process.StandardOutput.ReadToEndAsync()
          $stderr = $process.StandardError.ReadToEndAsync()
          try {
            $inputFile = [System.IO.File]::OpenRead($env:VERITAS_CLIPBOARD_INPUT)
            try { $inputFile.CopyTo($process.StandardInput.BaseStream) }
            finally { $inputFile.Dispose(); $process.StandardInput.Close() }
            $process.WaitForExit()
            exit $process.ExitCode
          } finally {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
          }
          """

          powershell(script, [
            {"VERITAS_CLIPBOARD_ARGUMENTS", Enum.join(arguments, " ")} | environment
          ])

        _ ->
          System.cmd(
            "/bin/sh",
            [
              "-c",
              ~s(exec "$@" < "$VERITAS_CLIPBOARD_INPUT" > /dev/null 2>&1),
              "clipboard",
              executable | arguments
            ],
            env: environment,
            stderr_to_stdout: true
          )
      end

    match?({_output, 0}, result)
  rescue
    _error -> false
  end

  # Only fixed scripts are encoded; the secret stays in the private input file.
  defp powershell(script, environment) do
    encoded = script |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> Base.encode64()

    System.cmd(
      "powershell.exe",
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
      env: environment,
      stderr_to_stdout: true
    )
  end
end
