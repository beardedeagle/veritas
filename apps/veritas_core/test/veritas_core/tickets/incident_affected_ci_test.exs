defmodule Veritas.Core.Tickets.IncidentAffectedCITest.Faulting do
  @moduledoc false
  @behaviour Veritas.Store
  alias Veritas.Store.Memory
  @fault {__MODULE__, :fault}
  @hits {__MODULE__, :hits}

  # Real Memory transactions/overlays/commit/rollback, with one narrow fault.
  defdelegate transaction(workspace, fun, opts), to: Memory
  defdelegate put(tx, table, row), to: Memory
  defdelegate delete(tx, table, id), to: Memory
  defdelegate list(tx, table, filter), to: Memory
  defdelegate next_sequence(tx, key), to: Memory
  defdelegate unrelate(tx, kind, from, to), to: Memory
  defdelegate traverse(tx, from, direction, depth, opts), to: Memory
  defdelegate relation_counts(tx, ids), to: Memory
  defdelegate impact(tx, id, depth), to: Memory
  defdelegate put_ci_type(tx, spec), to: Memory
  defdelegate put_relation_kind(tx, spec), to: Memory
  defdelegate ci_types(tx), to: Memory
  defdelegate relation_kinds(tx), to: Memory
  defdelegate upsert_chunks(tx, subject, chunks), to: Memory
  defdelegate vector_search(tx, embedding, opts), to: Memory
  defdelegate fulltext_search(tx, query, opts), to: Memory
  defdelegate append_samples(tx, samples), to: Memory
  defdelegate range_samples(tx, target, from, to, opts), to: Memory
  defdelegate changes(tx, since, opts), to: Memory

  def describe, do: Map.put(Memory.describe(), :adapter, __MODULE__)

  def arm(mode, ticket, target, error) do
    Process.put(@fault, %{mode: mode, ticket: ticket, target: target, error: error})
    Process.put(@hits, [])
  end
  def hits, do: Enum.reverse(Process.get(@hits, []))
  def clear do
    Process.delete(@fault)
    Process.delete(@hits)
  end

  def fetch(tx, table, id) do
    case {table, fault(:fetch_ci)} do
      {:ci, %{target: ^id, error: error}} -> fail(:fetch_ci, error)
      _ -> Memory.fetch(tx, table, id)
    end
  end

  def outgoing_relations(tx, kind, from) do
    case fault(:reader) do
      %{ticket: ^from, error: error} when kind in ["affects", :affects] -> fail(:reader, error)
      _ -> Memory.outgoing_relations(tx, kind, from)
    end
  end

  def relate(tx, kind, from, to, attrs) do
    case fault(:delta) do
      %{ticket: ^from, target: ^to, error: error} when kind in ["affects", :affects] ->
        # Buffer the real addition before failing: rollback must discard it,
        # along with any removals/writes already buffered by the real domain.
        case Memory.relate(tx, kind, from, to, attrs) do
          {:ok, _} -> fail(:delta, error)
          failure -> failure
        end
      _ -> Memory.relate(tx, kind, from, to, attrs)
    end
  end

  def append_audit(tx, row) do
    ticket_fault = fault(:ticket_audit)
    workflow_fault = fault(:workflow_audit)
    cond do
      ticket_fault && row["subject"] == ticket_fault.ticket &&
          row["subject_table"] == "ticket" && row["to_state"] == "new" &&
          row["diff"]["operation"] == "amend" ->
        fail(:ticket_audit, ticket_fault.error)
      workflow_fault && row["subject"] == workflow_fault.ticket &&
          row["subject_table"] == "workflow_run" && row["to_state"] == "active" ->
        fail(:workflow_audit, workflow_fault.error)
      true -> Memory.append_audit(tx, row)
    end
  end

  defp fault(mode) do
    case Process.get(@fault) do
      %{mode: ^mode} = config -> config
      _ -> nil
    end
  end
  defp fail(mode, error) do
    Process.put(@hits, [mode | Process.get(@hits, [])])
    {:error, error}
  end
end

defmodule Veritas.Core.Tickets.IncidentAffectedCITest do
  @moduledoc """
  Six public persisted affected-CI case groups using real Memory transactions.

  Affects edges are the only membership authority. Raw legacy ticket.ci is
  deliberately independent. Historical duplicate/dangling fixtures never seed
  Incidents, revisions, clocks, workflow runs or audit history: those originate
  in public APIs. Registry data and CIs use existing public CMDB operations.

  Frozen-source expected RED is unsupported affected-CI mutation or missing
  canonical readback, plus native-null binding coercion. Fixture failures are
  not those REDs. Exact injected failures count only if their seam is reached.
  Root owns compilation/execution; this file is not runtime acceptance.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, CI, Principal, Tickets, Workflows}
  alias Veritas.Store
  alias Veritas.Store.{Error, Memory}
  alias Veritas.Store.Surreal.Schema
  alias __MODULE__.Faulting

  @tables [:ticket, :ticket_detail, :incident, :sla_clock, :incident_hold_episode,
    :workflow_run, :workflow, :ci, :audit_event, :event_outbox]
  @parked_data ~w(current_step answers outputs approved_outputs completed_steps)
  @array_error {:invalid_domain_fields, %{"affected_ci_ids" => :array_of_references_required}}
  @reference_error {:invalid_domain_fields, %{"affected_ci_ids" => :invalid_reference}}

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = unique_workspace()
    foreign_workspace = unique_workspace()
    if is_nil(Process.whereis(Memory.Server)), do: start_supervised!(Memory.Server)
    on_exit(fn ->
      try do
        remove_memory_workspaces([workspace, foreign_workspace])
      after
        restore_store(previous)
      end
    end)
    Application.put_env(:veritas_core, :store, Memory)
    admin = Principal.new("affected_workflow_admin", workspace, [:platform_admin], kind: :human)
    desk = Principal.new("affected_subject", workspace, [:service_desk_agent], kind: :human)
    steward = Principal.new("affected_ci_steward", workspace, [:ci_steward], kind: :human)
    foreign = Principal.new("affected_foreign", foreign_workspace, [:ci_steward], kind: :human)
    register_reference_types(workspace)
    register_reference_types(foreign_workspace)
    a = create_ci(workspace, "A", steward)
    b = create_ci(workspace, "B", steward)
    c = create_ci(workspace, "C", steward)
    foreign_ci = create_ci(foreign_workspace, "Foreign only", foreign)
    assert {:ok, ticket_only} = Tickets.open(workspace, "service_request",
      %{"title" => "A ticket is not a CI", "priority" => "low"}, desk,
      Principal.audit_actor(desk), [])
    assert {:ok, workflow} = Workflows.save(workspace, nil, definition(), admin)
    assert {:ok, _} = Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)
    {:ok, workspace: workspace, foreign_workspace: foreign_workspace, admin: admin, desk: desk,
     workflow: workflow, a: a["id"], b: b["id"], c: c["id"],
     foreign_ci: foreign_ci["id"], ticket_only: ticket_only["id"]}
  end

  describe "1 - managed omission, clear and explicit-empty presence" do
    # Catches deriving membership from submitted fields instead of existing edges.
    test "omitted membership preserves every physical edge and the parked run", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      before = snapshot(ctx.workspace)
      correct(ctx, id, %{"title" => "Unrelated correction"}, 1)
      after_state = snapshot(ctx.workspace)
      assert after_state.relations == before.relations
      assert_parked(before, after_state, id, 2)
      assert is_nil(affected_mark(after_state, id))
      assert_projection(ctx, id, [ctx.a, ctx.b])
    end

    # Catches omission/[] conflation, deleting another relation kind, or moving
    # the workflow while applying a same-state domain correction.
    test "explicit empty clears only affects and records a checked managed correction", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      before = snapshot(ctx.workspace)
      correct(ctx, id, %{"affected_ci_ids" => []}, 1)
      after_state = snapshot(ctx.workspace)
      assert edges(after_state, id, "affects") == []
      assert edges(after_state, id, "implements") == edges(before, id, "implements")
      assert_parked(before, after_state, id, 2)
      assert_presence(ctx, after_state, id)
      assert_projection(ctx, id, [])
      assert_membership_audit(before, after_state, id, [ctx.a, ctx.b], [])
    end

    # Catches treating the first explicit [] as no_change when the graph was
    # already empty but no explicit membership attestation had ever been made.
    test "first empty attestation is meaningful even for an already empty graph", ctx do
      id = start_empty(ctx)
      before = snapshot(ctx.workspace)
      assert is_nil(affected_mark(before, id))
      assert {:ok, run} = Workflows.update_domain(ctx.workspace, id, %{"affected_ci_ids" => []},
        ctx.desk, revisions(1))
      assert run["revision"] == 2
      after_state = snapshot(ctx.workspace)
      assert after_state.relations == before.relations
      assert_parked(before, after_state, id, 2)
      assert_presence(ctx, after_state, id)
      assert_projection(ctx, id, [])
      assert_membership_audit(before, after_state, id, [], [])
    end
  end

  describe "2 - native/JSON binding presence at intake and same-state completion" do
    # Catches losing array values or passing JSON text through as membership.
    test "native and JSON arrays including explicit empties work at public intake", ctx do
      for {answer, expected} <- [{[ctx.a, ctx.b], [ctx.a, ctx.b]},
            {Jason.encode!([ctx.a, ctx.b]), [ctx.a, ctx.b]}, {[], []}, {"[]", []}] do
        assert {:ok, run} = start_result(ctx, %{"linked_cis" => answer}, %{})
        id = run["ticket"]
        state = snapshot(ctx.workspace)
        assert row(state, :workflow_run, id)["data"]["answers"]["intake"]["linked_cis"] == answer
        assert detail(state, id)["domain_revision"] == 1
        assert_presence(ctx, state, id)
        assert_projection(ctx, id, expected)
        assert_no_membership_copy(ctx, state, id)
      end
    end

    # Catches skipping domain writes for same-state completion, or losing []
    # when answers are normalized and the next manual step is selected.
    test "native and JSON arrays update membership during same-state completion", ctx do
      for {answer, expected} <- [{[ctx.c], [ctx.c]}, {Jason.encode!([ctx.c]), [ctx.c]},
            {[], []}, {"[]", []}] do
        id = start_empty(ctx)
        seed_links(ctx, id)
        before = snapshot(ctx.workspace)
        assert {:ok, result} = Workflows.complete(ctx.workspace, id,
          %{"linked_cis" => answer}, ctx.desk, revisions(1))
        assert result["revision"] == 2
        after_state = snapshot(ctx.workspace)
        run = row(after_state, :workflow_run, id)
        assert row(after_state, :ticket, id)["state"] == "new"
        assert detail(after_state, id)["domain_revision"] == 2
        assert run["data"]["current_step"] == "parked"
        assert run["data"]["completed_steps"] == ["intake", "review"]
        assert run["data"]["answers"]["review"]["linked_cis"] == answer
        assert run["definition"] == row(before, :workflow_run, id)["definition"]
        assert run["data"]["approved_outputs"] == []
        assert after_state.tables.sla_clock == before.tables.sla_clock
        assert edges(after_state, id, "implements") == edges(before, id, "implements")
        assert_projection(ctx, id, expected)
        assert_no_membership_copy(ctx, after_state, id)
      end
    end

    # Catches using the normalized empty-answer placeholder to clear a graph
    # when the caller never supplied the optional binding.
    test "omitted bound answers preserve membership and do not attest a clear", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      before = snapshot(ctx.workspace)
      assert {:ok, _} = Workflows.complete(ctx.workspace, id, %{"note" => "Unbound extension answer"},
        ctx.desk, revisions(1))
      after_state = snapshot(ctx.workspace)
      assert after_state.relations == before.relations
      assert is_nil(affected_mark(after_state, id))
      assert_projection(ctx, id, [ctx.a, ctx.b])
    end

    # Catches the known nil-to-empty-string/omission coercion in answers().
    test "explicit native null is not omission at intake or completion", ctx do
      assert_bound_refusal(ctx, nil, @array_error)
    end

    # Catches accepting null/invalid/duplicate arrays or returning a different
    # unrelated policy/revision refusal before the input boundary is checked.
    test "JSON null malformed arrays and duplicates are structured input refusals", ctx do
      for value <- ["null", "[", 42, %{"not" => "an array"}, [ctx.a, ctx.a],
            Jason.encode!([ctx.a, ctx.a])] do
        assert_bound_refusal(ctx, value, @array_error)
      end
    end

    # Catches selecting a winner instead of refusing normalized conflicting
    # explicit binding and supplemental facts, before any write can commit.
    test "conflicting supplemental membership refuses at both workflow boundaries", ctx do
      for answer <- [[ctx.a], Jason.encode!([ctx.a])] do
        error = {:invalid_domain_fields, %{"affected_ci_ids" => :conflicting_value}}
        before = snapshot(ctx.workspace)
        assert {:error, ^error} = start_result(ctx, %{"linked_cis" => answer},
          %{"affected_ci_ids" => [ctx.c]})
        assert snapshot(ctx.workspace) == before
        id = start_empty(ctx)
        seed_links(ctx, id)
        before = snapshot(ctx.workspace)
        assert {:error, ^error} = Workflows.complete(ctx.workspace, id,
          %{"linked_cis" => answer}, ctx.desk,
          revisions(1) ++ [domain_fields: %{"affected_ci_ids" => [ctx.c]}])
        assert snapshot(ctx.workspace) == before
      end
    end

    # Catches a direct supplemental/native null escaping the array validator.
    test "null is never a valid corrective membership array", ctx do
      id = start_empty(ctx)
      for value <- [nil, "null"] do
        before = snapshot(ctx.workspace)
        assert {:error, @array_error} = Tickets.update_domain(ctx.workspace, id,
          %{"affected_ci_ids" => value}, ctx.desk, revisions(1))
        assert snapshot(ctx.workspace) == before
      end
    end
  end

  describe "3 - real references and exact fetch errors" do
    # Catches blanket rejection despite legitimate same-Workspace CIs; no
    # nonexistent per-CI ACL is introduced by this fixture or expectation.
    test "a desk human selects real same-Workspace CIs", ctx do
      id = start_empty(ctx)
      before = snapshot(ctx.workspace)
      correct(ctx, id, %{"affected_ci_ids" => [ctx.a, ctx.b]}, 1)
      after_state = snapshot(ctx.workspace)
      assert_projection(ctx, id, [ctx.a, ctx.b])
      assert Enum.sort(Enum.map(edges(after_state, id, "affects"), & &1["to"])) ==
        Enum.sort([ctx.a, ctx.b])
      assert_parked(before, after_state, id, 2)
      assert_no_membership_copy(ctx, after_state, id)
    end

    # Catches foreign lookup fallback, accepting a non-CI table's record, or
    # collapsing missing/foreign/wrong-type references into a successful patch.
    test "missing foreign-only and ticket-only targets are invalid references", ctx do
      id = start_empty(ctx)
      for target <- ["missing_affected_ci", ctx.foreign_ci, ctx.ticket_only] do
        before = snapshot(ctx.workspace)
        foreign_before = snapshot(ctx.foreign_workspace)
        assert {:error, @reference_error} = Tickets.update_domain(ctx.workspace, id,
          %{"affected_ci_ids" => [target]}, ctx.desk, revisions(1))
        assert snapshot(ctx.workspace) == before
        assert snapshot(ctx.foreign_workspace) == foreign_before
      end
    end

    # Catches treating a fetch failure as a missing CI or a generic refusal.
    test "a targeted reference fetch failure propagates unchanged", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      assert_fault_rollback(ctx, id, :fetch_ci)
    end
  end

  describe "4 - exact physical retention and dangling historical endpoints" do
    # Catches endpoint-set recreation: both distinct A identities/attributes
    # must survive, every B identity must go, and C is added exactly once.
    test "replacement retains all duplicate A rows and removes all duplicate B rows", ctx do
      id = start_empty(ctx)
      seed_duplicate_history(ctx, id)
      before = snapshot(ctx.workspace)
      correct(ctx, id, %{"affected_ci_ids" => [ctx.a, ctx.c]}, 1)
      after_state = snapshot(ctx.workspace)
      retained = Enum.filter(edges(after_state, id, "affects"), &(&1["to"] == ctx.a))
      expected_a = Enum.filter(edges(before, id, "affects"), &(&1["to"] == ctx.a))
      assert length(expected_a) == 2
      assert retained == expected_a
      assert Enum.all?(edges(after_state, id, "affects"), &(&1["to"] != ctx.b))
      assert [_new_c] = Enum.filter(edges(after_state, id, "affects"), &(&1["to"] == ctx.c))
      assert edges(after_state, id, "implements") == edges(before, id, "implements")
      assert_projection(ctx, id, [ctx.a, ctx.c])
      assert_membership_audit(before, after_state, id, [ctx.a, ctx.b], [ctx.a, ctx.c])
      assert_no_membership_copy(ctx, after_state, id)
    end

    # Catches validating removed targets before planning a repair: a dangling
    # B edge must be removable without resurrecting/fetching its absent CI.
    test "removing a dangling B succeeds while retaining the physical A row", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      remove_historical_ci(ctx.workspace, ctx.b)
      before = snapshot(ctx.workspace)
      correct(ctx, id, %{"affected_ci_ids" => [ctx.a]}, 1)
      after_state = snapshot(ctx.workspace)
      assert edges(after_state, id, "affects") ==
        Enum.filter(edges(before, id, "affects"), &(&1["to"] == ctx.a))
      assert edges(after_state, id, "implements") == edges(before, id, "implements")
      assert_projection(ctx, id, [ctx.a])
      assert is_nil(Enum.find(after_state.tables.ci, &(&1["id"] == ctx.b)))
    end

    # Catches a no_change fast path bypassing validation of desired retained CIs.
    test "retaining a dangling target refuses without changing its historical edge", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      remove_historical_ci(ctx.workspace, ctx.b)
      before = snapshot(ctx.workspace)
      assert {:error, @reference_error} = Tickets.update_domain(ctx.workspace, id,
        %{"affected_ci_ids" => [ctx.a, ctx.b]}, ctx.desk, revisions(1))
      assert snapshot(ctx.workspace) == before
    end
  end

  describe "5 - reader delta and late audit failures remain atomic" do
    # Catches presenting reader errors as a successful empty canonical graph.
    test "canonical readback propagates its exact relation-reader failure", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      before = snapshot(ctx.workspace)
      failure = failure(:reader)
      {result, hits} = with_fault(:reader, id, ctx.c, failure, fn ->
        Tickets.read_domain(ctx.workspace, id, ctx.desk)
      end)
      assert snapshot(ctx.workspace) == before
      assert {:error, ^failure} = result
      assert hits == [:reader]
    end

    test "a corrective relation-reader failure cannot mutate the managed Incident", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      assert_fault_rollback(ctx, id, :reader)
    end

    # The adapter buffers a real C addition and then fails, so a fake adapter
    # that merely pretends to commit cannot establish this rollback result.
    test "a real buffered delta is discarded when the targeted addition fails", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      assert_fault_rollback(ctx, id, :delta)
    end

    test "ticket audit failure rolls back domain graph clocks and workflow", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      assert_fault_rollback(ctx, id, :ticket_audit)
    end

    # This seam is after the real ticket audit and workflow-row put, not the
    # earlier ticket-audit control; both pending audits must remain uncommitted.
    test "later workflow audit failure also rolls back the earlier ticket and graph writes", ctx do
      id = start_empty(ctx)
      seed_links(ctx, id)
      assert_fault_rollback(ctx, id, :workflow_audit)
    end
  end

  describe "6 - raw legacy ci and canonical graph remain separate" do
    # Catches legacy backfill, destructive clearing of ticket.ci, or regression
    # of the independently retained legacy-plus-graph impact query contract.
    test "canonical clear retains raw historical ci and its legacy impact meaning", ctx do
      id = start_empty(ctx)
      set_historical_raw_ci(ctx.workspace, id, ctx.a)
      assert :ok = Store.transaction(ctx.workspace, fn tx ->
        assert {:ok, _} = Store.relate(tx, "affects", id, ctx.b, %{"note" => "Existing graph B"})
        :ok
      end)
      before = snapshot(ctx.workspace)
      assert row(before, :ticket, id)["ci"] == ctx.a
      assert_projection(ctx, id, [ctx.b])
      assert id in impacted_tickets(ctx.workspace, ctx.a)
      assert id in impacted_tickets(ctx.workspace, ctx.b)
      correct(ctx, id, %{"affected_ci_ids" => []}, 1)
      after_state = snapshot(ctx.workspace)
      assert row(after_state, :ticket, id)["ci"] == ctx.a
      assert edges(after_state, id, "affects") == []
      assert_projection(ctx, id, [])
      assert id in impacted_tickets(ctx.workspace, ctx.a)
      refute id in impacted_tickets(ctx.workspace, ctx.b)
      assert_no_membership_copy(ctx, after_state, id)
      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end
  end

  defp assert_fault_rollback(ctx, id, mode) do
    before = snapshot(ctx.workspace)
    failure = failure(mode)
    {result, hits} = with_fault(mode, id, ctx.c, failure, fn ->
      Tickets.update_domain(ctx.workspace, id, %{"affected_ci_ids" => [ctx.a, ctx.c]},
        ctx.desk, revisions(1))
    end)
    # Read with the restored real adapter and directly from committed Server
    # relations, never through the failing reader or its transaction overlay.
    assert snapshot(ctx.workspace) == before
    assert {:error, ^failure} = result
    assert hits == [mode]
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp failure(mode) do
    Error.new(:unavailable, "Injected affected-CI boundary failure",
      details: %{reason: :injected_affected_ci, seam: mode}, retryable: false)
  end

  defp with_fault(mode, id, target, failure, fun) do
    previous = Application.fetch_env(:veritas_core, :store)
    Faulting.arm(mode, id, target, failure)
    try do
      Application.put_env(:veritas_core, :store, Faulting)
      result = fun.()
      {result, Faulting.hits()}
    after
      Faulting.clear()
      restore_store(previous)
    end
  end

  defp assert_bound_refusal(ctx, value, error) do
    before = snapshot(ctx.workspace)
    assert {:error, ^error} = start_result(ctx, %{"linked_cis" => value}, %{})
    assert snapshot(ctx.workspace) == before
    id = start_empty(ctx)
    seed_links(ctx, id)
    before = snapshot(ctx.workspace)
    assert {:error, ^error} = Workflows.complete(ctx.workspace, id,
      %{"linked_cis" => value}, ctx.desk, revisions(1))
    assert snapshot(ctx.workspace) == before
  end

  defp start_empty(ctx) do
    assert {:ok, run} = start_result(ctx, %{}, %{})
    assert run["status"] == "active"
    assert run["revision"] == 1
    state = snapshot(ctx.workspace)
    assert detail(state, run["ticket"])["domain_revision"] == 1
    run["ticket"]
  end

  defp start_result(ctx, answers, supplemental) do
    Workflows.start(ctx.workspace, ctx.workflow["id"], %{"title" => "Affected-CI fixture",
      "answers" => answers, "domain_fields" => supplemental}, ctx.desk)
  end

  defp correct(ctx, id, fields, revision) do
    assert {:ok, result} = Tickets.update_domain(ctx.workspace, id, fields, ctx.desk, revisions(revision))
    assert result["domain_revision"] == revision + 1
    assert result["workflow_revision"] == revision + 1
    result
  end

  defp revisions(revision), do: [expected_revision: revision, expected_domain_revision: revision]

  defp assert_projection(ctx, id, expected) do
    assert {:ok, view} = Tickets.read_domain(ctx.workspace, id, ctx.desk)
    actual = view.domain["affected_ci_ids"]
    assert is_list(actual)
    assert Enum.sort(actual) == Enum.sort(expected)
    assert {:ok, repeated} = Tickets.read_domain(ctx.workspace, id, ctx.desk)
    assert repeated.domain["affected_ci_ids"] == actual
    view
  end

  defp assert_parked(before, after_state, id, revision) do
    old = row(before, :workflow_run, id)
    run = row(after_state, :workflow_run, id)
    assert run["status"] == "active"
    assert run["revision"] == revision
    assert detail(after_state, id)["domain_revision"] == revision
    assert row(after_state, :ticket, id)["state"] == "new"
    assert run["definition"] == old["definition"]
    assert run["workflow_revision"] == old["workflow_revision"]
    assert Map.take(run["data"], @parked_data) == Map.take(old["data"], @parked_data)
    assert after_state.tables.workflow == before.tables.workflow
    assert after_state.tables.sla_clock == before.tables.sla_clock
    assert after_state.tables.incident_hold_episode == before.tables.incident_hold_episode
  end

  defp assert_presence(ctx, state, id) do
    mark = affected_mark(state, id)
    assert is_map(mark)
    assert mark["actor"] == %{"type" => "user", "id" => ctx.desk.id}
    assert {:ok, _, 0} = DateTime.from_iso8601(mark["recorded_at"])
  end

  defp assert_no_membership_copy(ctx, state, id) do
    refute Map.has_key?(row(state, :ticket, id), "affected_ci_ids")
    refute Map.has_key?(detail(state, id), "affected_ci_ids")
    provenance = detail(state, id)["domain_provenance"]
    for target <- [ctx.a, ctx.b, ctx.c] do
      refute contains_value?(provenance, target)
    end
  end
  defp contains_value?(map, value) when is_map(map),
    do: Enum.any?(Map.values(map), &contains_value?(&1, value))
  defp contains_value?(list, value) when is_list(list),
    do: Enum.any?(list, &contains_value?(&1, value))
  defp contains_value?(actual, value), do: actual == value

  defp assert_membership_audit(before, after_state, id, old, desired) do
    delta = after_state.tables.audit_event -- before.tables.audit_event
    assert length(delta) == 2
    assert [event] = Enum.filter(delta, &(&1["subject_table"] == "ticket" and &1["subject"] == id))
    assert Enum.sort(event["diff"]["before"]["affected_ci_ids"]) == Enum.sort(old)
    assert Enum.sort(event["diff"]["after"]["affected_ci_ids"]) == Enum.sort(desired)
    assert event["diff"]["domain_revision"] == detail(after_state, id)["domain_revision"]
    assert event["diff"]["operation"] == "amend"
  end

  defp affected_mark(state, id) do
    get_in(detail(state, id), ["domain_provenance", "fields", "affected_ci_ids"])
  end
  defp detail(state, id) do
    found = Enum.filter(state.tables.incident, &(&1["ticket_id"] == id))
    assert [result] = found
    result
  end
  defp row(state, table, id) do
    result = Enum.find(Map.fetch!(state.tables, table), &(&1["id"] == id))
    assert is_map(result)
    result
  end
  defp edges(state, id, kind) do
    Enum.filter(state.relations, &(&1["from"] == id and &1["kind"] == kind))
  end

  defp snapshot(workspace) do
    assert {:ok, tables} = Store.transaction(workspace, fn tx ->
      rows = Map.new(@tables, fn table ->
        assert {:ok, rows} = Store.list(tx, table, %{where: [], order_by: [id: :asc]})
        {table, rows}
      end)
      {:ok, rows}
    end)
    assert {:ok, committed} = Memory.Server.relations(Memory.Server, workspace)
    %{tables: tables, relations: Enum.sort_by(committed, & &1["id"])}
  end

  defp seed_links(ctx, id) do
    assert :ok = Store.transaction(ctx.workspace, fn tx ->
      assert {:ok, _} = Store.relate(tx, "affects", id, ctx.a, %{"note" => "Pre-existing A"})
      assert {:ok, _} = Store.relate(tx, "affects", id, ctx.b, %{"note" => "Pre-existing B"})
      assert {:ok, _} = Store.relate(tx, "implements", id, ctx.c, %{"note" => "Retain other kind"})
      :ok
    end)
  end

  defp seed_duplicate_history(ctx, id) do
    seed_links(ctx, id)
    # Replace only this public-created Incident's affects fixtures with old
    # physical identities; preserve its implements row and every other source.
    assert :ok = Store.transaction(ctx.workspace, fn tx ->
      assert :ok = Store.unrelate(tx, "affects", id, ctx.a)
      assert :ok = Store.unrelate(tx, "affects", id, ctx.b)
      :ok
    end)
    historical = for {edge_id, target, note} <- [
      {"old_a_one", ctx.a, "A first attributes"}, {"old_a_two", ctx.a, "A second attributes"},
      {"old_b_one", ctx.b, "B first attributes"}, {"old_b_two", ctx.b, "B second attributes"}
    ] do
      { :relate, "affects", %{"workspace" => ctx.workspace, "id" => edge_id,
        "kind" => "affects", "from" => id, "to" => target,
        "attributes" => %{"note" => note, "historical" => true}} }
    end
    assert {:ok, _} = Memory.Server.commit(Memory.Server, historical)
  end

  defp remove_historical_ci(workspace, id) do
    # Model an old relation whose endpoint disappeared; never a proposed
    # production deletion path or fabricated Incident record.
    assert :ok = Store.transaction(workspace, fn tx -> Store.delete(tx, :ci, id) end)
  end
  defp set_historical_raw_ci(workspace, id, ci_id) do
    assert {:ok, _} = Store.transaction(workspace, fn tx ->
      assert {:ok, ticket} = Store.fetch(tx, :ticket, id)
      Store.put(tx, :ticket, Map.put(ticket, "ci", ci_id))
    end)
  end
  defp impacted_tickets(workspace, id) do
    assert {:ok, %{tickets: tickets}} = Store.transaction(workspace, &Store.impact(&1, id, 1))
    Enum.map(tickets, & &1["id"])
  end

  defp register_reference_types(workspace) do
    assert {:ok, _} = CI.register_type(workspace, %{"id" => "affected_fixture",
      "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      "required" => []})
    for kind <- Enum.filter(Schema.relation_kinds(), &(&1["id"] in ["affects", "implements"])) do
      assert {:ok, _} = CI.register_relation_kind(workspace, kind)
    end
  end
  defp create_ci(workspace, name, principal) do
    assert {:ok, ci} = CI.create(workspace, %{"ci_type" => "affected_fixture", "name" => name,
      "attributes" => %{}, "lifecycle_state" => "active", "criticality" => "low",
      "actor" => Principal.audit_actor(principal)})
    ci
  end

  defp definition do
    bound = %{"key" => "linked_cis", "label" => "Affected CIs", "type" => "textarea",
      "binding" => "affected_ci_ids", "required" => false}
    note = %{"key" => "note", "label" => "Note", "type" => "text", "required" => false}
    %{"name" => "Affected CI public binding fixture", "ticket_type" => "incident",
      "description" => "Parked new-state workflow; no lifecycle, policy or provider prerequisite",
      "steps" => [
        %{"id" => "intake", "name" => "Intake", "kind" => "intake", "phase" => "intake",
          "fields" => [bound, note], "next" => ["review"]},
        %{"id" => "review", "name" => "Review", "kind" => "manual", "phase" => "processing",
          "fields" => [bound, note], "next" => ["parked"]},
        %{"id" => "parked", "name" => "Parked", "kind" => "manual", "phase" => "after_action",
          "fields" => [], "next" => []}
      ]}
  end

  defp unique_workspace,
    do: "t_affected_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp restore_store({:ok, configuration}), do: Application.put_env(:veritas_core, :store, configuration)
  defp restore_store(:error), do: Application.delete_env(:veritas_core, :store)
  defp remove_memory_workspaces(workspaces) do
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox = state.outbox |> Map.drop(workspaces) |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] in workspaces))
        end)
        %{state | workspaces: Map.drop(state.workspaces, workspaces), outbox: outbox}
      end)
    end
    :ok
  end
end
