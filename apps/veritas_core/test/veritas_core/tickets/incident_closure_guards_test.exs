defmodule Veritas.Core.Tickets.IncidentClosureGuardsTest.FixedZone do
  @moduledoc "Synthetic fixed-offset calendar rules for closure guards, not IANA/DST evidence."
  @behaviour Calendar.TimeZoneDatabase
  @period %{utc_offset: 0, std_offset: 0, zone_abbr: "CLOSE-TEST"}

  @impl true
  def time_zone_periods_from_wall_datetime(_wall, "Test/ClosureGuards"), do: {:ok, @period}
  def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}

  @impl true
  def time_zone_period_from_utc_iso_days(_days, "Test/ClosureGuards"), do: {:ok, @period}
  def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}
end

defmodule Veritas.Core.Tickets.IncidentClosureGuardsTest do
  @moduledoc """
  Public persisted guards for manual Incident closure with an unfinished root
  cause.

  Contract: 02-contract.md section 5 (manual closure requires restoration,
  confirmation, an actual linked Problem and durable human approval) and
  section 7.3 (desk/Incident Manager closure authority, conditional approval
  checks). Every Incident and Problem here is produced by public creation and
  transitions; the association, closure, clock effects and approval commit
  together or not at all. Closure never creates a Problem and never advances a
  Problem lifecycle.

  Root-approved reference fixtures materialize only Schema's existing ten
  Incident transition tuples and explicit enabled synthetic user rows. The
  synthetic fixed-offset provider is configuration, not timezone evidence. No
  Policy mock, no seeded history; refused closures must leave every persisted
  record byte-identical apart from the exactly-one checked refusal audit the
  policy writes for an approval denial. Root owns RED/GREEN execution.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory
  alias Veritas.Store.Surreal.Schema
  alias __MODULE__.FixedZone

  @rules_version "synthetic-closure-v1"
  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @days ~w(mon tue wed thu fri sat sun)

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = StoreCase.unique_workspace()

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspace(workspace)
        remove_memory_workspace(workspace <> "_foreign")
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    admin = Principal.new("closure_policy_admin", workspace, [:platform_admin], kind: :human)
    # The authoring principal is a desk MANAGER: `incident_class` is a
    # manager-only field (policy.ex:407, managers = service_desk_manager |
    # incident_manager), so a service_desk_agent creation with the fixture's
    # classification is refused before any closure behavior is reachable. The
    # closer stays the incident_manager, preserving the author-separation the
    # conditional-closure conflict check requires (author/requester != closer).
    creator = Principal.new("closure_desk_author", workspace, [:service_desk_manager], kind: :human)
    closer = Principal.new("closure_incident_manager", workspace, [:incident_manager], kind: :human)
    install_reference_data(workspace, [creator.id, closer.id])

    assert {:ok, draft} = Tickets.save_incident_policy(workspace, policy_document(), admin, nil)

    assert {:ok, policy} =
             Tickets.publish_incident_policy(workspace, admin, draft.policy_revision,
               Keyword.put(clock_options(), :approve, true)
             )

    assert policy.readiness.missing == []

    {:ok, workspace: workspace, creator: creator, closer: closer, policy_id: policy.active_version}
  end

  # Isolation: confirmation is the only missing closed fact when the root
  # cause is complete. A refused closure writes no audit and changes nothing.
  test "closure without the requester's confirmation is refused and preserves every record", ctx do
    journey = resolved_incident(ctx, root_cause_track: "complete")
    baseline = snapshot(ctx.workspace, journey.id)

    refusal =
      Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
        Principal.audit_actor(ctx.closer),
        closure_opts(journey, 240, 4, ctx, %{})
      )

    assert {:error, {:invalid_domain_fields, errors}} = refusal
    assert errors == %{"confirmation_evidence" => :required}

    after_refusal = snapshot(ctx.workspace, journey.id)
    assert after_refusal.ticket == baseline.ticket
    assert after_refusal.detail == baseline.detail
    assert after_refusal.response == baseline.response
    assert after_refusal.resolution == baseline.resolution
    assert after_refusal.holds == baseline.holds
    assert after_refusal.audit == baseline.audit
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # The conditional path: an open root cause needs an authorized same-Workspace
  # Problem, the human's explicit approval, and the durable approval record.
  # The association must not create or advance a second Problem.
  test "conditional closure demands durable human approval and persists the linked Problem", ctx do
    journey = resolved_incident(ctx, root_cause_track: "open")
    assert {:ok, problem} = open_problem(ctx.workspace, ctx.closer, "Closure guard fixture problem")
    problems_before = problems_in(ctx.workspace)
    selected_before = ticket_row(ctx.workspace, problem["id"])
    before = snapshot(ctx.workspace, journey.id)
    # Contract §5: the resolution cycle ends at resolution (+180), not at
    # closure; closure must preserve the already-stopped row untouched.
    assert before.resolution["stopped_at"] == at(journey, 180)

    without_approval =
      Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
        Principal.audit_actor(ctx.closer),
        closure_opts(journey, 240, 4, ctx, closure_fields(problem["id"]))
      )

    assert {:error, :approval_required} = without_approval

    refused = snapshot(ctx.workspace, journey.id)
    assert refused.ticket == before.ticket
    assert refused.detail == before.detail
    assert refused.response == before.response
    assert refused.resolution == before.resolution
    assert refused.holds == before.holds
    assert length(refused.audit) == length(before.audit) + 1
    [refusal_event] = Enum.drop(refused.audit, length(before.audit))
    assert refusal_event["to_state"] == "refused"
    assert refusal_event["actor_id"] == ctx.closer.id
    assert refusal_event["diff"]["capability"] == "ticket:write"
    assert refusal_event["diff"]["refusal"] == "approval_required"
    assert is_nil(refused.detail["closure_approval"])
    assert problems_in(ctx.workspace) == problems_before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    assert {:ok, closed} =
             Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
               Principal.audit_actor(ctx.closer),
               closure_opts(journey, 300, 4, ctx, closure_fields(problem["id"])) ++ [approve: true]
             )

    assert closed["state"] == "closed"
    assert closed["domain_revision"] == 5
    assert DateTime.compare(closed["closed_at"], at(journey, 300)) == :eq

    final = snapshot(ctx.workspace, journey.id)
    approval = final.detail["closure_approval"]
    assert approval["problem_id"] == problem["id"]
    assert approval["actor"] == %{"type" => "user", "id" => ctx.closer.id}
    assert approval["approved_at"] == DateTime.to_iso8601(at(journey, 300))
    assert approval["domain_revision"] == 5

    # Historical clocks survive closure unchanged: the response cycle stopped
    # at acknowledgement, the resolution cycle at resolution.
    assert final.response == before.response
    assert final.resolution == before.resolution
    assert final.holds == before.holds
    assert Enum.take(final.audit, length(refused.audit)) == refused.audit
    [closure_event] = Enum.drop(final.audit, length(refused.audit))
    assert closure_event["to_state"] == "closed"
    assert closure_event["diff"]["approval"]["problem_id"] == problem["id"]
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    # Closure linked the selected Problem: no extra Problem was created and
    # the selected row itself is byte-for-byte what it was before closure.
    assert problems_in(ctx.workspace) == problems_before
    assert ticket_row(ctx.workspace, problem["id"]) == selected_before
  end

  # A declared open root cause without a Problem reference is refused by name.
  test "closure names the missing Problem and mutates nothing", ctx do
    journey = resolved_incident(ctx, root_cause_track: "open")
    baseline = snapshot(ctx.workspace, journey.id)

    refusal =
      Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
        Principal.audit_actor(ctx.closer),
        closure_opts(journey, 240, 4, ctx, confirmation_only()) ++ [approve: true]
      )

    assert {:error, {:invalid_domain_fields, errors}} = refusal
    assert errors == %{"problem_id" => :required}

    after_refusal = snapshot(ctx.workspace, journey.id)
    assert after_refusal.ticket == baseline.ticket
    assert after_refusal.detail == baseline.detail
    assert after_refusal.response == baseline.response
    assert after_refusal.resolution == baseline.resolution
    assert after_refusal.holds == baseline.holds
    assert after_refusal.audit == baseline.audit
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # A reference that exists but is not a Problem is insufficient during closure.
  test "closure refuses a wrong-type reference and mutates nothing", ctx do
    journey = resolved_incident(ctx, root_cause_track: "open")
    assert {:ok, other_incident} = open_incident_row(ctx)
    wrong_target_before = ticket_row(ctx.workspace, other_incident["id"])
    baseline = snapshot(ctx.workspace, journey.id)

    refusal =
      Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
        Principal.audit_actor(ctx.closer),
        closure_opts(journey, 240, 4, ctx, closure_fields(other_incident["id"])) ++ [approve: true]
      )

    assert {:error, {:invalid_domain_fields, errors}} = refusal
    assert errors == %{"problem_id" => :invalid_reference}

    after_refusal = snapshot(ctx.workspace, journey.id)
    assert after_refusal.ticket == baseline.ticket
    assert after_refusal.detail == baseline.detail
    assert after_refusal.response == baseline.response
    assert after_refusal.resolution == baseline.resolution
    assert after_refusal.holds == baseline.holds
    assert after_refusal.audit == baseline.audit
    # The wrong-type target itself is untouched, whole row.
    assert ticket_row(ctx.workspace, other_incident["id"]) == wrong_target_before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # A real Problem in another Workspace is not an authorized association.
  # Foreign setup uses a legitimate foreign Principal; the attempted linkage
  # is still performed by the local closer.
  test "closure refuses a foreign-Workspace Problem and mutates neither Workspace", ctx do
    journey = resolved_incident(ctx, root_cause_track: "open")
    foreign = ctx.workspace <> "_foreign"
    foreign_author = Principal.new("foreign_problem_author", foreign, [:problem_manager], kind: :human)
    assert {:ok, foreign_problem} = open_problem(foreign, foreign_author, "Foreign workspace problem")
    foreign_row_before = ticket_row(foreign, foreign_problem["id"])
    foreign_audit_before = audit_events(foreign, foreign_problem["id"])
    baseline = snapshot(ctx.workspace, journey.id)

    refusal =
      Tickets.transition(ctx.workspace, journey.id, "closed", ctx.closer,
        Principal.audit_actor(ctx.closer),
        closure_opts(journey, 240, 4, ctx, closure_fields(foreign_problem["id"])) ++ [approve: true]
      )

    assert {:error, {:invalid_domain_fields, errors}} = refusal
    assert errors == %{"problem_id" => :invalid_reference}

    after_refusal = snapshot(ctx.workspace, journey.id)
    assert after_refusal.ticket == baseline.ticket
    assert after_refusal.detail == baseline.detail
    assert after_refusal.response == baseline.response
    assert after_refusal.resolution == baseline.resolution
    assert after_refusal.holds == baseline.holds
    assert after_refusal.audit == baseline.audit
    # The foreign Problem and its recorded history are byte-for-byte intact.
    assert ticket_row(foreign, foreign_problem["id"]) == foreign_row_before
    assert audit_events(foreign, foreign_problem["id"]) == foreign_audit_before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp resolved_incident(ctx, root_cause_track: track) do
    fields = %{
      "impact" => "individual", "urgency" => "medium", "severity" => "minor",
      "incident_class" => "minor", "priority_justification" => "Closure fixture derives P3",
      "assignee" => ctx.closer.id,
      "notification_evidence" => %{"reference" => "manual:closure-fixture-notice", "channel" => "email",
        "direction" => "outbound", "recipient" => "closure-fixture@example.invalid"}
    }

    assert {:ok, ticket} =
             Tickets.open(ctx.workspace, "incident",
               %{"title" => "Closure guard fixture", "domain_fields" => fields}, ctx.creator,
               Principal.audit_actor(ctx.creator), options(ctx)
             )

    assert ticket["domain_revision"] == 1
    journey = %{id: ticket["id"], opened_at: ticket["opened_at"]}

    assert {:ok, _} =
             Tickets.transition(ctx.workspace, journey.id, "acknowledged", ctx.closer,
               Principal.audit_actor(ctx.closer),
               options(ctx) ++ [expected_domain_revision: 1, transaction_time: at(journey, 60), domain_fields: %{}]
             )

    assert {:ok, _} =
             Tickets.transition(ctx.workspace, journey.id, "in_progress", ctx.closer,
               Principal.audit_actor(ctx.closer),
               options(ctx) ++ [expected_domain_revision: 2, transaction_time: at(journey, 120),
                 domain_fields: %{"track_plan" => %{"text" => "Synthetic restoration work plan"}}]
             )

    assert {:ok, _} =
             Tickets.transition(ctx.workspace, journey.id, "resolved", ctx.closer,
               Principal.audit_actor(ctx.closer),
               options(ctx) ++ [expected_domain_revision: 3, transaction_time: at(journey, 180),
                 domain_fields: %{"restore_track" => "complete",
                   "restoration_evidence" => %{"reference" => "manual:closure-fixture-restore",
                     "text" => "Service restored on the fixture"},
                   "resolution_code" => "fixed_permanently", "root_cause_track" => track}]
             )

    journey
  end

  defp open_incident_row(ctx) do
    fields = %{
      "impact" => "individual", "urgency" => "medium", "severity" => "minor",
      "incident_class" => "minor", "priority_justification" => "Wrong-type reference fixture",
      "notification_evidence" => %{"reference" => "manual:wrong-type-notice", "channel" => "email",
        "direction" => "outbound", "recipient" => "wrong-type@example.invalid"}
    }

    Tickets.open(ctx.workspace, "incident",
      %{"title" => "Wrong-type reference target", "domain_fields" => fields}, ctx.creator,
      Principal.audit_actor(ctx.creator), options(ctx)
    )
  end

  defp open_problem(workspace, principal, title) do
    Tickets.open(workspace, "problem", %{"title" => title, "description" => "Synthetic reference Problem"},
      principal, Principal.audit_actor(principal), [])
  end

  defp closure_fields(problem_id) do
    Map.put(confirmation_only(), "problem_id", problem_id)
  end

  defp confirmation_only do
    %{"confirmation_evidence" => %{"reference" => "manual:closure-fixture-confirm",
      "channel" => "email", "direction" => "inbound", "recipient" => "closure-fixture@example.invalid",
      "text" => "Requester confirmed service restoration"}}
  end

  defp closure_opts(journey, seconds, revision, ctx, fields) do
    options(ctx) ++ [expected_domain_revision: revision, transaction_time: at(journey, seconds),
      domain_fields: fields]
  end

  defp at(journey, seconds), do: DateTime.add(journey.opened_at, seconds, :second)
  defp clock_options, do: [timezone_database: FixedZone, timezone_rules_version: @rules_version]
  defp options(ctx), do: clock_options() ++ [expected_policy_version: ctx.policy_id]

  defp snapshot(workspace, ticket_id) do
    assert {:ok, result} =
             Store.transaction(workspace, fn tx ->
               assert {:ok, ticket} = Store.fetch(tx, :ticket, ticket_id)
               assert {:ok, [detail]} = Store.list(tx, :incident, %{where: [ticket_id: ticket_id]})
               assert {:ok, clocks} = Store.list(tx, :sla_clock, %{where: [ticket: ticket_id]})
               assert [response] = Enum.filter(clocks, &(&1["kind"] == "response"))
               assert [resolution] = Enum.filter(clocks, &(&1["kind"] == "resolution"))
               assert {:ok, holds} = Store.list(tx, :incident_hold_episode,
                 %{where: [clock: resolution["id"]], order_by: [episode: :asc]})
               assert {:ok, audit} = Store.list(tx, :audit_event,
                 %{where: [subject: ticket_id, subject_table: "ticket"], order_by: [sequence: :asc]})
               {:ok, %{ticket: ticket, detail: detail, response: response, resolution: resolution,
                 holds: holds, audit: audit}}
             end)

    result
  end

  # Whole-row and whole-collection reads, so preservation claims cover every
  # persisted field and no extra Problem can hide behind an id filter.
  defp ticket_row(workspace, ticket_id) do
    assert {:ok, row} = Store.transaction(workspace, fn tx -> Store.fetch(tx, :ticket, ticket_id) end)
    row
  end

  defp problems_in(workspace) do
    assert {:ok, rows} =
             Store.transaction(workspace, fn tx ->
               Store.list(tx, :ticket, %{where: [ticket_type: "problem"], order_by: [id: :asc]})
             end)

    rows
  end

  defp audit_events(workspace, ticket_id) do
    assert {:ok, events} =
             Store.transaction(workspace, fn tx ->
               Store.list(tx, :audit_event,
                 %{where: [subject: ticket_id, subject_table: "ticket"], order_by: [sequence: :asc]})
             end)

    events
  end

  defp policy_document do
    rules = for impact <- @impacts, urgency <- @urgencies,
      do: %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
    targets = Map.new(~w(P1 P2 P3 P4), fn priority ->
      {priority, %{
        "response" => %{"amount" => 1, "unit" => "hours", "basis" => "business", "calendar" => "closure_fixture"},
        "resolution" => %{"amount" => 240, "unit" => "hours", "basis" => "business", "calendar" => "closure_fixture"}
      }}
    end)
    %{"priority_rules" => rules, "sla_targets" => targets, "reopen_resolution" => "new_cycle",
      "calendars" => %{"closure_fixture" => %{"timezone" => "Test/ClosureGuards",
        "weekly" => Map.new(@days, &{&1, [["00:00", "24:00"]]}),
        "nonworking_dates" => [], "exceptions" => []}}}
  end

  defp install_reference_data(workspace, user_ids) do
    # Exact canonical lookup data and row metadata, not new transitions or
    # authority. The user rows only satisfy the real reference validator.
    transitions = Schema.incident_transitions()
    assert length(transitions) == 10
    # The transaction commits the reference rows and returns the callback's
    # own value: Memory commits, then hands back `:ok` (store/memory.ex:113-126).
    assert :ok = Store.transaction(workspace, fn tx ->
      Enum.each(transitions, fn {type, from, to} ->
        assert {:ok, _} = Store.put(tx, :ticket_transition,
          %{"id" => type <> "__" <> from <> "__" <> to, "ticket_type" => type,
            "from_state" => from, "to_state" => to, "requires_approval" => false, "sla_effect" => "none"})
      end)
      Enum.each(user_ids, fn user_id ->
        assert {:ok, _} = Store.put(tx, :user,
          %{"id" => user_id, "disabled" => false, "display_name" => "Synthetic closure principal"})
      end)
      :ok
    end)
  end

  defp remove_memory_workspace(workspace) do
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox = state.outbox |> Map.delete(workspace) |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] == workspace))
        end)
        %{state | workspaces: Map.delete(state.workspaces, workspace), outbox: outbox}
      end)
    end
    :ok
  end
end
