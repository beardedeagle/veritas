defmodule Veritas.Plugin.Host.Default do
  @moduledoc """
  The shipped Host API adapter: the host's own data plane, reached through
  `Veritas.Store`.

  This is the implementation of `Veritas.Plugin.Host` that ships with the
  host. It exists so the Host API is not a promise: `host.read_records`
  reads records, `host.write_records` writes them, `host.query_graph`
  traverses the CMDB, and each of them goes through the same store port the
  rest of the product uses — the same Workspace scope, the same audit rules,
  the same transactions.

  It is **Default**: an operator may install another adapter — one that
  serves a different data plane, or a stub that records what a Plugin asked
  for — without changing the boundary, the transport or the enforcement
  point.

  ## What this adapter does not do

  `host.publish_event` is refused with `{:error, :unsupported}`. Publishing
  an event means writing a row into the transactional outbox, and the store
  port (`Veritas.Store`) offers no operation that does that: the outbox is
  written by the store adapter itself as part of a record write. Adding a
  publishing operation to the store port is a change to `Veritas.Store`,
  which is outside this runtime's ownership, so the operation says so
  instead of pretending.

  The outbox is still fed: every write a Plugin makes through
  `host.write_records` lands in it, because that is how the store works.
  """

  @behaviour Veritas.Plugin.Host

  alias Veritas.Store

  @impl true
  @spec init(term()) :: term()
  def init(opts), do: opts

  @impl true
  @spec call(Veritas.Plugin.Host.context(), Veritas.Plugin.Host.request(), term()) ::
          {:ok, term()} | {:error, term()}
  def call(context, %{"method" => method, "params" => params}, _state) do
    params = if is_map(params), do: params, else: %{}

    case method do
      "read_records" -> read_records(context, table(params), decode_filter(params["filter"]))
      "write_records" -> write_records(context, table(params), records(params))
      "query_graph" -> query_graph(context, params)
      "publish_event" -> publish_event(context, params["event_type"], params["payload"])
      _other -> {:error, :unknown_method}
    end
  end

  @impl true
  @spec read_records(Veritas.Plugin.Host.context(), :ci | :ticket, map()) ::
          {:ok, %{rows: [map()], cursor: binary() | nil}} | {:error, term()}
  def read_records(context, table, filter) do
    workspace = workspace(context)

    case Store.transaction(workspace, fn tx -> Store.list(tx, table, filter) end) do
      {:ok, rows} -> {:ok, %{rows: rows, cursor: nil}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @impl true
  @spec write_records(Veritas.Plugin.Host.context(), :ci | :ticket, [map()]) ::
          {:ok, [map()]} | {:error, term()}
  def write_records(context, table, records) do
    workspace = workspace(context)

    result =
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, written} ->
        case write_record(workspace, table, record, context) do
          {:ok, row} -> {:cont, {:ok, written ++ [row]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # A record is written through the **domain**, and not into the store.
  #
  # The domain holds the rules the corpus states — a Configuration Item's
  # lifecycle, a ticket's workflow — and it records every change in the Audit
  # Log. A Plugin that wrote to the store directly could put a record into a
  # state the domain would refuse, write a column the domain owns, and leave
  # no trace of either in the Audit Log: the Audit Log is what says what
  # happened to the Workspace, and a write that is not in it did not happen
  # as far as anyone can tell.
  #
  # The **actor** is the Plugin, and the host's own actor is not a thing a
  # Plugin can choose: a Plugin that could write an Audit Log entry in
  # somebody else's name would be writing a record it is not the author of.
  defp write_record(workspace, :ci, record, context) do
    attrs = Map.put(record, "actor", actor(context))

    case record["id"] do
      nil -> Veritas.Core.CI.create(workspace, attrs)
      id -> Veritas.Core.CI.update(workspace, id, attrs)
    end
  end

  defp write_record(workspace, :ticket, record, context) do
    attrs = Map.put(record, "actor", actor(context))

    case record["id"] do
      nil ->
        # A ticket the Plugin asks for. The domain opens it, so that it gets
        # the type's initial state, the type's detail row, and an identifier
        # the host minted rather than one the Plugin chose: identity belongs
        # to the host.
        Veritas.Core.Tickets.open(
          workspace,
          record["ticket_type"],
          attrs,
          actor(context)
        )

      id ->
        # A ticket that exists. The write either moves it through its
        # workflow or corrects what it says, and which one it is comes from
        # what the write names: a write that names a state is a move, and a
        # write that names content and no state is a correction. The host is
        # a transport — it asks the domain what a ticket's content is, and
        # the domain owns the vocabulary of a ticket's fields.
        case to_state(record) do
          {:ok, state} -> move_ticket(workspace, id, state, record, context)
          {:error, :no_state} -> edit_ticket(workspace, id, record, context)
        end
    end
  end

  # A write that names a state: a move.
  #
  # The move comes first and on its own, because it is checked against the
  # workflow table before anything is written: a refused move writes nothing
  # at all, and the content the write also carried is not written either.
  defp move_ticket(workspace, id, state, record, context) do
    # Sessions carry no delegated authority; a scope alone grants no ITIL role.
    case Veritas.Core.Tickets.transition(
           workspace,
           id,
           state,
           Veritas.Core.Principal.new(context.plugin_id, workspace, [], kind: :service),
           reason: reason(record),
           correlation_id: record["correlation_id"]
         ) do
      {:ok, moved} -> apply_content(workspace, id, record, context, moved)
      {:error, reason} -> {:error, reason}
    end
  end

  # The content a move also carried, applied to the ticket that has just
  # moved.
  #
  # Only the fields the write names, and only the ones the domain calls
  # content, are passed on: an update refuses a field it does not own by
  # name, and a write that is legal today — a move that happens to carry the
  # ticket's requester — must not be refused because of it.
  #
  # An update that changes nothing is not a failure: the content already held
  # those values, so the row from the move is what the Plugin gets back.
  defp apply_content(workspace, id, record, context, moved) do
    case Map.take(record, Veritas.Core.Tickets.content_fields()) do
      content when map_size(content) == 0 ->
        {:ok, moved}

      content ->
        case Veritas.Core.Tickets.update(
               workspace,
               id,
               content,
               actor(context),
               reason: reason(record),
               correlation_id: record["correlation_id"]
             ) do
          {:ok, updated} -> {:ok, updated}
          {:error, :no_change} -> {:ok, moved}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A write that names no state: a correction of what the ticket says.
  #
  # The fields that describe the write itself are not part of what is
  # written — the identifier says which ticket, the reason and the
  # correlation id say what the write is — and the rest is what the ticket is
  # corrected to. The domain owns the vocabulary of a ticket's fields, so a
  # field it does not own is refused **by name** and the Plugin is told
  # which one it may not write.
  #
  # A write that says nothing at all is the refusal it has always been.
  defp edit_ticket(workspace, id, record, context) do
    attrs = Map.drop(record, ["id", "actor", "reason", "correlation_id", "state", "to_state"])

    if map_size(attrs) == 0 do
      {:error, :no_state}
    else
      Veritas.Core.Tickets.update(
        workspace,
        id,
        attrs,
        actor(context),
        reason: reason(record),
        correlation_id: record["correlation_id"]
      )
    end
  end

  # The state a ticket write moves the ticket to, if it names one.
  #
  # A write that names a state is a move, and the move is checked against the
  # workflow table. A write that names none — or names something that is not
  # a state — is not a move at all: it is a correction of what the ticket
  # says, and the domain decides whether the fields it names are fields it
  # owns.
  defp to_state(record) do
    case record["state"] || record["to_state"] do
      state when is_binary(state) -> {:ok, state}
      _other -> {:error, :no_state}
    end
  end

  defp reason(record), do: record["reason"] || "a plugin wrote the record"

  defp actor(context), do: %{type: "plugin", id: Map.get(context, :plugin_id)}

  @impl true
  @spec query_graph(Veritas.Plugin.Host.context(), map()) :: {:ok, [map()]} | {:error, term()}
  def query_graph(context, params) do
    workspace = workspace(context)
    root = params["root"]
    direction = direction(params["direction"])
    depth = depth(params["depth"])
    opts = kinds(params["kinds"])

    case Store.transaction(workspace, fn tx ->
           Store.traverse(tx, root, direction, depth, opts)
         end) do
      {:ok, %{nodes: nodes, edges: edges}} -> {:ok, nodes ++ edges}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @impl true
  @spec publish_event(Veritas.Plugin.Host.context(), binary() | nil, term()) ::
          {:ok, binary()} | {:error, term()}
  def publish_event(_context, _event_type, _payload) do
    {:error,
     {:unsupported,
      "this host build cannot publish an event: the store port has no operation that " <>
        "writes the transactional outbox directly"}}
  end

  # ── the wire shapes ────────────────────────────────────────────────────────

  defp workspace(context), do: Map.get(context, :workspace)

  defp table(params) do
    case Map.get(params, "table") do
      "ticket" -> :ticket
      _other -> :ci
    end
  end

  defp records(params) do
    case Map.get(params, "records") do
      records when is_list(records) -> records
      _other -> []
    end
  end

  defp direction("in"), do: :in
  defp direction(_other), do: :out

  defp depth(depth) when is_integer(depth) and depth > 0, do: min(depth, 5)
  defp depth(_other), do: 1

  defp kinds(nil), do: []
  defp kinds(kinds) when is_list(kinds), do: [kinds: kinds]
  defp kinds(_other), do: []

  # The filter arrives as JSON, so its fields are strings. The store's port
  # says atoms, and an atom that already exists is used; one that does not
  # is left as the string it arrived as, because inventing an atom from a
  # Plugin's input is how a process grows atoms until it dies.
  defp decode_filter(nil), do: %{where: []}

  defp decode_filter(filter) when is_map(filter) do
    %{
      where: filter |> Map.get("where", []) |> Enum.map(&decode_condition/1),
      order_by: filter |> Map.get("order_by", []) |> Enum.map(&decode_order/1),
      limit: filter["limit"],
      offset: filter["offset"]
    }
  end

  defp decode_filter(_filter), do: %{where: []}

  defp decode_condition([field, value]), do: {field_atom(field), value}
  defp decode_condition(_other), do: {:id, nil}

  defp decode_order([field, direction]),
    do: {field_atom(field), if(direction == "desc", do: :desc, else: :asc)}

  defp decode_order(_other), do: {:id, :asc}

  defp field_atom(field) when is_atom(field), do: field

  defp field_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> field
  end
end
