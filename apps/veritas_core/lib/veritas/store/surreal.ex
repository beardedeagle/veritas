defmodule Veritas.Store.Surreal do
  @moduledoc """
  The shipped data-access Adapter: SurrealDB over raw HTTP.

  It implements the `Veritas.Store` contract (`docs/32`, ADR-033). The
  datastore is a **Default**: this Adapter is the implementation that ships,
  and any Adapter that satisfies the same contract may replace it without a
  fork.

  ## Why not the official client

  `surrealdb.ex` embeds a Rust NIF. That breaks the distribution matrix —
  Alpine/musl, Windows and Nix each need per-target prebuilt NIFs — and a NIF
  crash takes the whole BEAM down with it. So the client is hand-written over
  Finch.

  ## How a transaction works

  A transaction buffers its statements and sends them as **one** HTTP request
  wrapped in `BEGIN TRANSACTION; … COMMIT TRANSACTION;`. SurrealDB executes a
  multi-statement request atomically, so the domain change, its Audit Log row
  and the outbox row land together or not at all (the `atomic_audit` and
  `atomic_outbox` capabilities).

  A read inside a transaction is served immediately — SurrealDB's HTTP API has
  no cursor to read from inside an open transaction — and the Adapter keeps an
  overlay of the rows the transaction has written, so a read observes the
  transaction's **own** writes (read-your-writes) and the committed state
  otherwise.

  ## When a statement fails

  The engine answers a batch with **one result per statement, in order**, and
  the batch is `BEGIN;` + the statements + `COMMIT;` — so the result at index
  `i` names the statement at index `i - 1`. The Adapter uses that to put the
  **failing statement** in the error's details, so a store fault says which
  statement failed instead of only that something did.

  Two things keep that honest:

    * the statements the Adapter buffers are **one statement each** to the
      engine. The outbox's `LET …;` and the `UPSERT` that uses it are two
      statements to the engine, so they are two here too — otherwise the
      engine's results and the Adapter's list fall out of step and a failure
      names the wrong statement;
    * the statement in the details is the statement **as it may be shown**: a
      credential-shaped value in it (a password hash) is replaced with `NONE`.
      A statement is the Adapter's own text and it holds the caller's data, so
      it is a detail — it travels in an error, where a diagnosis can use it,
      and it never crosses the API boundary.

  ## Workspace isolation

  Each Workspace is a **database** in the store, and every request carries the
  Workspace in the `surreal-ns` and `surreal-db` headers. A statement cannot
  be built without a Workspace, so a row cannot be read across Workspaces.

  ## The free build

  The free build is single-node: no quorum, so no automatic datastore
  failover. The coordination layer in `docs/26` covers that instead. It does
  have the multi-paradigm engine — the graph model, HNSW vector indexes, BM25
  full-text, time-series, changefeeds and record-level permissions — and this
  Adapter uses all of them.
  """

  @behaviour Veritas.Store

  require Logger

  alias Veritas.Store
  alias Veritas.Store.Chain
  alias Veritas.Store.Error
  alias Veritas.Store.Surreal.Schema
  alias Veritas.Store.Tx

  defmodule Raw do
    @moduledoc """
    A SurrealQL fragment that is written as it is.

    Used for exactly one thing: a variable reference in a `SET` clause. A
    string would be quoted, and `'$auditseq'` is a string, not the value the
    transaction allocated.
    """
    defstruct [:value]
  end

  @max_traversal_depth 5
  # The node budget of a traversal. The corpus caps nodes and not only depth:
  # depth five at a fan-out of twelve visits 248,832 nodes, which is an
  # outage. A traversal that reaches the budget stops and says it was
  # truncated — a partial graph that admits it is honest.
  @max_traversal_nodes 5_000
  @reconcile_limit 500
  @max_list_limit 1_000

  # ── the contract ──────────────────────────────────────────────────────────

  @impl true
  def transaction(workspace, fun, _opts \\ []) do
    # The Workspace name reaches a statement — it is a record id, and it is
    # part of a sequence's composite id — so it is held to the same allowlist
    # as any other id. A Workspace whose name cannot be an id is refused
    # here, before a statement is built from it.
    case id_or_nil(workspace) do
      nil ->
        {:error,
         Error.new(
           :invalid_request,
           "a workspace name may contain only letters, digits and underscore",
           details: %{}
         )}

      workspace ->
        run_transaction(workspace, fun)
    end
  end

  defp run_transaction(workspace, fun) do
    {:ok, accumulator} = Tx.start_link(workspace)

    try do
      case fun.({:veritas_store_tx, accumulator}) do
        {:error, reason} ->
          {:error, reason}

        value ->
          case commit(accumulator) do
            {:ok, _rows} -> value
            {:error, reason} -> {:error, reason}
          end
      end
    rescue
      error ->
        {:error,
         Error.new(:internal, "the transaction raised: #{Exception.message(error)}",
           details: %{exception: error, stacktrace: __STACKTRACE__}
         )}
    after
      Tx.stop(accumulator)
    end
  end

  @impl true
  def fetch({:veritas_store_tx, accumulator}, table, record_id) do
    id = normalise_id(record_id)

    case Tx.get_overlay(accumulator, table, id) do
      {:ok, record} ->
        # A row the transaction has deleted does not exist. The overlay holds
        # the marker the delete leaves behind, and the marker is not a record.
        if Veritas.Store.Filter.deleted?(record), do: {:ok, nil}, else: {:ok, record}

      :error ->
        statement = "SELECT * FROM #{table_name(table)}:#{id}"

        case request(workspace(accumulator), statement) do
          {:ok, [row | _]} -> {:ok, normalise_row(row, table)}
          {:ok, []} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def put({:veritas_store_tx, accumulator}, table, record) do
    id = normalise_id(Map.get(record, "id") || Map.get(record, :id))

    if is_nil(id) do
      {:error, Error.new(:invalid_request, "a record needs an id", details: %{table: table})}
    else
      case Schema.declared_fields()[table_name(table)] do
        nil ->
          # A table the schema does not declare is a table the store does not
          # have. Writing to it would leave a row the engine invents, with no
          # fields declared and no Workspace scope — so the write is refused,
          # and the refusal names the table.
          {:error,
           Error.new(:invalid_request, "the table is not declared in the store's schema",
             details: %{table: table_name(table)}
           )}

        _declared ->
          row =
            record
            |> Map.put("id", id)
            |> stamp_workspace(table, workspace(accumulator))

          with :ok <- validate_references(table, row) do
            {statement, shown} = upsert_statements(table, id, row)

            :ok = Tx.buffer(accumulator, statement, shown)
            buffer_outbox(accumulator, workspace(accumulator), table, id, "put")
            :ok = Tx.put_overlay(accumulator, table, id, row)

            {:ok, row}
          end
      end
    end
  end

  @impl true
  def delete({:veritas_store_tx, accumulator}, table, record_id) do
    id = normalise_id(record_id)

    :ok = Tx.buffer(accumulator, "DELETE #{table_name(table)}:#{id}")
    buffer_outbox(accumulator, workspace(accumulator), table, id, "delete")
    :ok = Tx.put_overlay(accumulator, table, id, %{"id" => id, "deleted" => true})
    :ok
  end

  # The statement that writes a row, and the statement as it may be shown.
  #
  # A statement is the Adapter's own text and it holds the caller's data, so
  # it is a **detail**: it travels in an error, where a diagnosis can use
  # it, and it never crosses the API boundary. But a row may carry a
  # credential — a password hash — and a credential does not belong in an
  # error, however useful the statement would be there.
  #
  # So the two statements differ only where the row has a secret field, and
  # the shown one carries `NONE` in its place.
  defp upsert_statements(table, id, row) do
    statement = "UPSERT #{table_name(table)}:#{id} #{encode_fields(row, table)}"

    if secret_field?(row) do
      shown_row = redact_row(row)
      {statement, "UPSERT #{table_name(table)}:#{id} #{encode_fields(shown_row, table)}"}
    else
      {statement, statement}
    end
  end

  # The fields whose values must never leave the host in a diagnostic.
  #
  # The list is deliberately broad: a false positive costs a diagnostic one
  # value, and a false negative costs a credential.
  @secret_field_markers ~w(password secret token credential private_key)

  defp secret_field?(row) do
    Enum.any?(row, fn {key, _value} -> secret_field_name?(key) end)
  end

  defp secret_field_name?(key) do
    name = key |> to_string() |> String.downcase()

    Enum.any?(@secret_field_markers, fn marker -> String.contains?(name, marker) end)
  end

  defp redact_row(row) do
    Map.new(row, fn {key, value} ->
      if secret_field_name?(key), do: {key, "NONE"}, else: {key, value}
    end)
  end

  @impl true
  def list({:veritas_store_tx, accumulator}, table, filter) do
    filter = filter || %{where: []}
    overlay = Tx.overlay_rows(accumulator, table)

    own =
      overlay
      |> Enum.reject(&Veritas.Store.Filter.deleted?/1)
      |> Veritas.Store.Filter.filter_rows(filter[:where] || [])

    # Exclude every replaced/deleted committed version BEFORE pagination.
    # Otherwise a delete or a change out of the filter leaves a short page.
    extra =
      [workspace_clause(table, workspace(accumulator)), list_exclusions(table, overlay)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" AND ")

    statement =
      [
        "SELECT * FROM #{table_name(table)}",
        where_clause(filter[:where] || [], extra, table),
        order_clause(filter[:order_by])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    offset = filter[:offset] || 0

    # At most length(own) rows can be inserted ahead of the engine's page.
    # Skip only the committed prefix guaranteed to precede the merged page;
    # retain at most the requested page plus that already-buffered overlap.
    {start, count} =
      if filter[:limit] do
        start = max(offset - length(own), 0)
        {start, min(filter[:limit], @max_list_limit) + offset - start}
      else
        {0, nil}
      end

    with {:ok, rows} <- list_rows(workspace(accumulator), statement, count, start) do
      rows = Enum.map(rows, &normalise_row(&1, table))
      page = Map.put(filter, :offset, offset - start)
      {:ok, Veritas.Store.Filter.apply(rows ++ own, page)}
    end
  end

  defp list_exclusions(_table, []), do: nil

  defp list_exclusions(table, overlay) do
    ids = Enum.map_join(overlay, ", ", &record_ref(table, &1["id"]))
    "id NOT IN [#{ids}]"
  end

  # Individual requests retain the existing bound, even when a transaction's
  # own writes require a wider candidate window. No full-table fetch replaces
  # a bounded request, and a later-page error is returned, not a partial answer.
  defp list_rows(workspace, statement, nil, _start), do: request(workspace, statement)

  defp list_rows(workspace, statement, count, start) do
    size = min(count, @max_list_limit)

    with {:ok, rows} <- request(workspace, statement <> " " <> limit_clause(size, start)) do
      if count > size and length(rows) == size do
        with {:ok, rest} <- list_rows(workspace, statement, count - size, start + size) do
          {:ok, rows ++ rest}
        end
      else
        {:ok, rows}
      end
    end
  end

  @impl true
  def next_sequence({:veritas_store_tx, accumulator}, key) do
    statement =
      "UPSERT #{sequence_table()}:#{sequence_id(workspace(accumulator), key)} " <>
        "SET next_value += 1 RETURN next_value"

    case request(workspace(accumulator), statement) do
      {:ok, [%{"next_value" => value} | _]} -> {:ok, value}
      {:ok, _rows} -> {:error, Error.new(:protocol, "the sequence statement returned no value")}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def relate({:veritas_store_tx, accumulator}, kind, from, to, attrs) do
    from_id = normalise_id(from)
    to_id = normalise_id(to)

    with {:ok, spec} <- relation_kind_spec({:veritas_store_tx, accumulator}, kind) do
      edge_table = edge_table(spec)
      edge_id = edge_id(kind, from_id, to_id)

      statement = edge_statement(spec, kind, edge_table, edge_id, from_id, to_id, attrs)

      :ok = Tx.buffer(accumulator, "DELETE #{edge_table}:#{edge_id}")
      :ok = Tx.buffer(accumulator, statement)

      buffer_outbox(
        accumulator,
        workspace(accumulator),
        String.to_atom(edge_table),
        edge_id,
        "put"
      )

      {:ok,
       %{
         "id" => edge_id,
         "kind" => to_string(kind),
         "from" => from_id,
         "to" => to_id,
         "attributes" => attrs
       }}
    end
  end

  # A kind that names its endpoint tables gets a **relation table**: a typed
  # edge the engine can traverse. A kind that does not gets a plain edge table
  # with `from` and `to` columns. Both are first-class typed records; the
  # difference is whether the engine can walk the edge itself.
  defp edge_statement(spec, kind, edge_table, edge_id, from_id, to_id, attrs) do
    case {spec["from_table"], spec["to_table"]} do
      {from_table, to_table} when is_binary(from_table) and is_binary(to_table) ->
        "RELATE #{table_name(from_table)}:#{from_id}->#{edge_table}:#{edge_id}->" <>
          "#{table_name(to_table)}:#{to_id} " <>
          encode_fields(Map.put(attrs, "kind", to_string(kind)), edge_table, ["kind"])

      _other ->
        "UPSERT #{edge_table}:#{edge_id} " <>
          encode_fields(
            attrs
            |> Map.put("kind", to_string(kind))
            |> Map.put("from", from_id)
            |> Map.put("to", to_id),
            edge_table,
            ["kind", "from", "to"]
          )
    end
  end

  @impl true
  def unrelate({:veritas_store_tx, accumulator}, kind, from, to) do
    from_id = normalise_id(from)
    to_id = normalise_id(to)

    with {:ok, spec} <- relation_kind_spec({:veritas_store_tx, accumulator}, kind) do
      edge_table = edge_table(spec)
      edge_id = edge_id(kind, from_id, to_id)

      :ok = Tx.buffer(accumulator, "DELETE #{edge_table}:#{edge_id}")

      buffer_outbox(
        accumulator,
        workspace(accumulator),
        String.to_atom(edge_table),
        edge_id,
        "delete"
      )

      :ok
    end
  end

  @impl true
  def traverse({:veritas_store_tx, accumulator}, from, direction, depth, opts) do
    depth = min(depth, @max_traversal_depth)
    kinds = opts |> Keyword.get(:kinds) |> normalise_kinds()
    id = normalise_id(from)

    {nodes, truncated} =
      walk(
        {:veritas_store_tx, accumulator},
        [id],
        direction,
        depth,
        [],
        MapSet.new([id]),
        kind_specs({:veritas_store_tx, accumulator}, kinds)
      )

    {:ok,
     %{
       nodes: nodes,
       edges: Enum.map(nodes, &Map.get(&1, "edge", %{})),
       truncated: truncated
     }}
  end

  @impl true
  def relation_counts({:veritas_store_tx, accumulator}, ids) do
    ids = ids |> Enum.map(&normalise_id/1) |> Enum.uniq()

    specs = kind_specs({:veritas_store_tx, accumulator}, nil)

    case edges_for_level(accumulator, ids, :both, specs) do
      {:ok, edges} ->
        # The rows come back in the store's own shape — a relation row names its
        # ends `in` and `out` — and the count reads `from` and `to`. They are
        # the same ends under the names the Adapter normalises them to, so the
        # rows are normalised first. Counting the raw rows finds no `from` and
        # no `to`, and every CI reads as having no relations at all.
        edges = Enum.map(edges, &normalise_edge_for(&1, specs))
        {:ok, count_relations(ids, edges)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # How many relations each of the records has.
  #
  # A relation is counted by its ends: the record on one side of the edge is
  # the record the other side is related to, and the two directions are
  # counted apart, because a relation that goes both ways is two relations.
  # The count is the number of *distinct* neighbours, which is what the CMDB
  # shows: two kinds of relation reaching one CI is one CI with two
  # relations, and the count says two.
  defp count_relations(ids, edges) do
    ids
    |> Enum.reduce(%{}, fn id, acc ->
      Map.put(acc, id, %{in: MapSet.new(), out: MapSet.new()})
    end)
    |> then(fn acc ->
      Enum.reduce(edges, acc, fn edge, acc ->
        acc
        |> count_one(edge["to"], edge["from"], :in)
        |> count_one(edge["from"], edge["to"], :out)
      end)
    end)
    |> Map.new(fn {id, sides} -> {id, MapSet.size(sides.in) + MapSet.size(sides.out)} end)
  end

  defp count_one(acc, root, neighbour, side) do
    case Map.fetch(acc, root) do
      {:ok, sides} ->
        Map.put(acc, root, Map.put(sides, side, MapSet.put(sides[side], neighbour)))

      :error ->
        acc
    end
  end

  @impl true
  def impact({:veritas_store_tx, accumulator}, ci_id, depth) do
    depth = min(depth, @max_traversal_depth)
    id = normalise_id(ci_id)

    case fetch({:veritas_store_tx, accumulator}, :ci, id) do
      {:ok, nil} ->
        {:ok, %{ci: nil, services: [], tickets: []}}

      {:error, reason} ->
        {:error, reason}

      {:ok, ci} ->
        {dependents, _truncated} =
          walk(
            {:veritas_store_tx, accumulator},
            [id],
            :in,
            depth,
            [],
            MapSet.new([id]),
            kind_specs({:veritas_store_tx, accumulator}, ["depends_on"])
          )

        dependents = Enum.map(dependents, & &1["id"])

        services =
          dependents
          |> Enum.map(&{&1, "ci", %{}})
          |> then(&fetch_rows(accumulator, &1))
          |> Map.values()
          |> Enum.filter(&(&1["ci_type"] == "service"))

        {:ok, tickets} = tickets_for(accumulator, [id | dependents])

        {:ok, %{ci: ci, services: services, tickets: tickets}}
    end
  end

  @impl true
  def put_ci_type({:veritas_store_tx, accumulator}, spec) do
    id = normalise_id(Map.get(spec, "id"))

    # The Adapter owns the Workspace scope, so the row carries the Workspace
    # of the transaction that wrote it. The `ci_type` table declares the
    # reference and does not allow it to be absent: a CI type that belongs to
    # no Workspace is a type every Workspace can see.
    row =
      Map.merge(spec, %{"id" => id})
      |> stamp_workspace(:ci_type, workspace(accumulator))

    statement = "UPSERT ci_type:#{id} #{encode_fields(row, :ci_type)}"

    :ok = Tx.buffer(accumulator, statement)
    buffer_outbox(accumulator, workspace(accumulator), :ci_type, id, "put")
    :ok = Tx.put_overlay(accumulator, :ci_type, id, row)

    {:ok, row}
  end

  @impl true
  def put_relation_kind({:veritas_store_tx, accumulator}, spec) do
    id = normalise_id(Map.get(spec, "id"))
    from_table = to_string(Map.get(spec, "from_table"))
    to_table = to_string(Map.get(spec, "to_table"))

    row = Map.merge(spec, %{"id" => id, "from_table" => from_table, "to_table" => to_table})

    # The registry is data; the edge table is the engine's shape for it. Both
    # are written here so a kind registered at runtime is usable immediately.
    statements = [
      "UPSERT relation_kind:#{id} #{encode_fields(row, :relation_kind)}",
      edge_table_definition(row)
    ]

    Enum.each(statements, &Tx.buffer(accumulator, &1))

    :ok =
      buffer_outbox(accumulator, workspace(accumulator), :relation_kind, id, "put")

    :ok = Tx.put_overlay(accumulator, :relation_kind, id, row)

    {:ok, row}
  end

  @impl true
  def ci_types({:veritas_store_tx, accumulator}) do
    case request(workspace(accumulator), "SELECT * FROM ci_type ORDER BY id ASC") do
      {:ok, rows} ->
        {:ok,
         rows |> Enum.map(&normalise_row(&1, "ci_type")) |> merge_overlay(accumulator, :ci_type)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def relation_kinds({:veritas_store_tx, accumulator}) do
    case request(workspace(accumulator), "SELECT * FROM relation_kind ORDER BY id ASC") do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.map(&normalise_row(&1, "relation_kind"))
         |> merge_overlay(accumulator, :relation_kind)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upsert_chunks({:veritas_store_tx, accumulator}, subject, chunks) do
    id = normalise_id(subject)

    # A chunk's index is a number, and it is part of the chunk's record id.
    # A chunk whose index is not a number is refused before anything is
    # written: the alternative — filing it under a different index — would
    # answer a question nobody asked, and would leave the chunk's own field
    # and its record id disagreeing.
    with :ok <- validate_chunk_indices(chunks) do
      upsert_validated_chunks(accumulator, id, chunks)
    end
  end

  defp validate_chunk_indices(chunks) do
    invalid? =
      Enum.any?(chunks, fn chunk ->
        case Map.get(chunk, "chunk_index") do
          value when is_integer(value) and value >= 0 -> false
          _other -> true
        end
      end)

    if invalid? do
      {:error,
       Error.new(:invalid_request, "a chunk index must be a non-negative integer", details: %{})}
    else
      :ok
    end
  end

  defp upsert_validated_chunks(accumulator, id, chunks) do
    # A new generation replaces the old chunks rather than mutating them: a
    # hit's score is only comparable within one embedding version.
    #
    # The old chunks are removed by a filtered table delete. A wildcard in a
    # record id (`search_chunk:subject_*`) is not a record id, and the store
    # refuses to parse it.
    :ok = Tx.buffer(accumulator, "DELETE search_chunk WHERE subject = #{encode(id)}")

    statements =
      Enum.map(chunks, fn chunk ->
        index = Map.get(chunk, "chunk_index")
        chunk_id = "#{id}_#{index}"

        "UPSERT search_chunk:#{chunk_id} #{encode_fields(Map.merge(chunk, %{"id" => chunk_id, "subject" => id}), :search_chunk)}"
      end)

    Enum.each(statements, &Tx.buffer(accumulator, &1))
    {:ok, length(chunks)}
  end

  @impl true
  def vector_search({:veritas_store_tx, accumulator}, embedding, opts) do
    limit = min(Keyword.get(opts, :limit, 10), @max_list_limit)

    statement =
      "SELECT id, subject, chunk_index, content, " <>
        "vector::similarity::cosine(embedding, #{encode(embedding)}) AS score " <>
        "FROM search_chunk ORDER BY score DESC, id ASC LIMIT #{limit}"

    case request(workspace(accumulator), statement) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fulltext_search({:veritas_store_tx, accumulator}, query, opts) do
    limit = min(Keyword.get(opts, :limit, 10), @max_list_limit)

    terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&escape_literal/1)

    match =
      case terms do
        [] -> "content @1@ ''"
        [term] -> "content @1@ #{term}"
        terms -> Enum.map_join(terms, " OR ", &"content @1@ #{&1}")
      end

    statement =
      "SELECT id, subject, chunk_index, content, search::score(1) AS score " <>
        "FROM search_chunk WHERE #{match} ORDER BY score DESC, id ASC LIMIT #{limit}"

    case request(workspace(accumulator), statement) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def append_samples({:veritas_store_tx, accumulator}, samples) do
    statements =
      Enum.map(samples, fn sample ->
        target = normalise_id(Map.get(sample, "target"))
        metric = to_string(Map.get(sample, "metric") || "value")
        at = Map.get(sample, "at")

        # A sample carries its own id when it has one; otherwise the id is
        # derived from the target, the bucket and the metric, so a re-write
        # of the same sample replaces it rather than duplicating it.
        id =
          case Map.get(sample, "id") do
            nil -> composite_id([target, iso(at), metric])
            given -> normalise_id(given)
          end

        row =
          sample
          |> Map.put("id", id)
          |> Map.put("metric", metric)

        "UPSERT metric_sample:#{id} #{encode_fields(row, :metric_sample)}"
      end)

    Enum.each(statements, &Tx.buffer(accumulator, &1))
    {:ok, length(samples)}
  end

  @impl true
  def range_samples({:veritas_store_tx, accumulator}, target, from, to, opts) do
    limit = min(Keyword.get(opts, :limit, 1_000), @max_list_limit)
    id = normalise_id(target)

    statement =
      "SELECT * FROM metric_sample WHERE target = #{encode(id)} " <>
        "AND at >= #{encode(from)} AND at <= #{encode(to)} ORDER BY at ASC LIMIT #{limit}"

    case request(workspace(accumulator), statement) do
      {:ok, rows} -> {:ok, Enum.map(rows, &normalise_row(&1, "metric_sample"))}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def append_audit({:veritas_store_tx, accumulator}, event) do
    id = normalise_id(Map.get(event, "id"))
    workspace = workspace(accumulator)

    # The sequence is allocated for the transaction and stamped on the row, so
    # the value the caller is handed is the value the row carries. It is
    # allocated before the commit, so a transaction that aborts leaves a gap —
    # monotonic, never gapless, and never reused.
    {:ok, sequence} = next_sequence({:veritas_store_tx, accumulator}, {:audit, workspace})

    row =
      event
      |> Map.put("id", id)
      |> Map.put("sequence", sequence)
      |> Map.put("workspace", workspace)

    statement = "UPSERT audit_event:#{id} #{encode_fields(row, :audit_event)}"

    :ok = Tx.buffer(accumulator, statement)
    buffer_outbox(accumulator, workspace, :audit_event, id, "put")

    # The row joins the transaction's overlay, so that a later read in this
    # transaction sees it. The Audit Log's chain is built from the rows a
    # transaction can read, and an audit row no read can see is an event with
    # no predecessor: two events in one transaction would take the same
    # predecessor, and the chain would fork.
    #
    # The overlay row carries the shape the committed row will have — the
    # sequence it was allocated, the predecessor the caller chose and the
    # signature over them — so that the event after it links to it.
    :ok = Tx.put_overlay(accumulator, :audit_event, id, row)

    {:ok, sequence}
  end

  @impl true
  def changes({:veritas_store_tx, accumulator}, since, opts) do
    limit = min(Keyword.get(opts, :limit, 100), @max_list_limit)

    # The sequence is a number. It is checked rather than escaped, because a
    # number is what it is: a value that is not one is a caller mistake, and
    # a sequence that is not a number is not a sequence. It is refused rather
    # than coerced, because coercing it to zero would quietly answer a
    # different question than the one that was asked.
    case since do
      value when is_integer(value) and value >= 0 ->
        statement =
          "SELECT * FROM event_outbox WHERE sequence > #{value} ORDER BY sequence ASC LIMIT #{limit}"

        case request(workspace(accumulator), statement) do
          {:ok, rows} -> {:ok, rows}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error,
         Error.new(:invalid_request, "a change feed must start from a non-negative sequence",
           details: %{}
         )}
    end
  end

  @impl true
  def describe do
    %{
      adapter: __MODULE__,
      contract_version: Store.contract_version(),
      capabilities: [
        :graph,
        :vector,
        :fulltext,
        :time_series,
        :change_stream,
        :atomic_audit,
        :atomic_outbox
      ],
      engine: %{
        name: "surrealdb",
        version: Schema.engine_version(),
        durable: true,
        # The free build is a single-node engine: there is no quorum, so the
        # failover path is the promotion procedure, not the store.
        clustered: false,
        url: base_url(),
        max_traversal_depth: @max_traversal_depth
      }
    }
  end

  # ── migration ─────────────────────────────────────────────────────────────

  @doc """
  Brings a Workspace to the current schema.

  Idempotent: every `DEFINE` uses `OVERWRITE`, and the seed rows are
  `UPSERT`s, so running the migrator against a migrated Workspace is a no-op.

  The migration runs in three phases, because a column's type cannot be
  changed under the rows that hold the old shape:

    1. **widen** — a column whose type changed accepts the old value and the
       new one, and a column the schema added is created permissive;
    2. **reconcile** — every row is rewritten against the widened schema: its
       references are converted, the fields it lacks are filled, and the
       fields the schema no longer declares are removed. The Audit Log's
       chain is established here, because a legacy row that carries no hash
       has to join the chain before the chain's columns are tightened;
    3. **tighten** — the corpus's schema is applied exactly.
  """
  @spec migrate(Store.workspace()) :: :ok | {:error, Error.t()}
  def migrate(workspace) do
    with {:ok, workspace} <- ensure_namespace(workspace),
         :ok <- widen_changed_fields(workspace),
         :ok <- reconcile_rows(workspace),
         {:ok, chain} <- establish_chain(workspace),
         :ok <- advance_counters(workspace),
         {:ok, _rows} <- request(workspace, join_statements(Schema.statements())),
         :ok <- prune_dropped_fields(workspace),
         {:ok, _rows} <- request(workspace, join_statements(relation_kind_statements())),
         {:ok, _rows} <- request(workspace, join_statements(Schema.seed_statements(workspace))),
         {:ok, _rows} <- request(workspace, Schema.version_statement()),
         :ok <- permit_unhashed_rows(workspace, chain) do
      case chain do
        :refused ->
          # The chain was left as it was found, so the historical signatures
          # were not replaced. The migration did its work, and saying `:ok`
          # would report an adoption that did not happen.
          {:error,
           Error.new(
             :internal,
             "the audit chain of workspace #{inspect(workspace)} was refused; the historical signatures were not replaced",
             details: %{workspace: workspace}
           )}

        _established ->
          :ok
      end
    else
      {:error, reason} ->
        # A migration that fails is a deployment fault, and it is quiet
        # unless it says so: the caller usually ignores the result, and the
        # symptom appears much later as missing tables.
        Logger.error(
          "[veritas.store] the migration of workspace #{inspect(workspace)} failed: " <>
            (Error.message(reason) || inspect(reason))
        )

        {:error, reason}
    end
  end

  # A row the chain could not be established for keeps its column permissive:
  # the corpus's `hash` is a required field, and a column that requires a
  # value the row does not have refuses every write to that row. The gap is
  # visible in the schema and in the Audit Log's own verification, which is
  # where it belongs.
  defp permit_unhashed_rows(workspace, :refused) do
    apply_statements(workspace, [
      "DEFINE FIELD OVERWRITE hash ON audit_event TYPE string | NONE DEFAULT NONE;"
    ])
  end

  defp permit_unhashed_rows(_workspace, _chain), do: :ok

  # Every row that carries a sequence counts against the counter that hands
  # out the next one, and a counter that lags behind the rows hands out a
  # sequence that is already taken.
  #
  # The legacy counters do lag: they were allocated before the rows the
  # migration adopts, and a store whose counter is behind its rows refuses
  # the next write with "Database index `outbox_workspace` already contains
  # [workspace, 1]".
  defp advance_counters(workspace) do
    counters = [
      {"audit_event", {:audit, workspace}},
      {"event_outbox", "outbox"},
      {"ticket", "ticket"}
    ]

    statements =
      Enum.flat_map(counters, fn {table, key} ->
        case request(workspace, "SELECT VALUE sequence FROM #{table}") do
          {:ok, sequences} ->
            case Enum.reject(List.wrap(sequences), &is_nil/1) do
              [] ->
                []

              values ->
                [
                  "UPSERT #{sequence_table()}:#{sequence_id(workspace, key)} SET next_value = #{Enum.max(values)}"
                ]
            end

          _other ->
            []
        end
      end)

    apply_statements(workspace, statements)
  end

  # The fields the schema no longer declares are removed from the store's
  # tables, once the rows no longer carry them. The corpus is the schema of
  # record (`docs/07`), and a column the corpus dropped is not part of it.
  #
  # The values are gone before this: the reconciliation unset them, and a
  # field whose definition outlives its value is a column the store still
  # maintains for nothing.
  defp prune_dropped_fields(workspace) do
    statements =
      Enum.flat_map(Schema.tables(), fn table ->
        name = table.name
        declared = Schema.declared_fields()[name] || []

        case request(workspace, "INFO FOR TABLE #{name}") do
          {:ok, [info | _]} ->
            info
            |> Map.get("fields", %{})
            |> Map.keys()
            |> Enum.reject(fn field ->
              field in declared or field == "id" or String.contains?(field, ".")
            end)
            |> Enum.sort()
            |> Enum.map(fn field -> "REMOVE FIELD #{field} ON #{name};" end)

          _other ->
            []
        end
      end)

    apply_statements(workspace, statements)
  end

  # The edge table of every registered relation kind. The kinds are data, and
  # the edge table is the engine's shape for them.
  defp relation_kind_statements do
    Enum.flat_map(Schema.relation_kinds(), fn kind ->
      [edge_table_definition(kind)]
    end)
  end

  # The row backfill. A row written under an earlier schema does not have the
  # fields this one declares, and the values it has may be typed differently —
  # a reference was a string, and is now a record. A row is therefore
  # rewritten, field by field, against the current schema: the fields it
  # keeps are re-stated with the types the schema now wants, and the fields it
  # lacks take their defaults.
  #
  # This is part of the migration rather than an afterthought. Without it, the
  # first write to a migrated row fails on the coercion of a field the
  # domain never wrote.
  # A field whose type changed cannot be tightened while the old values are
  # still in the rows. The store refuses a write whose value does not fit the
  # column, and the *old* value does not fit the *new* column — so the field
  # is first widened to accept both shapes, the rows are converted, and only
  # then is the field tightened to the type the corpus declares.
  #
  # Without this, a store that holds old rows keeps the old column type: the
  # DDL applies (the store does not validate on a redefinition) and the next
  # write fails with "Expected `string` but found `user:u1`" — a store fault
  # that looks like a domain fault.
  defp widen_changed_fields(workspace) do
    # The tables come first. A table the store does not hold yet is created
    # as an ordinary table when a field is defined on it, and a field that is
    # `FLEXIBLE` may only be used in a `SCHEMAFULL` table.
    :ok = apply_statements(workspace, Schema.table_definitions())

    statements =
      Enum.flat_map(Schema.tables(), fn table ->
        name = table.name
        specs = Schema.field_specs()[name] || %{}

        case request(workspace, "INFO FOR TABLE #{name}") do
          {:ok, [info | _]} ->
            current = Map.get(info, "fields", %{})
            declared = Schema.declared_fields()[name] || []

            widened =
              Enum.flat_map(specs, fn {field, spec} ->
                # The `id` field is the record's own key, not a column: the
                # store does not report it in `INFO FOR TABLE`, and a union
                # type on a record id key is refused outright.
                if field == "id" do
                  []
                else
                  case current_type(current[field]) do
                    nil ->
                      # The field is new. It is created permissive, so the rows
                      # that predate it stay writable, and it is tightened in
                      # the third phase once every row carries a value for it.
                      [widen_statement(name, field, widened_type(nil, spec.type), spec)]

                    "^type" ->
                      []

                    current ->
                      # The field changed type. The old values do not fit the
                      # new type, so it accepts both until the rows are
                      # converted.
                      [widen_statement(name, field, widened_type(current, spec.type), spec)]
                  end
                end
              end)

            # The fields this schema no longer declares are widened as well:
            # the reconciliation removes them from the rows, and a field that
            # does not accept `NONE` refuses to be unset.
            #
            # A nested definition — `roles.*`, the item type of an array — is
            # left alone: it belongs to the field that holds it, and widening
            # it on its own makes the array's own type contradict it.
            dropped =
              current
              |> Map.keys()
              |> Enum.reject(fn field ->
                field in declared or field == "id" or String.contains?(field, ".")
              end)
              |> Enum.sort()
              |> Enum.flat_map(fn field ->
                case current_type(current[field]) do
                  nil ->
                    []

                  type ->
                    [
                      widen_statement(
                        name,
                        field,
                        widened_type(type, type),
                        %{flexible: flexible?(current[field])}
                      )
                    ]
                end
              end)

            widened ++ dropped

          _other ->
            []
        end
      end)

    apply_statements(workspace, statements)
  end

  # Whether the field's own definition is `FLEXIBLE`.
  defp flexible?(definition) when is_binary(definition),
    do: String.contains?(definition, " FLEXIBLE")

  defp flexible?(_definition), do: false

  # The widened field: every kind the field accepts while the rows are
  # converted, plus `none`, so that a row carrying the old value and a row
  # carrying no value at all are both writable.
  #
  # The field's own modifiers are kept. A field that is `FLEXIBLE` accepts
  # the free-form keys a JSON payload carries, and a widened field that loses
  # its `FLEXIBLE` refuses the very rows the migration is moving: the store
  # answers "Found field '`diff`.state', but no such field exists".
  defp widen_statement(table, field, type, spec) do
    flexible = if spec[:flexible], do: " FLEXIBLE", else: ""

    "DEFINE FIELD OVERWRITE #{field} ON #{table} TYPE #{type}#{flexible} DEFAULT NONE;"
  end

  # The type a field is widened to: the kinds the old type and the new one
  # accept, and `none`.
  #
  # `option<X>` is a *modifier*, not a kind: it cannot appear in a union
  # (`none | object | option<object>` is a parse error), and the store itself
  # normalises it to `none | object`. The types are therefore reduced to
  # their kinds before they are joined.
  defp widened_type(current, target) do
    [current, target]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&kinds_of/1)
    |> Kernel.++(["none"])
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.join(" | ")
  end

  # The type a field currently has, read out of the store's own definition.
  defp current_type(nil), do: nil

  defp current_type(definition) when is_binary(definition) do
    case Regex.run(
           ~r/\bTYPE\s+(.+?)(?:\s+(?:DEFAULT|ASSERT|VALUE|PERMISSIONS|FLEXIBLE)|\s*$)/,
           definition
         ) do
      [_, type] -> String.trim(type)
      _other -> nil
    end
  end

  defp current_type(_other), do: nil

  # The kinds of a type: `option<object>` is `none | object`, and
  # `record<user> | NONE` is `record<user> | none`.
  defp kinds_of(type) do
    type
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn
      "option<" <> rest ->
        # Only the closing ">" of the option belongs to it: the type inside may
        # be generic, and `array<float>>` must not lose both.
        inner = rest |> String.slice(0..-2//1) |> String.trim()
        ["none" | kinds_of(inner)]

      "option" <> _rest ->
        ["none", "object"]

      part ->
        [part]
    end)
  end

  # The reconciliation phase: every row is rewritten against the current
  # schema — its reference values are converted, the fields it lacks are
  # filled, and the fields the schema no longer declares are removed.
  defp reconcile_rows(workspace) do
    # Every unique index is dropped for the reconciliation.
    #
    # A unique index is built on a field the reconciliation can fill, and the
    # reconciliation gives every legacy row the same value for a field it
    # lacks: the index refuses the second row, the reconcile statement is
    # applied atomically, and the whole migration aborts. The store is then
    # left unmigrated, and every later run aborts the same way.
    #
    # The chain's index is the same case for the same reason — it is unique
    # on (workspace, sequence) and the legacy rows carry duplicate
    # sequences — and it is rebuilt once the chain has ordered the rows. The
    # schema application that follows the reconciliation rebuilds them all.
    :ok = drop_unique_indexes(workspace)

    Enum.each(Schema.tables(), fn table ->
      :ok = reconcile_table(workspace, table)
    end)
  end

  defp reconcile_table(workspace, table) do
    name = table.name

    case request(workspace, "SELECT * FROM #{name} LIMIT #{@reconcile_limit}") do
      {:ok, rows} ->
        if length(rows) == @reconcile_limit do
          Logger.warning(
            "[veritas.store] the reconciliation of #{name} in workspace #{inspect(workspace)} " <>
              "stopped at its limit of #{@reconcile_limit} rows: the rows past it keep the old shape."
          )
        end

        statements =
          Enum.flat_map(rows, fn row -> row_statements(workspace, name, row) end)

        apply_statements_atomically(workspace, statements)

      _other ->
        :ok
    end
  end

  # Every unique index the schema declares, dropped for the reconciliation
  # and rebuilt by the schema application that follows it.
  #
  # An index is dropped only when the store has it: a store that was never
  # migrated has no index to remove.
  defp drop_unique_indexes(workspace) do
    Enum.each(Schema.declared_unique_indexes(), fn %{table: table, name: name} ->
      case request(workspace, "INFO FOR TABLE #{table_name(table)}") do
        {:ok, [info | _]} ->
          if Map.has_key?(info["indexes"] || %{}, name) do
            apply_statements(workspace, ["REMOVE INDEX #{name} ON #{table_name(table)};"])
          end

        _other ->
          :ok
      end
    end)
  end

  # The chain phase: the Audit Log rows the migration adopts are given a
  # chain, and the order they are in is the order the chain says.
  #
  # The chain itself is the **host's**: the Adapter stores the chain fields
  # and never computes a chain (`docs/32`), so the host is asked through the
  # seam and what it answers is written. The sequence each row carries is
  # the chain's order — the sequence is a property of the chain, not of when
  # the migration happened to run — and the counter follows it, so the next
  # event continues the chain rather than colliding with it.
  defp establish_chain(workspace) do
    case request(workspace, "SELECT * FROM audit_event ORDER BY timestamp ASC") do
      {:ok, []} ->
        {:ok, :established}

      {:ok, rows} ->
        # The rows are normalised before the chain is reconciled, because the
        # reconciliation signs what it reads. The normal read path returns a
        # timestamp as a `%DateTime{}` and a reference as a bare id; the raw
        # rows carry a timestamp as a string and a reference as a record id.
        # Canonical signs a `%DateTime{}` as one tag and a string as another, so
        # the same row signed one way verifies and fails the other. Normalising
        # makes the migration read the row the way every other read does, and
        # the existing row verifies as it stands.
        rows = Enum.map(rows, &normalise_row(&1, "audit_event"))

        case Chain.reconcile(rows) do
          {:ok, assignments} ->
            case write_chain(workspace, rows, assignments) do
              :ok -> {:ok, :established}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            # The chain was left exactly as it was found: a row whose hash does
            # not match its own content has been tampered with, and a row
            # whose predecessor is missing means the Log has a gap. Rewriting
            # either would hide what it says.
            Logger.error(
              "[veritas.store] the chain of workspace #{inspect(workspace)} was left as it was found: " <>
                reason
            )

            {:ok, :refused}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The chain fields the host answered, and the sequence the chain's order
  # gives each row. A row whose chain fields do not change is not written:
  # the migration touches the Audit Log only where it has to.
  defp write_chain(workspace, rows, assignments) do
    current = Map.new(rows, fn row -> {bare_id(row["id"]), row} end)

    statements =
      assignments
      |> Enum.with_index(1)
      |> Enum.map(fn {assignment, sequence} ->
        id = bare_id(assignment.id)
        row = Map.get(current, id, %{})
        record_id = record_id_literal(id)

        fields =
          []
          |> changed_field(row["prev_hash"], assignment.prev_hash, "prev_hash")
          |> changed_field(row["hash"], assignment.hash, "hash")
          |> Kernel.++(["sequence = #{sequence}"])

        "UPSERT audit_event:#{record_id} SET #{Enum.join(fields, ", ")}"
      end)

    statements =
      statements ++
        [
          # The counter follows the chain, so the next event continues it.
          "UPSERT #{sequence_table()}:#{sequence_id(workspace, "audit")} SET next_value = #{length(assignments)}",
          "DEFINE INDEX OVERWRITE audit_chain ON audit_event FIELDS workspace, sequence UNIQUE;"
        ]

    apply_statements(workspace, statements)
  end

  # A chain field is written only when it changes: a row that already carries
  # the value the host answered is left alone.
  defp changed_field(fields, current, value, field) do
    if same_value?(current, value) do
      fields
    else
      fields ++ ["#{field} = #{encode(value)}"]
    end
  end

  defp same_value?(nil, nil), do: true
  defp same_value?("", nil), do: true
  defp same_value?(nil, ""), do: true

  defp same_value?(current, value) when is_binary(current) and is_binary(value),
    do: current == value

  defp same_value?(_current, _value), do: false

  defp row_statements(workspace, table, row) do
    id = bare_id(Map.get(row, "id"))
    record_id = record_id_literal(id)
    declared = Schema.declared_fields()[table] || []

    defaults = Schema.defaults()[table] || %{}

    assignments =
      declared
      |> Enum.flat_map(fn field ->
        cond do
          field == "id" ->
            ["id = #{encode(id)}"]

          Map.has_key?(row, field) ->
            # A reference the corpus types as a record was a plain id in the
            # old rows: it is converted here, or the store would refuse the
            # write with "Expected `record<user>` but found `u1`".
            ["#{field} = #{backfill_value(table, field, Map.get(row, field))}"]

          Map.has_key?(defaults, field) ->
            # A field this schema added and the row does not have takes its
            # default, so the row matches the schema it is now under.
            ["#{field} = #{defaults[field]}"]

          true ->
            # A field the schema requires and the row does not have cannot be
            # left absent: the store would refuse the write. It is given a
            # value of the right shape, so the row is valid and the gap is
            # visible rather than silent.
            case required_fallback(workspace, table, field, id) do
              nil -> []
              value -> ["#{field} = #{value}"]
            end
        end
      end)

    # A field the schema no longer declares is removed first: a row that
    # still carries it cannot be written at all, and `SET` and `UNSET` cannot
    # share a statement, so it is two statements in one transaction.
    extras =
      row
      |> Map.keys()
      |> Enum.reject(fn field -> field in declared end)
      |> Enum.sort()

    unset =
      if extras == [],
        do: [],
        else: ["UPDATE #{table}:#{record_id} UNSET #{Enum.join(extras, ", ")}"]

    unset ++ ["UPDATE #{table}:#{record_id} SET #{Enum.join(assignments, ", ")}"]
  end

  defp backfill_value(table, field, value) do
    # A datetime the store returned as an ISO string is written back as a
    # datetime literal, or the store refuses the coercion.
    if is_binary(value) and datetime_field?(table, field) do
      "d'#{value}'"
    else
      case Map.get(Schema.reference_fields()[table] || %{}, field) do
        nil ->
          encode(value)

        ref when is_binary(value) ->
          # A row the store already holds may carry a reference that is not
          # an id — a row written before the id allowlist existed. It is
          # escaped rather than refused, because a migration must be able
          # to carry the data it finds.
          "type::record('#{ref}', #{escape_literal(bare_id(value))})"

        _other ->
          encode(value)
      end
    end
  end

  defp datetime_field?(table, field) do
    case Schema.field_types()[table] |> Map.get(field) do
      nil -> false
      type -> String.starts_with?(type, "datetime")
    end
  end

  # The value a required field takes when a legacy row does not carry it: one
  # of the right shape, derived from the row itself.
  defp required_fallback(workspace, table, field, id) do
    case Schema.field_types()[table] |> Map.get(field) do
      nil ->
        nil

      type ->
        # A field a unique index covers cannot take the same value in every
        # row: the index would refuse the second row, and the migration
        # would abort. Its placeholder is distinct per row, and visible.
        unique? = field in Schema.unique_indexed_fields(table)

        # A reference takes a reference: the fallback must satisfy the
        # column's type, not merely be a string of the right shape.
        case Map.get(Schema.reference_fields()[table] || %{}, field) do
          nil ->
            fallback_for(type, id, unique?)

          ref ->
            placeholder =
              if unique? do
                "__placeholder_#{id}"
              else
                Map.get(Schema.required_references()[table] || %{}, field) ||
                  reference_placeholder(ref, workspace)
              end

            "type::record('#{ref}', #{escape_literal(placeholder)})"
        end
    end
  end

  # A Workspace reference points at the Workspace being migrated; any other
  # reference falls back to a record named after the table it points at, so
  # the row is valid and the gap is visible rather than silent.
  defp reference_placeholder("workspace", workspace), do: workspace
  defp reference_placeholder(ref, _workspace), do: ref

  defp fallback_for(type, _id, false) do
    cond do
      String.starts_with?(type, "string") -> "''"
      String.starts_with?(type, "int") -> "0"
      String.starts_with?(type, "bool") -> "false"
      String.starts_with?(type, "datetime") -> "d'1970-01-01T00:00:00Z'"
      String.starts_with?(type, "object") -> "{}"
      String.starts_with?(type, "array") -> "[]"
      true -> nil
    end
  end

  # The fallback for a field a unique index covers. It is distinct per row,
  # so the index the reconciliation is running under can be rebuilt over the
  # rows it produced, and it is visible: a row that carries a placeholder
  # says that its value is a gap, not an answer.
  defp fallback_for(type, id, true) do
    cond do
      String.starts_with?(type, "string") -> "'__placeholder_#{id}'"
      String.starts_with?(type, "int") -> "#{abs(:erlang.phash2(id, 4_000_000_000)) + 1}"
      String.starts_with?(type, "bool") -> "false"
      String.starts_with?(type, "datetime") -> "d'1970-01-01T00:00:00Z'"
      String.starts_with?(type, "object") -> "{}"
      String.starts_with?(type, "array") -> "[]"
      true -> nil
    end
  end

  @doc "The schema version this Adapter expects."
  @spec migration_version() :: String.t()
  def migration_version, do: Schema.version()

  defp apply_statements(workspace, statements) do
    case request_without_statement(workspace, join_statements(statements)) do
      {:ok, _rows} ->
        :ok

      {:error, reason} ->
        # A migration that fails says which statement failed: the store's
        # message names the field, and the statement says what the field
        # was meant to be.
        Logger.error(
          "[veritas.store] the migration statement failed: " <>
            inspect(Enum.join(statements, " | ")) <>
            " — " <> (Error.message(reason) || inspect(reason))
        )

        {:error, reason}
    end
  end

  # The statements are applied in one transaction, so a row is never left
  # half-migrated: the field it no longer has removed and the fields it now
  # needs both land, or neither does.
  defp apply_statements_atomically(workspace, statements) do
    body = "BEGIN TRANSACTION;\n" <> join_statements(statements) <> "\nCOMMIT TRANSACTION;"

    case request_without_statement(workspace, body) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The bare id of a record the store named, or of a reference an earlier
  # schema held as a string.
  #
  # A reference written under an older schema is a *rendered* record id, and
  # the rendering was applied more than once: `workspace:default` became
  # `workspace:`workspace:default``, and the store escapes the backtick it
  # renders a string with. The bare id is what is left when the renderings
  # and the escapes are undone.
  #
  # A record id holds letters, digits and underscores only, so the id is the
  # last segment after the table name, whatever the rendering was.
  # A record id in a statement.
  #
  # An id the Adapter produced is already bare, and is written bare. An id
  # that came **from the store** is written in the array form with the
  # literal escaped, because a row whose id is not an id — a row written by
  # the injection this file used to have, say — must not be able to close
  # the statement it is written back in.
  defp record_id_literal(id) do
    case id_or_nil(id) do
      nil -> "[" <> escape_literal(id) <> "]"
      bare -> bare
    end
  end

  # The bare form of an id the store returned. The store's own ids are
  # stripped of their physical `table:` prefix, and are checked by the
  # caller before they are written: see `record_id_literal/1`.
  defp bare_id(id) when is_binary(id) do
    id
    |> String.replace(["\\", "`"], "")
    |> String.split(":")
    |> List.last()
  end

  defp bare_id(id), do: to_string(id)

  # ── internals ─────────────────────────────────────────────────────────────

  defp commit(accumulator) do
    statements = Tx.statements(accumulator)

    if statements == [] do
      {:ok, []}
    else
      body = "BEGIN TRANSACTION;\n" <> join_statements(statements) <> "\nCOMMIT TRANSACTION;"

      request_batch(workspace(accumulator), body, Tx.safe_statements(accumulator))
    end
  end

  defp workspace(accumulator), do: Tx.workspace(accumulator)

  # Statements are terminated here, so a statement may be written with or
  # without its own semicolon.
  defp join_statements(statements) do
    statements
    |> Enum.map(&String.trim_trailing(&1, " \t\r\n;"))
    |> Enum.map_join(";\n", & &1)
    |> Kernel.<>(";")
  end

  # The outbox row. Its Workspace is a **reference**, like every other
  # Workspace-bearing field (`docs/07`), so it is written through the
  # reference-aware encoder rather than as a plain string.
  #
  # The corpus's relay columns ride along: `event_type` names the change,
  # `payload` carries it, and `published_at` is set when the relay has
  # published the row.
  # The outbox statements: **two** of them, because the engine counts them
  # as two.
  #
  # The sequence is a variable, and a variable is set by its own statement —
  # so `LET ... ;` and the `UPSERT` that uses it are two statements to the
  # engine. They have to be two here too, or this list and the engine's
  # results fall out of step, and a failure then names the wrong statement.
  defp outbox_statements(workspace, table, id, op) do
    sequence_var =
      "outboxseq#{:erlang.phash2({table, id, op, System.unique_integer([:positive])})}"

    outbox_id = identifier()

    row = %{
      "id" => outbox_id,
      "workspace" => workspace,
      "sequence" => %Raw{value: "$#{sequence_var}"},
      "table" => to_string(table),
      "record_id" => id,
      "op" => op,
      "at" => DateTime.utc_now(),
      "event_type" => "#{table}.#{op}",
      "payload" => %{"table" => to_string(table), "record_id" => id, "op" => op},
      "published_at" => nil
    }

    [
      "LET $#{sequence_var} = (UPSERT #{sequence_table()}:#{sequence_id(workspace, "outbox")} SET next_value += 1 RETURN next_value)[0].next_value",
      "UPSERT event_outbox:#{outbox_id} #{encode_fields(row, :event_outbox)}"
    ]
  end

  # Buffers the outbox statements, in order.
  defp buffer_outbox(accumulator, workspace, table, id, op) do
    Enum.each(outbox_statements(workspace, table, id, op), fn statement ->
      :ok = Tx.buffer(accumulator, statement)
    end)
  end

  defp relation_kind_spec({:veritas_store_tx, accumulator}, kind) do
    # The registry row is addressed by its record id, not by the `id` field:
    # the store owns that field, and it holds the record id.
    statement = "SELECT * FROM relation_kind:#{normalise_id(to_string(kind))}"

    case request(workspace(accumulator), statement) do
      {:ok, [spec | _]} ->
        {:ok, spec}

      {:ok, []} ->
        # A kind that is used before it is registered is registered on the
        # way in: the vocabulary is data, and relating with a new kind is
        # how a new kind appears.
        register_relation_kind(accumulator, to_string(kind))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_relation_kind(accumulator, id) do
    spec = %{"id" => id}

    :ok =
      Tx.buffer(accumulator, "UPSERT relation_kind:#{id} #{encode_fields(spec, :relation_kind)}")

    :ok = Tx.put_overlay(accumulator, :relation_kind, id, spec)

    {:ok, spec}
  end

  # The edge table of a kind: the table it comes from, and the kind. The
  # kind's id is the record id the store assigned, so the bare id is what
  # belongs in a table name. The Schema owns the name, so the migration and
  # the Adapter agree on it.
  defp edge_table(spec), do: Schema.edge_table(spec)

  # The edge's record id is built from the kind and the two endpoints. All
  # three are ids: the endpoints were normalised when the relation was made,
  # and the kind is one the registry holds.
  defp edge_id(kind, from, to) do
    "#{normalise_id(kind)}_#{normalise_id(from)}_#{normalise_id(to)}"
  end

  defp edge_table_definition(spec) do
    Schema.edge_table_statements(spec)
  end

  # The relation kinds a traversal walks, and their edge tables, read **once**.
  #
  # The vocabulary is data and does not change while a traversal runs, so
  # reading it per vertex turned one hop into nine requests: the registry, the
  # registry again per kind, and the edge query per kind.
  defp kind_specs(handle, names) do
    case relation_kinds(handle) do
      {:ok, rows} ->
        case names do
          nil -> rows
          names -> Enum.filter(rows, &(&1["id"] in names))
        end

      {:error, _reason} ->
        []
    end
  end

  # The edges of a level, in one statement.
  #
  # The corpus's rule is "one batched query per level", and this is it: one
  # statement names every edge table the traversal walks and every vertex the
  # level holds, so a level costs one request however wide it is. `UNION ALL`
  # is not available to the engine here — it is a parse error — so the tables
  # are concatenated as arrays, which the engine plans as one statement with
  # one index scan per table.
  # The first argument is the transaction's **accumulator** — the process that
  # holds the Workspace and the buffered writes — not the `{:veritas_store_tx,
  # accumulator}` handle the domain passes in. The handle is the port's type and
  # the accumulator is the Adapter's content, and this function needs the
  # content: it reads the Workspace through `workspace/1`, which is a call to
  # the accumulator process.
  defp edges_for_level(accumulator, ids, direction, specs) do
    subqueries =
      Enum.flat_map(specs, fn spec -> edge_subqueries(spec, ids, direction) end)

    case subqueries do
      [] ->
        {:ok, []}

      _ ->
        # One statement, so the rows are the only thing the Adapter decodes:
        # a `LET` and a `RETURN` would be two results, and the `LET`'s null
        # would be read as a row.
        statement = "RETURN " <> Enum.join(subqueries, " + ") <> ";"

        case request(workspace(accumulator), statement) do
          {:ok, rows} -> {:ok, rows}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The subqueries one kind contributes: the edges whose `out` end is a vertex
  # of the level, and the edges whose `in` end is one.
  #
  # A relation table is queried through its `in` and `out` record links; a
  # plain edge table through its `from` and `to` columns. Both are the same
  # question asked of the engine in the way the engine can answer it.
  defp edge_subqueries(spec, ids, direction) do
    edge = edge_table(spec)

    case {spec["from_table"], spec["to_table"]} do
      {from_table, to_table} when is_binary(from_table) and is_binary(to_table) ->
        out_side = edge_subquery(edge, "out", to_table, ids, "id, in, out, kind")
        in_side = edge_subquery(edge, "in", from_table, ids, "id, in, out, kind")

        case direction do
          :in -> [out_side]
          :out -> [in_side]
          :both -> [out_side, in_side]
        end

      _other ->
        out_side = edge_subquery(edge, "to", "ci", ids, "id, from, to, kind")
        in_side = edge_subquery(edge, "from", "ci", ids, "id, from, to, kind")

        case direction do
          :in -> [out_side]
          :out -> [in_side]
          :both -> [out_side, in_side]
        end
    end
  end

  # One subquery: the edges of a table whose field holds one of the level's
  # vertices.
  #
  # The table name and the record references go through the same gates as
  # every other statement this Adapter writes: the identifier allowlist and
  # the literal escaper.
  defp edge_subquery(edge, field, table, ids, projection) do
    refs = Enum.map_join(ids, ", ", fn id -> record_ref(table, id) end)

    "(SELECT #{projection} FROM #{table_name(edge)} WHERE #{field} IN [#{refs}])"
  end

  # A row written in this transaction is visible to a read in it, and a row
  # this transaction has deleted is not visible at all.
  defp merge_overlay(rows, accumulator, table) do
    Veritas.Store.Filter.merge(rows, Tx.overlay_rows(accumulator, table))
  end

  defp normalise_edge(row, spec) do
    from = Map.get(row, "in") || Map.get(row, "from")
    to = Map.get(row, "out") || Map.get(row, "to")

    %{
      "id" => row["id"] |> to_string() |> String.split(":") |> List.last(),
      "kind" => edge_kind(row, spec),
      "from" => from |> to_string() |> String.split(":") |> List.last(),
      "to" => to |> to_string() |> String.split(":") |> List.last(),
      "from_table" => spec["from_table"],
      "to_table" => spec["to_table"]
    }
  end

  # The kind of an edge. The edge carries it in its own column; the registry
  # row's id is the store's record id, not the kind.
  defp edge_kind(row, spec) do
    case row["kind"] do
      nil -> spec["id"] |> to_string() |> String.split(":") |> List.last()
      kind -> to_string(kind)
    end
  end

  defp walk(_accumulator, _frontier, _direction, 0, acc, _seen, _specs), do: {acc, false}

  # The traversal expands a level at a time.
  #
  # The edges of every vertex discovered at a level are read in one statement
  # and their rows in another, so a level costs two requests however wide it
  # is. The traversal walks the graph, not a list: the edges of the start
  # vertex alone cannot reach the vertices beyond it, and a traversal that
  # filtered one fixed set of edges at every level would be blind past the
  # first hop and answer the same nodes for every depth.
  #
  # The depth bound is the contract's: a node found at the bound is returned
  # and not expanded. The node budget is the corpus's: a traversal that runs
  # away is an outage, and a truncated graph that says so is honest.
  defp walk(
         {:veritas_store_tx, accumulator} = handle,
         frontier,
         direction,
         depth,
         acc,
         seen,
         specs
       ) do
    cond do
      frontier == [] ->
        {acc, false}

      depth == 0 ->
        {acc, false}

      true ->
        case edges_for_level(accumulator, frontier, direction, specs) do
          {:ok, edges} ->
            edges = Enum.map(edges, &normalise_edge_for(&1, specs))
            {next, truncated} = next_nodes(accumulator, edges, direction, acc, seen)
            acc = acc ++ next

            if truncated do
              {acc, true}
            else
              walk(
                handle,
                Enum.map(next, & &1["id"]),
                direction,
                depth - 1,
                acc,
                seen,
                specs
              )
            end

          {:error, _reason} ->
            {acc, false}
        end
    end
  end

  # The nodes a level reaches.
  #
  # An edge names the vertex it comes from and the one it reaches; the
  # direction says which is which. A node two kinds of relation reach is one
  # node, and a node the traversal has already found is not found again.
  defp next_nodes(accumulator, edges, direction, acc, seen) do
    candidates =
      edges
      |> Enum.flat_map(fn edge -> candidates_for(edge, direction) end)
      |> Enum.uniq_by(fn {id, _table, _edge} -> id end)
      |> Enum.reject(fn {id, _table, _edge} ->
        MapSet.member?(seen, id) or Enum.any?(acc, &(&1["id"] == id))
      end)

    room = @max_traversal_nodes - length(acc)
    truncated = length(candidates) > room
    candidates = Enum.take(candidates, max(room, 0))

    rows = fetch_rows(accumulator, candidates)

    next =
      candidates
      |> Enum.map(fn {id, table, edge} ->
        case Map.get(rows, {table, id}) do
          nil -> nil
          row -> Map.put(row, "edge", edge)
        end
      end)
      |> Enum.reject(&is_nil/1)

    {next, truncated}
  end

  # The ends of an edge, from the point of view of the direction walked.
  defp candidates_for(edge, :in), do: [{edge["from"], edge["from_table"], edge}]
  defp candidates_for(edge, :out), do: [{edge["to"], edge["to_table"], edge}]

  defp candidates_for(edge, :both) do
    [{edge["from"], edge["from_table"], edge}, {edge["to"], edge["to_table"], edge}]
  end

  # The rows of a level, in one statement per table.
  #
  # The rows are read by record id, one point read each: a filter on a list
  # of ids is a table scan, and a scan of the CI table is a scan of every CI
  # in the Workspace.
  defp fetch_rows(accumulator, candidates) do
    candidates
    |> Enum.group_by(fn {_id, table, _edge} -> table end)
    |> Enum.reduce(%{}, fn {table, group}, acc ->
      ids = group |> Enum.map(fn {id, _table, _edge} -> id end) |> Enum.uniq()

      case request(workspace(accumulator), fetch_statement(table, ids)) do
        {:ok, rows} ->
          rows
          |> Enum.map(&normalise_row(&1, table))
          |> Enum.reduce(acc, fn row, acc -> Map.put(acc, {table, row["id"]}, row) end)

        {:error, _reason} ->
          acc
      end
    end)
  end

  # The statement that reads a table's rows by record id.
  #
  # The table name and the ids go through the same gates as every other
  # statement this Adapter writes.
  defp fetch_statement(table, ids) do
    name = table_name(table)

    reads =
      Enum.map_join(ids, " + ", fn id ->
        "(SELECT * FROM #{name} WHERE id = #{name}:#{normalise_id(id)})"
      end)

    "RETURN #{reads};"
  end

  # The edge of a row, normalised. The row names its own kind, so a batched
  # read — which mixes the tables of several kinds — still knows which edge
  # table the row came from.
  defp normalise_edge_for(row, specs) do
    kind = row["kind"] |> to_string() |> String.split(":") |> List.last()

    case Enum.find(specs, &(&1["id"] == kind)) do
      nil -> normalise_edge(row, %{"id" => kind})
      spec -> normalise_edge(row, spec)
    end
  end

  # The tickets that touch the given CIs.
  #
  # A ticket is not linked to a CI by a column: the `ticket` table declares
  # no such field and is SCHEMAFULL, so a row cannot carry one. A ticket
  # reaches a CI through the relation kinds whose edges run from a ticket to
  # a CI -- `affects`, `implements`, `remediates` -- and the edge tables are
  # indexed on `out`, so the hop is an index scan instead of a read of every
  # edge in the Workspace.
  #
  # The ticket rows are then read by record id, one point read each.
  defp tickets_for(accumulator, ci_ids) do
    case ticket_ci_kinds(accumulator) do
      {:ok, specs} ->
        case edges_for_level(accumulator, ci_ids, :in, specs) do
          {:ok, edges} ->
            ticket_ids =
              edges
              |> Enum.map(&Map.get(&1, "in"))
              |> Enum.map(&bare_id/1)
              |> Enum.uniq()

            rows = fetch_rows(accumulator, Enum.map(ticket_ids, &{&1, "ticket", %{}}))

            {:ok, rows |> Map.values() |> Enum.sort_by(& &1["id"])}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The relation kinds whose edges run from a ticket to a CI.
  defp ticket_ci_kinds(accumulator) do
    case relation_kinds({:veritas_store_tx, accumulator}) do
      {:ok, rows} ->
        {:ok,
         Enum.filter(rows, fn row ->
           row["from_table"] == "ticket" and row["to_table"] == "ci"
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalise_kinds(nil), do: nil
  defp normalise_kinds(kinds), do: Enum.map(kinds, &to_string/1)

  # ── statements ────────────────────────────────────────────────────────────

  defp where_clause(where, extra, table) do
    references = Schema.reference_fields()[table_name(table)] || %{}

    clauses =
      [extra] ++
        Enum.map(where, fn {field, value} ->
          filter_clause(field, value, references)
        end)

    case Enum.reject(clauses, &(&1 in [nil, ""])) do
      [] -> nil
      clauses -> "WHERE " <> Enum.join(clauses, " AND ")
    end
  end

  defp filter_clause(field, value, references) do
    name = field_name(field)

    case Map.get(references, name) do
      table when is_binary(table) and is_binary(value) ->
        # A filter compares the exact logical id. A qualified, blank or invalid
        # id cannot match: do not strip a prefix or turn a nonmatch into an error.
        if id_or_nil(value) == value,
          do: "#{name} = #{record_ref(table, value)}",
          else: "false"

      _ ->
        # Filter strings are always literals, never the raw datetime fragments
        # accepted by the write encoder.
        literal = if is_binary(value), do: escape_literal(value), else: encode(value)
        "#{name} = #{literal}"
    end
  end

  # The Workspace a row belongs to.
  #
  # The Adapter scopes the *namespace* to the Workspace, but a row carries
  # its own Workspace, and a statement that does not say so cannot use the
  # composite index that leads with it: the leading column is unconstrained,
  # so the engine reads the whole table and sorts the rows it found. It is a
  # correctness matter as well as a speed one -- a row that belongs to
  # another Workspace must never be returned.
  #
  # Only the tables that declare a `workspace` field are scoped this way. A
  # table that does not carry one -- the transition table, the schema
  # version, the Workspace itself -- is scoped by construction.
  defp workspace_clause(table, workspace) do
    if "workspace" in (Schema.declared_fields()[table_name(table)] || []) do
      "workspace = #{record_ref("workspace", workspace)}"
    end
  end

  defp order_clause(nil), do: nil
  defp order_clause([]), do: nil

  defp order_clause(order_by) do
    "ORDER BY " <>
      Enum.map_join(order_by, ", ", fn {field, direction} ->
        "#{field_name(field)} #{if direction == :desc, do: "DESC", else: "ASC"}"
      end)
  end

  defp limit_clause(limit, offset) do
    limit = min(limit, @max_list_limit)
    clause = "LIMIT #{limit}"
    if offset && offset > 0, do: clause <> " START #{offset}", else: clause
  end

  # The record is projected onto the table's declared fields. A field the
  # schema does not declare is not stored — and it is **reported**, because a
  # silently dropped field is a domain bug that would otherwise surface as
  # missing data much later.
  # The fields of the row that the table declares.
  #
  # The relation tables are created per relation type, so the corpus's schema
  # does not declare them: the projection is told what such a table has,
  # rather than dropping every field of the edge and warning about it.
  defp encode_fields(record, table, extra \\ []) do
    name = table_name(table)
    declared = (Schema.declared_fields()[name] || []) ++ extra
    references = Schema.reference_fields()[name] || %{}

    {kept, dropped} =
      Enum.split_with(record, fn {field, _value} -> to_string(field) in declared end)

    # The `id` is the record's identity, not a column. The engine holds it as
    # the record id and the Adapter maps it back to the port's logical id on
    # read, so it is never written as a field — and it is not a dropped field
    # to warn about either, because it was never meant to be one.
    dropped = Enum.reject(dropped, fn {field, _value} -> to_string(field) == "id" end)

    report_dropped(name, dropped)

    kept = fill_required_references(kept, name)

    assignments =
      Enum.map(kept, fn {field, value} ->
        field = to_string(field)
        "#{field_name(field)} = #{encode_value(field, value, references)}"
      end)

    # A statement never carries an empty `SET`: the store refuses to parse
    # one, and a row with nothing to say is not written.
    if assignments == [], do: "", else: "SET " <> Enum.join(assignments, ", ")
  end

  # A reference the schema requires, and the row does not carry, is given the
  # placeholder the schema names. The row is then valid against the schema it
  # is written under, and the placeholder is visible in the CMDB.
  defp fill_required_references(kept, table) do
    case Schema.required_references()[table] do
      nil ->
        kept

      required ->
        Enum.map(kept, fn {field, value} ->
          case Map.get(required, to_string(field)) do
            nil ->
              {field, value}

            placeholder ->
              if is_nil(value) or value == "",
                do: {field, placeholder},
                else: {field, value}
          end
        end)
    end
  end

  defp report_dropped(_table, []), do: :ok

  defp report_dropped(table, dropped) do
    fields = dropped |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    Logger.warning(
      "[veritas.store] #{table}: dropped #{length(fields)} field(s) the schema does not declare: " <>
        inspect(fields)
    )

    :telemetry.execute([:veritas, :store, :field_dropped], %{table: table}, %{
      count: length(fields)
    })
  end

  # A reference is a plain id in the port and a record reference in the store.
  #
  # The id is the **whole** of what may be interpolated here. It is checked
  # against the id allowlist, so a value that tries to close the literal and
  # append a statement of its own cannot be one: the only thing that reaches
  # the statement is a bare id, and the table name is checked the same way.
  defp encode_value(field, value, references) do
    case Map.get(references, field) do
      nil -> encode(value)
      table when is_binary(value) -> record_ref(table, value)
      _other -> encode(value)
    end
  end

  # A reference field carries a record **id**, not free text. A value that is
  # not an id is refused here, where the refusal can be a typed error, rather
  # than where the statement is built, where the only answer available is an
  # exception.
  #
  # The value is not echoed: it is the caller's own input, but a refusal that
  # quotes it back is a refusal that helps the next attempt.
  defp validate_references(table, record) do
    references = Schema.reference_fields()[table_name(table)] || %{}

    case Enum.find(references, fn {field, _ref} ->
           value = Map.get(record, field)
           not is_nil(value) and value != "" and is_nil(id_or_nil(value))
         end) do
      nil ->
        :ok

      {field, _ref} ->
        {:error,
         Error.new(:invalid_request, "a reference field must carry a record id",
           details: %{table: table_name(table), field: field}
         )}
    end
  end

  defp encode(%Raw{value: value}), do: value
  defp encode(nil), do: "NONE"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_float(value), do: Float.to_string(value)

  defp encode(%DateTime{} = value), do: "d'" <> DateTime.to_iso8601(value) <> "'"

  defp encode(value) when is_binary(value) do
    if String.starts_with?(value, "d'") and String.ends_with?(value, "'") do
      value
    else
      escape_literal(value)
    end
  end

  defp encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &encode/1) <> "]"
  end

  defp encode(value) when is_map(value) do
    if Enum.all?(value, fn {k, _} -> is_binary(k) end) do
      fields = Enum.map_join(value, ", ", fn {k, v} -> "#{field_name(k)}: #{encode(v)}" end)
      "{ " <> fields <> " }"
    else
      raise ArgumentError, "a record field name must be a string, got: #{inspect(value)}"
    end
  end

  # An atom is a **value**, not an identifier.
  #
  # The capabilities a provider carries are atoms, and written bare the engine
  # reads them as a field path — a name it does not have — and refuses the
  # statement. An atom is written as the string it names, which is what it
  # means everywhere else in the port.
  defp encode(value) when is_atom(value), do: escape_literal(to_string(value))

  defp encode(value), do: to_string(value)

  # A SurrealQL string literal.
  #
  # The **backslash is escaped first**, and the order matters. A value ending
  # in an odd number of backslashes would otherwise escape the closing quote,
  # and the string would continue past its intended end — which is how a
  # filter value stopped being a string and became an expression.
  #
  # Escaping the quote first would break this: the backslashes this
  # replacement adds would then be escaped by the first one.
  defp escape_literal(value) do
    "'" <> escape_literal_body(value) <> "'"
  end

  # The body of a literal, without the quotes. The **backslash is escaped
  # first**, and the order matters: a value ending in an odd number of
  # backslashes would otherwise escape the closing quote, and the string
  # would continue past its intended end — which is how a filter value
  # stopped being a string and became an expression.
  #
  # Escaping the quote first would break this: the backslashes that
  # replacement adds would then be escaped by the first one.
  defp escape_literal_body(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp field_name(field) when is_atom(field), do: field |> to_string() |> field_name()

  defp field_name(field) when is_binary(field) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, field) do
      field
    else
      raise ArgumentError, "invalid field name: #{inspect(field)}"
    end
  end

  defp table_name(table) when is_atom(table), do: table_name(to_string(table))

  defp table_name(table) when is_binary(table) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, table) do
      table
    else
      raise ArgumentError, "invalid table name: #{inspect(table)}"
    end
  end

  # A record reference.
  #
  # The value goes through **both** gates: the id allowlist, which decides
  # whether it is an id at all, and the literal escaper, which decides how it
  # is written. The escaper is redundant while the allowlist is as narrow as
  # it is, and that is the point: it is the second gate, and it stays if the
  # first is ever widened.
  #
  # The table is checked against the identifier allowlist too, so between
  # them the only characters that can reach the statement are letters,
  # digits and underscore.
  defp record_ref(table, id) do
    "type::record('#{table_name(table)}', #{escape_literal(normalise_id(id))})"
  end

  # The Adapter owns the Workspace scope, so it stamps it on the tables that
  # carry one. A table that does not declare the field is scoped by
  # construction — a detail row belongs to its ticket's Workspace.
  defp stamp_workspace(row, table, workspace) do
    if "workspace" in (Schema.declared_fields()[table_name(table)] || []) do
      Map.put(row, "workspace", workspace)
    else
      row
    end
  end

  # SurrealDB reports a record's id as `table:id`. The port's contract is
  # that the id is the **logical** id, and the physical form is the
  # Adapter's business.
  #
  # The same mapping applies to the other types the engine flattens: a
  # datetime comes back as an ISO-8601 string, and a row that is read and
  # written back must survive the round trip.
  defp normalise_row(row, table) when is_map(row) do
    row
    |> strip_id()
    |> coerce_datetimes(table_name(table))
  end

  defp normalise_row(row, _table), do: row

  # A record reference comes back as `table:id`; the port's records carry the
  # bare id.
  defp coerce_references(row, table) do
    case Schema.reference_fields()[table] do
      nil ->
        row

      references ->
        Enum.reduce(references, row, fn {field, _table}, row ->
          case Map.get(row, field) do
            value when is_binary(value) ->
              if String.contains?(value, ":"),
                do: Map.put(row, field, value |> String.split(":") |> List.last()),
                else: row

            _ ->
              row
          end
        end)
    end
  end

  defp strip_id(row) do
    case row["id"] do
      id when is_binary(id) ->
        if String.contains?(id, ":"),
          do: Map.put(row, "id", id |> String.split(":") |> List.last()),
          else: row

      _ ->
        row
    end
  end

  defp coerce_datetimes(row, table) do
    row = coerce_references(row, table)

    case Schema.datetime_fields()[table] do
      nil ->
        row

      fields ->
        Enum.reduce(fields, row, fn field, row ->
          case Map.get(row, field) do
            value when is_binary(value) ->
              case DateTime.from_iso8601(value) do
                {:ok, datetime, _offset} -> Map.put(row, field, datetime)
                _ -> row
              end

            _ ->
              row
          end
        end)
    end
  end

  # A record id, and a Workspace name, may contain only letters, digits and
  # underscore. This is the allowlist every interpolated identifier goes
  # through, so the set of characters that can reach a statement is closed.
  @id_pattern ~r/^[A-Za-z0-9_]+$/

  # The bare form of an id, or `nil` when it is not one. `nil` rather than an
  # exception, so a caller can be told what is wrong instead of being handed
  # a raised error.
  defp id_or_nil(value) when is_binary(value) do
    bare = value |> String.split(":") |> List.last()

    if Regex.match?(@id_pattern, bare), do: bare, else: nil
  end

  defp id_or_nil(_value), do: nil

  defp normalise_id(nil), do: nil

  defp normalise_id(id) when is_binary(id) do
    case id_or_nil(id) do
      nil ->
        raise ArgumentError,
              "a record id may contain only letters, digits and underscore: #{inspect(id)}"

      bare ->
        bare
    end
  end

  defp normalise_id(id), do: id |> to_string() |> normalise_id()

  defp sequence_table, do: "workspace_sequence"

  # A sequence's record id is a composite one: the Workspace and the counter
  # key, so two counters in one Workspace never collide.
  defp sequence_id(workspace, key) do
    key =
      case key do
        key when is_binary(key) -> key
        key -> inspect(key)
      end

    key = String.replace(key, ~r/[^A-Za-z0-9_]/, "_")
    "['#{workspace}_#{key}']"
  end

  # A composite record id: table:['a','b','c']. Used where the natural key of
  # a row is a tuple — a sample's target, bucket and metric.
  defp composite_id(parts) do
    "[" <> Enum.map_join(parts, ",", &encode/1) <> "]"
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(value), do: to_string(value)

  # ── HTTP ──────────────────────────────────────────────────────────────────

  # The Workspace is created at the engine's **root**, so these two statements
  # are the only ones the Adapter runs without a namespace or a database of
  # their own. The name is therefore held to the id allowlist before it
  # reaches them, and the validated name is returned so that every statement
  # the migration builds afterwards uses the same one.
  defp ensure_namespace(workspace) do
    case id_or_nil(workspace) do
      nil ->
        {:error,
         Error.new(
           :invalid_request,
           "a workspace name may contain only letters, digits and underscore",
           details: %{}
         )}

      workspace ->
        with {:ok, _rows} <- request_root("DEFINE NAMESPACE IF NOT EXISTS #{workspace};"),
             {:ok, _rows} <-
               request_in_namespace("DEFINE DATABASE IF NOT EXISTS #{workspace};", workspace) do
          {:ok, workspace}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp request(workspace, statement),
    do: do_request(workspace, workspace, statement, single_statement(statement))

  defp request_root(statement), do: do_request(nil, nil, statement, single_statement(statement))

  defp request_in_namespace(statement, namespace),
    do: do_request(namespace, nil, statement, single_statement(statement))

  # A request that carries a batch of statements, so that a failure can
  # name the one that failed.
  defp request_batch(workspace, body, statements) do
    do_request(workspace, workspace, body, %{statements: statements, offset: 1})
  end

  # A request that carries one statement: the engine's result for it is the
  # first, because there is no `BEGIN` in front of it.
  defp single_statement(statement), do: %{statements: [statement], offset: 0}

  # A request that names no statement.
  #
  # The migration's statements are the schema itself, and the migration
  # already says which one failed in its own log. Putting the whole schema
  # into an error's details would be noise, and the schema is not one
  # statement: two of its definitions are several statements each.
  defp request_without_statement(workspace, body),
    do: do_request(workspace, workspace, body, nil)

  defp do_request(namespace, database, statement, batch) do
    config = config()

    case attempt(namespace, database, statement, config) do
      {:ok, 200, raw} ->
        decode(raw, batch)

      {:ok, status, _raw} when status in [401, 403] ->
        # The store refused the credential: the token expired, or the store's
        # rules changed under us. Sign in again, **once**, and retry the
        # request **once**. There is no loop -- a second refusal is the
        # caller's answer.
        forget_token(config)

        case attempt(namespace, database, statement, config) do
          {:ok, 200, raw} -> decode(raw, batch)
          {:ok, status, raw} -> {:error, http_error(status, raw)}
          {:error, reason} -> {:error, reason}
        end

      {:ok, status, raw} ->
        {:error, http_error(status, raw)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One request, with the credential the Adapter currently holds.
  defp attempt(namespace, database, statement, config) do
    with {:ok, authorization} <- authorization(config) do
      headers =
        [
          {"accept", "application/json"},
          {"content-type", "text/plain"}
        ] ++
          case {namespace, database} do
            {nil, _} -> []
            {ns, nil} -> [{"surreal-ns", ns}]
            {ns, db} -> [{"surreal-ns", ns}, {"surreal-db", db}]
          end ++ authorization

      case Finch.build(:post, "#{base_url()}/sql", headers, statement)
           |> Finch.request(:veritas_store_pool, []) do
        {:ok, %Finch.Response{status: status, body: raw}} -> {:ok, status, raw}
        {:error, reason} -> {:error, transport_error(reason)}
      end
    end
  end

  # The store is reached with a credential.
  #
  # A connection with **no** user is an anonymous connection, and an
  # anonymous connection to a store that happens to allow it looks exactly
  # like a working deployment — until the day the store's own rules change,
  # or until the day the store is reached by someone else. It is a
  # misconfiguration, not a mode, and it is refused here rather than
  # discovered later.
  # The store is reached with a credential.
  #
  # A connection with **no** user is an anonymous connection, and an
  # anonymous connection to a store that happens to allow it looks exactly
  # like a working deployment -- until the day the store's own rules change,
  # until the day the store is reached by someone else. It is a
  # misconfiguration, not a mode, and it is refused here rather than
  # discovered later.
  #
  # The credential is a **token**, not the password. The store re-verifies
  # the password on every request, and the password hash is deliberately slow
  # to verify: the credential costs more than the query it carries -- 10.7 ms
  # against a point read's 0.2 ms. A token is verified in microseconds, so
  # the Adapter signs in once and presents the token until the store refuses
  # it.
  #
  # The token is a credential, and it is never written to a log, an error
  # message, a report or a test output.
  defp authorization(config) do
    case config[:user] do
      user when is_binary(user) and user != "" ->
        case bearer_token(config) do
          {:ok, token} -> {:ok, [{"authorization", "Bearer " <> token}]}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error,
         Error.new(
           :invalid_request,
           "the datastore connection has no user configured; the store would be reached anonymously",
           details: %{}
         )}
    end
  end

  # The token, and the life it lives in.
  #
  # The token is obtained **once**, on the first request after a start or a
  # re-authentication, and is then presented on every request. It is cached
  # in `:persistent_term` because it changes rarely -- the store's root user
  # has `DURATION FOR TOKEN 1h` -- and because every process that makes a
  # request has to read it. The key carries the store and the user, so a
  # second store, or a second user, never reuses another's token.
  defp token_key(config), do: {__MODULE__, :bearer_token, base_url(), config[:user]}

  defp bearer_token(config) do
    key = token_key(config)

    case :persistent_term.get(key, nil) do
      nil ->
        case sign_in(config) do
          {:ok, token} ->
            :persistent_term.put(key, token)
            {:ok, token}

          {:error, reason} ->
            {:error, reason}
        end

      token ->
        {:ok, token}
    end
  end

  # Forgets the token, so that the next attempt signs in again.
  defp forget_token(config) do
    :persistent_term.erase(token_key(config))
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Signs in, once, and returns the token.
  #
  # The sign-in carries no namespace or database header: the token is then
  # the store's own, and it is valid for every namespace and database the
  # user may reach. A token obtained for one Workspace would not be.
  #
  # The password is on the wire and nowhere else: not in a log, not in an
  # error, and not in what the store hands back.
  defp sign_in(config) do
    body = Jason.encode!(%{"user" => config[:user], "pass" => config[:pass]})

    request =
      Finch.build(
        :post,
        "#{base_url()}/signin",
        [{"accept", "application/json"}, {"content-type", "application/json"}],
        body
      )

    case Finch.request(request, :veritas_store_pool, []) do
      {:ok, %Finch.Response{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"token" => token}} when is_binary(token) and token != "" ->
            {:ok, token}

          _other ->
            {:error,
             Error.new(:internal, "the store did not return a session token", details: %{})}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, http_error(status, "")}

      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  defp decode(raw, batch) do
    case Jason.decode(raw) do
      {:ok, results} when is_list(results) ->
        case first_failure(results) do
          nil ->
            rows =
              results
              |> Enum.map(&Map.get(&1, "result"))
              |> Enum.flat_map(fn
                result when is_list(result) -> result
                result -> [result]
              end)

            {:ok, rows}

          {failed, index} ->
            {:error, query_error(failed, batch, index)}
        end

      {:ok, %{"code" => code, "information" => information}} ->
        {:error,
         Error.new(:invalid_request, "the store rejected the statement",
           details: %{code: code, information: information}
         )}

      {:ok, other} ->
        {:ok, List.wrap(other)}

      {:error, reason} ->
        {:error,
         Error.new(:protocol, "the store returned an unreadable response",
           details: %{reason: reason}
         )}
    end
  end

  # The *root* failure, not the statements that were skipped because of it.
  # A batch reports "not executed" for every statement after the one that
  # actually failed, and reporting those would hide the cause.
  #
  # The index comes with it, because the index is what names the statement.
  defp first_failure(results) do
    failures =
      Enum.filter(Enum.with_index(results), fn {result, _index} -> result["status"] != "OK" end)

    case Enum.find(failures, fn {result, _index} -> not skipped?(result) end) do
      nil -> List.first(failures)
      found -> found
    end
  end

  # A statement the store skipped because an earlier one failed reports its
  # kind in the details. Those are the *consequence*; the cause is the first
  # failure that is not one of them.
  defp skipped?(failure) do
    kind = to_string(failure["kind"] || "")

    details_kind =
      case failure["details"] do
        %{"kind" => kind} -> to_string(kind)
        _ -> nil
      end

    Enum.any?([kind, details_kind], &(&1 in ["NotExecuted", "Cancelled"]))
  end

  # The store's own words are the **detail**, not the message.
  #
  # A message crosses the API boundary and reaches whoever asked the
  # question. A detail stays on the server, where a diagnosis can use it.
  # The engine's text can name a namespace, a table or a record — and the
  # namespace it names is not always the one the caller asked about — so the
  # message is composed here, from a closed vocabulary, and the engine's text
  # travels in `details` where it is still readable.
  defp query_error(failed, batch, index) do
    engine_message = to_string(failed["result"] || "")
    kind = to_string(failed["kind"] || "")
    details = with_statement(failed, failing_statement(batch, index))

    cond do
      conflict?(engine_message) ->
        Error.new(:conflict, "the store rejected the write as a conflict", details: details)

      missing_record?(engine_message) ->
        Error.new(:not_found, "the store could not find the record", details: details)

      permission_refused?(engine_message) ->
        Error.new(:permission_denied, "the store refused the operation", details: details)

      malformed?(engine_message) ->
        Error.new(:invalid_request, "the store rejected the statement", details: details)

      # A schema constraint refused the statement: a field the SCHEMAFULL
      # table does not have, a value the field's type will not take, a
      # required field left out, or an ASSERT the value does not satisfy.
      # The taxonomy says these are `:invalid_request` — the request was
      # malformed, or a constraint rejected it — and not `:internal`, which
      # is "always a defect, never a normal outcome". A caller that sees
      # `:internal` assumes the product is broken; a caller that sees
      # `:invalid_request` knows its own row was wrong.
      constraint_rejected?(engine_message) ->
        Error.new(
          :invalid_request,
          "the store refused the statement: a schema constraint rejected it",
          details: details
        )

      kind == "NotFound" ->
        Error.new(:not_found, "the store could not find what the statement named",
          details: details
        )

      kind == "NotExecuted" or kind == "Cancelled" ->
        Error.new(:conflict, "the transaction was aborted by an earlier failure",
          details: details
        )

      true ->
        Error.new(:internal, "the store could not execute the statement", details: details)
    end
  end

  # The engine's own words, each one a named predicate: the taxonomy's codes
  # are the contract, and a function holding every phrase is a function
  # nobody can read.
  #
  # A schema constraint refused the statement: a field the SCHEMAFULL table
  # does not have, a value the field's type will not take, a required field
  # left out, or an ASSERT the value does not satisfy. The taxonomy says these
  # are `:invalid_request` — the request was malformed, or a constraint
  # rejected it — and not `:internal`, which is "always a defect, never a
  # normal outcome". A caller that sees `:internal` assumes the product is
  # broken; a caller that sees `:invalid_request` knows its own row was
  # wrong.
  defp conflict?(message) do
    String.contains?(message, "already exists") or String.contains?(message, "unique index")
  end

  defp missing_record?(message) do
    String.contains?(message, "does not exist") and String.contains?(message, "record")
  end

  defp permission_refused?(message) do
    String.contains?(message, "Permission") or String.contains?(message, "not allowed")
  end

  defp malformed?(message) do
    String.contains?(message, "Parse error") or String.contains?(message, "Unexpected token")
  end

  defp constraint_rejected?(message) do
    String.contains?(message, "Couldn't coerce value for field") or
      String.contains?(message, "but no such field exists for table") or
      String.contains?(message, "but field must conform to") or
      String.contains?(message, "for the `id` field")
  end

  # The statement that failed, named in the error's details.
  #
  # The engine answers a batch with one result per statement, **in order**,
  # and the batch the Adapter sends is `BEGIN;` + the statements + `COMMIT;`
  # — so the result at index `i` names the statement at index `i - 1`. The
  # offset is carried with the batch, because a request that is a single
  # statement has no `BEGIN` in front of it.
  #
  # Naming the statement is the difference between a diagnosis and a guess:
  # the engine's own words ("unreachable logic: Expected a document id to be
  # present") say nothing about *which* statement it was.
  defp failing_statement(%{statements: statements, offset: offset}, index)
       when is_list(statements) and is_integer(index) do
    Enum.at(statements, index - offset)
  end

  defp failing_statement(_batch, _index), do: nil

  defp with_statement(failed, nil), do: failed

  defp with_statement(failed, statement) when is_map(failed),
    do: Map.put(failed, "statement", statement)

  defp with_statement(failed, _statement), do: failed

  defp http_error(401, _raw),
    do: Error.new(:permission_denied, "the store refused the credentials")

  defp http_error(403, _raw), do: Error.new(:permission_denied, "the store refused the operation")
  defp http_error(404, _raw), do: Error.new(:not_found, "the store has no such endpoint")
  defp http_error(408, raw), do: Error.new(:timeout, "the store timed out", details: %{body: raw})

  defp http_error(status, raw) do
    Error.new(
      :internal,
      "the store answered with HTTP #{status}",
      details: %{body: raw, status: status, summary: summarise(raw)}
    )
  end

  # The store's own words, when it has any: a parse error names the
  # statement, and that is the difference between a fixable minute and an
  # afternoon of guessing. They are a **detail**: the statement is the
  # Adapter's, and it holds the caller's data.
  defp summarise(raw) do
    case Jason.decode(raw) do
      {:ok, %{"information" => information}} -> to_string(information)
      {:ok, %{"description" => description}} -> to_string(description)
      _ -> raw |> to_string() |> String.slice(0, 200)
    end
  end

  # The transport's own words stay in the detail too. They can carry the
  # address the store is reached at, and the address is the operator's.
  defp transport_error(reason) do
    Error.new(:unavailable, "the store could not be reached", details: %{reason: inspect(reason)})
  end

  # ── configuration ─────────────────────────────────────────────────────────

  @doc """
  The datastore connection settings.

      config :veritas_core, :surreal,
        url: "http://127.0.0.1:8000",
        user: "root",
        pass: "root"

  The URL may also come from `VERITAS_SURREAL_URL`.
  """
  @spec settings() :: keyword()
  def settings do
    Application.get_env(:veritas_core, :surreal, [])
  end

  defp config do
    configured =
      case Veritas.Store.Config.options() do
        [] -> settings()
        options -> Keyword.merge(settings(), options)
      end

    # The credentials have defaults, because a store that is unreachable
    # because a password was left out is a store fault that looks like a
    # network fault.
    Keyword.merge([user: "root", pass: "root"], configured)
  end

  defp base_url do
    config()[:url] || System.get_env("VERITAS_SURREAL_URL", "http://127.0.0.1:8000")
  end

  defp identifier, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
