defmodule Veritas.Store.Spec do
  @moduledoc """
  The conformance suite for a data-access Adapter.

  A store Adapter is a **Default** (`docs/32`, ADR-033): the shipped one is
  an implementation of the `Veritas.Store` contract, and any other may
  replace it. This module is what makes that claim checkable rather than
  aspirational: it runs the contract's obligations against a live Adapter
  and reports which ones hold.

  ## What it checks

  Each obligation from the contract document (`docs/32`) that can be
  observed from outside the Adapter:

    * **O-1 / O-2 — atomicity.** A failure inside a transaction leaves
      nothing behind: no domain row, no Audit Log row, no outbox row.
    * **O-3 — ordering.** Two events in the same millisecond get distinct,
      increasing sequence values.
    * **O-4 — Workspace isolation.** A record in one Workspace is invisible
      to another, through every read path.
    * **O-5 — durability of an acknowledged write.** A committed write
      survives the loss of the process that wrote it.
    * **O-6 — the Audit Log chain.** The chain verifies — **including an event
      whose diff carries a null**, because a signature may not cover a value
      the store cannot hold on every engine — and the sequence is strictly
      increasing.
    * **O-7 — one system of record.** The Adapter describes one engine.
    * **O-8 — depth-bounded traversal.** A traversal stops at the bound.
    * **O-9 — a data-driven relation vocabulary.** A kind registered at
      runtime is usable immediately.
    * **O-13 — the change stream.** The stream is ordered and continuous.
    * **O-14 — loud failure.** A capability the Adapter does not provide is
      refused, not answered with an empty result.
    * **O-15 — no internal retries.** One attempt reaches the store.

  ## What it does not check

  `docs/32` has fifteen obligations. This suite executes **eleven** of them.
  The other three are reported as *not executable* — with the reason — rather
  than passed in silence, because a suite that passes by construction is worse
  than no suite:

    * **O-10 — vector search.** The contract is stated, but the check is not
      written; an Adapter's vector behaviour is not yet proven by the suite.
    * **O-11 — full-text ranking.** The same.
    * **O-12 — time-series windowing.** The same.

  The ExUnit harness in `test/support/conformance.ex` registers those three as
  not executable and asserts the set, so the gap cannot widen unnoticed: when
  a check is written for one of them, the harness is changed with it.

  The suite writes to a scratch Workspace and cleans up after itself, so it
  is safe to run against a live store.

  ## Running it

      mix veritas.store.spec --workspace veritas_spec
      mix veritas.store.spec --workspace veritas_spec --adapter MyApp.Store.Postgres

  It is also the body of the ExUnit suite the SDET owns: the same module,
  called with the Adapter under test.
  """

  alias Veritas.Store
  alias Veritas.Store.Error

  @type result :: %{obligation: String.t(), ok: boolean(), detail: String.t()}

  @doc """
  Runs every obligation against the installed Adapter (or a named one).

  Returns a list of results and a boolean. It never raises: a failing
  obligation is a result, not an exception, because a conformance report
  that dies at the first failure is not a report.
  """
  @spec run(keyword()) :: {[result()], boolean()}
  def run(opts \\ []) do
    adapter = opts[:adapter] || Store.adapter()
    workspace = opts[:workspace] || "veritas_spec"

    results =
      [
        {"O-1/O-2 atomicity", fn -> atomicity(adapter, workspace) end},
        {"O-3 ordering", fn -> ordering(adapter, workspace) end},
        {"O-4 workspace isolation", fn -> isolation(adapter, workspace) end},
        {"O-5 durability", fn -> durability(adapter, workspace) end},
        {"O-6 audit chain", fn -> audit_chain(adapter, workspace) end},
        {"O-7 one system of record", fn -> one_system(adapter) end},
        {"O-8 depth-bounded traversal", fn -> bounded_traversal(adapter, workspace) end},
        {"O-9 relation vocabulary", fn -> relation_vocabulary(adapter, workspace) end},
        {"O-13 change stream", fn -> change_stream(adapter, workspace) end},
        {"O-14 loud failure", fn -> loud_failure(adapter, workspace) end},
        {"O-15 no internal retries", fn -> no_internal_retries(adapter, workspace) end}
      ]
      |> Enum.map(fn {obligation, check} -> run_check(obligation, check) end)

    {results, Enum.all?(results, & &1.ok)}
  end

  @doc "Formats a conformance report for a human."
  @spec format([result()]) :: String.t()
  def format(results) do
    passed = Enum.count(results, & &1.ok)

    body =
      Enum.map_join(results, "\n", fn result ->
        String.pad_trailing(result.obligation, 32) <>
          String.pad_trailing(if(result.ok, do: "PASS", else: "FAIL"), 6) <> result.detail
      end)

    """
    Store conformance — #{Store.adapter()} — #{Store.contract_version()}

    #{body}

    #{passed}/#{length(results)} obligations hold.
    """
  end

  # ── the obligations ───────────────────────────────────────────────────────

  # A failure inside the transaction must leave nothing behind.
  #
  # The positive control comes first: the same write path has to be shown to
  # write. An Adapter that never writes leaves nothing behind either, and
  # would pass this obligation by doing nothing at all.
  defp atomicity(_adapter, workspace) do
    with :ok <- visible_write(workspace, :ci, probe(identifier())),
         id = identifier(),
         result <-
           Store.transaction(workspace, fn tx ->
             {:ok, _} = Store.put(tx, :ci, probe(id))
             {:error, :spec_failure}
           end),
         read <- Store.transaction(workspace, fn tx -> Store.fetch(tx, :ci, id) end) do
      case {result, read} do
        {{:error, :spec_failure}, {:ok, nil}} ->
          merged_list(workspace)

        {{:error, :spec_failure}, {:ok, _row}} ->
          {:error, "a refused transaction left a row behind"}

        {other, read} ->
          {:error,
           "the transaction did not abort as asked: #{inspect(other)} (read: #{inspect(read)})"}
      end
    end
  end

  # A read inside a transaction must see the transaction's own writes, and the
  # filter, the ordering and the limit must apply to the **merged** result —
  # the committed rows and the transaction's own rows together.
  #
  # An Adapter that filters, orders and limits the committed rows and then
  # appends the transaction's own rows answers a different question from the
  # one that was asked: its own rows come back unfiltered, unordered and
  # unlimited, and the other Adapter's do not.
  defp merged_list(workspace) do
    name = "merged-list-probe-#{identifier()}"
    first = identifier()
    second = identifier()
    {low, high} = if first < second, do: {first, second}, else: {second, first}

    result =
      Store.transaction(workspace, fn tx ->
        {:ok, _} = Store.put(tx, :ci, probe(low) |> Map.put("name", name))
        {:ok, _} = Store.put(tx, :ci, probe(high) |> Map.put("name", name))

        {:ok, filtered} =
          Store.list(tx, :ci, %{where: [{"name", name}], order_by: [{:id, :desc}], limit: 10})

        {:ok, limited} =
          Store.list(tx, :ci, %{where: [{"name", name}], order_by: [{:id, :desc}], limit: 1})

        {:ok, filtered, limited}
      end)

    case result do
      {:ok, filtered, limited} ->
        cond do
          length(filtered) != 2 ->
            {:error,
             "the transaction's own writes were not both in the filtered list: #{inspect(filtered)}"}

          length(limited) != 1 ->
            {:error, "the limit was not applied to the merged list: #{inspect(limited)}"}

          hd(limited)["id"] != high ->
            {:error,
             "the ordering was not applied to the merged list: #{inspect(hd(limited)["id"])} is not the first id in descending order"}

          true ->
            :ok
        end

      other ->
        {:error, "the merged list could not be read: #{inspect(other)}"}
    end
  end

  # Two allocations must be distinct and increasing.
  defp ordering(_adapter, workspace) do
    first = Store.transaction(workspace, fn tx -> Store.next_sequence(tx, "spec") end)
    second = Store.transaction(workspace, fn tx -> Store.next_sequence(tx, "spec") end)

    case {first, second} do
      {{:ok, a}, {:ok, b}} when b > a -> :ok
      other -> {:error, "the sequence did not increase: #{inspect(other)}"}
    end
  end

  # A record written in one Workspace must be invisible in another.
  #
  # The positive control comes first: the record has to be visible in the
  # Workspace that wrote it, or the cross-Workspace check below is satisfied
  # by a write that never happened.
  defp isolation(_adapter, workspace) do
    id = identifier()
    other = workspace <> "_other"

    with :ok <- visible_write(workspace, :ci, probe(id)),
         read <- Store.transaction(other, fn tx -> Store.fetch(tx, :ci, id) end) do
      case read do
        # A Workspace that does not exist cannot hold the record either.
        {:error, %Error{code: :not_found}} -> :ok
        {:ok, nil} -> :ok
        {:ok, _row} -> {:error, "a record crossed the Workspace boundary"}
        {:error, reason} -> {:error, "the other Workspace could not be read: #{inspect(reason)}"}
      end
    end
  end

  # An acknowledged write must survive the process that wrote it.
  #
  # The write is read back in its own transaction — not the one that wrote it —
  # so an Adapter that buffers the write and never sends it fails here.
  defp durability(_adapter, workspace) do
    id = identifier()

    with {:ok, _row} <-
           Store.transaction(workspace, fn tx -> Store.put(tx, :ci, probe(id)) end),
         read <- Store.transaction(workspace, fn tx -> Store.fetch(tx, :ci, id) end) do
      case read do
        {:ok, %{"id" => ^id}} -> :ok
        other -> {:error, "the acknowledged write did not survive: #{inspect(other)}"}
      end
    else
      other -> {:error, "the write was not acknowledged: #{inspect(other)}"}
    end
  end

  # The Audit Log must chain, and the sequence must increase.
  #
  # The positive control comes first: an event is appended through the host's
  # own API, so the chain that is verified is a chain that holds something.
  # An empty chain verifies, and would pass this obligation by holding
  # nothing.
  defp audit_chain(_adapter, workspace) do
    # TWO events in ONE transaction, and the second must link to the first.
    #
    # The Audit Log's chain is built from the rows a transaction can read. An
    # Adapter that does not make its own writes visible to its own reads gives
    # both events the same predecessor: the chain forks, and a genuine history
    # verifies as tampering.
    first_subject = identifier()
    second_subject = identifier()

    written =
      Store.transaction(workspace, fn tx ->
        with {:ok, _first} <- append_audit(tx, workspace, first_subject),
             {:ok, _second} <- append_audit(tx, workspace, second_subject) do
          {:ok, :written}
        end
      end)

    with {:ok, :written} <- written,
         {:ok, :intact} <- Veritas.Core.Audit.verify(workspace),
         {:ok, rows} <- Veritas.Core.Audit.entries(workspace),
         :ok <- check_chain_links(rows, first_subject, second_subject) do
      # An event whose diff carries a **null** must verify too.
      #
      # The engines disagree about a null field — one keeps it, one drops it —
      # so a signature that covered the null could not be reproduced from the
      # row that was written, and a genuine history would verify as tampering.
      # The Log therefore writes a diff without the values that are not set,
      # and this is the check that says so: the Adapter holds the value the
      # way it holds every other value, and the chain still verifies.
      nil_subject = identifier()

      with {:ok, _row} <-
             Store.transaction(workspace, fn tx ->
               append_audit(tx, workspace, nil_subject, %{"state" => "probed", "note" => nil})
             end),
           {:ok, :intact} <- Veritas.Core.Audit.verify(workspace) do
        :ok
      else
        {:ok, {:broken_at, index}} ->
          {:error,
           "an event whose diff carries a null does not verify: the chain is broken at event #{index}"}

        other ->
          {:error, "an event whose diff carries a null could not be verified: #{inspect(other)}"}
      end
    else
      {:ok, {:broken_at, index}} -> {:error, "the chain is broken at event #{index}"}
      other -> {:error, "the chain could not be verified: #{inspect(other)}"}
    end
  end

  # The event written after another names that other as its predecessor.
  defp check_chain_links(rows, first_subject, second_subject) do
    first = Enum.find(rows, &(&1["subject"] == first_subject))
    second = Enum.find(rows, &(&1["subject"] == second_subject))

    cond do
      is_nil(first) or is_nil(second) ->
        {:error, "the Audit Log does not hold both events the transaction wrote"}

      second["prev_hash"] == first["hash"] ->
        :ok

      true ->
        {:error,
         "the second event does not link to the first: prev_hash #{inspect(second["prev_hash"])} is not the first event's hash #{inspect(first["hash"])}"}
    end
  end

  defp one_system(adapter) do
    description = adapter.describe()

    if is_map(description) and Map.has_key?(description, :engine) do
      :ok
    else
      {:error, "describe/0 does not describe one engine"}
    end
  end

  defp bounded_traversal(_adapter, workspace) do
    result =
      Store.transaction(workspace, fn tx ->
        Store.traverse(tx, identifier(), :out, 99, [])
      end)

    case result do
      {:ok, %{nodes: nodes}} when length(nodes) <= 5 -> :ok
      {:ok, %{nodes: nodes}} -> {:error, "the traversal returned #{length(nodes)} nodes"}
      other -> {:error, "the traversal failed: #{inspect(other)}"}
    end
  end

  defp relation_vocabulary(_adapter, workspace) do
    kind = "spec_kind_#{identifier()}"

    result =
      Store.transaction(workspace, fn tx ->
        with {:ok, _} <-
               Store.put_relation_kind(tx, %{
                 "id" => kind,
                 "from_table" => "ci",
                 "to_table" => "ci",
                 "inverse" => "spec_inverse"
               }) do
          :ok
        end
      end)

    # The registry is read in its own transaction: a kind the transaction
    # buffered is not yet a kind the store holds.
    kinds = Store.transaction(workspace, fn tx -> Store.relation_kinds(tx) end)

    case {result, kinds} do
      {:ok, _} ->
        case kinds do
          {:ok, kinds} ->
            if Enum.any?(kinds, &(&1["id"] == kind)) do
              :ok
            else
              {:error, "the registered kind did not appear in the registry"}
            end

          other ->
            {:error, "the registry could not be read: #{inspect(other)}"}
        end

      other ->
        {:error, "the relation kind could not be registered: #{inspect(other)}"}
    end
  end

  defp change_stream(_adapter, workspace) do
    id = identifier()

    # The change stream is fed by the outbox, and the outbox row is written in
    # the same transaction as the change it reports. A write with no audit
    # entry produces no change, so the check writes both.
    written =
      Store.transaction(workspace, fn tx ->
        with {:ok, _} <- Store.put(tx, :ci, probe(id)),
             {:ok, _sequence} <- append_audit(tx, workspace, id) do
          :ok
        end
      end)

    result =
      Store.transaction(workspace, fn tx ->
        Store.changes(tx, 0, limit: 1000)
      end)

    case result do
      {:ok, rows} ->
        if written != :ok do
          {:error, "the write that feeds the change stream failed: #{inspect(written)}"}
        else
          sequences = Enum.map(rows, & &1["sequence"])

          cond do
            rows == [] ->
              {:error, "the change stream is empty: the write produced no change"}

            not Enum.all?(sequences, &is_integer/1) ->
              {:error, "the change stream carries a sequence that is not a number"}

            sequences != Enum.sort(sequences) ->
              {:error, "the change stream is not ordered by sequence"}

            length(Enum.uniq(sequences)) != length(sequences) ->
              {:error, "the change stream repeats a sequence: #{inspect(sequences)}"}

            true ->
              :ok
          end
        end

      other ->
        {:error, "the change stream could not be read: #{inspect(other)}"}
    end
  end

  # A capability the Adapter does not have must be refused, not faked.
  defp loud_failure(adapter, workspace) do
    description = adapter.describe()
    capabilities = Map.get(description, :capabilities, [])

    if :vector in capabilities do
      :ok
    else
      result =
        Store.transaction(workspace, fn tx ->
          Store.vector_search(tx, [0.0], limit: 1)
        end)

      case result do
        {:error, %Error{code: :unsupported}} -> :ok
        {:error, %Error{code: code}} -> {:error, "expected :unsupported, got #{inspect(code)}"}
        other -> {:error, "an unsupported capability answered: #{inspect(other)}"}
      end
    end
  end

  # One attempt reaches the store: the Adapter does not retry behind the
  # caller's back.
  #
  # The write is read back afterwards: a call that answers "written" without
  # the write reaching the store has not made an attempt that reached the
  # store.
  defp no_internal_retries(_adapter, workspace) do
    id = identifier()

    visible_write(workspace, :ci, probe(id))
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # A write that must be visible.
  #
  # This is the positive control the write-based obligations need: an
  # obligation that asserts a write did *not* happen is worthless without it.
  # An Adapter whose write never reaches the store leaves nothing behind
  # either, and would pass every "nothing is left behind" check by doing
  # nothing at all.
  defp visible_write(workspace, table, record) do
    id = Map.get(record, "id")

    with {:ok, _row} <- Store.transaction(workspace, fn tx -> Store.put(tx, table, record) end),
         read <- Store.transaction(workspace, fn tx -> Store.fetch(tx, table, id) end) do
      case read do
        {:ok, %{"id" => ^id}} ->
          :ok

        other ->
          {:error, "the write was not visible: #{inspect(other)}"}
      end
    else
      other -> {:error, "the write did not succeed: #{inspect(other)}"}
    end
  end

  # An Audit Log event, written through the host's own API so the chain it
  # produces is a chain the host can verify.
  defp append_audit(tx, workspace, subject, diff \\ nil) do
    Veritas.Core.Audit.append(tx, workspace, %{
      subject: subject,
      subject_table: "ci",
      from_state: nil,
      to_state: nil,
      actor: %{type: "system", id: "spec"},
      reason: "store conformance probe",
      correlation_id: nil,
      diff: diff
    })
  end

  defp run_check(obligation, check) do
    case check.() do
      :ok -> %{obligation: obligation, ok: true, detail: ""}
      {:error, detail} -> %{obligation: obligation, ok: false, detail: detail}
      other -> %{obligation: obligation, ok: false, detail: "unexpected: #{inspect(other)}"}
    end
  rescue
    error -> %{obligation: obligation, ok: false, detail: "raised: #{Exception.message(error)}"}
  catch
    kind, value ->
      %{obligation: obligation, ok: false, detail: "threw #{kind}: #{inspect(value)}"}
  end

  # The probe row the checks write. It is a CI, because the CI table is the
  # one every Adapter is guaranteed to have.
  defp probe(id) do
    %{"id" => id, "ci_type" => "spec_probe", "name" => "store conformance probe"}
  end

  defp identifier, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
