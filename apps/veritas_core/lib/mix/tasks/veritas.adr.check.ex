defmodule Mix.Tasks.Veritas.Adr.Check do
  @shortdoc "Checks the Decision Register against the records in docs/adr"

  @moduledoc """
  Checks the Decision Register table in `docs/16-decision-register.md` against
  the records in `docs/adr/`.

      mix veritas.adr.check

  The register is the corpus's record of what was decided, and a record is
  worth nothing if the table and the files beside it disagree. The check
  compares them and fails on the disagreement, naming the identifier it is
  about.

  ## Where it looks

  The repository root is found by walking up from the current directory, so
  the task works from the root and from any application inside it.
  `--root PATH` checks a different tree instead — a checkout, a candidate
  branch, or a copy of the corpus — which is what makes the check usable on
  a tree that is not the one it is run from.

      mix veritas.adr.check --root /path/to/a/candidate/corpus

  ## The direction of the comparison

  **File → row, never row → file.** The Decision Register table is the source
  of truth, and the check never re-renders it from the files: a register
  generated from its own records cannot disagree with them, and can only
  lose the decisions the records never carried.

  ## What it fails on

    * **R1** — the table holds two rows for one identifier.
    * **R2** — the identifier sequence has a gap.
    * **R3** — a row does not have the columns the table's header declares.
    * **F1** — a record presents a Decision for an identifier the table lacks.
    * **F2** — two files present a Decision for the same identifier.
    * **F3** — a record's `**Status.**` and its row's Status cell differ.
    * **F4** — a record path the register names does not exist, or an identifier is claimed by a file that presents no Decision while no record file carries it.
    * **F5** — a record's Decision paragraph no longer matches its row, or its fingerprint does not match its Decision paragraph.

  A **file that names an identifier and presents no Decision of its own is a
  pointer, not a claim**, so a leftover stub is reported rather than counted
  as a second claim against the identifier it points at.

  ## What it reports without failing

  A pointer stub, a record with no fingerprint line, a record that restates
  the register's extent, a record whose name is off the convention, and a
  stated extent or next free identifier that disagrees with the table.

  ## Where the rule is written

  `docs/16` §ADR Process states the rule this task enforces, and
  `docs/16` §Register Integrity states why a register is append-only. The
  task reads both of them; it writes neither.
  """

  use Mix.Task

  alias Veritas.Core.Docs.AdrCheck

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [quiet: :boolean, root: :string])

    root = opts[:root] || project_root()
    register = Path.join([root, "docs", "16-decision-register.md"])
    records = Path.join([root, "docs", "adr"])

    case AdrCheck.check(register, records) do
      {:ok, report} -> agree(report, opts)
      {:error, report} -> disagree(report, opts)
    end
  end

  @doc """
  The repository's root, found by walking up from the current directory.

  The root is the directory that holds the register document, because the
  check is about that document and the records beside it.
  """
  @spec project_root() :: Path.t()
  def project_root do
    Path.expand(".")
    |> find_root()
    |> case do
      nil ->
        Mix.raise(
          "no docs/16-decision-register.md found above #{Path.expand(".")}. " <>
            "The decision register lives at the root of the repository."
        )

      root ->
        root
    end
  end

  defp find_root(dir) do
    if File.exists?(Path.join(dir, "docs/16-decision-register.md")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        nil
      else
        find_root(parent)
      end
    end
  end

  defp agree(report, opts) do
    unless opts[:quiet], do: print_summary(report)
    :ok
  end

  defp disagree(report, opts) do
    unless opts[:quiet], do: print_summary(report)

    Mix.shell().error("")
    Mix.shell().error("failures")

    Enum.each(report.failures, &print_failure/1)

    Mix.raise("""
    the decision register does not agree with the records in docs/adr.

    #{Enum.map_join(report.failures, "\n", fn failure -> "  * #{failure.class} #{failure.identifier || ""} — #{failure.message}" end)}

    The register is the corpus's record of what was decided. A reader who
    follows a number to a decision has to arrive at the decision that was
    actually taken, so the table and the records beside it have to agree.

    A drift in an **Accepted** decision's record is repaired by a
    **superseding ADR**, never by editing the record or the row in place.
    A row that was never filed is filed. A record that was never absorbed is
    absorbed or removed.
    """)
  end

  defp print_summary(report) do
    Mix.shell().info("decision register")
    Mix.shell().info("  docs/16-decision-register.md")
    Mix.shell().info("  #{extent_line(report)}")
    Mix.shell().info("  docs/adr — #{report.records} record(s), #{report.pointers} pointer(s)")

    if report.warnings != [] do
      Mix.shell().info("")
      Mix.shell().info("warnings")

      Enum.each(report.warnings, &print_warning/1)
    end
  end

  defp extent_line(report) do
    case report.extent do
      nil ->
        "#{report.rows} row(s), no identifier range"

      {first, last} ->
        "#{report.rows} row(s), ADR-#{pad(first)} … ADR-#{pad(last)}, " <>
          "#{report.rows} identifier(s), contiguous and one row per decision"
    end
  end

  defp print_failure(failure) do
    Mix.shell().error("  #{failure.class} #{failure.identifier || ""} — #{failure.message}")

    Enum.each(failure.detail, fn detail ->
      Mix.shell().error("      #{detail}")
    end)
  end

  defp print_warning(warning) do
    Mix.shell().info("  #{warning.class} #{warning.identifier || ""} — #{warning.message}")
  end

  defp pad(number), do: String.pad_leading(Integer.to_string(number), 3, "0")
end
