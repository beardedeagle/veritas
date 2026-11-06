defmodule Veritas.Store.Memory do
  @moduledoc """
  An in-memory implementation of the `Veritas.Store` contract.

  It exists for three reasons:

    * to prove the port is implementable without a database at all — a second
      implementation is the only honest evidence that a contract is a contract
      and not a description of one engine;
    * to give the domain a store for tests and for a home-lab deployment with
      no database installed;
    * to be the reference an Adapter author reads before writing their own.

  It is a **real** implementation, not a mock: it keeps the Audit Log chain
  order, the per-Workspace sequence, the outbox, the relation registries and
  the Workspace isolation. What it does not do is survive a restart of the
  BEAM, and it says so in `describe/0`.

  ## Transactions

  A transaction buffers its writes and applies them in one step at commit, so
  the atomicity obligation holds by construction rather than by hope.
  """

  @behaviour Veritas.Store

  alias Veritas.Store
  alias Veritas.Store.Error
  alias Veritas.Store.Tx

  @server Veritas.Store.Memory.Server
  # The node budget of a traversal. The corpus caps nodes and not only depth:
  # depth five at a fan-out of twelve visits 248,832 nodes, which is an outage.
  @max_traversal_nodes 5_000

  # ── lifecycle ─────────────────────────────────────────────────────────────

  @doc """
  Starts the in-memory store's process.

  It is **idempotent**: the process may already be running — the application
  starts it, and a test may start it too — and asking for a store that is
  already there must not be an error. The running process is returned.
  """
  def start_link(opts \\ []) do
    case Process.whereis(Veritas.Store.Memory.Server) do
      nil -> Veritas.Store.Memory.Server.start_link(opts)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Installs the in-memory store as the system's Adapter.

  The store's process is started if it is not running, and the running one is
  used if it is: the application starts that process at boot, so on a node
  that is already serving the process is usually already there. Asking for a
  store that is already there must not be an error — that is `start_link/1`'s
  promise — and it must not raise either, because this is the function that
  points the system at the in-memory store, and it has to be callable on a
  node that is already serving.

  Calling it more than once is safe: the second call finds the store running,
  and installs the same Adapter again.
  """
  @spec install(keyword()) :: :ok
  def install(opts \\ []) do
    ensure_running(opts)

    Veritas.Store.Config.configure({__MODULE__, []})
    :ok
  end

  # The store's process, started if it is not running.
  #
  # `start_link/1` is idempotent by its own promise, so the store is normally
  # already running and the answer is the running process. The
  # already-started answer is handled as well: it is what the underlying
  # `GenServer` answers when the process appears between the check and the
  # call. A store that could not be started at all is still a failure, and
  # says so.
  defp ensure_running(opts) do
    case start_link(opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise Error.new(
                :unavailable,
                "the in-memory store could not be started",
                details: %{reason: reason}
              )
    end
  end

  @doc "The current state of the store."
  @spec state() :: map()
  def state, do: Veritas.Store.Memory.Server.state()

  @doc "Replaces the current state of the store."
  @spec put_state(map()) :: :ok
  def put_state(state), do: Veritas.Store.Memory.Server.put_state(state)

  # ── the contract ──────────────────────────────────────────────────────────

  @impl true
  def transaction(workspace, fun, _opts \\ []) do
    {:ok, accumulator} = Tx.start_link(workspace)

    try do
      case fun.({:veritas_store_tx, accumulator}) do
        {:error, reason} ->
          {:error, reason}

        value ->
          case Veritas.Store.Memory.Server.commit(@server, Tx.ops(accumulator)) do
            {:ok, _state} -> value
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
        case Veritas.Store.Memory.Server.fetch(@server, workspace(accumulator), table, id) do
          {:ok, record} -> {:ok, record}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def put({:veritas_store_tx, accumulator}, table, record) do
    id = normalise_id(Map.get(record, "id") || raise(ArgumentError, "a record needs an id"))

    row =
      record
      |> Map.put("id", id)
      |> Map.put("workspace", workspace(accumulator))

    :ok = Tx.buffer_op(accumulator, {:put, table, row})
    :ok = Tx.put_overlay(accumulator, table, id, row)

    {:ok, row}
  end

  @impl true
  def delete({:veritas_store_tx, accumulator}, table, record_id) do
    id = normalise_id(record_id)
    :ok = Tx.buffer_op(accumulator, {:delete, table, id})
    :ok = Tx.put_overlay(accumulator, table, id, %{"id" => id, "deleted" => true})
    :ok
  end

  @impl true
  def list({:veritas_store_tx, accumulator}, table, filter) do
    {:ok, committed} =
      Veritas.Store.Memory.Server.list(@server, workspace(accumulator), table)

    overlay_rows = Tx.overlay_rows(accumulator, table)

    rows = Veritas.Store.Filter.merge(committed, overlay_rows)

    {:ok, Veritas.Store.Filter.apply(rows, filter)}
  end

  @impl true
  def next_sequence({:veritas_store_tx, accumulator}, key) do
    case Veritas.Store.Memory.Server.next_sequence(@server, workspace(accumulator), key) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def relate({:veritas_store_tx, accumulator}, kind, from, to, attrs) do
    edge = %{
      "id" => "#{kind}_#{normalise_id(from)}_#{normalise_id(to)}",
      "kind" => to_string(kind),
      "from" => normalise_id(from),
      "to" => normalise_id(to),
      "attributes" => attrs
    }

    :ok = Tx.buffer_op(accumulator, {:relate, kind, edge})
    {:ok, edge}
  end

  @impl true
  def unrelate({:veritas_store_tx, accumulator}, kind, from, to) do
    :ok = Tx.buffer_op(accumulator, {:unrelate, kind, normalise_id(from), normalise_id(to)})
    :ok
  end

  @impl true
  def traverse({:veritas_store_tx, accumulator}, from, direction, depth, opts) do
    kinds = Keyword.get(opts, :kinds)

    {:ok, nodes} =
      Veritas.Store.Memory.Server.traverse(
        @server,
        workspace(accumulator),
        from,
        direction,
        depth,
        kinds
      )

    # The node budget is the corpus's, and the same one the SurrealDB Adapter
    # applies: depth five at a fan-out of twelve visits 248,832 nodes.
    truncated = length(nodes) > @max_traversal_nodes
    nodes = Enum.take(nodes, @max_traversal_nodes)

    {:ok,
     %{
       nodes: nodes,
       edges: Enum.map(nodes, &edge_of/1),
       truncated: truncated
     }}
  end

  @impl true
  def relation_counts({:veritas_store_tx, accumulator}, ids) do
    Veritas.Store.Memory.Server.relation_counts(@server, workspace(accumulator), ids)
  end

  @impl true
  def impact({:veritas_store_tx, accumulator}, ci_id, depth) do
    case Veritas.Store.Memory.Server.impact(@server, workspace(accumulator), ci_id, depth) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_ci_type({:veritas_store_tx, accumulator}, spec) do
    # The Adapter owns the Workspace scope, so the row carries the Workspace
    # of the transaction that wrote it.
    row =
      spec |> Map.put("id", Map.get(spec, "id")) |> Map.put("workspace", workspace(accumulator))

    :ok = Tx.buffer_op(accumulator, {:put_ci_type, row})

    # A registry written in this transaction is visible to a read in it: the
    # registry is data, and data written now reads back now.
    :ok = Tx.put_overlay(accumulator, :ci_type, row["id"], row)

    {:ok, row}
  end

  @impl true
  def put_relation_kind({:veritas_store_tx, accumulator}, spec) do
    # The Adapter owns the Workspace scope, so the row carries the Workspace
    # of the transaction that wrote it. A registry written in one Workspace
    # is that Workspace's registry.
    row =
      spec |> Map.put("id", Map.get(spec, "id")) |> Map.put("workspace", workspace(accumulator))

    :ok = Tx.buffer_op(accumulator, {:put_relation_kind, row})
    :ok = Tx.put_overlay(accumulator, :relation_kind, row["id"], row)

    {:ok, row}
  end

  @impl true
  def ci_types({:veritas_store_tx, accumulator}) do
    with {:ok, rows} <- Veritas.Store.Memory.Server.ci_types(@server, workspace(accumulator)) do
      {:ok, merge_overlay(rows, accumulator, :ci_type)}
    end
  end

  @impl true
  def relation_kinds({:veritas_store_tx, accumulator}) do
    with {:ok, rows} <-
           Veritas.Store.Memory.Server.relation_kinds(@server, workspace(accumulator)) do
      {:ok, merge_overlay(rows, accumulator, :relation_kind)}
    end
  end

  @impl true
  def upsert_chunks({:veritas_store_tx, accumulator}, subject, chunks) do
    :ok = Tx.buffer_op(accumulator, {:upsert_chunks, normalise_id(subject), chunks})
    {:ok, length(chunks)}
  end

  @impl true
  def vector_search({:veritas_store_tx, accumulator}, embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)

    {:ok, chunks} = Veritas.Store.Memory.Server.chunks(@server, workspace(accumulator))

    hits =
      chunks
      |> Enum.map(fn chunk ->
        chunk
        |> Map.put("score", cosine(embedding, Map.get(chunk, "embedding", [])))
      end)
      |> Enum.reject(&(&1["score"] <= 0))
      |> Enum.sort_by(& &1["score"], :desc)
      |> Enum.take(limit)

    {:ok, hits}
  end

  @impl true
  def fulltext_search({:veritas_store_tx, accumulator}, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    terms = String.downcase(query) |> String.split(~r/\s+/, trim: true)

    {:ok, chunks} = Veritas.Store.Memory.Server.chunks(@server, workspace(accumulator))

    hits =
      chunks
      |> Enum.map(fn chunk ->
        body = String.downcase(Map.get(chunk, "content", ""))
        score = Enum.count(terms, &String.contains?(body, &1))
        Map.put(chunk, "score", score)
      end)
      |> Enum.reject(&(&1["score"] == 0))
      |> Enum.sort_by(& &1["score"], :desc)
      |> Enum.take(limit)

    {:ok, hits}
  end

  @impl true
  def append_samples({:veritas_store_tx, accumulator}, samples) do
    :ok = Tx.buffer_op(accumulator, {:append_samples, samples})
    {:ok, length(samples)}
  end

  @impl true
  def range_samples({:veritas_store_tx, accumulator}, target, from, to, opts) do
    limit = Keyword.get(opts, :limit, 1_000)

    {:ok, samples} =
      Veritas.Store.Memory.Server.samples(
        @server,
        workspace(accumulator),
        normalise_id(target),
        from,
        to
      )

    samples = Enum.take(samples, limit)

    {:ok, samples}
  end

  @impl true
  def append_audit({:veritas_store_tx, accumulator}, event) do
    case next_sequence({:veritas_store_tx, accumulator}, {:audit, workspace(accumulator)}) do
      {:ok, sequence} ->
        id = normalise_id(Map.get(event, "id"))

        row =
          event
          |> Map.put("id", id)
          |> Map.put("sequence", sequence)
          |> Map.put("workspace", workspace(accumulator))

        :ok = Tx.buffer_op(accumulator, {:append_audit, row})

        # The row joins the transaction's overlay, so that a later read in
        # this transaction sees it. The Audit Log's chain is built from the
        # rows a transaction can read, and an audit row no read can see is an
        # event with no predecessor: two events in one transaction would take
        # the same predecessor, and the chain would fork.
        :ok = Tx.put_overlay(accumulator, :audit_event, id, row)

        {:ok, sequence}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def changes({:veritas_store_tx, accumulator}, since, opts) do
    limit = Keyword.get(opts, :limit, 100)

    {:ok, rows} = Veritas.Store.Memory.Server.changes(@server, workspace(accumulator), since)

    rows = Enum.take(rows, limit)

    {:ok, rows}
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
        name: "in-memory",
        durable: false,
        version: "1"
      }
    }
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp workspace(accumulator), do: Tx.workspace(accumulator)

  # A row written in this transaction is visible to a read in it, and a row
  # this transaction has deleted is not visible at all.
  defp merge_overlay(rows, accumulator, table) do
    Veritas.Store.Filter.merge(rows, Tx.overlay_rows(accumulator, table))
  end

  defp normalise_id(id) when is_binary(id) do
    id |> to_string() |> String.split(":") |> List.last()
  end

  defp normalise_id(id), do: to_string(id)

  defp edge_of(node), do: Map.get(node, "edge", %{})

  defp cosine(left, right) do
    case {length(left), length(right)} do
      {0, _} ->
        0.0

      {_, 0} ->
        0.0

      {n, m} when n == m ->
        dot =
          Enum.zip(left, right)
          |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)

        left_norm = left |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
        right_norm = right |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

        if left_norm == 0 or right_norm == 0 do
          0.0
        else
          dot / (left_norm * right_norm)
        end

      _ ->
        0.0
    end
  end
end
