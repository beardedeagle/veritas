defmodule Veritas.Store.Surreal.IncidentMigration do
  @moduledoc """
  Preservation-first v5 → v6 Incident storage migration.

  A query callback uses the Adapter's existing authenticated transport. The
  bootstrap statements are used only for a database with no tables. A receipt
  committed atomically with bootstrap distinguishes our interrupted bootstrap
  from a populated, unversioned database. No legacy row is rewritten.

  Run with Workspace writers quiesced. This is not a distributed migration
  lock. Definitions and row fingerprints are checked before marker advancement;
  transport failures and unknown metadata fail closed, never become an empty
  database or a successful partial migration.
  """

  alias Veritas.Store.Error
  alias Veritas.Store.Surreal.Schema

  @page_size 256
  @receipt "schema_version:incident_v6_bootstrap"
  @receipt_version "6-bootstrap"
  @identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/
  @type query :: (String.t() -> {:ok, [map()]} | {:error, Error.t()})

  @doc """
  Applies or resumes the owned migration and dispatches explicit audit intent.

  Args:
    query: Existing Adapter query function returning decoded rows.
    bootstrap: Complete schema/seed statements, only for an empty database.
    audit: Callback accepting `:verify` or explicit `:resign`, returning `:ok`
      or `{:error, reason}`. Normal migration must not rewrite an audit chain.
    opts: Keyword options; `:resign?` reflects the host's existing scoped intent.

  Returns:
    `:ok` after metadata/preservation checks, audit handling and marker commit;
    otherwise an actionable `{:error, Veritas.Store.Error.t()}` or transport error.
  """
  @spec run(query(), [String.t()], (atom() -> :ok | {:error, term()}), keyword()) ::
          :ok | {:error, term()}
  def run(query, bootstrap, audit, opts \\ []) do
    mode = if Keyword.get(opts, :resign?, false) == true, do: :resign, else: :verify

    with {:ok, inventory} <- inventory(query),
         {:ok, phase} <- phase(query, inventory) do
      case phase do
        :empty -> bootstrap(query, bootstrap, audit, mode)
        :bootstrap -> finish_bootstrap(query, audit, mode)
        :v5 -> upgrade(query, inventory, audit, mode)
        :v6 -> validate_current(query, inventory, audit, mode)
      end
    end
  end

  defp phase(_query, inventory) when map_size(inventory) == 0, do: {:ok, :empty}

  defp phase(query, inventory) do
    if Map.has_key?(inventory, "schema_version") do
      with {:ok, rows} <- query.("SELECT * FROM schema_version LIMIT 3;") do
        case rows do
          [%{"id" => "schema_version:current", "version" => version} = row]
          when version in ["5", "6"] ->
            if timestamp?(row["applied_at"]),
              do: {:ok, if(version == "5", do: :v5, else: :v6)},
              else: refuse(:malformed_version, %{version: version})

          [%{"id" => @receipt, "version" => @receipt_version} = row] ->
            if timestamp?(row["applied_at"]),
              do: {:ok, :bootstrap},
              else: refuse(:malformed_bootstrap_receipt)

          _ ->
            refuse(:unsupported_or_malformed_version)
        end
      end
    else
      refuse(:populated_unversioned_database)
    end
  end

  defp timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp timestamp?(_value), do: false

  defp bootstrap(query, statements, audit, mode) do
    receipt =
      "CREATE #{@receipt} SET version = '#{@receipt_version}', applied_at = time::now();"

    # DDL, initial seeds and receipt either all commit, or none of them do.
    # A retry after that commit validates only; it never reseeds user rows.
    with {:ok, _} <- query.(transaction(statements ++ [receipt])) do
      finish_bootstrap(query, audit, mode)
    end
  end

  defp finish_bootstrap(query, audit, mode) do
    with {:ok, inventory} <- inventory(query),
         {:ok, []} <- plan(inventory, false),
         :ok <- audit_result(audit, mode),
         {:ok, _} <-
           query.(transaction([
             "IF (SELECT VALUE version FROM #{@receipt}) != ['#{@receipt_version}'] { THROW 'The bootstrap receipt changed'; };",
             "IF (SELECT * FROM schema_version:current) != [] { THROW 'A schema marker already exists'; };",
             marker(),
             "DELETE #{@receipt};"
           ])) do
      :ok
    end
  end

  defp upgrade(query, before, audit, mode) do
    with {:ok, statements} <- plan(before, true),
         {:ok, fingerprints} <- fingerprints(query, Map.keys(before)),
         {:ok, _} <- apply_statements(query, statements),
         {:ok, after_inventory} <- inventory(query),
         {:ok, []} <- plan(after_inventory, false),
         :ok <- preserved_metadata(before, after_inventory),
         {:ok, after_fingerprints} <- fingerprints(query, Map.keys(before)),
         :ok <- equal_rows(fingerprints, after_fingerprints),
         :ok <- audit_result(audit, mode),
         {:ok, _} <-
           query.(transaction([
             "IF (SELECT VALUE version FROM schema_version:current) != ['5'] { THROW 'The schema version changed during migration'; };",
             marker()
           ])) do
      :ok
    end
  end

  defp validate_current(query, inventory, audit, mode) do
    # Explicit re-sign still runs on v6. An ordinary repeat verifies, but does
    # not rewrite rows, seed policies or change the existing applied_at value.
    with {:ok, []} <- plan(inventory, false),
         :ok <- audit_result(audit, mode) do
      :ok
    end
  end

  defp apply_statements(_query, []), do: {:ok, []}
  defp apply_statements(query, statements), do: query.(transaction(statements))

  defp audit_result(audit, mode) do
    case audit.(mode) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> refuse(:invalid_audit_result)
    end
  end

  defp transaction(statements) do
    terminated = Enum.map(statements, fn statement ->
      statement = String.trim(statement)
      if String.ends_with?(statement, ";"), do: statement, else: statement <> ";"
    end)

    Enum.join(["BEGIN TRANSACTION;" | terminated] ++ ["COMMIT TRANSACTION;"], "\n")
  end

  defp marker,
    do: "UPSERT schema_version:current SET version = '#{Schema.version()}', applied_at = time::now();"

  defp inventory(query) do
    with {:ok, [%{"tables" => tables}]} when is_map(tables) <- query.("INFO FOR DB;") do
      Enum.reduce_while(Enum.sort(tables), {:ok, %{}}, fn {name, definition}, {:ok, acc} ->
        if is_binary(name) and Regex.match?(@identifier, name) and is_binary(definition) do
          case query.("INFO FOR TABLE #{name};") do
            {:ok, [%{"fields" => fields, "indexes" => indexes, "events" => events} = info]}
            when is_map(fields) and is_map(indexes) and is_map(events) ->
              {:cont, {:ok, Map.put(acc, name, %{table: definition, info: info})}}

            {:error, _} = error -> {:halt, error}
            _ -> {:halt, refuse(:malformed_table_metadata, %{table: name})}
          end
        else
          {:halt, refuse(:unsupported_table_identifier)}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> refuse(:malformed_database_metadata)
    end
  end

  # Missing v6-owned declarations are additions; mismatched declarations are
  # not permission to overwrite a custom or damaged schema. Only priority has
  # an explicitly authorized old representation.
  defp plan(inventory, allow_additions?) do
    owned = Schema.incident_definitions()

    Enum.reduce_while(Enum.sort(Schema.definitions()), {:ok, []}, fn {table, expected}, {:ok, acc} ->
      new_table? = Map.has_key?(owned, table) and table not in ["ticket", "incident"]

      case Map.get(inventory, table) do
        nil when allow_additions? and new_table? ->
          statements = [expected.table | ordered(expected.fields) ++ ordered(expected.indexes)]
          {:cont, {:ok, acc ++ statements}}

        nil ->
          {:halt, refuse(:missing_table, %{table: table})}

        actual ->
          with :ok <- same_definition(actual.table, expected.table, table),
               {:ok, fields} <-
                 members(actual.info["fields"], expected.fields, owned[table], :fields, table, allow_additions?),
               {:ok, indexes} <-
                 members(actual.info["indexes"], expected.indexes, owned[table], :indexes, table, allow_additions?) do
            {:cont, {:ok, acc ++ fields ++ indexes}}
          else
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp ordered(map), do: map |> Enum.sort() |> Enum.map(&elem(&1, 1))

  defp members(actual, expected, owned, kind, table, allow_additions?) do
    Enum.reduce_while(Enum.sort(expected), {:ok, []}, fn {name, definition}, {:ok, acc} ->
      current = Map.get(actual, name)
      additive? = allow_additions? and owned != nil and Map.has_key?(owned[kind], name)
      priority? = table == "ticket" and kind == :fields and name == "priority"

      cond do
        is_binary(current) and equivalent?(current, definition) ->
          {:cont, {:ok, acc}}

        additive? and priority? and is_binary(current) and
            equivalent?(current, Schema.v5_priority_definition()) ->
          {:cont, {:ok, acc ++ [definition]}}

        additive? and is_nil(current) and not priority? ->
          {:cont, {:ok, acc ++ [definition]}}

        true ->
          {:halt, refuse(:schema_mismatch, %{table: table, member: name, kind: kind})}
      end
    end)
  end

  defp same_definition(actual, expected, table) do
    if equivalent?(actual, expected), do: :ok, else: refuse(:schema_mismatch, %{table: table})
  end

  # INFO emits canonical DDL, not necessarily the spelling used by DEFINE.
  # Normalize only presentation/default syntax, retaining literal bytes,
  # permissions, types, assertions, VALUE expressions and modifier flags.
  # Unknown representations refuse rather than guessing equivalence.
  @doc false
  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(left, right) when is_binary(left) and is_binary(right),
    do: signature(left) == signature(right)

  def equivalent?(_left, _right), do: false

  defp signature(definition) do
    tokens =
      Regex.scan(~r/'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`[^`]*`|\$[a-zA-Z_]\w*|[a-zA-Z_]\w*|\d+|!=|<=|>=|==|::|[^\s]/u, definition)
      |> List.flatten()
      |> Enum.reject(&(&1 in [";", "OVERWRITE"]))
      |> Enum.map(fn token ->
        if Regex.match?(~r/\A`[a-zA-Z_]\w*`\z/, token), do: String.trim(token, "`"), else: token
      end)
      |> remove_on_table()

    case tokens do
      ["DEFINE", "FIELD", name, "ON", table | rest] ->
        field_signature(name, table, rest)

      ["DEFINE", "TABLE", name | rest] ->
        rest = if Enum.take(rest, 2) == ["TYPE", "NORMAL"], do: Enum.drop(rest, 2), else: rest
        {:table, name, trim_suffix(rest, ["PERMISSIONS", "NONE"])}

      ["DEFINE", "INDEX", "search_chunk_fts", "ON", "search_chunk", "FIELDS", "content", "FULLTEXT"] ->
        tokens ++ ["ANALYZER", "like", "BM25", "(", "1", ".", "2", ",", "0", ".", "75", ")"]

      _ -> tokens
    end
  end

  defp remove_on_table(["ON", "TABLE" | rest]), do: ["ON" | remove_on_table(rest)]
  defp remove_on_table([token | rest]), do: [token | remove_on_table(rest)]
  defp remove_on_table([]), do: []

  defp field_signature(name, table, rest) do
    {flexible, rest} = {"FLEXIBLE" in rest, Enum.reject(rest, &(&1 == "FLEXIBLE"))}
    rest = trim_suffix(rest, ["PERMISSIONS", "FULL"])
    {type, clauses} = Enum.split_while(tl_or_empty(rest), &(&1 not in ["DEFAULT", "ASSERT", "VALUE", "READONLY", "PERMISSIONS", "COMMENT", "REFERENCE"]))
    {:field, name, table, hd_or_nil(rest), flexible, type_signature(type), clause_signature(clauses)}
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | tail]), do: tail
  defp hd_or_nil([]), do: nil
  defp hd_or_nil([head | _]), do: head

  defp type_signature(["option", "<" | rest]) do
    if List.last(rest) == ">", do: type_signature(Enum.drop(rest, -1) ++ ["|", "NONE"]), else: rest
  end

  defp type_signature(tokens) do
    # INFO spells the optional type member as lowercase none, not the NONE
    # value literal. Do not fold identifiers inside record/custom types.
    tokens =
      case tokens do
        ["none", "|" | rest] -> ["NONE", "|" | rest]
        _ ->
          case Enum.split(tokens, -2) do
            {rest, ["|", "none"]} -> rest ++ ["|", "NONE"]
            _ -> tokens
          end
      end

    case tokens do
      ["NONE", "|" | rest] -> rest ++ ["|", "NONE"]
      _ -> tokens
    end
  end

  # Only the observed owned DEFAULT/ASSERT forms have structural signatures.
  # Unsupported syntax keeps its exact tokens; parse failure is never equality.
  defp clause_signature([clause | rest]) when clause in ["DEFAULT", "ASSERT"] do
    {expression, tail} = Enum.split_while(rest, &(&1 not in ["DEFAULT", "ASSERT", "VALUE", "READONLY", "PERMISSIONS", "COMMENT", "REFERENCE"]))
    signature = if clause == "DEFAULT", do: default_signature(expression), else: assertion_signature(expression)
    [{clause, signature} | clause_signature(tail)]
  end

  defp clause_signature([]), do: []
  defp clause_signature(tokens), do: [{:exact, tokens}]

  defp default_signature(tokens) do
    priority = ["IF", "$this", ".", "ticket_type", "=", "'incident'", "{", "NONE", "}", "ELSE", "{", "'medium'", "}"]

    if tokens == priority or tokens == ["(" | priority] ++ [")"],
      do: :incident_priority_default,
      else: {:exact, tokens}
  end

  defp assertion_signature(tokens) do
    case owned_assertion(tokens) do
      {:ok, signature} -> {:owned, signature}
      :error -> {:exact, tokens}
    end
  end

  defp owned_assertion(["$value", operator, "NONE", "OR" | rest]) when operator in ["IS", "="] do
    case value_constraint(rest) do
      {:ok, constraint} -> {:ok, {:nullable, constraint}}
      :error -> :error
    end
  end

  defp owned_assertion(["(", "$this", ".", "ticket_type", "=", "'incident'", "AND", "$value", operator, "NONE", ")", "OR" | rest])
       when operator in ["IS", "="], do: priority_assertion(rest)

  defp owned_assertion(["$this", ".", "ticket_type", "=", "'incident'", "AND", "$value", operator, "NONE", "OR" | rest])
       when operator in ["IS", "="], do: priority_assertion(rest)

  defp owned_assertion(tokens), do: enum_constraint(tokens)

  defp priority_assertion(tokens) do
    case enum_constraint(tokens) do
      {:ok, constraint} -> {:ok, {:incident_priority, constraint}}
      :error -> :error
    end
  end

  defp value_constraint(["(", "$value", ">=", low, "AND", "$value", "<=", high, ")"]),
    do: range_constraint(low, high)

  defp value_constraint(["$value", ">=", low, "AND", "$value", "<=", high]),
    do: range_constraint(low, high)

  defp value_constraint(["$value", operator, integer]) when operator in [">", ">="] do
    if Regex.match?(~r/\A[0-9]+\z/, integer), do: {:ok, {:comparison, operator, integer}}, else: :error
  end

  defp value_constraint(tokens), do: enum_constraint(tokens)

  defp range_constraint(low, high) do
    if Regex.match?(~r/\A[0-9]+\z/, low) and Regex.match?(~r/\A[0-9]+\z/, high),
      do: {:ok, {:inclusive_range, low, high}},
      else: :error
  end

  defp enum_constraint(["$value", operator, "[" | rest]) when operator in ["IN", "INSIDE"] do
    case string_members(rest) do
      {:ok, members} -> {:ok, {:enum, members}}
      :error -> :error
    end
  end

  defp enum_constraint(_tokens), do: :error

  defp string_members([literal, "]"]) do
    if string_literal?(literal), do: {:ok, [literal]}, else: :error
  end

  defp string_members([literal, "," | rest]) do
    with true <- string_literal?(literal),
         {:ok, members} <- string_members(rest) do
      {:ok, [literal | members]}
    else
      _ -> :error
    end
  end

  defp string_members(_tokens), do: :error
  defp string_literal?(token), do: Regex.match?(~r/\A'(?:\\.|[^'\\])*'\z/u, token)

  defp trim_suffix(tokens, suffix) do
    if Enum.take(tokens, -length(suffix)) == suffix, do: Enum.drop(tokens, -length(suffix)), else: tokens
  end

  defp preserved_metadata(before, after_inventory) do
    Enum.reduce_while(before, :ok, fn {table, old}, :ok ->
      current = Map.get(after_inventory, table)

      preserved? =
        current != nil and old.table == current.table and
          Enum.all?(old.info, fn {section, values} ->
            now = current.info[section]

            if is_map(values) and is_map(now) do
              Enum.all?(values, fn {name, value} ->
                (table == "ticket" and section == "fields" and name == "priority") or
                  Map.get(now, name) == value
              end)
            else
              now == values
            end
          end)

      if preserved?, do: {:cont, :ok}, else: {:halt, refuse(:metadata_changed, %{table: table})}
    end)
  end

  defp fingerprints(query, tables) do
    tables
    |> Enum.reject(&(&1 == "schema_version"))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn table, {:ok, acc} ->
      case fingerprint(query, table, 0, :crypto.hash_init(:sha256)) do
        {:ok, result} -> {:cont, {:ok, Map.put(acc, table, result)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp fingerprint(query, table, offset, hash) do
    statement = "SELECT * FROM #{table} ORDER BY id LIMIT #{@page_size} START #{offset};"

    with {:ok, rows} when is_list(rows) <- query.(statement) do
      if length(rows) <= @page_size and Enum.all?(rows, &(is_map(&1) and Map.has_key?(&1, "id"))) do
        hash = Enum.reduce(rows, hash, fn row, acc -> :crypto.hash_update(acc, :erlang.term_to_binary(row, [:deterministic])) end)
        count = offset + length(rows)

        if length(rows) == @page_size,
          do: fingerprint(query, table, count, hash),
          else: {:ok, {count, :crypto.hash_final(hash)}}
      else
        refuse(:malformed_row_page, %{table: table, offset: offset})
      end
    else
      {:error, _} = error -> error
      _ -> refuse(:malformed_row_page, %{table: table, offset: offset})
    end
  end

  defp equal_rows(before, after_rows) do
    if before == after_rows, do: :ok, else: refuse(:rows_changed_during_migration)
  end

  defp refuse(reason, details \\ %{}) do
    {:error,
     Error.new(:invalid_request, "Incident schema migration refused: #{reason}. Preserve the database and inspect the reported schema; no automatic legacy conversion is permitted.",
       details: Map.put(details, :migration_reason, reason)
     )}
  end
end
