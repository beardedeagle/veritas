defmodule Veritas.Core.Tickets.IncidentCreateAuthorizationTest do
  @moduledoc """
  Public human Incident creation and authorization-order regressions.

  Setup publishes only a workflow, never an Incident. Each intake uses the
  real Memory transaction adapter and reads committed rows independently.
  The allowed cases target the missing authorized-create branch; the refusal
  controls reject an unconditional create allow ahead of role/field checks.
  No deployment profile, production authorization or shared fixture is changed.

  This file is a tests-first candidate, not executed RED/GREEN evidence or
  real-Surreal/three-surface acceptance. Root owns isolated compilation/runs.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @state_tables [:ticket, :incident, :sla_clock, :incident_hold_episode, :workflow_run, :workflow]

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
    admin = Principal.new("create_policy_admin", workspace, [:platform_admin], kind: :human)
    requester = Principal.new("create_requester", workspace, [:requester], kind: :human)
    desk = Principal.new("create_desk", workspace, [:service_desk_agent], kind: :human)
    auditor = Principal.new("create_auditor", workspace, [:auditor], kind: :human)

    assert {:ok, workflow} = Workflows.save(workspace, nil, manual_definition(), admin)

    assert {:ok, _published} =
             Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)

    {:ok, workspace: workspace, workflow: workflow, admin: admin,
     requester: requester, desk: desk, auditor: auditor}
  end

  # Discriminates the missing authorized-create arm and a replacement that
  # permits desk creation only or requires policy/classification for drafts.
  test "a requester creates an unclassified new draft without configured policy", ctx do
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)

    assert {:ok, run} =
             Workflows.start(ctx.workspace, ctx.workflow["id"], intake(%{}), ctx.requester)

    {ticket, detail} = assert_committed_creation(ctx, run, ctx.requester, audit_before)
    assert is_nil(ticket["priority"])
    assert is_nil(detail["priority_policy_version"])
    assert is_nil(detail["impact_level"])
    assert is_nil(detail["urgency_level"])
    assert is_nil(detail["severity_level"])
    assert is_nil(detail["classification"])

    assert {:ok, view} = Tickets.read_domain(ctx.workspace, ticket["id"], ctx.requester)
    assert view.domain_revision == 1
    assert is_nil(view.domain["priority"])
    assert is_nil(view.domain["impact"])
    assert is_nil(view.domain["incident_class"])
    assert is_nil(view.policy.active_version)
  end

  # Discriminates the observed fallthrough with the original priority suite's
  # legitimate desk classification, rather than elevating its actor to admin.
  test "a desk human creates with explicit classification and configured P3 derivation", ctx do
    # Deliberate test-only operator data: all 20 cells map to P3. This is not
    # a product default; SLA targets/calendars and unrelated rules stay unset.
    rules =
      for impact <- @impacts, urgency <- @urgencies do
        %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
      end

    assert length(rules) == 20

    assert {:ok, draft} =
             Tickets.save_incident_policy(ctx.workspace, %{"priority_rules" => rules}, ctx.admin, nil)

    assert {:ok, policy} =
             Tickets.publish_incident_policy(ctx.workspace, ctx.admin, draft.policy_revision,
               approve: true
             )

    assert policy.readiness.operations.derive_priority == []
    assert is_binary(policy.active_version)
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)

    assert {:ok, run} =
             Workflows.start(ctx.workspace, ctx.workflow["id"], intake(classification()), ctx.desk)

    {ticket, detail} = assert_committed_creation(ctx, run, ctx.desk, audit_before)
    assert ticket["priority"] == "medium"
    assert detail["impact_level"] == "individual"
    assert detail["urgency_level"] == "medium"
    assert detail["severity_level"] == "minor"
    assert detail["priority_justification"] == "Explicit fixture classification derives P3"
    assert detail["priority_policy_version"] == policy.active_version

    assert {:ok, view} = Tickets.read_domain(ctx.workspace, ticket["id"], ctx.desk)
    assert view.domain_revision == 1
    assert view.domain["impact"] == "individual"
    assert view.domain["urgency"] == "medium"
    assert view.domain["severity"] == "minor"
    assert view.domain["priority"] == "P3"
    assert view.policy.active_version == policy.active_version
    assert view.workflow_revision == 1
  end

  # Discriminates an unconditional create allow placed before the create-role
  # refusal. Auditor can read the workflow but cannot create an Incident.
  test "an auditor cannot create even an unclassified draft", ctx do
    assert_refused_without_creation(ctx, ctx.auditor, %{},
      "This Principal may not create an Incident draft."
    )
  end

  # Discriminates a requester create allow moved ahead of classification gates.
  test "requester draft authority does not permit desk classification", ctx do
    assert_refused_without_creation(ctx, ctx.requester, classification(),
      "The requester cannot classify an Incident or select its priority."
    )
  end

  # Discriminates a desk create allow moved ahead of manager-only field checks.
  test "desk intake cannot set the manager-only major classification", ctx do
    assert_refused_without_creation(ctx, ctx.desk, %{"incident_class" => "major"},
      "Incident classification requires a Service Desk Manager or Incident Manager."
    )
  end

  # Discriminates a create allow bypassing the independent override authority
  # gate, even when the supplied override object is structurally valid.
  test "desk intake cannot submit a manager-only priority override", ctx do
    assert_refused_without_creation(ctx, ctx.desk,
      %{"priority_override" => %{"reason" => "Test-only unauthorized override request"}},
      "A priority override requires Service Desk Manager approval."
    )
  end

  defp assert_committed_creation(ctx, returned_run, principal, audit_before) do
    snapshot = persisted_state(ctx.workspace)
    assert [ticket] = snapshot.ticket
    assert [detail] = snapshot.incident
    assert [clock] = snapshot.sla_clock
    assert [run] = snapshot.workflow_run
    assert snapshot.incident_hold_episode == []

    assert ticket["workspace"] == ctx.workspace
    assert ticket["ticket_type"] == "incident"
    assert ticket["state"] == "new"
    assert ticket["title"] == "Create authorization fixture"
    assert ticket["requester"] == principal.id
    assert detail["ticket_id"] == ticket["id"]
    assert detail["domain_revision"] == 1
    assert clock["ticket"] == ticket["id"]
    assert clock["kind"] == "response"
    assert clock["domain_revision"] == 1
    assert clock["started_at"] == ticket["opened_at"]
    assert is_struct(ticket["opened_at"], DateTime)
    assert is_nil(clock["stopped_at"])
    assert is_nil(clock["policy_version"])
    assert is_nil(clock["calendar_version"])

    assert run == returned_run
    assert run["ticket"] == ticket["id"]
    assert run["workflow"] == ctx.workflow["id"]
    assert run["status"] == "active"
    assert run["revision"] == 1
    assert run["data"]["current_step"] == "review"
    assert run["data"]["completed_steps"] == ["intake"]
    assert [workflow] = snapshot.workflow
    assert run["definition"] == workflow["published_definition"]
    assert run["workflow_revision"] == workflow["published_revision"]

    assert {:ok, events} = Audit.entries(ctx.workspace)
    new_events = events -- audit_before
    assert length(new_events) == 2
    assert [creation] = Enum.filter(new_events, &(&1["subject_table"] == "ticket"))
    assert creation["subject"] == ticket["id"]
    assert is_nil(creation["from_state"])
    assert creation["to_state"] == "new"
    assert creation["actor_type"] == "user"
    assert creation["actor_id"] == principal.id
    assert creation["diff"]["operation"] == "create"
    assert creation["diff"]["domain_revision"] == 1
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
    {ticket, detail}
  end

  defp assert_refused_without_creation(ctx, principal, fields, expected_reason) do
    before = persisted_state(ctx.workspace)
    assert before.ticket == []
    assert before.incident == []
    assert before.sla_clock == []
    assert before.workflow_run == []
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)

    assert {:error, ^expected_reason} =
             Workflows.start(ctx.workspace, ctx.workflow["id"], intake(fields), principal)

    assert persisted_state(ctx.workspace) == before
    assert {:ok, events} = Audit.entries(ctx.workspace)
    assert [refusal] = events -- audit_before
    assert refusal["subject"] == ctx.workflow["id"]
    assert refusal["subject_table"] == "workflow"
    assert refusal["to_state"] == "refused"
    assert refusal["actor_type"] == "user"
    assert refusal["actor_id"] == principal.id
    assert refusal["reason"] == expected_reason
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
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

  defp intake(fields) do
    %{"title" => "Create authorization fixture", "domain_fields" => fields}
  end

  defp classification do
    %{
      "impact" => "individual",
      "urgency" => "medium",
      "severity" => "minor",
      "priority_justification" => "Explicit fixture classification derives P3"
    }
  end

  defp manual_definition do
    %{
      "name" => "Manual create authorization fixture",
      "ticket_type" => "incident",
      "description" => "Test-only intake and parked manual step; no lifecycle advancement",
      "steps" => [
        %{"id" => "intake", "name" => "Intake", "kind" => "intake", "phase" => "intake",
          "fields" => [], "next" => ["review"]},
        %{"id" => "review", "name" => "Manual review", "kind" => "manual", "phase" => "processing",
          "fields" => [], "next" => []}
      ]
    }
  end

  defp remove_memory_workspace(workspace) do
    # Preserve any shared supervised server and every other test's namespace.
    # ExUnit stops a server started by this case through start_supervised!/1.
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
