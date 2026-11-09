defmodule Veritas.Core.Tickets.IncidentDomainIntegrationTest do
  @moduledoc """
  Public managed-Incident persistence regressions, starting with communications.

  Contract: 02-contract.md sections 3 (typed markers and host-owned facts),
  4 (atomic persistence/provenance), 7.3 (human attestation, not a send).
  The coordinated history projection is an append-only list of field/marker/
  domain_revision entries. Marker attribution and recording time are host-owned.

  Real Memory transactions and trusted desk authority are used throughout.
  Setup publishes only a manual workflow; all Incident creation is public
  Workflows.start in test bodies. These synthetic references are test marker
  data, not claims that an email was sent or a provider was contacted.
  Root owns frozen-source RED/GREEN execution and evidence review.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @tables [:ticket, :incident, :sla_clock, :incident_hold_episode, :workflow_run, :workflow]
  @parked_data ~w(current_step answers outputs approved_outputs completed_steps)

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
    admin = Principal.new("integration_workflow_admin", workspace, [:platform_admin], kind: :human)
    desk = Principal.new("integration_desk", workspace, [:service_desk_agent], kind: :human)
    assert {:ok, workflow} = Workflows.save(workspace, nil, manual_definition(), admin)

    assert {:ok, _published} =
             Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)

    {:ok, workspace: workspace, desk: desk, workflow: workflow}
  end

  # Discriminates storing only the current marker while leaving the public
  # communication history empty, or dropping host attribution from that history.
  test "a managed notification persists host-attested communication provenance", ctx do
    ticket_id = start_incident(ctx)
    before = persisted_state(ctx.workspace)
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)
    marker = notification("manual:fixture-notice-one")
    lower = DateTime.utc_now()
    updated = amend(ctx, ticket_id, %{"notification_evidence" => marker}, 1)
    upper = DateTime.utc_now()
    assert updated["domain_revision"] == 2
    assert updated["workflow_revision"] == 2

    after_state = persisted_state(ctx.workspace)
    assert [detail] = after_state.incident
    stored_marker = detail["notification_evidence"]
    assert_attested_marker(stored_marker, marker, ctx.desk.id, lower, upper)
    assert {:ok, view} = Tickets.read_domain(ctx.workspace, ticket_id, ctx.desk)
    assert view.domain["notification_evidence"] == stored_marker
    assert view.domain_revision == 2
    assert view.workflow_revision == 2

    expected = %{"field" => "notification_evidence", "marker" => stored_marker,
      "domain_revision" => 2}
    assert view.provenance["communications"] == [expected]
    assert detail["domain_provenance"]["communications"] == [expected]
    assert_parked(before, after_state, 2)
    assert after_state.ticket == before.ticket

    assert {:ok, events} = Audit.entries(ctx.workspace)
    delta = events -- audit_before
    assert length(delta) == 2
    assert [event] = Enum.filter(delta, &(&1["subject_table"] == "ticket"))
    assert event["subject"] == ticket_id
    assert event["actor_id"] == ctx.desk.id
    assert event["actor_type"] == "user"
    assert event["diff"]["operation"] == "amend"
    assert event["diff"]["domain_revision"] == 2
    assert event["diff"]["after"]["notification_evidence"] == stored_marker
    assert event["diff"]["effective_at"] == stored_marker["recorded_at"]
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Discriminates replacing the history with only the latest marker, mutating
  # its earlier entry, or appending duplicates for an unrelated content edit.
  test "replacement markers retain earlier history through unrelated managed correction", ctx do
    ticket_id = start_incident(ctx)
    before = persisted_state(ctx.workspace)
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)
    first = notification("manual:fixture-notice-first")
    second = notification("manual:fixture-notice-second")
    lower = DateTime.utc_now()
    amend(ctx, ticket_id, %{"notification_evidence" => first}, 1)
    first_state = persisted_state(ctx.workspace)
    assert [first_detail] = first_state.incident
    first_marker = first_detail["notification_evidence"]
    first_upper = DateTime.utc_now()
    assert_attested_marker(first_marker, first, ctx.desk.id, lower, first_upper)

    second_lower = DateTime.utc_now()
    amend(ctx, ticket_id, %{"notification_evidence" => second}, 2)
    second_upper = DateTime.utc_now()
    amend(ctx, ticket_id, %{"title" => "Unrelated managed content correction"}, 3)

    after_state = persisted_state(ctx.workspace)
    assert [detail] = after_state.incident
    second_marker = detail["notification_evidence"]
    assert_attested_marker(second_marker, second, ctx.desk.id, second_lower, second_upper)
    expected = [
      %{"field" => "notification_evidence", "marker" => first_marker, "domain_revision" => 2},
      %{"field" => "notification_evidence", "marker" => second_marker, "domain_revision" => 3}
    ]

    assert detail["domain_provenance"]["communications"] == expected
    assert {:ok, view} = Tickets.read_domain(ctx.workspace, ticket_id, ctx.desk)
    assert view.provenance["communications"] == expected
    assert view.domain["notification_evidence"] == second_marker
    assert view.ticket["title"] == "Unrelated managed content correction"
    assert view.domain_revision == 4
    assert view.workflow_revision == 4
    assert_parked(before, after_state, 4)
    assert {:ok, events} = Audit.entries(ctx.workspace)
    assert length(events -- audit_before) == 6
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # These controls discriminate accepting caller-owned host metadata. They
  # reach Incident.normalize/object_shape via the public managed Tickets path;
  # the expected structured validation error is not a Policy denial sentinel.
  test "a notification cannot forge its recording actor", ctx do
    assert_forged_marker_refused(ctx, "recorded_by", "forged_actor")
  end

  test "a notification cannot forge its host recording instant", ctx do
    assert_forged_marker_refused(ctx, "recorded_at", "1970-01-01T00:00:00Z")
  end

  test "a notification cannot forge its host purpose", ctx do
    assert_forged_marker_refused(ctx, "purpose", "confirmation_evidence")
  end

  defp assert_forged_marker_refused(ctx, field, forged_value) do
    ticket_id = start_incident(ctx)
    before = persisted_state(ctx.workspace)
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)
    marker = Map.put(notification("manual:fixture-forged-notice"), field, forged_value)

    assert {:error, {:invalid_domain_fields, %{"notification_evidence" => :unknown_field}}} =
             Tickets.update_domain(ctx.workspace, ticket_id, %{"notification_evidence" => marker},
               ctx.desk, expected_revision: 1, expected_domain_revision: 1
             )

    assert persisted_state(ctx.workspace) == before
    assert {:ok, audit_after} = Audit.entries(ctx.workspace)
    assert audit_after == audit_before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp start_incident(ctx) do
    assert {:ok, run} =
             Workflows.start(ctx.workspace, ctx.workflow["id"],
               %{"title" => "Communication integration fixture"}, ctx.desk
             )

    assert run["status"] == "active"
    assert run["revision"] == 1
    assert {:ok, view} = Tickets.read_domain(ctx.workspace, run["ticket"], ctx.desk)
    assert view.domain_revision == 1
    assert view.workflow_revision == 1
    assert view.provenance["communications"] == []
    run["ticket"]
  end

  defp amend(ctx, ticket_id, fields, revision) do
    assert {:ok, result} =
             Tickets.update_domain(ctx.workspace, ticket_id, fields, ctx.desk,
               expected_revision: revision, expected_domain_revision: revision
             )

    result
  end

  defp assert_attested_marker(actual, supplied, actor_id, lower, upper) do
    assert Map.take(actual, ~w(reference text channel direction recipient)) == supplied
    assert actual["purpose"] == "notification_evidence"
    assert actual["recorded_by"] == actor_id
    assert {:ok, recorded, 0} = DateTime.from_iso8601(actual["recorded_at"])
    assert DateTime.compare(recorded, lower) in [:eq, :gt]
    assert DateTime.compare(recorded, upper) in [:eq, :lt]
  end

  defp assert_parked(before, after_state, revision) do
    assert [original_run] = before.workflow_run
    assert [run] = after_state.workflow_run
    assert [detail] = after_state.incident
    assert detail["domain_revision"] == revision
    assert run["revision"] == revision
    assert run["status"] == "active"
    assert run["definition"] == original_run["definition"]
    assert run["workflow_revision"] == original_run["workflow_revision"]
    assert Map.take(run["data"], @parked_data) == Map.take(original_run["data"], @parked_data)
    assert after_state.workflow == before.workflow
    assert after_state.sla_clock == before.sla_clock
    assert after_state.incident_hold_episode == before.incident_hold_episode
  end

  defp persisted_state(workspace) do
    assert {:ok, snapshot} =
             Store.transaction(workspace, fn tx ->
               snapshot = Map.new(@tables, fn table ->
                 assert {:ok, rows} = Store.list(tx, table, %{where: [], order_by: [id: :asc]})
                 {table, rows}
               end)
               {:ok, snapshot}
             end)

    snapshot
  end

  defp notification(reference) do
    %{"reference" => reference, "text" => "Synthetic human attestation fixture",
      "channel" => "email", "direction" => "outbound",
      "recipient" => "fixture-requester@example.invalid"}
  end

  defp manual_definition do
    %{"name" => "Manual domain integration fixture", "ticket_type" => "incident",
      "steps" => [
        %{"id" => "intake", "name" => "Intake", "kind" => "intake", "phase" => "intake",
          "fields" => [], "next" => ["review"]},
        %{"id" => "review", "name" => "Review", "kind" => "manual", "phase" => "processing",
          "fields" => [], "next" => []}
      ]}
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
