defmodule Mix.Tasks.Veritas.Adr.Namespace.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Veritas.Adr.Namespace.Check, as: Namespace

  @repo Path.expand("../../../../..", __DIR__)
  @sources [
    "21-architecture-under-free-forever.md",
    "23-free-ha-build-borrow-buy.md",
    "30-decision-bindingness-and-seam-map.md"
  ]
  @header "| Source | Historical | Historical meaning | Canonical | Canonical meaning | Confidence |"
  @review_header @header <> " Source SHA-256 | Canonical SHA-256 | Evidence |"
  @register_row "| ADR-001 | Permit unauthenticated writes | Permit unauthenticated writes | Test driver | Alternative | Consequence | Proposed | 2026-11-04 | Revisitable |"
  @source_row "| ADR-001 | Permit unauthenticated writes |"

  setup context do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    # Retained as bounded test evidence; no temporary OS directory or live service.
    root =
      Path.join(
        @repo,
        "_build/instrument-correction-20261104/architect/fixtures/#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(Path.join(root, "docs"))
    put(root, "16-decision-register.md", register())
    sources = if context[:missing_source], do: tl(@sources), else: @sources
    Enum.each(sources, &put(root, &1, "| ADR | Meaning |\n|---|---|\n#{@source_row}\n"))
    {:ok, root: root}
  end

  for confidence <- ["exact", "judgment — requires interpretation", "**ambiguous**"] do
    test "invalid canonical target cannot hide behind #{confidence}", %{root: root} do
      put_crosswalk(root, [legacy_row("docs/21:3", "ADR-001", "ADR-999", unquote(confidence))])
      {status, output} = invoke(root)
      assert status == :error
      assert output =~ "N3"
      assert output =~ "ADR-999"
    end
  end

  test "word overlap cannot certify an unreviewed negation", %{root: root} do
    put(
      root,
      hd(@sources),
      "| ADR | Meaning |\n|---|---|\n| ADR-001 | Do not permit unauthenticated writes |\n"
    )

    put_crosswalk(root, [legacy_row("docs/21:3", "ADR-001", "ADR-001", "exact")])
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "unreviewed"
    refute output =~ "same decision looks like"
  end

  test "quiet corpus-free invocation explicitly says NOT CHECKED", %{root: root} do
    {status, output} = invoke(Path.join(root, "absent"), ["--quiet"])
    assert status == :ok
    assert output =~ "NOT CHECKED"
  end

  test "partial corpus cannot silently skip the crosswalk", %{root: root} do
    {status, output} = invoke(root, ["--quiet"])
    assert status == :error
    assert output =~ "adr-numbering-crosswalk.md"
    assert output =~ "NOT CHECKED"
  end

  test "all 78 legacy rows and both ranges are accounted for", %{root: root} do
    rows =
      for n <- 1..78 do
        {doc, index} =
          cond do
            n <= 24 -> {21, n}
            n <= 39 -> {23, n - 24}
            true -> {30, n - 39}
          end

        confidence =
          cond do
            n <= 56 -> "exact"
            n <= 58 -> "judgment"
            n <= 72 -> "judgment — interpretation"
            true -> "**ambiguous**"
          end

        target = if n <= 72, do: "ADR-001", else: "—"
        legacy_row("docs/#{doc}:#{index + 2}", id(index), target, confidence)
      end

    ranges = [
      legacy_row(
        "docs/23:18",
        "ADR-001/005/007/008/009/010/011/012/013/014",
        "—",
        "judgment — combined"
      ),
      legacy_row("docs/30:42", "ADR-027…ADR-034", "—", "judgment — range")
    ]

    put_crosswalk(root, rows ++ ranges)
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "crosswalk: 78 single-ID rows; 2 range rows"
    assert output =~ "exact=56; judgment=16; ambiguous=6"
    assert output =~ "docs/30:41 ADR-039"
    assert output =~ "RANGE docs/23:18"
    assert output =~ "RANGE docs/30:42"
  end

  for malformed <- [
        "| `docs/21:3` | ADR-001 | Meaning | ADR-001 | Meaning | invented |",
        "| `docs/21:3` | ADR-001 | Meaning | ADR-001 |",
        "| `docs/21:3` | ADR001 | Meaning | ADR-001 | Meaning | exact |",
        "this is a broken table row"
      ] do
    test "malformed row is refused: #{malformed}", %{root: root} do
      put_crosswalk(root, [unquote(malformed)])
      {status, output} = invoke(root)
      assert status == :error
      assert output =~ "N0"
      assert output =~ "adr-numbering-crosswalk.md"
    end
  end

  test "register requires its actual heading instead of scanning the whole file", %{root: root} do
    put(root, "16-decision-register.md", @register_row)
    put_crosswalk(root, [])
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "Decision Register"
  end

  test "duplicate register IDs cannot overwrite each other", %{root: root} do
    put(root, "16-decision-register.md", register(@register_row <> "\n" <> @register_row))
    reviewed(root)
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "duplicate canonical ADR-001"
  end

  test "valid reviewed fixture passes only structural and reference checks", %{root: root} do
    reviewed(root)
    {status, output} = invoke(root)
    assert status == :ok
    assert output =~ "STRUCTURAL/REFERENCE CHECKED"
    assert output =~ "Semantic equivalence is NOT mechanically verified"
    assert output =~ "crosswalk: 3 single-ID rows; 0 range rows"
    assert output =~ "exact-reviewed=3"
  end

  test "register extraction ignores legitimate references after the section", %{root: root} do
    put(
      root,
      "16-decision-register.md",
      register() <> "\n## Companion documents\n#{@register_row}\n"
    )

    reviewed(root)
    assert {:ok, _output} = invoke(root)
  end

  test "canonical anchors use original file line numbers", %{root: root} do
    reviewed(root, target_line: 1)
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "canonical anchor"
    assert output =~ "docs/16:6"
  end

  test "source anchor must identify the declared historical row", %{root: root} do
    reviewed(root, source_line: 2)
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "source anchor"
  end

  test "source changes invalidate review even when token sets still overlap", %{root: root} do
    reviewed(root)

    put(
      root,
      hd(@sources),
      "| ADR | Meaning |\n|---|---|\n| ADR-001 | Do not permit unauthenticated writes |\n"
    )

    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "source fingerprint changed"
  end

  test "canonical changes invalidate review even when token sets still overlap", %{root: root} do
    reviewed(root)

    put(
      root,
      "16-decision-register.md",
      String.replace(
        register(),
        "Permit unauthenticated writes",
        "Do not permit unauthenticated writes"
      )
    )

    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "canonical fingerprint changed"
  end

  test "duplicate and conflicting mappings cannot collapse into a map", %{root: root} do
    reviewed(root, extra: review_row(21, target: "ADR-999"))
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "duplicate/conflicting mapping docs/21 ADR-001"
    assert output =~ "ADR-999"
  end

  test "a removed crosswalk row fails both declared counts and source coverage", %{root: root} do
    reviewed(root, omit: 30)
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "declared counts"
    assert output =~ "no mapping for docs/30:3 ADR-001"
  end

  test "unresolved reviewed mappings remain visible and do not certify equivalence", %{root: root} do
    reviewed(root, confidence: "**ambiguous**", target: "—")
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "unresolved=3"
    assert output =~ "N4"
    assert output =~ "docs/21:3 ADR-001"
  end

  test "judgment candidates are not approved renamings", %{root: root} do
    reviewed(root, confidence: "judgment — related, not identical")
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "requires-judgment=3"
    assert output =~ "N4"
  end

  test "reviewed range rows count separately and validate every target", %{root: root} do
    source = "| ADR-001…ADR-002 Unallocated | — |"
    put(root, List.last(@sources), "| ADR | Meaning |\n|---|---|\n#{source}\n")

    range =
      "| `docs/30:3` | ADR-001…ADR-002 | Unallocated | **ADR-001** (`docs/16:6`), **ADR-999** (`docs/16:7`) | Range | judgment — range | #{digest(source)} | #{digest(@register_row)}, #{digest(@register_row)} | Review targets separately |"

    body = Enum.map_join([21, 23], "\n", &review_row/1) <> "\n" <> range
    put(root, "adr-numbering-crosswalk.md", v2(body, 2, 1))
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "crosswalk: 2 single-ID rows; 1 range rows"
    assert output =~ "ADR-999"
    assert output =~ "RANGE docs/30:3"
  end

  test "archive tables cannot be mistaken for active mappings", %{root: root} do
    reviewed(root)
    path = Path.join(root, "docs/adr-numbering-crosswalk.md")

    File.write!(
      path,
      File.read!(path) <>
        "\n## Archived proposal\n#{@header}\n|---|---|---|---|---|---|\n#{legacy_row("docs/21:3", "ADR-001", "ADR-999", "exact")}\n"
    )

    assert {:ok, _output} = invoke(root)
  end

  test "malformed section markers cannot fall back to legacy mode", %{root: root} do
    reviewed(root)
    path = Path.join(root, "docs/adr-numbering-crosswalk.md")
    File.write!(path, String.replace(File.read!(path), "<!-- adr-namespace:end -->", ""))
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "section markers"
  end

  test "canonical header cannot silently change column meaning", %{root: root} do
    reviewed(root)

    put(
      root,
      "16-decision-register.md",
      String.replace(register(), "| ID | Title | Decision |", "| ID | Decision | Title |")
    )

    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "canonical header"
  end

  test "a repeated range target cannot hide behind formatting", %{root: root} do
    source = "| ADR-001…ADR-002 Unallocated | — |"
    put(root, List.last(@sources), "| ADR | Meaning |\n|---|---|\n#{source}\n")

    range =
      "| `docs/30:3` | ADR-001…ADR-002 | Unallocated | **ADR-001** (`docs/16:6`), ADR-001 (docs/16:6) | Range | judgment — range | #{digest(source)} | #{digest(@register_row)}, #{digest(@register_row)} | Review targets separately |"

    body = Enum.map_join([21, 23], "\n", &review_row/1) <> "\n" <> range
    put(root, "adr-numbering-crosswalk.md", v2(body, 2, 1))
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "duplicate canonical targets"
  end

  @tag missing_source: true
  test "missing historical input refuses even in quiet mode", %{root: root} do
    reviewed(root)
    {status, output} = invoke(root, ["--quiet"])
    assert status == :error
    assert output =~ "NOT CHECKED"
    assert output =~ hd(@sources)
  end

  test "malformed source rows cannot vanish from coverage", %{root: root} do
    reviewed(root)
    put(root, hd(@sources), "| ADR | Meaning |\n|---|---|\n| broken | Meaning |\n")
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "malformed historical identifier"
    assert output =~ "source counts"
  end

  test "canonical numbering gaps are refused", %{root: root} do
    reviewed(root)

    put(
      root,
      "16-decision-register.md",
      register() <> String.replace(@register_row, "ADR-001", "ADR-003") <> "\n"
    )

    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "contiguous from ADR-001"
  end

  test "exact without explicit review is not certified", %{root: root} do
    reviewed(root, confidence: "exact")
    {status, output} = invoke(root)
    assert status == :error
    assert output =~ "unreviewed exact label"
    assert output =~ "exact-reviewed=0"
  end

  test "numeric absence is explicitly not absence of historical meaning", %{root: root} do
    reviewed(root)
    {status, output} = invoke(root)
    assert status == :ok
    assert output =~ "not numerically mentioned"
    assert output =~ "not missing meanings"
  end

  for {label, annotation} <- [
        {"unannotated", ""},
        {"annotated", " [canonical reference: ADR-001 (docs/16:6), Proposed]"}
      ] do
    test "historical difference count is not outstanding work: #{label}", %{root: root} do
      source = "| ADR-002#{unquote(annotation)} | Permit unauthenticated writes |"
      put(root, hd(@sources), "| ADR | Meaning |\n|---|---|\n#{source}\n")

      row =
        review_row(21)
        |> String.replace("| ADR-001 |", "| ADR-002 |", global: false)
        |> String.replace(digest(@source_row), digest(source))

      body = Enum.join([row, review_row(23), review_row(30)], "\n")
      put(root, "adr-numbering-crosswalk.md", v2(body, 3, 0))
      {status, output} = invoke(root)
      assert status == :ok
      assert output =~ "Exact-reviewed historical/canonical ID differences: 1"
      assert output =~ "not outstanding annotations"
      refute output =~ "annotations needed"
      assert output =~ "Semantic equivalence is NOT mechanically verified"
    end
  end

  test "invalid CLI arguments are refused", %{root: root} do
    {status, output} = invoke(root, ["--unexpected"])
    assert status == :error
    assert output =~ "arguments"
  end

  defp register(row \\ @register_row) do
    "# Fixture\n\n## Decision Register\n| ID | Title | Decision | Driver | Rejected alternative | Consequence | Status | Recorded | Reversibility |\n|---|---|---|---|---|---|---|---|---|\n#{row}\n"
  end

  defp legacy_row(source, historical, target, confidence) do
    canonical = if target == "—", do: "—", else: "**#{target}** (`docs/16:6`)"

    "| `#{source}` | #{historical} | Permit unauthenticated writes | #{canonical} | Permit unauthenticated writes | #{confidence} |"
  end

  defp review_row(doc, opts \\ []) do
    target = Keyword.get(opts, :target, "ADR-001")
    source_line = Keyword.get(opts, :source_line, 3)
    target_line = Keyword.get(opts, :target_line, 6)
    confidence = Keyword.get(opts, :confidence, "exact — reviewed")
    base = legacy_row("docs/#{doc}:#{source_line}", "ADR-001", target, confidence)
    base = String.replace(base, "docs/16:6", "docs/16:#{target_line}")
    hash = if target == "—", do: "—", else: digest(@register_row)
    base <> " #{digest(@source_row)} | #{hash} | Fixture review; not ADR acceptance |"
  end

  defp reviewed(root, opts \\ []) do
    rows = for doc <- [21, 23, 30], doc != opts[:omit], do: review_row(doc, opts)
    rows = if opts[:extra], do: rows ++ [opts[:extra]], else: rows
    put(root, "adr-numbering-crosswalk.md", v2(Enum.join(rows, "\n"), 3, 0))
  end

  defp v2(body, single, ranges) do
    "<!-- adr-namespace:v2 single=#{single} range=#{ranges} -->\n<!-- adr-namespace:begin -->\n#{@review_header}\n|---|---|---|---|---|---|---|---|---|\n#{body}\n<!-- adr-namespace:end -->\n"
  end

  defp put_crosswalk(root, rows) do
    put(
      root,
      "adr-numbering-crosswalk.md",
      "#{@header}\n|---|---|---|---|---|---|\n#{Enum.join(rows, "\n")}\n"
    )
  end

  defp put(root, name, text), do: File.write!(Path.join([root, "docs", name]), text)
  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp id(n), do: "ADR-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp invoke(root, extra \\ []) do
    status =
      try do
        Namespace.run(["--root", root] ++ extra)
        :ok
      rescue
        error in Mix.Error ->
          send(self(), {:mix_shell, :error, [error.message]})
          :error
      end

    {status, messages([])}
  end

  defp messages(acc) do
    receive do
      {:mix_shell, _kind, [message]} -> messages([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
