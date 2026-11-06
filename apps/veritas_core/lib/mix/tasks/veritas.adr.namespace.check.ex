defmodule Mix.Tasks.Veritas.Adr.Namespace.Check do
  @shortdoc "Checks reviewed ADR mapping structure and references, not semantic equivalence"

  @moduledoc """
  Validates the proposed historical-to-canonical mapping in
  `docs/adr-numbering-crosswalk.md` against the Decision Register and the
  historical tables in docs/21, docs/23 and docs/30.

  This is a structural/reference checker, not a semantic proof or ADR acceptance.
  There is no word-overlap verdict. A reviewer records each mapping under the key
  `{source document, historical identifier}`. Exact-reviewed mappings carry
  source and canonical row SHA-256 fingerprints: these detect later changes,
  not whether the review was correct. Judgment and unresolved rows remain
  visible and keep the command nonzero. Historical renumberings are reported,
  never applied. Source statuses and bindingness are never changed.

  ## Parser contract

  The register requires exactly one `## Decision Register` section and its
  nine-column table. Line anchors retain original file offsets. IDs must be
  unique and contiguous from ADR-001. Other register sections are not scanned.

  Historical tables start with an `ADR` or `ID` header. The first cell contains
  an ADR-NNN identifier, optionally a title, an explicit slash list such as
  ADR-001/005, or an inclusive ellipsis range ADR-027…ADR-034. Every data row
  in these tables is examined; malformed rows cannot disappear.

  Crosswalk v2 has one `<!-- adr-namespace:v2 single=N range=M -->` declaration
  and one begin/end block (`<!-- adr-namespace:begin -->`,
  `<!-- adr-namespace:end -->`). Only that block is active; the original
  proposal can be preserved outside it. Its nine columns are Source, Historical,
  Historical meaning, Canonical, Canonical meaning, Confidence, Source SHA-256,
  Canonical SHA-256, Evidence. No unescaped cell pipes or multiline cells.
  Backticks and bold formatting are permitted. Confidence is exact, judgment or
  ambiguous, optionally followed by ` — explanation`. Only `exact — reviewed`
  is exact-reviewed. Other exact labels remain unreviewed.

  Source anchors are docs/21:N, docs/23:N or docs/30:N. Targets are
  `ADR-NNN (docs/16:N)`; multiple targets (ranges only) use comma separation.
  An unresolved target is `—`. Hashes are lowercase SHA-256 of the complete
  trimmed table row, without its newline; multiple canonical hashes follow
  target order. A fingerprint is provenance, not semantic certification.

  Legacy six-column Source tables are fully inventoried and reference-checked,
  but never certified as reviewed. V2 declared counts must match parsed counts,
  and every source row must have exactly one mapping. Range rows are separate
  from single-ID totals, with all explicit canonical targets checked.

  N0: malformed structure, counts or duplicate/conflicting keys.
  N1: invalid source anchor or changed source fingerprint.
  N3: invalid canonical target/anchor or changed canonical fingerprint.
  N4: review still required, unresolved mapping or range disposition.

  ## Invocation and absence

      mix veritas.adr.namespace.check [--root PATH] [--quiet]

  A wholly corpus-free checkout exits zero with an explicit NOT CHECKED message,
  even with --quiet. Missing/unreadable files in a partial corpus fail. Quiet
  suppresses only the per-row exact-review inventory, never coverage, pending
  decisions, missing inputs or the limits of the check. No applications or
  services are started by this task.
  """

  use Mix.Task

  @canonical "docs/16-decision-register.md"
  @crosswalk "docs/adr-numbering-crosswalk.md"
  @sources [
    {"docs/21", "docs/21-architecture-under-free-forever.md"},
    {"docs/23", "docs/23-free-ha-build-borrow-buy.md"},
    {"docs/30", "docs/30-decision-bindingness-and-seam-map.md"}
  ]
  @crosswalk_header [
    "Source",
    "Historical",
    "Historical meaning",
    "Canonical",
    "Canonical meaning",
    "Confidence"
  ]
  @review_header @crosswalk_header ++ ["Source SHA-256", "Canonical SHA-256", "Evidence"]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [quiet: :boolean, root: :string])
    if rest != [] or invalid != [], do: Mix.raise("Invalid namespace checker arguments")
    root = opts[:root] || find_root(Path.expand("."))

    if is_nil(root) do
      not_checked()
    else
      case File.read(Path.join(root, @canonical)) do
        {:ok, text} ->
          check(root, text, opts)

        {:error, :enoent} ->
          if Enum.any?(
               [@crosswalk | Enum.map(@sources, &elem(&1, 1))],
               &File.exists?(Path.join(root, &1))
             ) do
            Mix.raise("N0 #{@canonical}: NOT CHECKED — missing register in partial corpus")
          else
            not_checked()
          end

        {:error, reason} ->
          Mix.raise("N0 #{@canonical}: NOT CHECKED — #{:file.format_error(reason)}")
      end
    end
  end

  defp not_checked do
    Mix.shell().info(
      "NOT CHECKED: #{@canonical} is absent; no corpus was checked. Compatibility exit zero, not verification."
    )

    :ok
  end

  defp check(root, text, opts) do
    {register, register_errors} = register(text)
    {sources, source_errors} = sources(root)
    {crosswalk_text, read_errors} = read_input(root, @crosswalk)
    {mappings, mode, declared, crosswalk_errors} = crosswalk(crosswalk_text)

    structural =
      register_errors ++
        source_errors ++
        read_errors ++
        crosswalk_errors ++
        duplicates(mappings, &{&1.source, &1.id}, "duplicate/conflicting mapping", @crosswalk) ++
        coverage(mappings, sources, declared) ++
        Enum.flat_map(mappings, &references(&1, register, sources, mode))

    pending = Enum.flat_map(mappings, &pending(&1, mode))
    report(register, sources, mappings, mode, structural, opts)
    Enum.each(structural ++ pending, fn message -> Mix.shell().error(message) end)

    if structural ++ pending != [] do
      Mix.raise(
        "ADR namespace check: #{length(structural)} structural/reference failure(s); #{length(pending)} pending review(s). No semantic equivalence or ADR acceptance is certified."
      )
    end

    :ok
  end

  defp read_input(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, text} -> {text, []}
      {:error, reason} -> {"", ["N0 #{path}: NOT CHECKED — #{:file.format_error(reason)}"]}
    end
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.with_index(1)
  defp plain(text), do: text |> String.replace(~r/[`*]/, "") |> String.trim()

  defp cells(line),
    do:
      line
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)

  defp digest(line), do: :crypto.hash(:sha256, String.trim(line)) |> Base.encode16(case: :lower)

  # A deliberately narrow table reader: once a known header starts a table,
  # every subsequent nonblank row must have the same width and both pipes.
  defp tables(lines, headers, path) do
    {rows, errors, _width} =
      Enum.reduce(lines, {[], [], nil}, fn {raw, line}, {rows, errors, width} ->
        text = String.trim(raw)
        cs = cells(text)
        first = plain(hd(cs))

        cond do
          first in headers and String.starts_with?(text, "|") ->
            {rows, errors, length(cs)}

          width && text == "" ->
            {rows, errors, nil}

          width && Regex.match?(~r/^\|[\s:|\-]+\|$/, text) ->
            {rows, errors, width}

          width && String.starts_with?(text, "|") && String.ends_with?(text, "|") &&
              length(cs) == width ->
            {rows ++ [%{cells: cs, line: line, raw: raw}], errors, width}

          width ->
            {rows,
             errors ++ ["N0 #{path}:#{line}: malformed table row (expected #{width} cells)"], nil}

          String.starts_with?(text, "|") && Regex.match?(~r/^ADR/, first) ->
            {rows, errors ++ ["N0 #{path}:#{line}: ADR row outside a declared table"], nil}

          true ->
            {rows, errors, nil}
        end
      end)

    {rows, errors}
  end

  defp register(text) do
    all = lines(text)
    headings = Enum.filter(all, fn {line, _} -> String.trim(line) == "## Decision Register" end)

    case headings do
      [{_, start}] ->
        section =
          all
          |> Enum.drop(start)
          |> Enum.take_while(fn {line, _} ->
            not String.starts_with?(String.trim(line), "## ")
          end)

        {rows, errors} = tables(section, ["ID"], @canonical)

        expected_header = [
          "ID",
          "Title",
          "Decision",
          "Driver",
          "Rejected alternative",
          "Consequence",
          "Status",
          "Recorded",
          "Reversibility"
        ]

        headers =
          Enum.filter(section, fn {line, _} ->
            String.starts_with?(String.trim(line), "| ID |")
          end)

        errors =
          if length(headers) == 1 && cells(elem(hd(headers), 0)) == expected_header,
            do: errors,
            else: errors ++ ["N0 #{@canonical}: missing or malformed canonical header"]

        {valid, errors} =
          Enum.reduce(rows, {[], errors}, fn row, {valid, errors} ->
            case row.cells do
              [id, title, decision, _, _, _, _, _, _] ->
                if Regex.match?(~r/^ADR-\d{3}$/, id) and title != "" and decision != "" do
                  {valid ++ [Map.merge(row, %{id: id, title: title})], errors}
                else
                  {valid,
                   errors ++
                     [
                       "N0 #{@canonical}:#{row.line}: malformed canonical identifier or empty decision"
                     ]}
                end

              _ ->
                {valid, errors ++ ["N0 #{@canonical}:#{row.line}: expected nine canonical cells"]}
            end
          end)

        errors = errors ++ duplicates(valid, & &1.id, "duplicate canonical", @canonical)
        ids = Enum.map(valid, & &1.id) |> Enum.sort()
        expected = if ids == [], do: [], else: Enum.map(1..length(ids), &adr/1)

        errors =
          if ids == [] or ids != expected,
            do:
              errors ++
                [
                  "N0 #{@canonical}: canonical IDs must be nonempty, unique and contiguous from ADR-001"
                ],
            else: errors

        {valid, errors}

      _ ->
        {[], ["N0 #{@canonical}: expected exactly one ## Decision Register heading"]}
    end
  end

  defp identity(cell) do
    case Regex.run(
           ~r/^(ADR-\d{3}(?:\/\d{3})+|ADR-\d{3}…ADR-\d{3}|ADR-\d{3})(?:\s+.*)?$/,
           plain(cell)
         ) do
      [_, id] ->
        parts = Regex.scan(~r/\d{3}/, id) |> List.flatten() |> Enum.map(&String.to_integer/1)

        valid =
          Enum.all?(parts, &(&1 > 0)) && length(parts) == length(Enum.uniq(parts)) &&
            (not String.contains?(id, "…") or hd(parts) < List.last(parts))

        if valid, do: {:ok, id, length(parts) > 1}, else: :error

      _ ->
        :error
    end
  end

  defp sources(root) do
    Enum.reduce(@sources, {[], []}, fn {label, path}, {all, errors} ->
      {text, read_errors} = read_input(root, path)
      {rows, parse_errors} = tables(lines(text), ["ADR", "ID"], path)

      {valid, row_errors} =
        Enum.reduce(rows, {[], []}, fn row, {valid, row_errors} ->
          case identity(hd(row.cells)) do
            {:ok, id, range} ->
              {valid ++ [Map.merge(row, %{id: id, range: range, source: label})], row_errors}

            :error ->
              {valid, row_errors ++ ["N0 #{path}:#{row.line}: malformed historical identifier"]}
          end
        end)

      duplicate_errors = duplicates(valid, &{&1.source, &1.id}, "duplicate historical", path)
      {all ++ valid, errors ++ read_errors ++ parse_errors ++ row_errors ++ duplicate_errors}
    end)
  end

  defp crosswalk(text) do
    {section, mode, declared, errors} = active_section(text)
    {rows, table_errors} = tables(section, ["Source"], @crosswalk)

    headers =
      Enum.filter(section, fn {line, _} ->
        String.starts_with?(String.trim(line), "| Source |")
      end)

    expected_header = if mode == :reviewed, do: @review_header, else: @crosswalk_header

    header_errors =
      if headers != [] && Enum.all?(headers, fn {line, _} -> cells(line) == expected_header end),
        do: [],
        else: ["N0 #{@crosswalk}: missing or invalid crosswalk header"]

    {valid, errors} =
      Enum.reduce(rows, {[], errors ++ table_errors ++ header_errors}, fn row, {valid, errors} ->
        case mapping(row, mode) do
          {:ok, mapping} ->
            {valid ++ [mapping], errors}

          :error ->
            {valid,
             errors ++
               [
                 "N0 #{@crosswalk}:#{row.line}: malformed mapping cells, identifier, source or confidence"
               ]}
        end
      end)

    {valid, mode, declared, errors}
  end

  defp active_section(text) do
    all = lines(text)

    if String.contains?(text, "<!-- adr-namespace:") do
      declarations =
        Enum.flat_map(all, fn {line, number} ->
          case Regex.run(
                 ~r/^<!-- adr-namespace:v2 single=(\d+) range=(\d+) -->$/,
                 String.trim(line)
               ) do
            [_, single, range] ->
              [{number, {String.to_integer(single), String.to_integer(range)}}]

            _ ->
              []
          end
        end)

      begins =
        Enum.filter(all, fn {line, _} -> String.trim(line) == "<!-- adr-namespace:begin -->" end)

      ends =
        Enum.filter(all, fn {line, _} -> String.trim(line) == "<!-- adr-namespace:end -->" end)

      case {declarations, begins, ends} do
        {[{d, counts}], [{_, b}], [{_, e}]} when d < b and b < e ->
          {Enum.filter(all, fn {_, n} -> n > b and n < e end), :reviewed, counts, []}

        _ ->
          {[], :reviewed, nil, ["N0 #{@crosswalk}: invalid v2 declaration or section markers"]}
      end
    else
      {all, :legacy, nil, []}
    end
  end

  defp mapping(row, mode) do
    expected = if mode == :reviewed, do: 9, else: 6

    if length(row.cells) == expected do
      [source, historical, meaning, target, canonical_meaning, confidence | rest] = row.cells
      anchor = Regex.run(~r/^(docs\/(?:21|23|30)):(\d+)$/, plain(source))
      state = Regex.run(~r/^(exact|judgment|ambiguous)(?: — .+)?$/, plain(confidence))

      case {anchor, identity(historical), state} do
        {[_, source, number], {:ok, id, range}, [_, confidence_base]} ->
          if plain(historical) == id && meaning != "" && canonical_meaning != "" &&
               String.to_integer(number) > 0 do
            {:ok,
             Map.merge(row, %{
               source: source,
               anchor: String.to_integer(number),
               id: id,
               range: range,
               target: target,
               confidence: confidence_base,
               reviewed: plain(confidence) == "exact — reviewed",
               source_hash: Enum.at(rest, 0),
               target_hash: Enum.at(rest, 1),
               evidence: Enum.at(rest, 2)
             })}
          else
            :error
          end

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp duplicates(rows, key, label, path) do
    rows
    |> Enum.group_by(key)
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.flat_map(fn {key, group} ->
      if length(group) > 1 do
        name = if is_tuple(key), do: key |> Tuple.to_list() |> Enum.join(" "), else: key
        ["N0 #{path}: #{label} #{name} (lines #{Enum.map_join(group, ", ", & &1.line)})"]
      else
        []
      end
    end)
  end

  defp coverage(mappings, sources, declared) do
    counts = counts(mappings)
    source_counts = counts(sources)

    count_errors =
      if declared && declared != counts,
        do: [
          "N0 #{@crosswalk}: declared counts #{inspect(declared)} differ from parsed #{inspect(counts)}"
        ],
        else: []

    count_errors =
      if source_counts != counts,
        do:
          count_errors ++
            [
              "N0 #{@crosswalk}: source counts #{inspect(source_counts)} differ from crosswalk #{inspect(counts)}"
            ],
        else: count_errors

    count_errors =
      if mappings == [],
        do: count_errors ++ ["N0 #{@crosswalk}: no mappings checked"],
        else: count_errors

    count_errors ++
      Enum.flat_map(sources, fn row ->
        if Enum.any?(mappings, &(&1.source == row.source && &1.id == row.id)),
          do: [],
          else: ["N0 #{@crosswalk}: no mapping for #{row.source}:#{row.line} #{row.id}"]
      end)
  end

  defp counts(rows), do: {Enum.count(rows, &(not &1.range)), Enum.count(rows, & &1.range)}

  defp references(row, register, sources, mode) do
    location = "#{@crosswalk}:#{row.line} (#{row.source}:#{row.anchor} #{row.id})"

    source =
      Enum.find(sources, &(&1.source == row.source && &1.id == row.id && &1.line == row.anchor))

    source_errors =
      cond do
        is_nil(source) ->
          ["N1 #{location}: source anchor does not identify the historical row"]

        mode == :reviewed && row.source_hash != digest(source.raw) ->
          ["N1 #{location}: source fingerprint changed or invalid; re-review required"]

        true ->
          []
      end

    evidence_errors =
      if mode == :reviewed && (row.evidence == "" || row.evidence == "—"),
        do: ["N0 #{location}: missing review evidence"],
        else: []

    source_errors ++ evidence_errors ++ target_references(row, register, mode, location)
  end

  defp target_references(row, register, mode, location) do
    if plain(row.target) == "—" do
      cond do
        row.confidence == "exact" ->
          ["N3 #{location}: exact mapping needs a canonical target"]

        mode == :reviewed && row.target_hash != "—" ->
          ["N3 #{location}: unresolved target needs — fingerprint"]

        true ->
          []
      end
    else
      targets = String.split(row.target, ",")
      hashes = String.split(row.target_hash || "", ",") |> Enum.map(&String.trim/1)

      count_errors =
        if not row.range && length(targets) != 1,
          do: ["N3 #{location}: single-ID mapping needs exactly one target"],
          else: []

      count_errors =
        if mode == :reviewed && length(hashes) != length(targets),
          do: count_errors ++ ["N3 #{location}: target fingerprint count mismatch"],
          else: count_errors

      duplicate_errors =
        if length(Enum.uniq_by(targets, &plain/1)) != length(targets),
          do: ["N3 #{location}: duplicate canonical targets"],
          else: []

      count_errors ++
        duplicate_errors ++
        (targets
         |> Enum.with_index()
         |> Enum.flat_map(fn {target, i} ->
           target_reference(target, Enum.at(hashes, i), register, mode, location)
         end))
    end
  end

  defp target_reference(target, hash, register, mode, location) do
    case Regex.run(~r/^(ADR-\d{3}) \(docs\/16:(\d+)\)$/, plain(target)) do
      [_, id, line] ->
        case Enum.find(register, &(&1.id == id)) do
          nil ->
            ["N3 #{location}: canonical target #{id} does not exist"]

          canonical ->
            anchor_errors =
              if canonical.line != String.to_integer(line),
                do: [
                  "N3 #{location}: canonical anchor for #{id} must be docs/16:#{canonical.line}"
                ],
                else: []

            hash_errors =
              if mode == :reviewed && hash != digest(canonical.raw),
                do: [
                  "N3 #{location}: canonical fingerprint changed or invalid for #{id}; re-review required"
                ],
                else: []

            anchor_errors ++ hash_errors
        end

      _ ->
        ["N3 #{location}: malformed canonical target #{plain(target)}"]
    end
  end

  defp pending(row, mode) do
    reason =
      cond do
        mode == :legacy -> "unreviewed legacy mapping"
        row.range -> "range disposition requires judgment; not a single-ID renaming"
        row.confidence == "ambiguous" -> "unresolved mapping"
        row.confidence == "judgment" -> "requires judgment; candidate is not an approved renaming"
        not row.reviewed -> "unreviewed exact label; explicit exact — reviewed required"
        true -> nil
      end

    if reason, do: ["N4 #{row.source}:#{row.anchor} #{row.id}: #{reason}"], else: []
  end

  defp report(register, sources, mappings, mode, errors, opts) do
    {single, ranges} = counts(mappings)

    Mix.shell().info(
      "ADR namespace: #{length(register)} canonical rows; crosswalk: #{single} single-ID rows; #{ranges} range rows"
    )

    singles = Enum.reject(mappings, & &1.range)

    Mix.shell().info(
      Enum.map_join(["exact", "judgment", "ambiguous"], "; ", fn label ->
        "#{label}=#{Enum.count(singles, &(&1.confidence == label))}"
      end)
    )

    exact = Enum.count(singles, &(&1.reviewed && mode == :reviewed))

    Mix.shell().info(
      "exact-reviewed=#{exact}; requires-judgment=#{Enum.count(singles, &(&1.confidence == "judgment"))}; unresolved=#{Enum.count(singles, &(&1.confidence == "ambiguous"))}"
    )

    Enum.each(@sources, fn {label, _} ->
      {s, r} = sources |> Enum.filter(&(&1.source == label)) |> counts()
      {ms, mr} = mappings |> Enum.filter(&(&1.source == label)) |> counts()

      Mix.shell().info(
        "#{label}: source #{s} single + #{r} range; crosswalk #{ms} single + #{mr} range"
      )
    end)

    Enum.each(mappings, fn row ->
      cond do
        row.range ->
          Mix.shell().info(
            "RANGE #{row.source}:#{row.anchor} #{row.id}: explicitly accounted; not mechanically reconciled"
          )

        !opts[:quiet] ->
          Mix.shell().info(
            "MAP #{row.source}:#{row.anchor} #{row.id}: #{row.confidence}; target #{plain(row.target)}"
          )

        true ->
          :ok
      end
    end)

    mentioned = sources |> Enum.flat_map(&numeric_ids/1) |> MapSet.new()

    absent =
      register |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(mentioned, &1)) |> Enum.sort()

    Mix.shell().info(
      "Canonical IDs not numerically mentioned in source tables (not missing meanings): #{if absent == [], do: "none", else: Enum.join(absent, ", ")}"
    )

    historical_differences =
      Enum.count(singles, fn row ->
        row.reviewed && mode == :reviewed &&
          not String.starts_with?(plain(row.target), row.id <> " ")
      end)

    Mix.shell().info(
      "Exact-reviewed historical/canonical ID differences: #{historical_differences}; this counts provenance, not outstanding annotations or semantic approval."
    )

    if errors == [],
      do:
        Mix.shell().info(
          "STRUCTURAL/REFERENCE CHECKED; human review obligations listed separately."
        ),
      else: Mix.shell().info("STRUCTURAL/REFERENCE FAILED; no complete-check claim.")

    Mix.shell().info(
      "Semantic equivalence is NOT mechanically verified. Reviewed labels are recorded judgments, fingerprints detect drift, and mapping review is not ADR acceptance."
    )
  end

  defp numeric_ids(row) do
    numbers = Regex.scan(~r/\d{3}/, row.id) |> List.flatten() |> Enum.map(&String.to_integer/1)

    numbers =
      if String.contains?(row.id, "…"),
        do: Enum.to_list(hd(numbers)..List.last(numbers)),
        else: numbers

    Enum.map(numbers, &adr/1)
  end

  defp adr(n), do: "ADR-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp find_root(dir) do
    if File.exists?(Path.join(dir, @canonical)) || File.exists?(Path.join(dir, ".git")) do
      dir
    else
      parent = Path.dirname(dir)
      if parent == dir, do: nil, else: find_root(parent)
    end
  end
end
