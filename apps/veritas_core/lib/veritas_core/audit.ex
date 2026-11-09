defmodule Veritas.Core.Audit do
  @moduledoc """
  The append-only, hash-chained Audit Log.

  Every state change, authorisation and privileged operation is recorded here.
  The Log is **host-owned and append-only** (ADR-019): there is no update path
  and no delete path. A correction is a new record that references the record
  it corrects.

  ## The chain

  Each event carries the hash of the previous event for the same Workspace,
  and its own hash covers its content *and* the previous hash.

  The chain is **signed** with HMAC-SHA-256 under a key the host holds and
  the store never sees (`Veritas.Core.Audit.ChainKey`). That is what makes
  it evidence rather than decoration: an attacker who can write to the store
  can read the chain, but cannot recompute a hash for a row they invented,
  because they do not have the key. A chain whose key sits beside the data
  it protects can be rewritten by whoever can rewrite the data.

  ## What the signature covers

  The signed payload is a **canonical encoding** of the event: its subject,
  its states, its actor, its reason, its correlation id, its `diff` — what
  changed — and its `timestamp`. The diff is included because a chain that
  proves *that* a row was not changed but not *what* it said proves very
  little; and it is encoded canonically, with its keys sorted, because a
  signature over an unordered map is a signature that changes when nothing
  did.

  The `sequence` is covered by the chain's **structure** rather than by the
  signature: the verification walks the rows in sequence order and each row's
  `prev_hash` must be the hash of the row before it, so a row cannot be
  renumbered without the walk noticing. The one number the structure cannot
  cover is the number of the **last** row — nothing follows it to contradict
  it — and that is what the anchor is for.

  ## The anchor

  A chain that is only as long as its attacker leaves it is not evidence of
  anything: deleting the last events leaves a shorter chain that still
  verifies. So the chain is anchored: the head of the chain — its hash and
  its sequence — is written outside the store, and a verification compares
  the chain against it.

  In a single-Datacenter deployment the anchor is a file the host owns, in
  the directory `VERITAS_CHAIN_ANCHOR_DIR` names. In a multi-Datacenter
  deployment it is a head digest replicated to the control plane and
  compared across Datacenters (`docs/09` §11); that replication is not
  built yet, and this module says so rather than pretending.

  ## Why the hash is computed in the host

  The hash covers a canonical serialisation of the event. The chain algorithm
  is a host concern, not an adapter concern, so the chain stays verifiable
  even if the datastore is replaced (ADR-037, `docs/32`). The Adapter stores
  the row; it never computes a hash.
  """

  require Logger

  alias Veritas.Core.Audit.{Canonical, ChainKey}
  alias Veritas.Store
  alias Veritas.Store.Error

  @type actor :: %{type: String.t(), id: String.t()}

  @type event :: %{
          subject: String.t(),
          subject_table: String.t(),
          from_state: String.t() | nil,
          to_state: String.t() | nil,
          actor: actor(),
          reason: String.t() | nil,
          correlation_id: String.t() | nil,
          diff: map() | nil,
          timestamp: DateTime.t() | nil
        }

  # The link a row carries to the row before it: its hash, and — for the
  # anchor — its sequence.
  @type link :: %{hash: String.t() | nil, sequence: non_neg_integer() | nil}

  @anchor_dir_var "VERITAS_CHAIN_ANCHOR_DIR"

  @doc """
  Appends an event to the chain, inside the caller's transaction.

  The previous event's hash is read within the same transaction, so the chain
  links to the event that is actually its predecessor, and the domain change
  and this row commit together.
  """
  @spec append(Store.tx(), Store.workspace(), event()) :: {:ok, Store.seq()} | {:error, Error.t()}
  def append(tx, workspace, event) do
    with {:ok, previous} <- previous_link(tx) do
      # The host owns the timestamp, so the signature covers the moment the
      # event was recorded rather than the moment the row was written.
      event = Map.put(event, :timestamp, DateTime.utc_now())

      with {:ok, signature} <- sign_chain(previous, event) do
        row =
          %{
            "id" => identifier(),
            "workspace" => workspace,
            "subject" => event.subject,
            "subject_table" => event.subject_table,
            "from_state" => event.from_state,
            "to_state" => event.to_state,
            "actor_type" => event.actor.type,
            "actor_id" => event.actor.id,
            "timestamp" => event.timestamp,
            "reason" => event.reason,
            "correlation_id" => event.correlation_id,
            "prev_hash" => previous.hash,
            "hash" => signature,
            "diff" => without_nils(event.diff)
          }

        Store.append_audit(tx, row)
      end
    end
  end

  @doc """
  The link to the most recent event in the Workspace, or an empty link when
  the chain is empty.

  Ordering is by the Workspace sequence, never by wall-clock time: two events
  written in the same millisecond still have a defined order.
  """
  @spec previous_link(Store.tx()) :: {:ok, link()} | {:error, Error.t()}
  def previous_link(tx) do
    filter = %{where: [], order_by: [{:sequence, :desc}], limit: 1}

    case Store.list(tx, :audit_event, filter) do
      {:ok, [%{"hash" => hash, "sequence" => sequence} | _]} ->
        {:ok, %{hash: hash, sequence: sequence}}

      {:ok, _rows} ->
        {:ok, %{hash: nil, sequence: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The hash of the most recent event in the Workspace, or nil when the chain
  is empty.
  """
  @spec previous_hash(Store.tx()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def previous_hash(tx) do
    with {:ok, link} <- previous_link(tx), do: {:ok, link.hash}
  end

  @doc """
  An event's signature.

  The chain algorithm is host-owned so that it stays verifiable across a
  datastore substitution. The signature is an HMAC under the host's chain
  key, and it is prefixed with the id of the key that made it, so that a
  row says which key signed it and a key that is dropped too early is a
  loud failure rather than a silent one.
  """
  @spec sign(link(), event()) :: {:ok, String.t()} | {:error, term()}
  def sign(previous, event), do: ChainKey.sign(payload(previous, event))

  # The chain's own last row says which key the chain is under, and the row
  # that follows is signed under **that** key.
  #
  # A Workspace whose chain is under a retired key keeps that key until the
  # operator adopts the next one. The retired key stays in the ring — that
  # is what keeping it is for — so the chain can be signed under it. What it
  # must not do is mix the two: an event appended under the new key would
  # make the chain a mixture that the migration refuses to re-sign, and a
  # Workspace that cannot be migrated is a Workspace that is stuck.
  #
  # A chain with no key yet is the upgrade, and is signed with the ring's
  # current key, as it always was.
  defp sign_chain(previous, event) do
    case ChainKey.key_id(previous.hash) do
      {:keyed, id} -> ChainKey.sign(payload(previous, event), id)
      {:unsigned, nil} -> sign(previous, event)
    end
  end

  @doc """
  An event's signature, or a raised error when the chain cannot be signed.

  The migration uses this: a chain that cannot be signed is a migration that
  must not run.
  """
  @spec hash(link(), event()) :: String.t()
  def hash(previous, event) do
    case sign(previous, event) do
      {:ok, signature} -> signature
      {:error, reason} -> raise ArgumentError, "the audit chain could not be signed: #{reason}"
    end
  end

  @doc """
  The canonical payload an event's signature covers.

  Every field of the event is in it, the `diff` among them: a chain that
  proves a row was not changed but not what it said proves very little. The
  encoding is canonical, so the same event encodes the same way in every
  process, on every BEAM, and whether it was just written or read back from
  the store.
  """
  @spec payload(link(), event()) :: binary()
  def payload(previous, event) do
    Canonical.encode(%{
      "actor_id" => event.actor.id,
      "actor_type" => event.actor.type,
      "correlation_id" => event.correlation_id,
      "diff" => without_nils(event.diff),
      "from_state" => event.from_state,
      "prev_hash" => link(previous).hash,
      "reason" => event.reason,
      "subject" => event.subject,
      "subject_table" => event.subject_table,
      "timestamp" => event.timestamp,
      "to_state" => event.to_state
    })
  end

  # A diff is signed and stored without the values that are not set.
  #
  # The store drops a null field from the flexible object it writes, and the
  # canonical encoding tells an absent key from a key whose value is null. So a
  # diff that carried a null would sign a value the store cannot reproduce,
  # and the row would not verify when it was read back — a chain that reports a
  # break nobody caused is a chain nobody trusts. A value that is not set is
  # simply not in the diff.
  #
  # This is the structural guarantee, and it is here rather than in each writer
  # because the Log is reachable from outside this codebase: a writer that
  # reaches it through the public API would otherwise have to know the rule.
  # The writers that strip their own diffs do the same thing earlier, where the
  # diff is built.
  #
  # The removal is **deep**, because the store drops a null field from a nested
  # object too: a null inside a nested map breaks the row exactly as a null at
  # the top level does. A null inside a **list** is left alone — the store
  # keeps a null in an array, so it reads back as it was written.
  #
  # A struct is left alone as well: the canonical encoding has its own rule for
  # the ones it knows, and a diff that carried a struct would be a different
  # question.
  @spec without_nils(term()) :: term()
  defp without_nils(nil), do: nil
  defp without_nils(value) when is_struct(value), do: value

  defp without_nils(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new(fn {key, item} -> {key, without_nils(item)} end)
  end

  defp without_nils(value) when is_list(value), do: Enum.map(value, &without_nils/1)
  defp without_nils(value), do: value

  # A link, whether it is given as one or as the hash it carries.
  defp link(%{hash: hash}), do: %{hash: hash, sequence: nil}
  defp link(hash) when is_binary(hash), do: %{hash: hash, sequence: nil}
  defp link(nil), do: %{hash: nil, sequence: nil}

  @doc """
  Verifies the chain for a Workspace.

  Returns `{:ok, :intact}` when every event is signed under a key the host
  holds, every event links correctly to its predecessor, and the chain
  agrees with the anchor when there is one.

  When it does not, the answer says **which** thing is wrong, because the
  two are not the same claim:

    * `{:ok, {:broken_at, index}}` — an event was **changed**. It is signed
      under a key the host holds, and the signature is not the one its
      content produces. That is tampering, and it says so.
    * `{:error, reason}` — the chain **cannot be checked**. An event is
      signed under a key the host does not hold, or was signed before the
      chain was keyed. Nothing has been proven about the data: the event may
      be perfectly genuine, and the host simply cannot check it. That is a
      finding about the configuration, and it is not reported as tampering.

  This is the check the partition harness and the support bundle rely on.
  """
  @spec verify(Store.workspace()) ::
          {:ok, :intact}
          | {:ok, {:broken_at, non_neg_integer()}}
          | {:error, Error.t()}
  def verify(workspace) do
    Store.transaction(workspace, fn tx ->
      filter = %{where: [], order_by: [{:sequence, :asc}]}

      case Store.list(tx, :audit_event, filter) do
        {:ok, rows} ->
          verify_rows(workspace, rows)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Verifies normalized Audit Log rows supplied by the Workspace's adapter.

  Args:
    workspace (Store.workspace()): Workspace whose external anchor is checked.
    rows ([map()]): Complete audit history in ascending sequence order, using
      the same normalized values returned by the Store read path.

  Returns:
    The same intact, broken-at or error verdict as `verify/1`, without reading
    through the configured Store adapter or rewriting history.
  """
  @spec verify_rows(Store.workspace(), [map()]) ::
          {:ok, :intact}
          | {:ok, {:broken_at, non_neg_integer()}}
          | {:error, Error.t()}
  def verify_rows(workspace, rows) do
    case first_break(rows, %{hash: nil, sequence: nil}, 0) do
      nil -> check_anchor(workspace, rows)
      {index, :tampered} -> {:ok, {:broken_at, index}}
      {index, :unverifiable} -> {:error, unverifiable_error(rows, index)}
    end
  end

  @doc """
  Whether a Workspace's chain is anchored, and therefore whether a
  truncation of it would be detected.

  A chain with no anchor is still signed — an attacker cannot forge a row —
  but a chain with no anchor can be *shortened* without the verification
  noticing.
  """
  @spec anchored?(Store.workspace()) :: boolean()
  def anchored?(workspace) do
    match?({:ok, _anchor}, read_anchor(workspace))
  end

  @doc """
  Writes the head of a Workspace's chain to the anchor.

  The anchor is the chain's head — its hash and its sequence — held outside
  the store. It is what makes the chain's **length** evidence: a chain that
  has been cut short no longer reaches the head that was anchored.

  The anchor is only as good as where it is kept. A file the operator keeps
  beside the store defends against an attacker who reached the store over
  the network and nothing more; the control plane the corpus specifies
  defends against more, and is not built yet.
  """
  @spec checkpoint(Store.workspace()) ::
          {:ok, %{head: String.t(), sequence: non_neg_integer(), anchored: boolean()}}
          | {:error, Error.t()}
  def checkpoint(workspace) do
    with {:ok, rows} <-
           Store.transaction(workspace, fn tx ->
             Store.list(tx, :audit_event, %{where: [], order_by: [{:sequence, :desc}], limit: 1})
           end) do
      case rows do
        [%{"hash" => head, "sequence" => sequence} | _] ->
          anchor = %{
            "workspace" => workspace,
            "head" => head,
            "sequence" => sequence,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          case write_anchor(workspace, anchor) do
            :ok -> {:ok, %{head: head, sequence: sequence, anchored: true}}
            {:error, reason} -> {:error, reason}
          end

        _empty ->
          {:error,
           Error.new(:invalid_request, "the workspace has no chain to anchor", details: %{})}
      end
    end
  end

  @doc """
  Establishes the chain over the Audit Log rows a migration adopts.

  The rows are the ones the store holds, as it returned them. The chain is
  rebuilt from the links the rows carry: the root is the row that names no
  predecessor, and every other row follows the row its `prev_hash` names.
  Where two rows name the same predecessor — two events written from the
  same tip — the earlier one comes first, and the later one is re-linked to
  it.

  A row that carries **no key** — a row signed before the chain was keyed —
  joins the chain here, with the signature this module's algorithm gives it.
  That is the upgrade path: a chain signed with the old algorithm has no
  evidence in it, and the migration is the one moment that can give it some.

  Two conditions stop the reconciliation rather than paper over it:

    * a row whose signature does not match its own content has been tampered
      with, and a migration that rewrote it would hide that;
    * a row whose predecessor names a row the store does not hold means a row
      is missing, and re-linking the rest would hide the gap.

  A chain that is **half keyed and half not** is refused outright. It is
  either an upgrade that was interrupted, or something was stripped, and a
  migration that re-signed the whole of it would hide which.

  In both cases the chain is left exactly as it was found and the reason is
  returned, and the Log's own verification reports the break.

  This is the host's chain, and the host's chain algorithm: the Adapter asks
  for it through `Veritas.Store.Chain` and writes what comes back.
  """
  @spec reconcile_chain([map()]) :: {:ok, [map()]} | {:error, String.t()}
  def reconcile_chain(rows) do
    with :ok <- guard_uniform(rows),
         :ok <- guard_consistent(rows),
         :ok <- guard_resolvable(rows) do
      if legacy_chain?(rows) and not ChainKey.persistent?() do
        # There is no key here that another process can hold, so any
        # signature written now would be a signature nobody could ever check
        # — and the rows it was written over would be gone. The rows stay as
        # they are, with the legacy signatures they can still be checked
        # against, and a later migration under a real key can adopt them.
        Logger.warning(
          "[veritas.audit] the chain of this workspace was left as it was found: no persistent " <>
            "chain key is configured, so its legacy rows keep their legacy signatures. Set " <>
            "VERITAS_CHAIN_KEY or VERITAS_CHAIN_KEY_FILE and migrate again to sign them."
        )

        {:ok, []}
      else
        with :ok <- guard_signing_key(rows), do: assign_chain(chain_order(rows))
      end
    end
  end

  # The flag that says a re-sign was asked for by the operator's audited
  # action rather than by a migration. It is set for the duration of the
  # migration the rotation runs, and it is the only way a chain's signing
  # key changes.
  @resign_flag :veritas_chain_resign

  # A migration may not change the signing key of a chain. The chain's
  # signing key changes only through the operator's audited action — the
  # rotation — because a migration is not an operator action and the Audit
  # Log records operator actions.
  #
  # The cost of that rule: a Workspace whose chain is signed under a retired
  # key **fails its migration** rather than being silently re-signed, and
  # the operator has to run the rotation for it first. A migration that
  # quietly re-signed would move a chain's signing key without leaving a
  # trace of it anywhere.
  defp guard_signing_key(rows) do
    if Process.get(@resign_flag) do
      :ok
    else
      case rows |> Enum.map(&ChainKey.key_id(&1["hash"])) |> Enum.uniq() do
        [{:keyed, id}] ->
          if id == ChainKey.current_id() do
            :ok
          else
            {:error,
             "the chain of this workspace is signed under #{inspect(id)} and the ring signs " <>
               "with #{inspect(ChainKey.current_id())}; rotate and adopt the key first " <>
               "(`mix veritas.cli chain-key rotate`, then `mix veritas.cli chain-key adopt " <>
               "--workspace <workspace>`)"}
          end

        _other ->
          # A chain that is not signed yet has no signing key to change:
          # signing it for the first time is the upgrade, not a key change.
          :ok
      end
    end
  end

  @doc """
  Re-signs a Workspace's chain under the ring's current key and records the
  act **in that chain**.

  A re-sign is a **host operation**: the chain fields of every row are
  rewritten under the new key. The event that says so is written into the
  same chain, and it is what makes the re-sign *visible* — a re-sign changes
  the chain's bytes and its head, and the key id travelling with every
  signature is what tells a verifier that the chain was re-signed rather
  than only extended.

  The event says which key id the chain was signed under before and which it
  is signed under now. It never says anything about the keys themselves: a
  secret in the Audit Log would be a secret in the thing the Audit Log
  exists to protect.

  The re-sign itself goes through the **migration**, so that the chain is
  re-chained by the host's own chain algorithm and not by a second
  implementation of it.
  """
  @spec resign_chain(Store.workspace(), keyword()) :: {:ok, map()} | {:error, term()}
  def resign_chain(workspace, opts \\ []) do
    from = Keyword.get(opts, :from) || chain_key_id(workspace)
    to = Keyword.get(opts, :to) || ChainKey.current_id()
    actor = Keyword.get(opts, :actor, "operator")

    # The re-sign is the operator's action, and it is the only one allowed
    # to change a chain's signing key. The flag says so for the duration of
    # the migration it runs.
    Process.put(@resign_flag, true)

    try do
      with :ok <- re_sign(workspace) do
        event = %{
          subject: workspace,
          subject_table: "audit_chain",
          from_state: from,
          to_state: to,
          actor: %{type: "operator", id: actor},
          reason:
            "the audit chain key was rotated and this chain was re-signed under the new key",
          correlation_id: opts[:correlation_id],
          diff: %{
            "workspace" => workspace,
            "old_key_id" => from,
            "new_key_id" => to
          }
        }

        Store.transaction(workspace, fn tx -> append(tx, workspace, event) end)
      end
    after
      Process.delete(@resign_flag)
    end
  end

  # The key id the chain is signed under today, or nil when it is not signed.
  defp chain_key_id(workspace) do
    Store.transaction(workspace, fn tx ->
      case Store.list(tx, :audit_event, %{where: [], order_by: [{:sequence, :asc}], limit: 1}) do
        {:ok, [%{"hash" => hash} | _]} ->
          case ChainKey.key_id(hash) do
            {:keyed, id} -> id
            {:unsigned, nil} -> nil
          end

        {:ok, _empty} ->
          nil

        {:error, reason} ->
          reason
      end
    end)
  end

  # The re-sign itself: the same path the migration takes. A migration that
  # **refused** the chain is not a re-sign, and saying otherwise would
  # record an adoption that did not happen.
  defp re_sign(workspace) do
    case Store.adapter().migrate(workspace) do
      :ok -> :ok
      {:ok, :refused} -> {:error, "the chain was left as it was found; it was not re-signed"}
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A chain of rows that were signed before the chain was keyed.
  defp legacy_chain?([]), do: false

  defp legacy_chain?(rows) do
    Enum.all?(rows, fn row ->
      match?({:unsigned, nil}, ChainKey.key_id(row["hash"]))
    end)
  end

  # A chain is either signed with a key or it is not. A chain that is both
  # is refused: it is either an interrupted upgrade or something that was
  # tampered with, and re-signing it would hide which.
  defp guard_uniform([]), do: :ok

  defp guard_uniform(rows) do
    kinds = rows |> Enum.map(&ChainKey.key_id(&1["hash"])) |> Enum.uniq()

    case kinds do
      [_one] ->
        :ok

      _mixed ->
        {:error, "the audit chain is partly signed and partly not; refusing to re-sign it"}
    end
  end

  # A row's signature must match the one its own content and its own
  # predecessor produce. A row with no key is judged against the algorithm
  # that signed it, because a migration has to be able to tell a legacy row
  # from a tampered one.
  #
  # The three outcomes are kept apart, because they are three different
  # things: a row that agrees, a row that was changed, and a row the host
  # cannot check. A migration must not re-sign the last two — a
  # re-signature would make them look like the first.
  defp guard_consistent(rows) do
    # `find_value/2`, not `find/2`: the answer is what the check *says* about
    # the row, not the row itself.
    case Enum.find_value(rows, &contradicts_itself?/1) do
      nil ->
        :ok

      {row, :tampered} ->
        {:error, "the audit row #{row["id"]} does not match its own hash"}

      {row, :unverifiable} ->
        {:error,
         "the audit row #{row["id"]} is signed with a key this host does not hold, " <>
           "so it cannot be checked and must not be re-signed"}
    end
  end

  defp contradicts_itself?(row) do
    case row["hash"] do
      nil ->
        false

      "" ->
        false

      stored ->
        case ChainKey.key_id(stored) do
          {:keyed, _id} ->
            case ChainKey.verdict(stored, payload(link(row["prev_hash"]), event(row))) do
              :matches -> false
              :tampered -> {row, :tampered}
              :unverifiable -> {row, :unverifiable}
            end

          {:unsigned, nil} ->
            if stored == ChainKey.legacy_mac(legacy_payload(row)),
              do: false,
              else: {row, :tampered}
        end
    end
  end

  # The payload the chain used before it was keyed. It is here so that a
  # legacy row can be told from a tampered one, and so that an upgrade can
  # recognise what it is replacing.
  defp legacy_payload(row) do
    [
      row["prev_hash"] || "",
      row["subject"] || "",
      row["subject_table"] || "",
      row["from_state"] || "",
      row["to_state"] || "",
      row["actor_type"] || "",
      row["actor_id"] || "",
      row["reason"] || "",
      row["correlation_id"] || ""
    ]
    |> Enum.join("|")
  end

  # Every predecessor a row names must be a row the store holds. A link that
  # resolves to nothing means a row is missing.
  defp guard_resolvable(rows) do
    known = MapSet.new(rows, fn row -> row["hash"] end)

    case Enum.find(rows, fn row ->
           case row["prev_hash"] do
             nil -> false
             "" -> false
             previous -> not MapSet.member?(known, previous)
           end
         end) do
      nil -> :ok
      row -> {:error, "the audit row #{row["id"]} names a predecessor the store does not hold"}
    end
  end

  # The chain's order: the root first, then the row that names it, and so on.
  # Where two rows name the same predecessor, the earlier one comes first.
  defp chain_order(rows) do
    children = Enum.group_by(rows, fn row -> row["prev_hash"] end, fn row -> row end)

    roots =
      rows
      |> Enum.filter(fn row -> blank?(row["prev_hash"]) end)
      |> Enum.sort_by(&timestamp/1)

    walk(roots, children, MapSet.new(), [])
  end

  defp walk([], _children, _seen, ordered), do: Enum.reverse(ordered)

  defp walk([row | rest], children, seen, ordered) do
    if MapSet.member?(seen, row["id"]) do
      walk(rest, children, seen, ordered)
    else
      kids =
        children
        |> Map.get(row["hash"], [])
        |> Enum.sort_by(&timestamp/1)

      walk(kids ++ rest, children, MapSet.put(seen, row["id"]), [row | ordered])
    end
  end

  # The chain each row belongs to: the predecessor's hash, and the signature
  # this module's algorithm gives the row.
  defp assign_chain(rows) do
    rows
    |> Enum.reduce_while({:ok, [], %{hash: nil, sequence: nil}}, fn row, {:ok, acc, previous} ->
      case sign(previous, event(row)) do
        {:ok, signature} ->
          assignment = %{
            id: row["id"],
            prev_hash: previous.hash,
            hash: signature
          }

          {:cont, {:ok, [assignment | acc], %{hash: signature, sequence: row["sequence"]}}}

        {:error, reason} ->
          {:halt, {:error, "the audit chain could not be signed: #{reason}"}}
      end
    end)
    |> case do
      {:ok, assignments, _previous} -> {:ok, Enum.reverse(assignments)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The event a row carries, in the shape the signature takes it.

  Public because the payload of a row is a function of the row: a reader
  that wants to know what a row would have to say to be signed a particular
  way needs the same mapping the signature uses.
  """
  @spec event(map()) :: event()
  def event(row) do
    %{
      subject: row["subject"],
      subject_table: row["subject_table"],
      from_state: row["from_state"],
      to_state: row["to_state"],
      actor: %{type: row["actor_type"], id: row["actor_id"]},
      reason: row["reason"],
      correlation_id: row["correlation_id"],
      diff: row["diff"],
      timestamp: row["timestamp"]
    }
  end

  defp timestamp(row), do: row["timestamp"] || ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false

  @doc """
  The Audit Log rows of a Workspace, oldest first.
  """
  @spec entries(Store.workspace()) :: {:ok, [map()]} | {:error, Error.t()}
  def entries(workspace) do
    Store.transaction(workspace, fn tx ->
      Store.list(tx, :audit_event, %{where: [], order_by: [{:sequence, :asc}]})
    end)
  end

  # The first event that does not hold up, and why. The verdict is the
  # difference between "somebody changed this" and "this cannot be checked".
  defp first_break([], _previous, _index), do: nil

  defp first_break([row | rest], previous, index) do
    event = event(row)
    verdict = ChainKey.verdict(row["hash"], payload(previous, event))
    linked? = row["prev_hash"] == previous.hash

    if linked? and verdict == :matches do
      first_break(rest, %{hash: row["hash"], sequence: row["sequence"]}, index + 1)
    else
      # A link that does not hold is tampering whatever the signature says.
      {index, if(linked?, do: verdict, else: :tampered)}
    end
  end

  # The chain cannot be checked. The message says what is missing, so that
  # the operator is told to give the host a key rather than to go looking for
  # somebody who tampered with the Log.
  defp unverifiable_error(rows, index) do
    row = Enum.at(rows, index) || %{}

    detail =
      case ChainKey.key_id(row["hash"]) do
        {:keyed, id} ->
          "the event at #{index} is signed with the key #{inspect(id)}, which this host does not hold"

        {:unsigned, nil} ->
          "the event at #{index} was signed before the chain was keyed, and has no evidence in it"
      end

    Error.new(
      :invalid_request,
      "the Audit Log cannot be verified: " <> detail,
      details: %{workspace: row["workspace"], index: index}
    )
  end

  # ── the anchor ─────────────────────────────────────────────────────────────

  # A chain that is only as long as its attacker leaves it is not evidence.
  # The anchor is the chain's head, held outside the store; a chain that
  # does not reach the head that was anchored has been cut short.
  #
  # Only a chain that was **never** anchored reads as intact. An anchor that
  # cannot be read, or that is gone although the Workspace was checkpointed,
  # is a finding: the evidence of the chain's length is missing, and saying
  # "intact" would be a claim the host cannot back.
  defp check_anchor(workspace, rows) do
    case read_anchor(workspace) do
      {:ok, anchor} ->
        compare_anchor(anchor, rows)

      {:error, :no_anchor} ->
        # This deployment has no anchor, or this Workspace was never
        # checkpointed. The chain is still signed — an attacker cannot forge
        # a row — but it can be shortened without the verification noticing,
        # and `anchored?/1` says which case this is.
        {:ok, :intact}

      {:error, :unreadable_anchor} ->
        anchor_error(workspace, "the anchor of this workspace cannot be read")

      {:error, :missing_anchor} ->
        anchor_error(workspace, "the anchor of this workspace is gone")

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The anchor is not evidence of anything, so the chain cannot be checked
  # against it. That is a finding about the host's own state, and it says
  # what is missing rather than that the data was changed.
  defp anchor_error(workspace, message) do
    {:error,
     Error.new(
       :internal,
       message <> ", so the length of the chain cannot be checked",
       details: %{workspace: workspace}
     )}
  end

  # The anchor names a **sequence** and the hash that was at it. The chain
  # must still carry that sequence, with that hash: a chain that has been cut
  # short does not, and neither does one whose rows have been renumbered.
  defp compare_anchor(anchor, rows) do
    sequence = anchor["sequence"]
    head = anchor["head"]

    case Enum.find_index(rows, &(&1["sequence"] == sequence)) do
      nil ->
        # The sequence the anchor named is not in the chain.
        {:ok, {:broken_at, length(rows)}}

      index ->
        case Enum.at(rows, index) do
          %{"hash" => ^head} -> {:ok, :intact}
          _row -> {:ok, {:broken_at, index}}
        end
    end
  end

  defp read_anchor(workspace) do
    case anchor_path(workspace) do
      nil ->
        {:error, :no_anchor}

      path ->
        case File.read(path) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, %{"head" => head, "sequence" => sequence}} ->
                {:ok, %{"head" => head, "sequence" => sequence}}

              _other ->
                {:error, :unreadable_anchor}
            end

          {:error, :enoent} ->
            # The anchor file is gone. That is only benign if this Workspace
            # was never checkpointed: a Workspace that **was** checkpointed
            # and whose anchor is gone cannot say whether its chain was cut
            # short, and the evidence that it was not is gone with it.
            if checkpointed?(workspace) do
              {:error, :missing_anchor}
            else
              {:error, :no_anchor}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Whether this Workspace was checkpointed at all.
  #
  # The receipt is what tells a Workspace that was never anchored apart from
  # one whose anchor was deleted: without it, a missing anchor file reads as
  # "never checkpointed", and a chain whose evidence of its length was
  # removed would report itself as intact.
  defp checkpointed?(workspace) do
    case receipt_path(workspace) do
      nil -> false
      path -> File.exists?(path)
    end
  end

  defp write_anchor(workspace, anchor) do
    case anchor_path(workspace) do
      nil ->
        {:error, Error.new(:invalid_request, "no anchor directory is configured", details: %{})}

      path ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, Jason.encode!(anchor)),
             # The receipt is written **after** the anchor: a receipt without
             # an anchor would report a chain that was never anchored as one
             # whose anchor was deleted, and an anchor without a receipt only
             # means that a later deletion of it would not be noticed.
             :ok <- write_receipt(workspace, anchor) do
          :ok
        else
          {:error, reason} ->
            {:error,
             Error.new(:internal, "the anchor could not be written", details: %{reason: reason})}
        end
    end
  end

  # The receipt of a checkpoint: the fact that this Workspace **was**
  # anchored.
  #
  # It is what tells a Workspace that was never checkpointed apart from one
  # whose anchor has been deleted, so that a chain whose evidence of its
  # length is missing says so instead of reporting itself as intact.
  defp write_receipt(workspace, anchor) do
    case receipt_path(workspace) do
      nil ->
        {:error, Error.new(:invalid_request, "no anchor directory is configured", details: %{})}

      path ->
        File.write(
          path,
          Jason.encode!(%{"workspace" => workspace, "sequence" => anchor["sequence"]})
        )
    end
  end

  defp anchor_path(workspace) do
    case System.get_env(@anchor_dir_var) do
      directory when is_binary(directory) and directory != "" ->
        Path.join(directory, workspace <> ".anchor.json")

      _unset ->
        nil
    end
  end

  # The receipt of a checkpoint, beside the anchor it belongs to.
  defp receipt_path(workspace) do
    case System.get_env(@anchor_dir_var) do
      directory when is_binary(directory) and directory != "" ->
        Path.join(directory, workspace <> ".anchored")

      _unset ->
        nil
    end
  end

  # Record ids must be alphanumeric and underscore only: a '-' is lexed by
  # SurrealQL as a duration suffix and fails to parse.
  defp identifier, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
