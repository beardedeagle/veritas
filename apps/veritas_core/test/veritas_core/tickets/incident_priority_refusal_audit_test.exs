defmodule Veritas.Core.Tickets.IncidentPriorityRefusalAuditTest.AuditWriteFailure do
  @moduledoc false
  @behaviour Veritas.Store

  alias Veritas.Store.{Error, Memory}

  # Keep real Memory buffering/commit/rollback. Only the audit write fails;
  # returning success without committing is deliberately not a test double here.
  defdelegate transaction(workspace, fun, opts), to: Memory
  defdelegate fetch(tx, table, id), to: Memory
  defdelegate put(tx, table, row), to: Memory
  defdelegate delete(tx, table, id), to: Memory
  defdelegate list(tx, table, filter), to: Memory
  defdelegate next_sequence(tx, key), to: Memory
  defdelegate relate(tx, kind, from, to, attrs), to: Memory
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

  def append_audit(_tx, _event), do: {:error, failure()}

  def failure do
    Error.new(:unavailable, "Injected refusal-audit write failure",
      details: %{reason: :injected_refusal_audit_write},
      retryable: false
    )
  end
end

defmodule Veritas.Core.Tickets.IncidentPriorityRefusalAuditTest do
  @moduledoc """
  Unrun tests-first candidate for the narrowed priority-refusal audit finding.

  A legitimate desk agent may classify an Incident but cannot select a priority
  differing from its configured derivation without approved override evidence.
  Both refusal paths must append exactly one ticket-subject refusal, or return
  the audit Store error, without mutating the Incident or its active workflow.

  Uses the real Memory transaction adapter, not a pretend successful commit.
  This is neither executed RED evidence nor real-Surreal/three-surface proof.
  No production repair is implied by this candidate.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory
  alias __MODULE__.AuditWriteFailure

  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @state_tables [:ticket, :incident, :sla_clock, :incident_hold_episode, :workflow_run]
  @override_denial "A priority override requires Service Desk Manager approval."

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = StoreCase.unique_workspace()

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspace(workspace)
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    admin = Principal.new("policy_fixture_admin", workspace, [:platform_admin], kind: :human)
    desk = Principal.new("classification_fixture_desk", workspace, [:service_desk_agent], kind: :human)

    # Explicit test-only operator data, not a product/default matrix. All 20
    # distinct cells deliberately derive P3, making the requested P1 divergent.
    rules =
      for impact <- @impacts, urgency <- @urgencies do
        %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
      end

    assert length(rules) == 20

    assert {:ok, draft} =
             Tickets.save_incident_policy(workspace, %{"priority_rules" => rules}, admin, nil)

    assert {:ok, policy} =
             Tickets.publish_incident_policy(workspace, admin, draft.policy_revision, approve: true)

    assert policy.readiness.operations.derive_priority == []
    assert is_binary(policy.active_version)

    # No state advancement, SLA target, calendar, AI or provider is needed to
    # reach this amendment refusal. Unset unrelated policy components stay unset.
    assert {:ok, workflow} = Workflows.save(workspace, nil, manual_definition(), admin)

    assert {:ok, _published} =
             Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)

    assert {:ok, run} =
             Workflows.start(
               workspace,
               workflow["id"],
               %{
                 "title" => "Priority refusal audit fixture",
                 "domain_fields" => %{
                   "impact" => "individual",
                   "urgency" => "medium",
                   "severity" => "minor",
                   "priority_justification" => "Explicit fixture classification derives P3"
                 }
               },
               desk
             )

    assert run["status"] == "active"
    assert {:ok, view} = Tickets.read_domain(workspace, run["ticket"], desk)
    assert view.domain["priority"] == "P3"
    assert view.domain["impact"] == "individual"
    assert view.domain["urgency"] == "medium"
    assert view.policy.active_version == policy.active_version
    assert is_integer(view.domain_revision)
    assert view.workflow_revision == run["revision"]

    before = persisted_state(workspace)
    assert [%{"id" => ticket_id, "state" => "new"}] = before.ticket
    assert ticket_id == run["ticket"]
    assert [%{"domain_revision" => domain_revision}] = before.incident
    assert domain_revision == view.domain_revision
    assert [_response_clock] = before.sla_clock
    assert [%{"revision" => run_revision}] = before.workflow_run
    assert run_revision == run["revision"]
    assert {:ok, audit_before} = Audit.entries(workspace)

    {:ok,
     workspace: workspace,
     desk: desk,
     ticket_id: ticket_id,
     before: before,
     audit_before: audit_before,
     opts: [
       expected_revision: run_revision,
       expected_domain_revision: domain_revision,
       expected_policy_version: policy.active_version
     ]}
  end

  test "divergent priority without override commits exactly one approval-required refusal", ctx do
    assert {:error, :approval_required} =
             Tickets.update_domain(ctx.workspace, ctx.ticket_id, divergent_priority(), ctx.desk, ctx.opts)

    assert persisted_state(ctx.workspace) == ctx.before

    # Expected RED on the stopped candidate: the current ordinary error branch
    # rolls back, so this list is empty. This is an expectation, not a run result.
    assert [refusal] = new_audit_events(ctx)
    assert_ticket_refusal(refusal, ctx, "approval_required")
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "explicit override denial remains one audited refusal through Workflows", ctx do
    assert {:error, @override_denial} =
             Workflows.update_domain(
               ctx.workspace,
               ctx.ticket_id,
               explicit_override(),
               ctx.desk,
               Keyword.put(ctx.opts, :approve, true)
             )

    assert persisted_state(ctx.workspace) == ctx.before
    assert [refusal] = new_audit_events(ctx)
    assert_ticket_refusal(refusal, ctx, "not_authorised")
    assert refusal["reason"] == @override_denial
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "failure to audit the no-override refusal propagates the Store error atomically", ctx do
    Application.put_env(:veritas_core, :store, AuditWriteFailure)
    failure = AuditWriteFailure.failure()

    # Also expected RED until this refusal actually attempts the audit append:
    # approval_required is not an acceptable substitute for the injected error.
    assert {:error, ^failure} =
             Tickets.update_domain(ctx.workspace, ctx.ticket_id, divergent_priority(), ctx.desk, ctx.opts)

    assert persisted_state(ctx.workspace) == ctx.before
    assert new_audit_events(ctx) == []
  end

  test "explicit override control propagates the same audit failure without mutations", ctx do
    Application.put_env(:veritas_core, :store, AuditWriteFailure)
    failure = AuditWriteFailure.failure()

    assert {:error, ^failure} =
             Workflows.update_domain(
               ctx.workspace,
               ctx.ticket_id,
               explicit_override(),
               ctx.desk,
               Keyword.put(ctx.opts, :approve, true)
             )

    assert persisted_state(ctx.workspace) == ctx.before
    assert new_audit_events(ctx) == []
  end

  defp divergent_priority do
    %{"priority" => "P1", "priority_justification" => "Desk requests a different priority"}
  end

  defp explicit_override do
    Map.put(divergent_priority(), "priority_override", %{"reason" => "Explicit desk override request"})
  end

  defp persisted_state(workspace) do
    assert {:ok, snapshot} =
             Store.transaction(workspace, fn tx ->
               snapshot =
                 Map.new(@state_tables, fn table ->
                   assert {:ok, rows} =
                            Store.list(tx, table, %{where: [], order_by: [id: :asc]})

                   {table, rows}
                 end)

               {:ok, snapshot}
             end)

    snapshot
  end

  defp new_audit_events(ctx) do
    assert {:ok, events} = Audit.entries(ctx.workspace)
    events -- ctx.audit_before
  end

  defp assert_ticket_refusal(refusal, ctx, code) do
    assert refusal["subject"] == ctx.ticket_id
    assert refusal["subject_table"] == "ticket"
    assert refusal["from_state"] == "new"
    assert refusal["to_state"] == "refused"
    assert refusal["actor_type"] == "user"
    assert refusal["actor_id"] == ctx.desk.id
    assert refusal["diff"]["refusal"] == code
    assert refusal["diff"]["operation"] == "amend"
  end

  defp manual_definition do
    %{
      "name" => "Manual priority audit fixture",
      "ticket_type" => "incident",
      "description" => "Test-only intake and parked manual step; no lifecycle advancement",
      "steps" => [
        %{
          "id" => "intake",
          "name" => "Intake",
          "kind" => "intake",
          "phase" => "intake",
          "fields" => [],
          "next" => ["review"]
        },
        %{
          "id" => "review",
          "name" => "Manual review",
          "kind" => "manual",
          "phase" => "processing",
          "fields" => [],
          "next" => []
        }
      ]
    }
  end

  defp remove_memory_workspace(workspace) do
    # Preserve a shared application's supervised server and every other test's
    # namespace. A server started by this case is instead stopped by ExUnit.
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox =
          state.outbox
          |> Map.delete(workspace)
          |> Map.update(:__all__, [], fn rows ->
            Enum.reject(rows, &(&1["workspace"] == workspace))
          end)

        %{state | workspaces: Map.delete(state.workspaces, workspace), outbox: outbox}
      end)
    end

    :ok
  end
end
