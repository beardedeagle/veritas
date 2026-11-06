defmodule Mix.Tasks.Veritas.Secrets do
  @moduledoc """
  Scans the repository for secrets that must not be committed.

      mix veritas.secrets          # the full git history
      mix veritas.secrets path     # a built artefact as well

  The scan is [gitleaks'](https://github.com/gitleaks/gitleaks): it reads the
  repository's whole history rather than the working tree, because a secret is
  still a secret after it is deleted, and it reports the rule it matched
  rather than the value.

  Two places are scanned, because they fail differently. The history is
  scanned in every run, because a credential committed once is in the history
  for as long as the repository exists. A built artefact is scanned when a
  path is given, because a release carries whatever its build carried, and a
  binary that ships a key ships the key whether or not the source ever held
  it.

  The tool is not vendored: it is a pinned binary installed by the pipeline and
  expected on `PATH` here. A scan that cannot run is a failure, never a pass.
  """

  use Mix.Task

  @shortdoc "Scans the repository history, and a built artefact, for secrets"

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, strict: [])

    root = Mix.Tasks.Veritas.Toolchain.project_root()
    gitleaks = gitleaks!()

    Mix.shell().info("secret scan: the git history")

    history =
      System.cmd(
        gitleaks,
        ["git", "--redact", "--no-banner", "--exit-code", "1", "."],
        cd: root,
        stderr_to_stdout: true
      )

    status = report(history, "the git history")

    artefact =
      case rest do
        [] ->
          :ok

        [path] ->
          Mix.shell().info("secret scan: #{path}")

          built =
            System.cmd(
              gitleaks,
              ["dir", "--redact", "--no-banner", "--exit-code", "1", path],
              cd: root,
              stderr_to_stdout: true
            )

          report(built, path)

        _ ->
          Mix.raise("usage: mix veritas.secrets [path]")
      end

    if failed?(status) or failed?(artefact) do
      Mix.raise("""
      a secret was found.

      The output above names the rule that matched. The value is redacted, and
      it is still in the repository or in the artefact: remove it, and if it
      was a credential, change it.
      """)
    end

    unless opts[:quiet] do
      Mix.shell().info("no secrets found")
    end

    :ok
  end

  defp report({output, status}, what) do
    unless String.contains?(output, "no leaks found") do
      Mix.shell().info(output)
    end

    if status == 0 do
      Mix.shell().info("  #{what}: clean")
    else
      Mix.shell().error("  #{what}: secrets found")
    end

    status
  end

  # `:ok` is the sentinel for a scan that was not run — no artefact was given.
  defp failed?(:ok), do: false
  defp failed?(status), do: status != 0

  defp gitleaks! do
    case System.find_executable("gitleaks") do
      nil ->
        Mix.raise("""
        gitleaks is not on PATH.

        The secret scan cannot run without it, and a scan that cannot run is
        not a pass. The pipeline installs a pinned release and verifies it
        against the published checksums; the same installation is one command
        away:

            bash .github/scripts/install-gitleaks.sh
        """)

      path ->
        path
    end
  end
end
