defmodule Veritas.Store.Memory.Server do
  @moduledoc """
  The process that holds the in-memory store's state.

  Every write goes through one process, so a transaction applies its whole
  buffer in one step: the atomicity obligation is structural here, not
  something the Adapter has to be trusted to get right.

  ## The shape of the state

  The state is a map of **Workspaces**, and each Workspace holds its own
  records, relations, registries, sequences, chunks, samples and Audit Log
  rows. The Workspace is the isolation unit of the contract (`docs/32` O-4),
  so a row cannot be seen from another Workspace — not by convention, but
  because the other Workspace's map is not on the path.

      %{
        workspaces: %{
          "acme" => %{
            records: %{ci: %{"ci-1" => %{...}}},
            relations: [...],
            ci_types: %{...},
            relation_kinds: %{...},
            sequences: %{"ticket" => 7},
            chunks: [...],
            samples: [...],
            audit: [...]
          }
        },
        outbox: %{"acme" => [...]},
        calls: [],
        transitions: [...]
      }
  """

  use GenServer

  @default_workspace "default"

  # ── lifecycle ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The current state, as a view the domain tests read."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Replaces the current state."
  def put_state(state), do: GenServer.call(__MODULE__, {:put_state, state})

  @doc "The raw state, without the flattened view."
  def raw_state, do: GenServer.call(__MODULE__, :raw_state)

  # ── the store's operations ────────────────────────────────────────────────

  def fetch(server, workspace, table, id),
    do: GenServer.call(server, {:fetch, workspace, table, id})

  def list(server, workspace, table), do: GenServer.call(server, {:list, workspace, table})

  def next_sequence(server, workspace, key),
    do: GenServer.call(server, {:next_sequence, workspace, key})

  def commit(server, buffer), do: GenServer.call(server, {:commit, buffer})

  def traverse(server, workspace, from, direction, depth, kinds),
    do: GenServer.call(server, {:traverse, workspace, from, direction, depth, kinds})

  @doc "Reads the committed relation rows of one Workspace without fetching endpoints."
  @spec relations(GenServer.server(), String.t()) :: {:ok, [map()]}
  def relations(server, workspace), do: GenServer.call(server, {:relations, workspace})

  def relation_counts(server, workspace, ids),
    do: GenServer.call(server, {:relation_counts, workspace, ids})

  def impact(server, workspace, ci_id, depth),
    do: GenServer.call(server, {:impact, workspace, ci_id, depth})

  def ci_types(server, workspace), do: GenServer.call(server, {:ci_types, workspace})
  def relation_kinds(server, workspace), do: GenServer.call(server, {:relation_kinds, workspace})
  def chunks(server, workspace), do: GenServer.call(server, {:chunks, workspace})

  def samples(server, workspace, target, from, to),
    do: GenServer.call(server, {:samples, workspace, target, from, to})

  def changes(server, workspace, since), do: GenServer.call(server, {:changes, workspace, since})

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, view(state), state}

  @impl true
  def handle_call(:raw_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:put_state, view}, _from, state) do
    {:reply, :ok, merge_view(state, view)}
  end

  @impl true
  def handle_call({:fetch, workspace, table, id}, _from, state) do
    record = ws_get(state, workspace, [:records, table, id])
    {:reply, {:ok, record}, record_call(state, {:fetch, table, id})}
  end

  @impl true
  def handle_call({:list, workspace, table}, _from, state) do
    rows =
      case table do
        # The Audit Log is append-only: its rows are a list, not a map of
        # records. It is read back through the same path as every other
        # table, or the chain cannot be verified.
        :audit_event ->
          ws_get(state, workspace, [:audit]) || []

        :event_outbox ->
          outbox_rows(state, workspace)

        _other ->
          Map.values(ws_get(state, workspace, [:records, table]) || %{})
      end

    {:reply, {:ok, rows}, record_call(state, {:list, table})}
  end

  @impl true
  def handle_call({:next_sequence, workspace, key}, _from, state) do
    {value, state} = bump(state, workspace, key)
    {:reply, {:ok, value}, state}
  end

  @impl true
  def handle_call({:commit, buffer}, _from, state) do
    {state, outbox} = Enum.reduce(buffer, {state, []}, &apply_op(&1, &2))

    # The outbox accumulates: the change stream is the whole history of the
    # Workspace's changes, not only the last transaction's.
    state = %{state | outbox: Map.update(state.outbox, :__all__, outbox, &(&1 ++ outbox))}
    {:reply, {:ok, state}, record_call(state, {:transaction, buffer})}
  end

  @impl true
  def handle_call({:relations, workspace}, _from, state) do
    rows =
      case ws_get(state, workspace, [:relations]) do
        nil -> []
        rows -> rows
      end

    {:reply, {:ok, rows}, state}
  end

  @impl true
  def handle_call({:relation_counts, workspace, ids}, _from, state) do
    edges = ws_get(state, workspace, [:relations]) || []

    counts =
      Enum.reduce(ids, %{}, fn id, acc ->
        Map.put(acc, id, %{in: MapSet.new(), out: MapSet.new()})
      end)

    counts =
      Enum.reduce(edges, counts, fn edge, acc ->
        acc = count_side(acc, edge["to"], edge["from"], :in)
        count_side(acc, edge["from"], edge["to"], :out)
      end)

    counts =
      Map.new(counts, fn {id, sides} ->
        {id, MapSet.size(sides.in) + MapSet.size(sides.out)}
      end)

    {:reply, {:ok, counts}, state}
  end

  def handle_call({:traverse, workspace, from, direction, depth, kinds}, _from, state) do
    edges = ws_get(state, workspace, [:relations]) || []

    kinds = kinds || Enum.map(edges, & &1["kind"])

    nodes = walk(state, workspace, edges, from, direction, depth, kinds, [], MapSet.new())

    {:reply, {:ok, nodes}, state}
  end

  @impl true
  def handle_call({:impact, workspace, ci_id, depth}, _from, state) do
    edges = ws_get(state, workspace, [:relations]) || []
    ci = ws_get(state, workspace, [:records, :ci, ci_id])

    dependents =
      walk(state, workspace, edges, ci_id, :in, depth, nil, [], MapSet.new([ci_id]))
      |> Enum.map(& &1["id"])

    services =
      dependents
      |> Enum.map(&ws_get(state, workspace, [:records, :ci, &1]))
      |> Enum.filter(&(&1 && &1["ci_type"] == "service"))

    affected_cis = MapSet.new([ci_id | dependents])

    related_tickets =
      Enum.reduce(edges, MapSet.new(), fn edge, ids ->
        if edge["kind"] == "affects" and MapSet.member?(affected_cis, edge["to"]) do
          MapSet.put(ids, edge["from"])
        else
          ids
        end
      end)

    # Legacy ticket.ci remains an impact input, not canonical membership.
    # Filter the ticket rows once so a ticket matched both ways appears once.
    tickets =
      (ws_get(state, workspace, [:records, :ticket]) || %{})
      |> Map.values()
      |> Enum.filter(fn ticket ->
        MapSet.member?(affected_cis, ticket["ci"]) or
          MapSet.member?(related_tickets, ticket["id"])
      end)

    {:reply, {:ok, %{ci: ci, services: services, tickets: tickets}}, state}
  end

  @impl true
  def handle_call({:ci_types, workspace}, _from, state) do
    {:reply, {:ok, Map.values(ws_get(state, workspace, [:ci_types]) || %{})}, state}
  end

  @impl true
  def handle_call({:relation_kinds, workspace}, _from, state) do
    {:reply, {:ok, Map.values(ws_get(state, workspace, [:relation_kinds]) || %{})}, state}
  end

  @impl true
  def handle_call({:chunks, workspace}, _from, state) do
    {:reply, {:ok, ws_get(state, workspace, [:chunks]) || []}, state}
  end

  @impl true
  def handle_call({:samples, workspace, target, from, to}, _from, state) do
    rows =
      (ws_get(state, workspace, [:samples]) || [])
      |> Enum.filter(fn sample ->
        sample["target"] == target and
          DateTime.compare(sample["at"], from) != :lt and
          DateTime.compare(sample["at"], to) != :gt
      end)
      |> Enum.sort_by(& &1["at"], DateTime)

    {:reply, {:ok, rows}, state}
  end

  @impl true
  def handle_call({:changes, workspace, since}, _from, state) do
    rows =
      outbox_rows(state, workspace)
      |> Enum.filter(&(&1["sequence"] > since))
      |> Enum.sort_by(& &1["sequence"])

    {:reply, {:ok, rows}, state}
  end

  # The outbox rows of one Workspace. Every row carries the Workspace it was
  # written in, so the stream is scoped the same way every other read is.
  defp outbox_rows(state, workspace) do
    (Map.get(state.outbox, workspace, []) ++ Map.get(state.outbox, :__all__, []))
    |> Enum.filter(&(&1["workspace"] == workspace))
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp initial_state do
    %{
      workspaces: %{},
      outbox: %{},
      calls: [],
      transitions: Veritas.Store.Surreal.Schema.incident_transitions()
    }
  end

  defp view(state) do
    workspace = @default_workspace

    %{
      tickets: ws_get(state, workspace, [:records, :ticket]) || %{},
      details: ws_get(state, workspace, [:records, :incident]) || %{},
      audit: ws_get(state, workspace, [:audit]) || [],
      transitions: state.transitions,
      calls: state.calls
    }
  end

  defp merge_view(state, view) do
    workspace = @default_workspace

    state
    |> ws_put(workspace, [:records, :ticket], Map.get(view, :tickets, %{}))
    |> ws_put(workspace, [:records, :incident], Map.get(view, :details, %{}))
    |> ws_put(workspace, [:audit], Map.get(view, :audit, []))
    |> Map.put(:calls, Map.get(view, :calls, state.calls))
    |> Map.put(:transitions, Map.get(view, :transitions, state.transitions))
  end

  defp record_call(state, call) do
    %{state | calls: state.calls ++ [call]}
  end

  # ── the Workspace's state ─────────────────────────────────────────────────

  defp workspace(state, workspace) do
    # Only absent Workspaces receive built-ins; existing registries are authoritative.
    Map.get_lazy(state.workspaces, workspace, fn ->
      relation_kinds =
        Map.new(Veritas.Store.Surreal.Schema.relation_kinds(), fn row ->
          {row["id"], Map.put(row, "workspace", workspace)}
        end)

      %{relation_kinds: relation_kinds}
    end)
  end

  defp ws_get(state, workspace, path), do: get_in(workspace(state, workspace), path)

  defp ws_put(state, workspace, path, value) do
    ws = put_nested(workspace(state, workspace), path, value)
    %{state | workspaces: Map.put(state.workspaces, workspace, ws)}
  end

  defp ws_append(state, workspace, key, items) do
    ws = workspace(state, workspace)
    existing = Map.get(ws, key, [])

    %{
      state
      | workspaces: Map.put(state.workspaces, workspace, Map.put(ws, key, existing ++ items))
    }
  end

  # `put_in/3` cannot create the missing levels of a path, so every write
  # goes through here. The recursion happens *inside* the level it creates:
  # the leaf belongs to the nested map, not to its parent.
  defp put_nested(state, [key], value), do: Map.put(state, key, value)

  defp put_nested(state, [key | rest], value) do
    Map.put(state, key, put_nested(Map.get(state, key) || %{}, rest, value))
  end

  defp bump(state, workspace, key) do
    current = ws_get(state, workspace, [:sequences, key]) || 0
    value = current + 1

    {value, ws_put(state, workspace, [:sequences, key], value)}
  end

  defp apply_op({:put, table, row}, {state, outbox}) do
    workspace = row["workspace"] || @default_workspace
    state = ws_put(state, workspace, [:records, table, row["id"]], row)
    {state, outbox_row} = outbox_row(state, workspace, table, row["id"], "put")
    {state, [outbox_row | outbox]}
  end

  defp apply_op({:delete, table, id}, acc) do
    apply_op({:delete, @default_workspace, table, id}, acc)
  end

  defp apply_op({:delete, workspace, table, id}, {state, outbox}) do
    records = ws_get(state, workspace, [:records]) || %{}

    state =
      ws_put(state, workspace, [:records, table], Map.delete(records[table] || %{}, id))

    {state, outbox_row} = outbox_row(state, workspace, table, id, "delete")
    {state, [outbox_row | outbox]}
  end

  defp apply_op({:relate, _kind, edge}, {state, outbox}) do
    workspace = edge["workspace"] || @default_workspace
    {ws_append(state, workspace, :relations, [edge]), outbox}
  end

  defp apply_op({:unrelate, kind, from, to}, acc) do
    apply_op({:unrelate, @default_workspace, kind, from, to}, acc)
  end

  defp apply_op({:unrelate, workspace, kind, from, to}, {state, outbox}) do
    relations = ws_get(state, workspace, [:relations]) || []

    kept =
      Enum.reject(relations, fn edge ->
        edge["kind"] == to_string(kind) and edge["from"] == from and edge["to"] == to
      end)

    {ws_put(state, workspace, [:relations], kept), outbox}
  end

  defp apply_op({:put_ci_type, row}, {state, outbox}) do
    workspace = row["workspace"] || @default_workspace
    {ws_put(state, workspace, [:ci_types, row["id"]], row), outbox}
  end

  defp apply_op({:put_relation_kind, row}, {state, outbox}) do
    workspace = row["workspace"] || @default_workspace
    {ws_put(state, workspace, [:relation_kinds, row["id"]], row), outbox}
  end

  defp apply_op({:upsert_chunks, subject, chunks}, {state, outbox}) do
    workspace = @default_workspace
    existing = ws_get(state, workspace, [:chunks]) || []

    kept = Enum.reject(existing, &(&1["subject"] == subject))
    tagged = Enum.map(chunks, &Map.put(&1, "subject", subject))

    {ws_put(state, workspace, [:chunks], kept ++ tagged), outbox}
  end

  defp apply_op({:append_samples, samples}, {state, outbox}) do
    workspace = @default_workspace
    {ws_append(state, workspace, :samples, samples), outbox}
  end

  defp apply_op({:append_audit, row}, {state, outbox}) do
    workspace = row["workspace"] || @default_workspace
    {ws_append(state, workspace, :audit, [row]), outbox}
  end

  # The outbox row, and the state that carries its sequence.
  #
  # The sequence is allocated from the Workspace's outbox counter and the
  # counter is advanced with it, so two changes never claim the same place in
  # the stream. A counter that is read but never advanced hands out the same
  # sequence to every change.
  defp outbox_row(state, workspace, table, id, op) do
    {sequence, state} = bump(state, workspace, {:outbox, workspace})

    {state,
     %{
       "sequence" => sequence,
       "workspace" => workspace,
       "table" => to_string(table),
       "record_id" => id,
       "op" => op,
       "at" => DateTime.utc_now()
     }}
  end

  # One end of an edge, counted for the record on the other end.
  defp count_side(counts, root, neighbour, side) do
    case Map.fetch(counts, root) do
      {:ok, sides} ->
        Map.put(counts, root, Map.put(sides, side, MapSet.put(sides[side], neighbour)))

      :error ->
        counts
    end
  end

  defp walk(_state, _workspace, _edges, _id, _direction, 0, _kinds, acc, _seen), do: acc

  defp walk(state, workspace, edges, id, direction, depth, kinds, acc, seen) do
    if MapSet.member?(seen, id) do
      acc
    else
      seen = MapSet.put(seen, id)

      next =
        edges
        |> Enum.filter(fn edge ->
          kind_match = is_nil(kinds) or to_string(edge["kind"]) in kinds

          cond do
            not kind_match -> false
            direction in [:out, :both] -> edge["from"] == id
            direction in [:in, :both] -> edge["to"] == id
            true -> false
          end
        end)
        |> Enum.flat_map(fn edge ->
          other = if edge["from"] == id, do: edge["to"], else: edge["from"]

          record =
            ws_get(state, workspace, [:records, :ci, other]) ||
              ws_get(state, workspace, [:records, :ticket, other])

          case record do
            nil -> []
            record -> [Map.put(record, "edge", edge)]
          end
        end)

      acc = acc ++ next

      next
      |> Enum.map(& &1["id"])
      |> Enum.reduce(acc, fn child_id, acc ->
        walk(state, workspace, edges, child_id, direction, depth - 1, kinds, acc, seen)
      end)
    end
  end
end
