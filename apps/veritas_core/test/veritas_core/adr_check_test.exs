defmodule Veritas.Core.Docs.AdrCheckTest do
  use ExUnit.Case, async: true

  alias Veritas.Core.Docs.AdrCheck

  @register "docs/16-decision-register.md"
  @records "docs/adr"

  describe "the corpus as it stands" do
    test "the register and the records agree" do
      root = project_root()

      assert {:ok, report} =
               AdrCheck.check(Path.join(root, @register), Path.join(root, @records))

      assert report.failures == []

      # The canary. The register is append-only, so this number moves
      # upward and only upward: a smaller one means a row was lost, which
      # is the catastrophe the loss record in `docs/16` is about. It is
      # raised when a row is filed — ADR-073 was filed on 2026-11-01.
      assert report.extent == {1, 73}
      assert report.rows == 73

      # The identifiers are contiguous, one row per identifier, and the
      # register's own statement of its extent agrees with the table.
      assert Enum.map(report.identifiers, &number/1) == Enum.to_list(1..73)
      assert length(Enum.uniq(report.identifiers)) == report.rows
      assert report.stated_extent == report.extent

      # Every record carries the fingerprint line the corpus's convention
      # asks for, so F5 is exact for every one of them.
      refute Enum.any?(report.warnings, &(&1.class == "W2")),
             "every record file should carry a Decision fingerprint line"
    end
  end

  describe "a mutated copy of the corpus" do
    test "a duplicated identifier fails" do
      corpus = copy_corpus()
      register = Path.join(corpus, @register)

      text = File.read!(register)
      [row] = Regex.run(~r/^\| ADR-070 \|.*$/m, text)

      File.write!(register, String.replace(text, row, row <> "\n" <> row, global: false))

      assert {:error, report} = AdrCheck.check(register, Path.join(corpus, @records))

      assert_failure(report, "R1", "ADR-070")
    end

    test "a record with no row fails" do
      corpus = copy_corpus()

      File.write!(Path.join([corpus, @records, "0099-unfiled-decision.md"]), """
      # ADR-099 — A decision the register never heard of

      **Identifier: ADR-099.** This record presents a decision that was never
      filed in the register, which is exactly what the check is for.

      **Decision.** The unfiled decision stands here, and the Decision Register
      table has no row for it.

      **Status.** Accepted.
      """)

      assert {:error, report} =
               AdrCheck.check(Path.join(corpus, @register), Path.join(corpus, @records))

      assert_failure(report, "F1", "ADR-099")
    end

    test "two files claiming one identifier fail" do
      corpus = copy_corpus()

      # A second file that presents the same Decision under a different
      # name: the duplicate-file hazard the identifier diff cannot see.
      File.cp!(
        Path.join([corpus, @records, "0062-bootstrap-token-custody.md"]),
        Path.join([corpus, @records, "0062-bootstrap-token-custody-again.md"])
      )

      assert {:error, report} =
               AdrCheck.check(Path.join(corpus, @register), Path.join(corpus, @records))

      assert_failure(report, "F2", "ADR-062")
    end

    test "a status disagreement fails" do
      corpus = copy_corpus()
      record = Path.join([corpus, @records, "0062-bootstrap-token-custody.md"])

      text = File.read!(record)
      drifted = String.replace(text, "**Status.** Accepted.", "**Status.** Proposed.")

      refute drifted == text
      File.write!(record, drifted)

      assert {:error, report} =
               AdrCheck.check(Path.join(corpus, @register), Path.join(corpus, @records))

      assert_failure(report, "F3", "ADR-062")
    end

    test "a dangling record path fails" do
      # The register names this file; the copy does not have it.
      corpus = copy_corpus(without: "0062-bootstrap-token-custody.md")

      assert {:error, report} =
               AdrCheck.check(Path.join(corpus, @register), Path.join(corpus, @records))

      assert_failure(report, "F4", "ADR-062")
    end

    test "a drifted Decision fails on the fingerprints" do
      corpus = copy_corpus()
      record = Path.join([corpus, @records, "0070-chain-key-node-rotation.md"])

      text = File.read!(record)

      # One word, and not a literal: the command names are untouched, so
      # only the fingerprint can see this. This is the mutation that
      # proves the freeze rule is enforceable — it is the shape the
      # ADR-068 defect had, and the shape a fingerprint exists to catch.
      drifted =
        String.replace(
          text,
          "The chain-signing key is **node-scoped**",
          "The chain-signing key is **workspace-scoped**",
          global: false
        )

      refute drifted == text
      File.write!(record, drifted)

      assert {:error, report} =
               AdrCheck.check(Path.join(corpus, @register), Path.join(corpus, @records))

      assert_failure(report, "F5", "ADR-070")

      failure = Enum.find(report.failures, &(&1.class == "F5" and &1.identifier == "ADR-070"))

      assert Enum.any?(failure.detail, &(&1 =~ "fingerprint")),
             """
             the F5 failure should say that the fingerprints differ, and it said:

             #{Enum.map_join(failure.detail, "\n", &"  * #{&1}")}
             """
    end
  end

  defp assert_failure(report, class, identifier) do
    assert Enum.any?(report.failures, &(&1.class == class and &1.identifier == identifier)),
           """
           expected a #{class} failure naming #{identifier}, and the check reported:

           #{Enum.map_join(report.failures, "\n", &"  * #{&1.class} #{&1.identifier} — #{&1.message}")}
           """
  end

  # A copy of the register document and the records, so a mutation never
  # touches the corpus itself.

  defp copy_corpus(opts \\ []) do
    root = project_root()

    corpus =
      Path.join(System.tmp_dir!(), "veritas-adr-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(corpus, @records))
    File.cp!(Path.join(root, @register), Path.join(corpus, @register))

    for name <- File.ls!(Path.join(root, @records)), name != opts[:without] do
      File.cp!(Path.join([root, @records, name]), Path.join([corpus, @records, name]))
    end

    # The copy is removed when the test ends. `File.rm_rf/1` does not raise
    # when the removal is refused, because a refusal to tidy up is not a
    # failure of the thing being proved.
    on_exit(fn -> File.rm_rf(corpus) end)

    corpus
  end

  defp number(identifier) do
    identifier |> String.replace_prefix("ADR-", "") |> String.to_integer()
  end

  defp project_root do
    __DIR__
    |> Path.expand()
    |> find_root()
  end

  defp find_root(dir) do
    if File.exists?(Path.join(dir, @register)) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        raise "the repository root was not found above #{__DIR__}"
      else
        find_root(parent)
      end
    end
  end
end
