defmodule Veritas.Core.Tickets.IncidentHoldAccountingTest.FixedZone do
  @moduledoc "Synthetic fixed-offset calendar rules for hold accounting, not IANA/DST evidence."
  @behaviour Calendar.TimeZoneDatabase
  @period %{utc_offset: 0, std_offset: 0, zone_abbr: "HOLD-TEST"}

  @impl true
  def time_zone_periods_from_wall_datetime(_wall, "Test/HoldAccounting"), do: {:ok, @period}
  def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}

  @impl true
  def time_zone_period_from_utc_iso_days(_days, "Test/HoldAccounting"), do: {:ok, @period}
  def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}
end

defmodule Veritas.Core.Tickets.IncidentHoldAccountingTest do
  @moduledoc """
  Public persisted hold accounting with explicit synthetic calendar policy.

  Contract: 02-contract.md section 5 and docs/02's qualifying-hold cap. Every
  Incident, clock and episode is produced by public creation/transitions.
  Actual opened_at anchors the timeline; later instants are trusted host
  transaction_time options, never forged domain timestamps or prior history.

  Root-approved reference fixtures materialize only Schema's existing ten
  Incident transition tuples and one enabled user row. This does not qualify
  fresh Workspace bootstrap, authentication, real Surreal or IANA/DST rules.
  No global timezone/profile setting is changed. Root owns RED/GREEN execution.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory
  alias Veritas.Store.Surreal.Schema
  alias __MODULE__.FixedZone

  @rules_version "synthetic-hold-v1"
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
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    admin = Principal.new("hold_policy_admin", workspace, [:platform_admin], kind: :human)
    operator = Principal.new("hold_worker", workspace, [:incident_manager], kind: :human)
    install_reference_data(workspace, operator.id)

    assert {:ok, draft} = Tickets.save_incident_policy(workspace, policy_document(), admin, nil)
    assert {:ok, policy} =
             Tickets.publish_incident_policy(workspace, admin, draft.policy_revision,
               Keyword.put(clock_options(), :approve, true)
             )

    assert policy.readiness.missing == []
    assert {:ok, bindings} =
             Store.transaction(workspace, fn tx ->
               assert {:ok, version} = Store.fetch(tx, :incident_policy_version, policy.active_version)
               calendar_id = version["definition"]["calendar_versions"]["hold_fixture"]
               assert {:ok, calendar} = Store.fetch(tx, :incident_calendar_version, calendar_id)
               {:ok, %{policy: version, calendar: calendar}}
             end)

    assert bindings.calendar["timezone_rules_version"] == @rules_version
    {:ok, workspace: workspace, operator: operator, policy: bindings.policy,
     calendar: bindings.calendar}
  end

  # Discriminates clearing current_hold without accumulating the ended episode,
  # then protects against double counting or rewriting an earlier episode.
  test "eligible ended episodes accumulate once and retain completed history", ctx do
    journey = start_work(ctx)
    baseline = snapshot(ctx, journey)
    transition(ctx, journey, "on_hold", 180, 3, hold_fields(ctx, journey, "customer_wait", 180))
    held = snapshot(ctx, journey)
    assert [open_episode] = held.holds
    assert open_episode["qualified_pause_us"] == 0
    assert is_nil(open_episode["ended_at"])
    assert held.resolution["current_hold"] == open_episode["id"]
    assert held.resolution["qualified_pause_us"] == 0

    transition(ctx, journey, "in_progress", 7_380, 4, resume_fields())
    first = snapshot(ctx, journey)
    assert [first_episode] = first.holds
    assert first_episode["qualified_pause_us"] == 7_200_000_000
    assert first_episode["started_at"] == at(journey, 180)
    assert first_episode["ended_at"] == at(journey, 7_380)
    assert first_episode["evidence"] == resume_fields()["resume_evidence"]
    assert is_nil(first.resolution["current_hold"])
    assert first.resolution["qualified_pause_us"] == 7_200_000_000

    transition(ctx, journey, "on_hold", 14_400, 5,
      hold_fields(ctx, journey, "third_party_wait", 14_400)
    )
    transition(ctx, journey, "in_progress", 25_200, 6, resume_fields())
    second = snapshot(ctx, journey)
    assert [retained, second_episode] = second.holds
    assert retained == first_episode
    assert second_episode["qualified_pause_us"] == 10_800_000_000
    assert second_episode["started_at"] == at(journey, 14_400)
    assert second_episode["ended_at"] == at(journey, 25_200)
    assert second.resolution["qualified_pause_us"] == 18_000_000_000
    assert is_nil(second.resolution["current_hold"])
    assert Enum.take(second.audit, length(first.audit)) == first.audit

    correct_title(ctx, journey, 28_800, 7)
    final = snapshot(ctx, journey)
    assert final.holds == second.holds
    assert final.resolution == second.resolution
    assert final.detail["domain_revision"] == 8
    assert final.ticket["state"] == "in_progress"
    assert final.response == baseline.response
    assert_pinned(ctx, final)
    assert_audited_total(final, 8, 18_000_000_000)
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Discriminates forgetting the completed pause aggregate, or awarding all six
  # days instead of the explicit five-business-day cap in this 24x7 fixture.
  test "eligible pause is capped while the actual six-day episode remains intact", ctx do
    journey = start_work(ctx)
    transition(ctx, journey, "on_hold", 180, 3, hold_fields(ctx, journey, "customer_wait", 180))
    held = snapshot(ctx, journey)
    assert [open_episode] = held.holds
    assert DateTime.compare(open_episode["pause_cap_at"], at(journey, 432_180)) == :eq

    transition(ctx, journey, "in_progress", 518_580, 4, resume_fields())
    final = snapshot(ctx, journey)
    assert [episode] = final.holds
    assert episode["id"] == open_episode["id"]
    assert episode["started_at"] == at(journey, 180)
    assert episode["ended_at"] == at(journey, 518_580)
    assert episode["pause_cap_at"] == open_episode["pause_cap_at"]
    assert episode["qualified_pause_us"] == 432_000_000_000
    assert final.resolution["qualified_pause_us"] == 432_000_000_000
    assert is_nil(final.resolution["current_hold"])
    assert final.ticket["state"] == "in_progress"
    assert final.detail["domain_revision"] == 5
    assert_pinned(ctx, final)
    assert_audited_total(final, 5, 432_000_000_000)
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Preservation control: a generic/internal hold never earns a customer or
  # third-party pause merely because it has a positive elapsed duration.
  test "an internal-work hold awards zero pause and preserves its completed record", ctx do
    journey = start_work(ctx)
    transition(ctx, journey, "on_hold", 180, 3, hold_fields(ctx, journey, "internal_work", 180))
    held = snapshot(ctx, journey)
    assert [open_episode] = held.holds
    assert is_nil(open_episode["pause_cap_at"])

    transition(ctx, journey, "in_progress", 7_380, 4, resume_fields())
    ended = snapshot(ctx, journey)
    assert [episode] = ended.holds
    assert episode["started_at"] == at(journey, 180)
    assert episode["ended_at"] == at(journey, 7_380)
    assert episode["qualified_pause_us"] == 0
    assert ended.resolution["qualified_pause_us"] == 0
    assert is_nil(ended.resolution["current_hold"])

    correct_title(ctx, journey, 10_800, 5)
    final = snapshot(ctx, journey)
    assert final.holds == ended.holds
    assert final.resolution == ended.resolution
    assert final.detail["domain_revision"] == 6
    assert_pinned(ctx, final)
    assert_audited_total(final, 6, 0)
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp start_work(ctx) do
    fields = %{
      "impact" => "individual", "urgency" => "medium", "severity" => "minor",
      "incident_class" => "minor", "priority_justification" => "Explicit hold fixture derives P3",
      "assignee" => ctx.operator.id,
      "notification_evidence" => %{"reference" => "manual:hold-fixture-notice", "channel" => "email",
        "direction" => "outbound", "recipient" => "hold-fixture@example.invalid"}
    }

    assert {:ok, ticket} =
             Tickets.open(ctx.workspace, "incident",
               %{"title" => "Hold accounting fixture", "domain_fields" => fields}, ctx.operator,
               Principal.audit_actor(ctx.operator), options(ctx)
             )

    assert ticket["domain_revision"] == 1
    assert is_struct(ticket["opened_at"], DateTime)
    journey = %{id: ticket["id"], opened_at: ticket["opened_at"]}
    transition(ctx, journey, "acknowledged", 60, 1, %{})
    transition(ctx, journey, "in_progress", 120, 2,
      %{"track_plan" => %{"text" => "Synthetic restoration work plan"}}
    )
    initial = snapshot(ctx, journey)
    assert initial.ticket["state"] == "in_progress"
    assert initial.detail["domain_revision"] == 3
    assert initial.holds == []
    assert initial.resolution["qualified_pause_us"] == 0
    assert initial.resolution["started_at"] == at(journey, 60)
    assert initial.response["stopped_at"] == at(journey, 60)
    assert_pinned(ctx, initial)
    journey
  end

  defp transition(ctx, journey, state, seconds, revision, fields) do
    opts = options(ctx) ++ [expected_domain_revision: revision,
      transaction_time: at(journey, seconds), domain_fields: fields]
    assert {:ok, ticket} =
             Tickets.transition(ctx.workspace, journey.id, state, ctx.operator,
               Principal.audit_actor(ctx.operator), opts
             )
    assert ticket["state"] == state
    assert ticket["domain_revision"] == revision + 1
    ticket
  end

  defp correct_title(ctx, journey, seconds, revision) do
    opts = options(ctx) ++ [expected_domain_revision: revision, transaction_time: at(journey, seconds)]
    assert {:ok, ticket} =
             Tickets.update_domain(ctx.workspace, journey.id,
               %{"title" => "Unrelated hold fixture correction"}, ctx.operator, opts
             )
    assert ticket["domain_revision"] == revision + 1
  end

  defp hold_fields(ctx, journey, reason, seconds) do
    %{"hold_reason" => reason, "hold_owner_id" => ctx.operator.id,
      "expected_resume_at" => DateTime.to_iso8601(at(journey, seconds + 864_000))}
  end

  defp resume_fields do
    %{"resume_evidence" => %{"reference" => "manual:hold-fixture-cleared", "text" => "Blocker cleared"}}
  end

  defp at(journey, seconds), do: DateTime.add(journey.opened_at, seconds, :second)
  defp clock_options, do: [timezone_database: FixedZone, timezone_rules_version: @rules_version]
  defp options(ctx), do: clock_options() ++ [expected_policy_version: ctx.policy["id"]]

  defp snapshot(ctx, journey) do
    assert {:ok, result} =
             Store.transaction(ctx.workspace, fn tx ->
               assert {:ok, ticket} = Store.fetch(tx, :ticket, journey.id)
               assert {:ok, [detail]} = Store.list(tx, :incident, %{where: [ticket_id: journey.id]})
               assert {:ok, clocks} = Store.list(tx, :sla_clock, %{where: [ticket: journey.id]})
               assert [response] = Enum.filter(clocks, &(&1["kind"] == "response"))
               assert [resolution] = Enum.filter(clocks, &(&1["kind"] == "resolution"))
               assert {:ok, holds} = Store.list(tx, :incident_hold_episode,
                 %{where: [clock: resolution["id"]], order_by: [episode: :asc]})
               assert {:ok, audit} = Store.list(tx, :audit_event,
                 %{where: [subject: journey.id, subject_table: "ticket"], order_by: [sequence: :asc]})
               assert {:ok, policy} = Store.fetch(tx, :incident_policy_version, ctx.policy["id"])
               assert {:ok, calendar} = Store.fetch(tx, :incident_calendar_version, ctx.calendar["id"])
               assert {:ok, run} = Store.fetch(tx, :workflow_run, journey.id)
               {:ok, %{ticket: ticket, detail: detail, response: response, resolution: resolution,
                 holds: holds, audit: audit, policy: policy, calendar: calendar, run: run}}
             end)
    result
  end

  defp assert_pinned(ctx, state) do
    assert state.policy == ctx.policy
    assert state.calendar == ctx.calendar
    assert state.calendar["timezone_rules_version"] == @rules_version
    assert is_nil(state.run)
    for clock <- [state.response, state.resolution] do
      assert clock["policy_version"] == ctx.policy["id"]
      assert clock["calendar_version"] == ctx.calendar["id"]
      assert clock["priority"] == "P3"
    end
  end

  defp assert_audited_total(state, revision, expected_pause) do
    event = List.last(state.audit)
    assert event["diff"]["domain_revision"] == revision
    assert event["actor_id"] == "hold_worker"
    assert event["actor_type"] == "user"
    assert [resolution] = Enum.filter(event["diff"]["clocks"], &(&1["kind"] == "resolution"))
    assert resolution["qualified_pause_us"] == expected_pause
  end

  defp policy_document do
    rules = for impact <- @impacts, urgency <- @urgencies,
      do: %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
    targets = Map.new(~w(P1 P2 P3 P4), fn priority ->
      {priority, %{
        "response" => %{"amount" => 1, "unit" => "hours", "basis" => "business", "calendar" => "hold_fixture"},
        "resolution" => %{"amount" => 240, "unit" => "hours", "basis" => "business", "calendar" => "hold_fixture"}
      }}
    end)
    %{"priority_rules" => rules, "sla_targets" => targets, "reopen_resolution" => "new_cycle",
      "calendars" => %{"hold_fixture" => %{"timezone" => "Test/HoldAccounting",
        "weekly" => Map.new(@days, &{&1, [["00:00", "24:00"]]}),
        "nonworking_dates" => [], "exceptions" => []}}}
  end

  defp install_reference_data(workspace, user_id) do
    # Exact canonical lookup data and row metadata, not new transitions or
    # authority. The user row only satisfies the real reference validator.
    transitions = Schema.incident_transitions()
    assert length(transitions) == 10
    assert {:ok, _user} = Store.transaction(workspace, fn tx ->
      Enum.each(transitions, fn {type, from, to} ->
        assert {:ok, _} = Store.put(tx, :ticket_transition,
          %{"id" => type <> "__" <> from <> "__" <> to, "ticket_type" => type,
            "from_state" => from, "to_state" => to, "requires_approval" => false, "sla_effect" => "none"})
      end)
      Store.put(tx, :user, %{"id" => user_id, "disabled" => false, "display_name" => "Synthetic hold worker"})
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
