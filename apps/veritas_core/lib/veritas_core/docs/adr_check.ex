defmodule Veritas.Core.Docs.AdrCheck do
  @moduledoc """
  The register-conformance check: the Decision Register table in
  `docs/16-decision-register.md` against the records in `docs/adr/`.

  ## What it is for

  A decision register is worth what a reader can get out of it: follow a
  number to a decision and check it. That holds for as long as the table and
  the records beside it agree, and they drift on their own. A row is edited
  in place. A record is renamed and the old name stays beside it. A proposal
  is filed and never absorbed. A decision moves and the record keeps the
  mechanism it had before the move. None of that announces itself in a
  Markdown table.

  So the check exists to **fail on the drift and name it**. It compares the
  table with the records and reports the identifier the two disagree about.

  ## The direction of the comparison

  **File → row, never row → file.** The table is the source of truth; the
  records are compared against it. The check never re-renders the table from
  the records, because a register generated from its own records cannot
  disagree with them — it can only lose the decisions the records never
  carried.

  ## What it reads

  The **Decision Register table** is parsed out of the register document: the
  longest run of `| ADR-NNN |` rows under its `## Decision Register` heading.
  It is not a file-wide grep, because the same document holds the
  Reversibility Review table and the Companion-documents table, whose rows
  are cross-references and read as false duplicates.

  Each file in the records directory is read for four things: the identifier
  it names, the `**Decision.**` paragraph, the `**Status.**` line, and the
  `**Decision fingerprint (sha256):**` line when it carries one.

  **A file that names an identifier but presents no Decision of its own is a
  pointer, not a claim.** That is how a leftover stub is recognised rather
  than counted as a second claim against the identifier it points at.

  ## What it fails on

  | Class | Fails when |
  |---|---|
  | **R1** — a duplicated identifier | The Decision Register table holds two rows for one identifier. |
  | **R2** — a gap in the sequence | The identifiers are not contiguous from ADR-001. |
  | **R3** — a malformed row | A row does not have the columns the table's header declares. |
  | **F1** — a record with no row | A file presents a Decision for an identifier the table does not have. |
  | **F2** — one identifier, two claims | Two files present a Decision for the same identifier. |
  | **F3** — a status disagreement | A record's `**Status.**` and its row's Status cell differ. |
  | **F4** — a dangling reference | A record path the register names does not exist, or an identifier is claimed by a file that presents no Decision while no record file carries it. |
  | **F5** — a drifted decision | A record's Decision paragraph no longer matches the decision its row records, or its fingerprint does not match its Decision paragraph. |

  A failure names the identifier it is about, so the message says which row
  or which file to look at.

  ## What it reports without failing

  | Class | Reported when |
  |---|---|
  | **W1** | A file names an identifier and presents no Decision: a pointer stub, inert and owed for removal. |
  | **W2** | A record carries no fingerprint line, so the exact comparison of its decision is unavailable. |
  | **W3** | A record restates the register's extent. The extent lives in one place. |
  | **W4** | A record's name does not follow `NNNN-<slug>.md`. |
  | **W5** | The extent or the next free identifier the register document states disagrees with the table. |

  ## What it does not cover

  The check reads the Decision Register table and the records directory, and
  nothing else. It does not read the Reversibility Review table as a table —
  its rows are cross-references, not records. It reads the
  **Companion-documents table** for two things only: the record paths it
  names, which it checks exist (F4), and the fingerprints it records beside
  them, which it checks against the records (F5). It does not read a
  status-bearing line outside the records directory, such as a status inside
  another corpus document. It does not judge whether a decision is a good
  decision.
  """

  defstruct rows: 0,
            identifiers: [],
            extent: nil,
            stated_extent: nil,
            records: 0,
            pointers: 0,
            failures: [],
            warnings: []

  @type t :: %__MODULE__{
          rows: non_neg_integer(),
          identifiers: [String.t()],
          extent: {pos_integer(), pos_integer()} | nil,
          stated_extent: {pos_integer(), pos_integer()} | nil,
          records: non_neg_integer(),
          pointers: non_neg_integer(),
          failures: [failure()],
          warnings: [warning()]
        }

  @type failure :: %{
          class: String.t(),
          identifier: String.t() | nil,
          message: String.t(),
          detail: [String.t()]
        }

  @type warning :: %{class: String.t(), identifier: String.t() | nil, message: String.t()}

  @row_pattern ~r/^\|\s*(ADR-\d+)\s*\|/
  @header_pattern ~r/^\|\s*ID\s*\|/
  @identifier_line ~r/\*\*Identifier:\s*(ADR-\d+)\./
  @title_identifier ~r/^#\s+.*?(ADR-\d+)/m
  @fingerprint_pattern ~r/\*\*Decision fingerprint \(sha256\):\*\*\s*([0-9a-f]{64})/
  @reference_pattern ~r/ADR-\d+/
  @code_literal_pattern ~r/`([^`\n]+)`/
  @number_pattern ~r/\d+/
  @extent_restatement ~r/ADR-\d{3}\s*(?:\.\.\.|…|–|—|-)\s*ADR-\d{3}/
  @stated_extent_pattern ~r/ADR-(\d{3})\s*(?:\.\.\.|…)\s*ADR-(\d{3})\s+are all in the Decision Register table/
  @stated_next_pattern ~r/ADR-(\d{3})\s+is the next free identifier/
  @record_path_pattern ~r/docs\/adr\/[A-Za-z0-9._-]+\.md/
  @hex_pattern ~r/\b[0-9a-f]{64}\b/

  @status_vocabulary ["Proposed", "Accepted", "Rejected"]

  @doc """
  Checks a register document against a directory of records.

  Returns `{:ok, report}` when the two agree and `{:error, report}` when they
  do not. The report carries the failures and the warnings in both cases, so
  a caller prints one thing either way.

  The register document is parsed, not grepped: only its Decision Register
  table is read. The records directory is read in full, and a file that
  presents no Decision of its own is a pointer rather than a claim.

  An input that cannot be read at all — a missing file, a document with no
  Decision Register section — is a failure of class `R0` rather than an
  exception, so a caller has one shape to handle.
  """
  @spec check(Path.t(), Path.t()) :: {:ok, t()} | {:error, t()}
  def check(register_path, records_dir) do
    case load(register_path, records_dir) do
      {:ok, text, rows, expected, records} ->
        report = report(text, rows, expected, records, Path.dirname(Path.dirname(register_path)))

        if report.failures == [], do: {:ok, report}, else: {:error, report}

      {:error, message} ->
        {:error, %__MODULE__{failures: [failure("R0", nil, message, [])]}}
    end
  end

  defp load(register_path, records_dir) do
    with {:ok, text} <- read_file(register_path),
         {:ok, rows, expected} <- parse_rows(text),
         {:ok, records} <- read_records(records_dir) do
      {:ok, text, rows, expected, records}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp read_records(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        records =
          names
          |> Enum.filter(&(Path.extname(&1) == ".md"))
          |> Enum.sort()
          |> Enum.map(&parse_record(Path.join(dir, &1)))

        {:ok, records}

      {:error, reason} ->
        {:error, "cannot list #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_record(path) do
    text = File.read!(path)

    %{
      path: path,
      name: Path.basename(path),
      identifier: identifier(text),
      decision: decision_text(text),
      status: status_text(text),
      fingerprint: fingerprint(text),
      references: references(text),
      restates_extent: Regex.match?(@extent_restatement, text)
    }
  end

  defp identifier(text) do
    case Regex.run(@identifier_line, text) do
      [_, id] ->
        id

      nil ->
        case Regex.run(@title_identifier, text) do
          [_, id] -> id
          nil -> nil
        end
    end
  end

  defp decision_text(text) do
    case paragraph(text, "Decision") do
      nil -> nil
      body -> normalise(body)
    end
  end

  defp status_text(text), do: paragraph(text, "Status")

  defp fingerprint(text) do
    case Regex.run(@fingerprint_pattern, text) do
      [_, hex] -> hex
      nil -> nil
    end
  end

  defp references(text) when is_binary(text) do
    @reference_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [reference] -> reference end)
    |> MapSet.new()
  end

  defp references(_text), do: MapSet.new()

  defp paragraph(text, field) do
    marker = "**#{field}.**"
    lines = String.split(text, "\n")

    case Enum.split_while(lines, &(not String.starts_with?(&1, marker))) do
      {_before, []} ->
        nil

      {_before, [line | rest]} ->
        [String.trim_leading(line, marker) | rest]
        |> Enum.take_while(&(String.trim(&1) != ""))
        |> Enum.join(" ")
        |> normalise()
    end
  end

  defp normalise(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The register document.

  defp parse_rows(text) do
    case section(text, "Decision Register") do
      nil ->
        {:error, "the register document has no `## Decision Register` section"}

      body ->
        lines = String.split(body, "\n")

        case longest_run(lines) do
          [] ->
            {:error, "the `## Decision Register` section holds no `| ADR-NNN |` rows"}

          run ->
            rows = Enum.map(run, &parse_row/1)
            {:ok, rows, expected_columns(lines, rows)}
        end
    end
  end

  defp section(text, heading) do
    lines = String.split(text, "\n")
    wanted = "## " <> heading

    case Enum.find_index(lines, &(String.trim(&1) == wanted)) do
      nil ->
        nil

      index ->
        {_before, rest} = Enum.split(lines, index + 1)

        rest
        |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "## ")))
        |> Enum.join("\n")
    end
  end

  defp longest_run(lines), do: longest_run(lines, [])

  defp longest_run([], best), do: best

  defp longest_run([line | rest], best) do
    {run, rest} = take_rows([line | rest], [])

    if length(run) >= length(best) do
      longest_run(rest, run)
    else
      longest_run(rest, best)
    end
  end

  defp take_rows([line | rest], acc) do
    if Regex.match?(@row_pattern, line) do
      take_rows(rest, [line | acc])
    else
      {Enum.reverse(acc), rest}
    end
  end

  defp take_rows([], acc), do: {Enum.reverse(acc), []}

  defp expected_columns(lines, rows) do
    declared =
      case Enum.find(lines, &Regex.match?(@header_pattern, &1)) do
        nil -> nil
        header -> length(cells(header))
      end

    declared || first_row_width(rows) || 0
  end

  defp first_row_width([row | _]), do: length(row.cells)
  defp first_row_width([]), do: nil

  defp parse_row(line) do
    row_cells = cells(line)
    id = List.first(row_cells)

    %{
      id: id,
      number: identifier_number(id),
      cells: row_cells,
      decision: Enum.at(row_cells, 2),
      status: Enum.at(row_cells, 6)
    }
  end

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp identifier_number(id) when is_binary(id) do
    case id |> String.replace_prefix("ADR-", "") |> Integer.parse() do
      {number, _} -> number
      :error -> nil
    end
  end

  defp identifier_number(_id), do: nil

  # The report.

  defp report(text, rows, expected, records, root) do
    claims = Enum.filter(records, & &1.decision)
    pointers = Enum.reject(records, & &1.decision)
    identifiers = rows |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort_by(&identifier_number/1)

    table_fingerprints = recorded_fingerprints(text)

    failures =
      duplicate_failures(rows) ++
        gap_failures(rows) ++
        malformed_failures(rows, expected) ++
        unfiled_failures(claims, rows) ++
        double_claim_failures(claims) ++
        status_failures(claims, rows) ++
        drift_failures(claims, rows, table_fingerprints, root) ++
        dangling_failures(text, root) ++
        unfiled_claim_failures(pointers, claims)

    warnings =
      pointer_warnings(pointers) ++
        fingerprint_warnings(claims, table_fingerprints, root) ++
        extent_warnings(claims) ++
        name_warnings(claims) ++
        stated_extent_warnings(text, rows)

    %__MODULE__{
      rows: length(rows),
      identifiers: identifiers,
      extent: extent(identifiers),
      stated_extent: stated_extent(text),
      records: length(claims),
      pointers: length(pointers),
      failures: Enum.sort_by(failures, & &1.class),
      warnings: Enum.sort_by(warnings, & &1.class)
    }
  end

  defp extent(identifiers) do
    numbers = identifiers |> Enum.map(&identifier_number/1) |> Enum.reject(&is_nil/1)

    case numbers do
      [] -> nil
      numbers -> {Enum.min(numbers), Enum.max(numbers)}
    end
  end

  # R1 — a duplicated identifier.

  defp duplicate_failures(rows) do
    rows
    |> Enum.group_by(& &1.id)
    |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
    |> Enum.map(fn {id, group} ->
      failure(
        "R1",
        id,
        "the Decision Register table holds #{length(group)} rows for #{id}.",
        [
          "the register holds one row per decision, so a second row for the same identifier is a copy of a decision rather than a decision of its own"
        ]
      )
    end)
  end

  # R2 — a gap in the sequence.

  defp gap_failures(rows) do
    numbers = rows |> Enum.map(& &1.number) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case numbers do
      [] ->
        []

      numbers ->
        last = Enum.max(numbers)

        for number <- 1..last, number not in numbers do
          id = "ADR-" <> String.pad_leading(Integer.to_string(number), 3, "0")

          failure(
            "R2",
            id,
            "the identifier sequence skips #{id}.",
            [
              "identifiers are contiguous and monotonic: a gap means a decision was filed without a row, or a row was dropped, and either way a citation of that number now resolves to nothing"
            ]
          )
        end
    end
  end

  # R3 — a malformed row.

  defp malformed_failures(rows, expected) do
    rows
    |> Enum.filter(&(length(&1.cells) != expected))
    |> Enum.map(fn row ->
      failure(
        "R3",
        row.id,
        "the row for #{row.id} holds #{length(row.cells)} columns and the table's header declares #{expected}.",
        [
          "a row that has lost a column, or gained one, has had its content shifted between the Decision Register table and another table in the same document"
        ]
      )
    end)
  end

  # F1 — a record with no row.

  defp unfiled_failures(claims, rows) do
    known = MapSet.new(rows, & &1.id)

    claims
    |> Enum.reject(fn record ->
      record.identifier && MapSet.member?(known, record.identifier)
    end)
    |> Enum.map(fn record ->
      id = record.identifier || "no identifier at all"

      failure(
        "F1",
        record.identifier,
        "the record #{record.name} presents a Decision for #{id}, and the Decision Register table has no row for it.",
        [
          "a decision in the record tree that the table does not carry is invisible to every reader who reads the register: either the row was never filed, or the record is a proposal that was never absorbed"
        ]
      )
    end)
  end

  # F2 — one identifier, two claims.

  defp double_claim_failures(claims) do
    claims
    |> Enum.reject(&is_nil(&1.identifier))
    |> Enum.group_by(& &1.identifier)
    |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
    |> Enum.map(fn {id, group} ->
      failure(
        "F2",
        id,
        "#{length(group)} files present a Decision for #{id}.",
        Enum.map(group, &"#{&1.name} presents a Decision of its own")
      )
    end)
  end

  # F3 — a status disagreement.

  defp status_failures(claims, rows) do
    by_id = Map.new(rows, &{&1.id, &1})

    claims
    |> Enum.filter(& &1.identifier)
    |> Enum.flat_map(fn record ->
      case Map.get(by_id, record.identifier) do
        nil -> []
        row -> status_failure(row, record)
      end
    end)
  end

  defp status_failure(row, record) do
    row_status = normalise_status(row.status)
    file_status = normalise_status(record.status)

    cond do
      file_status == "" ->
        [
          failure(
            "F3",
            row.id,
            "the record #{record.name} carries no `**Status.**` line.",
            [
              "the status vocabulary is closed: Proposed, Accepted, Superseded by ADR-NNN, or Rejected"
            ]
          )
        ]

      not valid_status?(file_status) ->
        [
          failure(
            "F3",
            row.id,
            "the record #{record.name} states the status #{inspect(file_status)}, which is outside the closed vocabulary.",
            [
              "the status vocabulary is closed: Proposed, Accepted, Superseded by ADR-NNN, or Rejected"
            ]
          )
        ]

      row_status != file_status ->
        [
          failure(
            "F3",
            row.id,
            "the row for #{row.id} says the status is #{inspect(row_status)} and the record #{record.name} says #{inspect(file_status)}.",
            []
          )
        ]

      true ->
        []
    end
  end

  defp normalise_status(nil), do: ""

  defp normalise_status(text) do
    text
    |> String.trim()
    |> String.split(~r/[,.]/, parts: 2)
    |> List.first()
    |> Kernel.||("")
    |> String.replace(~r/\([^)]*\)/, "")
    |> String.trim()
  end

  defp valid_status?(status) do
    status in @status_vocabulary or Regex.match?(~r/^Superseded by ADR-\d+$/, status)
  end

  # F5 — a drifted decision.

  defp drift_failures(claims, rows, table_fingerprints, root) do
    by_id = Map.new(rows, &{&1.id, &1})

    claims
    |> Enum.filter(& &1.identifier)
    |> Enum.flat_map(fn record ->
      case Map.get(by_id, record.identifier) do
        nil -> []
        row -> drift_failure(row, record, table_fingerprints, root)
      end
    end)
  end

  defp drift_failure(row, record, table_fingerprints, root) do
    case drift_details(row, record, table_fingerprints, root) do
      [] ->
        []

      details ->
        [
          failure(
            "F5",
            row.id,
            "the record #{record.name} does not match the decision its row records.",
            details
          )
        ]
    end
  end

  defp drift_details(row, record, table_fingerprints, root) do
    row_literals = literals(row.decision)
    file_literals = literals(record.decision)

    code_only_row = MapSet.difference(row_literals.code, file_literals.code)
    code_only_file = MapSet.difference(file_literals.code, row_literals.code)
    number_only_row = MapSet.difference(row_literals.numbers, file_literals.numbers)
    number_only_file = MapSet.difference(file_literals.numbers, row_literals.numbers)

    missing_references =
      MapSet.difference(
        MapSet.new(references(row.decision)),
        MapSet.new(record.references)
      )

    computed = digest(record.decision)
    table_hex = Map.get(table_fingerprints, relative_path(record, root))

    []
    |> add(
      code_only_row != MapSet.new(),
      "the row names #{describe_code(code_only_row)} and the record does not"
    )
    |> add(
      code_only_file != MapSet.new(),
      "the record names #{describe_code(code_only_file)} and the row does not"
    )
    |> add(
      number_only_row != MapSet.new(),
      "the row states #{describe_numbers(number_only_row)} and the record does not"
    )
    |> add(
      number_only_file != MapSet.new(),
      "the record states #{describe_numbers(number_only_file)} and the row does not"
    )
    |> add(
      missing_references != MapSet.new(),
      "the row refers to #{describe_references(missing_references)} and the record does not"
    )
    |> add(
      record.fingerprint != nil and record.fingerprint != computed,
      "the fingerprint the record carries does not match the hash of its Decision paragraph — the decision was changed after it was filed"
    )
    |> add(
      record.fingerprint != nil and table_hex != nil and record.fingerprint != table_hex,
      "the fingerprint the register records beside this file and the one the record carries differ"
    )
    |> add(
      table_hex != nil and table_hex != computed,
      "the fingerprint the register records beside this file does not match the hash of its Decision paragraph"
    )
  end

  defp add(details, true, message), do: details ++ [message]
  defp add(details, false, _message), do: details

  # The decision-bearing literals of a decision statement.
  #
  # A row is a condensation of its record, so the two cannot be compared as
  # text: the record carries the reasoning the row leaves out. What the two
  # must agree on is the literals a decision is made of — the commands, the
  # module names and the numbers it names. An identifier is a reference to
  # another row rather than a literal of this one, so it is compared
  # separately and by presence rather than by set.

  defp literals(text) when is_binary(text) do
    code =
      @code_literal_pattern
      |> Regex.scan(text)
      |> Enum.map(fn [_match, token] ->
        token |> String.replace(~r/\s+/, " ") |> String.trim()
      end)
      |> MapSet.new()

    numbers =
      text
      |> String.replace(@reference_pattern, " ")
      |> then(&Regex.scan(@number_pattern, &1))
      |> Enum.map(fn [number] -> number end)
      |> MapSet.new()

    %{code: code, numbers: numbers}
  end

  defp literals(_text), do: %{code: MapSet.new(), numbers: MapSet.new()}

  defp describe_code(set) do
    set |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`")
  end

  defp describe_numbers(set) do
    set |> Enum.sort() |> Enum.map_join(", ", &"the number #{&1}")
  end

  defp describe_references(set) do
    set |> Enum.sort() |> Enum.map_join(", ", &"#{&1}")
  end

  defp digest(nil), do: ""

  defp digest(text) do
    text
    |> normalise()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The warnings.

  defp pointer_warnings(pointers) do
    Enum.map(pointers, fn record ->
      warning(
        "W1",
        record.identifier,
        "#{record.name} names #{record.identifier || "no identifier"} and presents no Decision of its own. It is a pointer rather than a claim, and it is owed for removal."
      )
    end)
  end

  defp fingerprint_warnings(claims, table_fingerprints, root) do
    Enum.map(claims, fn record ->
      table_hex = Map.get(table_fingerprints, relative_path(record, root))

      case {record.fingerprint, table_hex} do
        {nil, nil} ->
          warning(
            "W2",
            record.identifier,
            "#{record.name} carries no `**Decision fingerprint (sha256):**` line, so the exact comparison of its decision is unavailable."
          )

        {nil, hex} ->
          warning(
            "W2",
            record.identifier,
            "#{record.name} carries no `**Decision fingerprint (sha256):**` line, while the register records one beside it (`sha256:#{hex}`)."
          )

        {_hex, _table} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extent_warnings(claims) do
    Enum.filter(claims, & &1.restates_extent)
    |> Enum.map(fn record ->
      warning(
        "W3",
        record.identifier,
        "#{record.name} restates the register's extent. The extent lives in one place — the current-range paragraph in the register document — and a second copy of it is a second thing to keep true."
      )
    end)
  end

  defp name_warnings(claims) do
    claims
    |> Enum.map(fn record ->
      case record.identifier do
        nil ->
          warning(
            "W4",
            nil,
            "#{record.name} presents a Decision and names no identifier, so the check cannot tell which row it belongs to."
          )

        id ->
          expected = String.pad_leading(Integer.to_string(identifier_number(id)), 4, "0")

          if String.starts_with?(record.name, expected <> "-") do
            nil
          else
            warning(
              "W4",
              id,
              "#{record.name} does not follow the naming convention: the record for #{id} is named `#{expected}-<slug>.md`."
            )
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # F4 — a dangling reference.

  defp dangling_failures(text, root) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      @record_path_pattern
      |> Regex.scan(line)
      |> Enum.map(fn [path] -> path end)
    end)
    |> Enum.uniq()
    |> Enum.reject(&File.exists?(Path.join(root, &1)))
    |> Enum.map(fn path ->
      failure(
        "F4",
        identifier_from_path(path),
        "the register document names #{path}, and there is no such file.",
        [
          "a record path that points at a file which is not there sends the reader to nothing: the record was never filed, or it was renamed and the old name stayed beside it"
        ]
      )
    end)
  end

  defp identifier_from_path(path) do
    case Regex.run(~r/(\d{4})-[a-z0-9-]+\.md$/, path) do
      [_, number] -> "ADR-" <> String.slice(number, -3, 3)
      nil -> nil
    end
  end

  # F4 — an identifier claimed by a file that presents no Decision, with no
  # record file carrying it. The record was never filed.

  defp unfiled_claim_failures(pointers, claims) do
    claimed = MapSet.new(claims, & &1.identifier)

    Enum.reject(pointers, fn pointer ->
      is_nil(pointer.identifier) or MapSet.member?(claimed, pointer.identifier)
    end)
    |> Enum.map(fn record ->
      failure(
        "F4",
        record.identifier,
        "#{record.name} names #{record.identifier} and presents no Decision of its own, and no record file carries that identifier.",
        [
          "the identifier is claimed by a file that is not a record: the record was never filed, so a citation of that number resolves to nothing"
        ]
      )
    end)
  end

  # The fingerprints the register records beside its record files.
  #
  # A hex belongs to the record path it follows on the same line, which is
  # how the Companion-documents table writes it.

  defp recorded_fingerprints(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      paths = positions(line, @record_path_pattern)

      line
      |> positions(@hex_pattern)
      |> Enum.flat_map(fn {start, hex} ->
        case paths |> Enum.filter(fn {path_start, _} -> path_start < start end) |> List.last() do
          nil -> []
          {_, path} -> [{path, hex}]
        end
      end)
    end)
    |> Map.new()
  end

  defp positions(line, pattern) do
    pattern
    |> Regex.scan(line, return: :index)
    |> Enum.map(fn ranges ->
      {start, length} =
        case ranges do
          [_, capture] -> capture
          [full] -> full
        end

      {start, binary_part(line, start, length)}
    end)
  end

  defp relative_path(record, root) do
    record.path
    |> Path.relative_to(root)
    |> String.replace("\\", "/")
  end

  defp stated_extent(text) do
    case Regex.run(@stated_extent_pattern, text) do
      [_, first, last] -> {String.to_integer(first), String.to_integer(last)}
      nil -> nil
    end
  end

  defp stated_extent_warnings(text, rows) do
    identifiers = rows |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort_by(&identifier_number/1)

    extent_warning(text, identifiers) ++ next_free_warning(text, identifiers)
  end

  defp extent_warning(text, identifiers) do
    with stated when not is_nil(stated) <- stated_extent(text),
         actual when not is_nil(actual) <- extent(identifiers) do
      if stated == actual do
        []
      else
        [
          warning(
            "W5",
            nil,
            "the register document states the extent as ADR-#{pad(stated)} and the table holds ADR-#{pad(actual)}."
          )
        ]
      end
    else
      _ -> []
    end
  end

  defp next_free_warning(text, identifiers) do
    with [_, next] <- Regex.run(@stated_next_pattern, text),
         actual when not is_nil(actual) <- extent(identifiers) do
      expected = actual |> elem(1) |> Kernel.+(1)

      if String.to_integer(next) == expected do
        []
      else
        [
          warning(
            "W5",
            nil,
            "the register document states that ADR-#{next} is the next free identifier, and the table's highest identifier is ADR-#{pad(actual)}."
          )
        ]
      end
    else
      _ -> []
    end
  end

  defp pad({first, last}) do
    String.pad_leading(Integer.to_string(first), 3, "0") <>
      " … " <> String.pad_leading(Integer.to_string(last), 3, "0")
  end

  defp failure(class, identifier, message, detail) do
    %{class: class, identifier: identifier, message: message, detail: detail}
  end

  defp warning(class, identifier, message) do
    %{class: class, identifier: identifier, message: message}
  end
end
