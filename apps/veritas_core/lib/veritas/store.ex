defmodule Veritas.Store do
  @moduledoc """
  The data-access port. The domain depends on this behaviour; Adapters implement
  it (`docs/32`, ADR-033).

  The datastore is a **Default**, not a Fixed decision: this behaviour is the
  contract, and the shipped Adapter is one implementation of it. A replacement
  Adapter is a configuration change, not a fork.

  ## The obligations, in summary

  The full contract — one obligation per rule, each with an automatable
  acceptance test — lives in `docs/32` §"The contract document". In short:

    * **Workspace scoping.** Every operation is scoped to a Workspace. An
      Adapter cannot build a statement without one, so a row that cannot be
      attributed to a Workspace cannot be read across Workspaces.
    * **Atomicity.** A transaction commits or commits nothing. The domain
      change, its Audit Log row and the outbox row share **one** transaction.
    * **Ordering.** Ordering is the per-Workspace sequence. Never wall-clock
      time.
    * **One system of record.** The Adapter holds exactly one store. No shadow
      store, no second writer.
    * **Loud failure.** An obligation the Adapter cannot meet produces a typed
      error (`%Veritas.Store.Error{}`). There is no silent degradation: an
      unsupported capability is refused, not answered with an empty result.

  ## The transaction handle

  `tx()` is opaque. It is created by an Adapter inside `transaction/3` and is
  meaningless outside one. The domain never inspects it, so no Adapter type
  can leak into a domain context (the same rule the agentic port applies to
  model providers, `docs/15`).

  A read inside a transaction observes the transaction's **own writes** and the
  committed state otherwise. It does not observe another transaction's
  uncommitted writes.

  ## The outbox row

  Every `put/3` and `delete/3` also appends an outbox row **in the same
  transaction**, so an event exists if and only if the change exists. The row
  shape is part of this contract, because the projection applier and the
  cross-Datacenter relay read it:

      %{
        "sequence" => integer,
        "workspace" => String.t(),
        "table" => String.t(),
        "id" => String.t(),
        "op" => "put" | "delete",
        "at" => DateTime.t()
      }
  """

  alias Veritas.Store.Error

  @typedoc "A Workspace identifier."
  @type workspace :: String.t()

  @typedoc "A logical record identifier. Physical ids are Adapter-internal."
  @type record_id :: String.t()

  @typedoc "A domain table name. The Adapter maps it to its physical table."
  @type table :: atom()

  @typedoc "A per-Workspace ordering value."
  @type seq :: non_neg_integer()

  @typedoc """
  A row: a map with string keys.

  Named `row` rather than `record`, because `record/0` is a built-in Elixir
  type and a public type of that name would override it.
  """
  @type row :: map()

  @typedoc "A relation kind, as registered in the relation-kind registry."
  @type relation_kind :: atom()

  @typedoc "An optional capability an Adapter may provide."
  @type capability ::
          :graph
          | :vector
          | :fulltext
          | :time_series
          | :change_stream
          | :atomic_audit
          | :atomic_outbox

  @typedoc "A listing filter. The Adapter applies it inside the Workspace scope."
  @type filter :: %{
          required(:where) => list({atom(), term()}),
          optional(:order_by) => list({atom(), :asc | :desc}),
          optional(:limit) => pos_integer(),
          optional(:offset) => non_neg_integer()
        }

  @typedoc """
  An opaque transaction handle.

  Constructed only by an Adapter, inside `transaction/3`.
  """
  @opaque tx :: {:veritas_store_tx, term()}

  @typedoc "The contract version an Adapter implements."
  @type contract_version :: String.t()

  @typedoc """
  What a transaction body returns.

  `{:error, reason}` aborts the transaction; any other value commits it and is
  the transaction's result.
  """
  @type result :: term()

  @doc "The contract version this port describes."
  @spec contract_version() :: contract_version()
  def contract_version, do: "store/1"

  @doc """
  The Adapter currently installed.

  The datastore is a Default: this is the one place the domain reaches the
  store, and the only thing a substitution has to change.
  """
  @spec adapter() :: module()
  defdelegate adapter(), to: Veritas.Store.Config

  # ── the calling façade ────────────────────────────────────────────────────
  #
  # The domain calls the **port**, never the Adapter. Each function below
  # resolves the installed Adapter and forwards to it. That keeps the domain's
  # dependency on the seam rather than on an implementation, and it means a
  # substitution is invisible above this line.

  @doc "See `Veritas.Store.transaction/3`."
  @spec transaction(workspace(), (tx() -> result()), keyword()) ::
          result() | {:error, Error.t()}
  def transaction(workspace, fun, opts \\ []), do: adapter().transaction(workspace, fun, opts)

  @doc "See `Veritas.Store.fetch/3`."
  @spec fetch(tx(), table(), record_id()) :: {:ok, row() | nil} | {:error, Error.t()}
  def fetch(tx, table, record_id), do: adapter().fetch(tx, table, record_id)

  @doc "See `Veritas.Store.put/3`."
  @spec put(tx(), table(), row()) :: {:ok, row()} | {:error, Error.t()}
  def put(tx, table, record), do: adapter().put(tx, table, record)

  @doc "See `Veritas.Store.delete/3`."
  @spec delete(tx(), table(), record_id()) :: :ok | {:error, Error.t()}
  def delete(tx, table, record_id), do: adapter().delete(tx, table, record_id)

  @doc "See `Veritas.Store.list/3`."
  @spec list(tx(), table(), filter()) :: {:ok, [row()]} | {:error, Error.t()}
  def list(tx, table, filter), do: adapter().list(tx, table, filter)

  @doc "See `Veritas.Store.next_sequence/2`."
  @spec next_sequence(tx(), term()) :: {:ok, seq()} | {:error, Error.t()}
  def next_sequence(tx, key), do: adapter().next_sequence(tx, key)

  @doc "See `Veritas.Store.relate/5`."
  @spec relate(tx(), relation_kind(), record_id(), record_id(), map()) ::
          {:ok, row()} | {:error, Error.t()}
  def relate(tx, kind, from, to, attrs), do: adapter().relate(tx, kind, from, to, attrs)

  @doc "See `Veritas.Store.unrelate/4`."
  @spec unrelate(tx(), relation_kind(), record_id(), record_id()) :: :ok | {:error, Error.t()}
  def unrelate(tx, kind, from, to), do: adapter().unrelate(tx, kind, from, to)

  @doc "See the optional `outgoing_relations/3` callback."
  @spec outgoing_relations(tx(), relation_kind() | String.t(), record_id()) ::
          {:ok, %{edges: [row()]}} | {:error, Error.t()}
  def outgoing_relations(tx, kind, from) do
    module = adapter()

    if Code.ensure_loaded?(module) and function_exported?(module, :outgoing_relations, 3) do
      module.outgoing_relations(tx, kind, from)
    else
      {:error, Error.new(:unsupported, "the adapter does not provide outgoing relation reads")}
    end
  end

  @doc "See `Veritas.Store.traverse/5`."
  @spec traverse(tx(), record_id(), :out | :in | :both, pos_integer(), keyword()) ::
          {:ok, %{nodes: [row()], edges: [row()]}} | {:error, Error.t()}
  def traverse(tx, from, direction, depth, opts),
    do: adapter().traverse(tx, from, direction, depth, opts)

  @doc "See `Veritas.Store.relation_counts/2`."
  @spec relation_counts(tx(), [record_id()]) ::
          {:ok, %{optional(record_id()) => non_neg_integer()}} | {:error, Error.t()}
  def relation_counts(tx, ids), do: adapter().relation_counts(tx, ids)

  @doc "See `Veritas.Store.impact/3`."
  @spec impact(tx(), record_id(), pos_integer()) ::
          {:ok, %{ci: row() | nil, services: [row()], tickets: [row()]}} | {:error, Error.t()}
  def impact(tx, ci_id, depth), do: adapter().impact(tx, ci_id, depth)

  @doc "See `Veritas.Store.put_ci_type/2`."
  @spec put_ci_type(tx(), map()) :: {:ok, row()} | {:error, Error.t()}
  def put_ci_type(tx, spec), do: adapter().put_ci_type(tx, spec)

  @doc "See `Veritas.Store.put_relation_kind/2`."
  @spec put_relation_kind(tx(), map()) :: {:ok, row()} | {:error, Error.t()}
  def put_relation_kind(tx, spec), do: adapter().put_relation_kind(tx, spec)

  @doc "See `Veritas.Store.ci_types/1`."
  @spec ci_types(tx()) :: {:ok, [row()]} | {:error, Error.t()}
  def ci_types(tx), do: adapter().ci_types(tx)

  @doc "See `Veritas.Store.relation_kinds/1`."
  @spec relation_kinds(tx()) :: {:ok, [row()]} | {:error, Error.t()}
  def relation_kinds(tx), do: adapter().relation_kinds(tx)

  @doc "See `Veritas.Store.upsert_chunks/3`."
  @spec upsert_chunks(tx(), record_id(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def upsert_chunks(tx, subject, chunks), do: adapter().upsert_chunks(tx, subject, chunks)

  @doc "See `Veritas.Store.vector_search/3`."
  @spec vector_search(tx(), [float()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def vector_search(tx, embedding, opts), do: adapter().vector_search(tx, embedding, opts)

  @doc "See `Veritas.Store.fulltext_search/3`."
  @spec fulltext_search(tx(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def fulltext_search(tx, query, opts), do: adapter().fulltext_search(tx, query, opts)

  @doc "See `Veritas.Store.append_samples/2`."
  @spec append_samples(tx(), [map()]) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def append_samples(tx, samples), do: adapter().append_samples(tx, samples)

  @doc "See `Veritas.Store.range_samples/5`."
  @spec range_samples(tx(), record_id(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def range_samples(tx, target, from, to, opts),
    do: adapter().range_samples(tx, target, from, to, opts)

  @doc "See `Veritas.Store.append_audit/2`."
  @spec append_audit(tx(), map()) :: {:ok, seq()} | {:error, Error.t()}
  def append_audit(tx, event), do: adapter().append_audit(tx, event)

  @doc "See `Veritas.Store.changes/3`."
  @spec changes(tx(), seq(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def changes(tx, since, opts), do: adapter().changes(tx, since, opts)

  # ── transaction scope ─────────────────────────────────────────────────────

  @doc """
  Runs `fun` inside one transaction.

  Every mutation the function performs through the `tx` handle commits
  together or not at all.

  The function's return value **is** the transaction's result — the same
  shape the callbacks return, so a domain `with` chain reads the same inside
  and outside a transaction. A body that returns `{:error, reason}` aborts the
  transaction and the reason is returned to the caller; a commit that fails
  returns `{:error, %Veritas.Store.Error{}}`.
  """
  @callback transaction(workspace(), (tx() -> result()), opts :: keyword()) ::
              result() | {:error, Error.t()}

  # ── records ───────────────────────────────────────────────────────────────

  @doc "Reads one record by identifier. `{:ok, nil}` when it does not exist."
  @callback fetch(tx(), table(), record_id()) :: {:ok, row() | nil} | {:error, Error.t()}

  @doc "Writes one record. The record carries its own `id`."
  @callback put(tx(), table(), row()) :: {:ok, row()} | {:error, Error.t()}

  @doc "Deletes one record. Deleting an absent record is not an error."
  @callback delete(tx(), table(), record_id()) :: :ok | {:error, Error.t()}

  @doc "Lists records of a table, filtered and ordered, inside the Workspace scope."
  @callback list(tx(), table(), filter()) :: {:ok, [row()]} | {:error, Error.t()}

  # ── ordering ──────────────────────────────────────────────────────────────

  @doc """
  Allocates the next ordering value for a key, from the store itself.

  There is no second counter system: the value comes from the same store, so
  it cannot drift from the data it orders. The value is allocated immediately
  before the transaction commits, so a transaction that aborts may leave a gap.
  Monotonicity — never gaplessness — is what callers may rely on.
  """
  @callback next_sequence(tx(), key :: term()) :: {:ok, seq()} | {:error, Error.t()}

  # ── graph ─────────────────────────────────────────────────────────────────

  @doc """
  Relates two records with a typed relation.

  The kind comes from the relation-kind registry, which holds **data**, not
  schema: a kind may be registered at runtime and used immediately.
  """
  @callback relate(
              tx(),
              kind :: relation_kind(),
              from :: record_id(),
              to :: record_id(),
              attrs :: map()
            ) :: {:ok, row()} | {:error, Error.t()}

  @doc "Removes a relation between two records."
  @callback unrelate(tx(), kind :: relation_kind(), from :: record_id(), to :: record_id()) ::
              :ok | {:error, Error.t()}

  @doc """
  Reads every outgoing edge of a registered kind in the transaction's Workspace.

  Returns `{:ok, %{edges: edges}}`, where each edge has the string keys `id`,
  `kind`, `from`, `to` and `attributes` (a map). Identifiers are logical ids;
  physical edge identities and attributes are preserved, not deduplicated.
  Buffered additions and removals are visible. No endpoint is fetched: a
  missing source or target does not hide an otherwise well-formed edge, and
  a known kind with no edges returns `{:ok, %{edges: []}}`.

  Invalid identifiers produce a safe `:invalid_request` without echoing input.
  An unknown Workspace-local kind produces `:invalid_request` with details
  `%{reason: :unknown_relation_kind}`. Undecodable stored references produce
  `:protocol`. Reads are complete or return a typed error, never a successful
  truncated result. Adapters without this optional callback return `:unsupported`.
  """
  @callback outgoing_relations(
              tx(),
              kind :: relation_kind() | String.t(),
              from :: record_id()
            ) :: {:ok, %{edges: [row()]}} | {:error, Error.t()}
  @optional_callbacks outgoing_relations: 3

  @doc """
  Walks relations from a record.

  The depth is bounded by the contract, not by the caller: an Adapter must
  truncate at the bound rather than expand without limit.
  """
  @callback traverse(
              tx(),
              from :: record_id(),
              direction :: :out | :in | :both,
              depth :: pos_integer(),
              opts :: keyword()
            ) ::
              {:ok, %{nodes: [row()], edges: [row()]}} | {:error, Error.t()}

  @doc """
  How many relations each of the records has.

  A relation count is a question about **many records at once**: the CMDB's
  list page asks it of every row, and asking it per row is the N+1 the
  performance corpus names.

  The count is the number of distinct records related to the one, counted in
  both directions: a record related twice to the same neighbour has one
  relation to it and is related to it in one direction.
  """
  @callback relation_counts(tx(), record_ids :: [record_id()]) ::
              {:ok, %{optional(record_id()) => non_neg_integer()}} | {:error, Error.t()}

  @doc """
  The blast radius of a CI: the CIs that depend on it, the services they
  belong to, and the open tickets that touch them.
  """
  @callback impact(tx(), ci_id :: record_id(), depth :: pos_integer()) ::
              {:ok, %{ci: row() | nil, services: [row()], tickets: [row()]}}
              | {:error, Error.t()}

  # ── registries (data, not schema) ─────────────────────────────────────────

  @doc "Registers or updates a CI type. Additive: existing CIs are unaffected."
  @callback put_ci_type(tx(), spec :: map()) :: {:ok, row()} | {:error, Error.t()}

  @doc "Registers or updates a relation kind. Additive."
  @callback put_relation_kind(tx(), spec :: map()) :: {:ok, row()} | {:error, Error.t()}

  @doc "The registered CI types."
  @callback ci_types(tx()) :: {:ok, [row()]} | {:error, Error.t()}

  @doc "The registered relation kinds."
  @callback relation_kinds(tx()) :: {:ok, [row()]} | {:error, Error.t()}

  # ── search ────────────────────────────────────────────────────────────────

  @doc "Writes or replaces the search chunks of a subject."
  @callback upsert_chunks(tx(), subject :: record_id(), chunks :: [map()]) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Vector search.

  A hit carries the subject, the chunk index, the score, the embedding model
  and the embedding version. A model change writes a **new generation** of
  chunks rather than mutating the old ones in place.
  """
  @callback vector_search(tx(), embedding :: [float()], opts :: keyword()) ::
              {:ok, [map()]} | {:error, Error.t()}

  @doc "Full-text search. Ranking is BM25-equivalent and stable for a fixed corpus."
  @callback fulltext_search(tx(), query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, Error.t()}

  # ── time series ───────────────────────────────────────────────────────────

  @doc "Appends metric samples."
  @callback append_samples(tx(), samples :: [map()]) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc "Reads the samples of a target inside a time window, ordered by bucket."
  @callback range_samples(
              tx(),
              target :: record_id(),
              from :: DateTime.t(),
              to :: DateTime.t(),
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, Error.t()}

  # ── Audit Log and change stream ───────────────────────────────────────────

  @doc """
  Appends an Audit Log row, inside the caller's transaction.

  The row carries the host-computed chain fields. The Adapter stores them; it
  never computes a hash and never writes an Audit Log row on its own.
  """
  @callback append_audit(tx(), event :: map()) :: {:ok, seq()} | {:error, Error.t()}

  @doc """
  The change stream: outbox rows after a sequence, in ascending order, without
  gaps and without duplicates.
  """
  @callback changes(tx(), since :: seq(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, Error.t()}

  # ── identity ──────────────────────────────────────────────────────────────

  @doc """
  What this Adapter is, and what it can do.

  The declared capabilities are a promise the conformance suite checks. An
  Adapter that does not provide a capability must refuse the corresponding
  call with `code: :unsupported` — never answer it with an empty result.
  """
  @callback describe() :: %{
              adapter: atom(),
              contract_version: contract_version(),
              capabilities: [capability()],
              engine: map()
            }
end
