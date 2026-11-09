defmodule Veritas.Web.IncidentManualJourneyTest do
  @moduledoc """
  Rendered creation, acknowledgement and work with independent persisted reads.

  The authenticated human comes from the existing HTTP sign-in helper. Only
  canonical transition lookup rows and one enabled reference user are inserted
  directly; no Incident, detail, clock, communication marker or audit history is
  seeded. This is not Workspace bootstrap or reference-user provisioning proof.

  Explicit public policy setup chooses synthetic elapsed-time targets, not
  product defaults. No timezone provider, global profile, IANA/DST behavior,
  migration, hold/resolution/closure journey or real-adapter acceptance is
  claimed. Root owns execution and preservation of actual failure evidence.
  """
  use Veritas.Web.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Veritas.Web.StoreCase, only: [sign_in: 3, unique_workspace: 0]

  alias Veritas.Core.{Audit, Principal, Tickets}
  alias Veritas.Store
  alias Veritas.Store.Memory
  alias Veritas.Store.Surreal.Schema

  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @title "Rendered manual Incident fixture"
  @notice %{
    "reference" => "manual:rendered-incident-fixture-notice",
    "channel" => "email",
    "direction" => "outbound",
    "recipient" => "fixture-requester@example.invalid"
  }

  setup %{conn: conn} do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = unique_workspace()

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

    signed_in =
      sign_in(conn, workspace,
        email: "manual-incident-operator@example.invalid",
        roles: ["Platform Admin", "Incident Manager", "Service Desk Agent"]
      )

    principal = signed_in.principal
    install_reference_data(workspace, principal.id)

    assert {:ok, draft} =
             Tickets.save_incident_policy(workspace, policy_document(), principal, nil)

    assert draft.policy_revision == 1

    assert {:ok, policy} =
             Tickets.publish_incident_policy(workspace, principal, draft.policy_revision,
               approve: true,
               expected_policy_version: nil
             )

    assert policy.policy_revision == 2
    assert is_nil(policy.draft)
    assert policy.readiness.operations.acknowledge == []
    assert {:ok, []} = Tickets.list(workspace)

    {:ok, conn: signed_in.conn, workspace: workspace, principal: principal, policy: policy}
  end

  test "rendered controls create, acknowledge and start work with durable facts, clocks and audit",
       ctx do
    {:ok, index, _} = live(ctx.conn, "/incidents")
    index |> element("#create-ticket") |> render_click()
    assert has_element?(index, "#raise-ticket")

    index
    |> form("#raise-ticket", %{
      "ticket_type" => "incident",
      "title" => @title,
      "description" => "Explicit synthetic manual journey, not an imported Incident",
      "domain_fields" => %{
        "impact" => "individual",
        "urgency" => "medium",
        "severity" => "minor",
        "incident_class" => "minor",
        "priority_justification" => "The explicit fixture matrix derives P3",
        "assignee" => ctx.principal.id,
        "notification_evidence" => @notice
      }
    })
    |> render_change()

    index |> element("#create-nav-communications") |> render_click()
    index |> form("#raise-ticket") |> render_submit()

    assert {:ok, [ticket]} = Tickets.list(ctx.workspace)
    assert ticket["title"] == @title
    id = ticket["id"]
    created = snapshot(ctx, id)

    assert created.ticket["state"] == "new"
    assert created.ticket["requester"] == ctx.principal.id
    assert created.ticket["assignee"] == ctx.principal.id
    assert created.ticket["priority"] == "medium"
    assert created.detail["domain_revision"] == 1
    assert created.detail["impact_level"] == "individual"
    assert created.detail["urgency_level"] == "medium"
    assert created.detail["severity_level"] == "minor"
    assert created.detail["classification"] == "minor"
    assert created.detail["priority_policy_version"] == ctx.policy.active_version
    assert Map.take(created.detail["notification_evidence"], Map.keys(@notice)) == @notice
    assert created.detail["notification_evidence"]["recorded_by"] == ctx.principal.id

    assert {:ok, _, _} =
             DateTime.from_iso8601(created.detail["notification_evidence"]["recorded_at"])

    assert is_nil(created.run)
    assert created.holds == []
    assert [response] = created.clocks
    assert response["kind"] == "response"
    assert response["started_at"] == created.ticket["opened_at"]
    assert is_nil(response["stopped_at"])
    assert_clock_binding(response, ctx.policy.active_version)
    assert_audit_step(created, ctx, nil, "new", "create", 1)
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    # Navigate only after confirming the destination is an actual rendered link.
    path = "/incidents/#{id}"
    assert has_element?(index, ~s(a[href="#{path}"]))
    {:ok, detail, _} = live(ctx.conn, path)

    assert has_element?(
             detail,
             ~s(#incident-transition select[name="to_state"] option[value="acknowledged"])
           )

    detail
    |> form("#incident-transition", %{"to_state" => "acknowledged"})
    |> render_submit()

    acknowledged = snapshot(ctx, id)
    assert acknowledged.ticket["state"] == "acknowledged"
    assert acknowledged.detail["domain_revision"] == 2
    assert acknowledged.detail["notification_evidence"] == created.detail["notification_evidence"]
    assert Enum.take(acknowledged.audit, length(created.audit)) == created.audit
    assert acknowledged.policy == created.policy
    assert acknowledged.holds == []
    assert is_nil(acknowledged.run)

    assert [stopped_response] = Enum.filter(acknowledged.clocks, &(&1["kind"] == "response"))
    assert [resolution] = Enum.filter(acknowledged.clocks, &(&1["kind"] == "resolution"))
    assert stopped_response["id"] == response["id"]
    assert stopped_response["started_at"] == response["started_at"]
    assert is_struct(stopped_response["stopped_at"], DateTime)
    assert DateTime.compare(stopped_response["stopped_at"], response["started_at"]) in [:eq, :gt]
    assert resolution["started_at"] == stopped_response["stopped_at"]
    assert is_nil(resolution["stopped_at"])
    assert resolution["qualified_pause_us"] == 0
    assert_clock_binding(stopped_response, ctx.policy.active_version)
    assert_clock_binding(resolution, ctx.policy.active_version)
    assert_audit_step(acknowledged, ctx, "new", "acknowledged", "transition", 2)
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    assert has_element?(
             detail,
             ~s(#incident-transition select[name="to_state"] option[value="in_progress"])
           )

    plan = %{"text" => "Investigate the fixture API, restore service, then verify recovery"}

    detail |> element("#incident-nav-response") |> render_click()

    detail
    |> form("#incident-record", %{"domain_fields" => %{"track_plan" => plan}})
    |> render_submit()

    planned = snapshot(ctx, id)
    assert planned.detail["domain_revision"] == 3
    assert planned.ticket["state"] == "acknowledged"
    assert_audit_step(planned, ctx, "acknowledged", "acknowledged", "amend", 3)

    detail
    |> form("#incident-transition", %{"to_state" => "in_progress"})
    |> render_submit()

    working = snapshot(ctx, id)
    assert working.ticket["state"] == "in_progress"
    assert working.detail["domain_revision"] == 4
    assert working.detail["track_plan"] == plan
    assert working.detail["notification_evidence"] == created.detail["notification_evidence"]

    assert working.detail["domain_provenance"]["communications"] ==
             created.detail["domain_provenance"]["communications"]

    assert working.clocks == acknowledged.clocks
    assert working.policy == created.policy
    assert working.holds == []
    assert is_nil(working.run)
    assert Enum.take(working.audit, length(acknowledged.audit)) == acknowledged.audit
    assert length(working.audit) == 4
    assert_audit_step(working, ctx, "acknowledged", "in_progress", "transition", 4)
    assert List.last(working.audit)["diff"]["after"]["track_plan"] == plan
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    # A new routed mount and an independent public read must see the saved work.
    {:ok, reloaded, _} = live(ctx.conn, path)
    html = render(reloaded)
    assert html =~ "in_progress"
    assert html =~ plan["text"]
    assert html =~ "Domain revision: 4"
    assert snapshot(ctx, id) == working
    assert {:ok, readback} = Tickets.read_domain(ctx.workspace, id, ctx.principal)
    assert readback.domain_revision == 4
    assert is_nil(readback.workflow_revision)
    assert readback.domain["priority"] == "P3"
    assert readback.domain["track_plan"] == plan
    assert readback.policy.active_version == ctx.policy.active_version
    assert readback.readiness.operations.acknowledge == []
  end

  test "creation opens as a labelled modal and cancel discards the unsaved form", ctx do
    {:ok, view, _} = live(ctx.conn, "/incidents")
    refute has_element?(view, "#raise-ticket")

    view |> element("#create-ticket", "Create Incident") |> render_click()
    assert has_element?(view, ~s(#create-ticket-modal[role="dialog"][aria-modal="true"]))
    assert has_element?(view, "#create-ticket-modal #raise-ticket")
    refute has_element?(view, "#raise-ticket details")
    refute has_element?(view, ~s(#raise-ticket input[name^="include_domain"]))
    assert has_element?(view, "#create-ticket-modal button[type=submit]", "Submit")
    assert has_element?(view, "#create-ticket-modal", "Who or what is affected")
    assert has_element?(view, "#create-ticket-modal", "Affected systems")
    assert has_element?(view, ~s(#create-nav-overview[aria-current="page"]))
    assert has_element?(view, "#create-section-priority[hidden]")

    view |> form("#raise-ticket", %{"title" => "Unsaved incident"}) |> render_change()
    view |> element("#cancel-create-ticket", "Cancel") |> render_click()
    refute has_element?(view, "#create-ticket-modal")
    assert {:ok, []} = Tickets.list(ctx.workspace)

    view |> element("#create-ticket") |> render_click()
    assert has_element?(view, ~s(#raise-ticket input[name="title"][value=""]))
  end

  test "creation sections keep one draft and cancel resets it", ctx do
    {:ok, view, _} = live(ctx.conn, "/incidents")
    view |> element("#create-ticket") |> render_click()

    view
    |> form("#raise-ticket", %{
      "title" => "Retained creation draft",
      "description" => "Draft report",
      "domain_fields" => %{
        "impact" => "team",
        "track_plan" => %{"text" => "Draft recovery plan"},
        "notification_evidence" => @notice
      }
    })
    |> render_change()

    view |> element("#create-nav-priority") |> render_click()
    assert has_element?(view, "#create-section-overview[hidden]")
    refute has_element?(view, "#create-section-priority[hidden]")

    assert has_element?(
             view,
             ~s(#create-section-priority select[name="domain_fields[impact]"] option[value="team"][selected])
           )

    view |> element("#create-nav-response") |> render_click()

    assert has_element?(
             view,
             ~s(#create-section-response textarea[name="domain_fields[track_plan][text]"]),
             "Draft recovery plan"
           )

    view |> element("#create-nav-communications") |> render_click()
    assert has_element?(view, ~s(#create-nav-communications[aria-current="page"]))

    assert has_element?(
             view,
             ~s(input[name="domain_fields[notification_evidence][reference]"][value="#{@notice["reference"]}"])
           )

    view |> element("#create-nav-overview") |> render_click()

    assert has_element?(
             view,
             ~s(#raise-ticket input[name="title"][value="Retained creation draft"])
           )

    view |> element("#cancel-create-ticket") |> render_click()
    view |> element("#create-ticket") |> render_click()
    assert has_element?(view, ~s(#create-nav-overview[aria-current="page"]))
    assert has_element?(view, ~s(#raise-ticket input[name="title"][value=""]))
    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "creation validation opens the section containing the invalid field", ctx do
    {:ok, view, _} = live(ctx.conn, "/incidents")
    view |> element("#create-ticket") |> render_click()
    view |> element("#create-nav-communications") |> render_click()

    view
    |> form("#raise-ticket", %{
      "title" => "Invalid restart time",
      "domain_fields" => %{"expected_resume_at" => "not-a-timestamp"}
    })
    |> render_submit()

    assert has_element?(view, "#create-ticket-modal [role=alert]")
    assert has_element?(view, ~s(#create-nav-hold[aria-current="page"]))
    refute has_element?(view, "#create-section-hold[hidden]")
    assert has_element?(view, ~s(#raise-ticket input[name="title"][value="Invalid restart time"]))
    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "creation and saved records share sections and retain every domain control", ctx do
    ticket = record_fixture(ctx)
    {:ok, creation, _} = live(ctx.conn, "/incidents")
    creation |> element("#create-ticket") |> render_click()
    {:ok, record, _} = live(ctx.conn, "/incidents/#{ticket["id"]}")

    for key <- ~w(overview priority ownership response communications hold resolution) do
      assert has_element?(creation, "#create-nav-#{key}")
      assert has_element?(record, "#incident-nav-#{key}")
    end

    assert has_element?(record, "#incident-nav-history")
    refute has_element?(creation, "#create-nav-history")

    controls = fn view ->
      Regex.scan(~r/name="domain_fields\[([^\]]+)\]/, render(view), capture: :all_but_first)
      |> List.flatten()
      |> Enum.frequencies()
    end

    assert map_size(controls.(creation)) == 24
    assert controls.(record) == controls.(creation)
    assert has_element?(record, ~s(#incident-nav-overview[aria-current="page"]))

    assert has_element?(
             record,
             ~s|#incident-reported-by[readonly]:not([name])[value="#{ticket["requester"]}"]|
           )
  end

  test "saved-record validation selects the matching shared section and preserves the draft",
       ctx do
    ticket = record_fixture(ctx)
    {:ok, record, _} = live(ctx.conn, "/incidents/#{ticket["id"]}")
    record |> element("#incident-nav-communications") |> render_click()

    record
    |> form("#incident-record", %{
      "description" => "Retain these unsaved notes",
      "domain_fields" => %{"expected_resume_at" => "not-a-timestamp"}
    })
    |> render_submit()

    assert has_element?(record, ~s(#incident-nav-hold[aria-current="page"]))
    refute has_element?(record, "#incident-section-hold[hidden]")

    assert has_element?(
             record,
             ~s(input[name="domain_fields[expected_resume_at]"][value="not-a-timestamp"])
           )

    assert has_element?(
             record,
             ~s(textarea[name="description"]),
             "Retain these unsaved notes"
           )

    assert {:ok, saved} = Tickets.read_domain(ctx.workspace, ticket["id"], ctx.principal)
    assert saved.domain_revision == 1
    assert saved.ticket["description"] == "Saved description"
  end

  test "saved fields stay populated across sections, cancel resets, and save changes only edited facts",
       ctx do
    ticket = record_fixture(ctx)
    before = snapshot(ctx, ticket["id"])
    {:ok, view, _} = live(ctx.conn, "/incidents/#{ticket["id"]}")

    reference = Tickets.reference(ticket)
    assert has_element?(view, "header", "Incident #{reference}")

    assert has_element?(
             view,
             ~s(#incident-reference-copy[data-reference="#{reference}"] button[type="button"][aria-label="Copy #{reference}"])
           )

    assert has_element?(view, ~s(#incident-reference-copy [role="status"][aria-live="polite"]))

    assert has_element?(
             view,
             ~s(#incident-record input[name="title"][value="Saved record fixture"])
           )

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="description"]),
             "Saved description"
           )

    assert has_element?(
             view,
             ~s(#incident-record select[name="domain_fields[impact]"] option[value="team"][selected])
           )

    assert has_element?(view, "#incident-section-response[hidden]")
    refute has_element?(view, ~s(#incident-record input[name^="include_domain"]))
    refute has_element?(view, "#incident-correction")

    view |> element("#incident-nav-response") |> render_click()
    refute has_element?(view, "#incident-section-response[hidden]")

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="domain_fields[track_plan][text]"]),
             "Saved response plan"
           )

    view |> form("#incident-record", %{"description" => "Unsaved description"}) |> render_change()
    view |> element("#incident-nav-communications") |> render_click()

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="description"]),
             "Unsaved description"
           )

    assert has_element?(
             view,
             ~s(#incident-record input[name="domain_fields[notification_evidence][reference]"][value="manual:rendered-incident-fixture-notice"])
           )

    assert snapshot(ctx, ticket["id"]) == before

    view |> element("#cancel-incident-record") |> render_click()

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="description"]),
             "Saved description"
           )

    assert has_element?(view, "#save-incident-record[disabled]")

    view
    |> form("#incident-record", %{"description" => "Persisted revised description"})
    |> render_submit()

    after_save = snapshot(ctx, ticket["id"])
    assert after_save.ticket["description"] == "Persisted revised description"
    assert after_save.ticket["requester"] == before.ticket["requester"]
    assert after_save.ticket["state"] == before.ticket["state"]
    assert after_save.detail["domain_revision"] == 2
    assert after_save.detail["notification_evidence"] == before.detail["notification_evidence"]

    assert after_save.detail["domain_provenance"]["communications"] ==
             before.detail["domain_provenance"]["communications"]

    assert after_save.clocks == before.clocks
    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    {:ok, reloaded, _} = live(ctx.conn, "/incidents/#{ticket["id"]}")

    assert has_element?(
             reloaded,
             ~s(#incident-record textarea[name="description"]),
             "Persisted revised description"
           )
  end

  test "a stale record save retains the draft and requires an explicit reload", ctx do
    ticket = record_fixture(ctx)
    {:ok, view, _} = live(ctx.conn, "/incidents/#{ticket["id"]}")

    assert {:ok, _} =
             Tickets.update_domain(
               ctx.workspace,
               ticket["id"],
               %{"description" => "A concurrent saved edit"},
               ctx.principal,
               expected_domain_revision: 1
             )

    view |> form("#incident-record", %{"description" => "My unsaved draft"}) |> render_submit()
    assert render(view) =~ "domain_revision_conflict"

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="description"]),
             "My unsaved draft"
           )

    assert {:ok, saved} = Tickets.read(ctx.workspace, ticket["id"])
    assert saved["description"] == "A concurrent saved edit"
    view |> element("#cancel-incident-record") |> render_click()

    assert has_element?(
             view,
             ~s(#incident-record textarea[name="description"]),
             "A concurrent saved edit"
           )
  end

  test "a forged record save from an Auditor is refused and audited", ctx do
    ticket = record_fixture(ctx)

    signed_in =
      sign_in(ctx.conn, ctx.workspace,
        email: "record-auditor@example.invalid",
        roles: ["Auditor"]
      )

    {:ok, view, _} = live(signed_in.conn, "/incidents/#{ticket["id"]}")
    assert ticket["requester"] != signed_in.principal.id

    assert has_element?(
             view,
             ~s(#incident-reported-by[readonly][value="#{ticket["requester"]}"])
           )

    render_submit(view, "save-record", %{"domain_fields" => "not-an-object"})
    assert render(view) =~ "invalid_request"
    render_submit(view, "save-record", %{"title" => "Forbidden replacement"})
    assert {:ok, saved} = Tickets.read(ctx.workspace, ticket["id"])
    assert saved["title"] == ticket["title"]
    assert {:ok, events} = Audit.entries(ctx.workspace)
    assert List.last(events)["to_state"] == "refused"
  end

  defp record_fixture(ctx) do
    assert {:ok, ticket} =
             Tickets.open(
               ctx.workspace,
               "incident",
               %{
                 "title" => "Saved record fixture",
                 "description" => "Saved description",
                 "domain_fields" => %{
                   "impact" => "team",
                   "urgency" => "high",
                   "severity" => "major",
                   "incident_class" => "minor",
                   "priority_justification" => "Fixture team blocked",
                   "assignee" => ctx.principal.id,
                   "notification_evidence" => @notice,
                   "track_plan" => %{"text" => "Saved response plan"}
                 }
               },
               ctx.principal,
               Principal.audit_actor(ctx.principal),
               []
             )

    ticket
  end

  test "a refused submission keeps the modal values and a successful retry closes it", ctx do
    {:ok, view, _} = live(ctx.conn, "/incidents")
    view |> element("#create-ticket") |> render_click()
    view |> element("#create-nav-communications") |> render_click()

    view
    |> form("#raise-ticket", %{"title" => "", "description" => "Keep these incident notes"})
    |> render_submit()

    assert has_element?(view, "#create-ticket-modal [role=alert]")
    assert has_element?(view, ~s(#create-nav-overview[aria-current="page"]))

    assert has_element?(
             view,
             ~s(#raise-ticket textarea[name="description"]),
             "Keep these incident notes"
           )

    assert {:ok, []} = Tickets.list(ctx.workspace)

    view
    |> form("#raise-ticket", %{
      "title" => "Recovered incident",
      "description" => "Keep these incident notes"
    })
    |> render_submit()

    refute has_element?(view, "#create-ticket-modal")
    assert {:ok, [ticket]} = Tickets.list(ctx.workspace)
    assert ticket["title"] == "Recovered incident"
    assert ticket["description"] == "Keep these incident notes"
  end

  test "a requester can open the modal and report an incident without classification", ctx do
    signed_in =
      sign_in(ctx.conn, ctx.workspace, email: "requester@example.invalid", roles: ["Requester"])

    {:ok, view, _} = live(signed_in.conn, "/incidents")

    view |> element("#create-ticket") |> render_click()
    view |> form("#raise-ticket", %{"title" => "Requester report"}) |> render_submit()

    refute has_element?(view, "#create-ticket-modal")
    assert {:ok, [ticket]} = Tickets.list(ctx.workspace)
    assert ticket["requester"] == signed_in.principal.id
  end

  test "a read-only user cannot open creation or persist a forged submission", ctx do
    signed_in =
      sign_in(ctx.conn, ctx.workspace, email: "auditor@example.invalid", roles: ["Auditor"])

    assert {:ok, before} = Audit.entries(ctx.workspace)
    {:ok, view, _} = live(signed_in.conn, "/incidents")
    assert has_element?(view, "#create-ticket[disabled]")

    render_click(view, "open-create")
    refute has_element?(view, "#create-ticket-modal")
    assert {:ok, ^before} = Audit.entries(ctx.workspace)

    render_click(view, "raise_ticket", %{"title" => "Forged report"})
    assert {:ok, []} = Tickets.list(ctx.workspace)
    assert {:ok, events} = Audit.entries(ctx.workspace)
    assert List.last(events)["to_state"] == "refused"
  end

  defp snapshot(ctx, id) do
    assert {:ok, result} =
             Store.transaction(ctx.workspace, fn tx ->
               assert {:ok, ticket} = Store.fetch(tx, :ticket, id)
               assert {:ok, [detail]} = Store.list(tx, :incident, %{where: [ticket_id: id]})

               assert {:ok, clocks} =
                        Store.list(tx, :sla_clock, %{where: [ticket: id], order_by: [kind: :asc]})

               assert {:ok, holds} = Store.list(tx, :incident_hold_episode, %{where: []})

               assert {:ok, audit} =
                        Store.list(tx, :audit_event, %{
                          where: [subject: id, subject_table: "ticket"],
                          order_by: [sequence: :asc]
                        })

               assert {:ok, policy} =
                        Store.fetch(tx, :incident_policy_version, ctx.policy.active_version)

               assert {:ok, run} = Store.fetch(tx, :workflow_run, id)

               {:ok,
                %{
                  ticket: ticket,
                  detail: detail,
                  clocks: clocks,
                  holds: holds,
                  audit: audit,
                  policy: policy,
                  run: run
                }}
             end)

    result
  end

  defp assert_clock_binding(clock, policy_version) do
    assert clock["policy_version"] == policy_version
    assert clock["priority"] == "P3"
    assert is_nil(clock["calendar_version"])
    assert clock["history_complete"] == true
  end

  defp assert_audit_step(state, ctx, from, to, operation, revision) do
    event = List.last(state.audit)
    assert event["from_state"] == from
    assert event["to_state"] == to
    assert event["actor_type"] == "user"
    assert event["actor_id"] == ctx.principal.id
    assert event["diff"]["operation"] == operation
    assert event["diff"]["domain_revision"] == revision
    assert event["diff"]["policy_version"] == ctx.policy.active_version
  end

  defp policy_document do
    rules =
      for impact <- @impacts, urgency <- @urgencies do
        %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
      end

    targets =
      Map.new(~w(P1 P2 P3 P4), fn priority ->
        {priority,
         %{
           "response" => %{"amount" => 60, "unit" => "minutes", "basis" => "elapsed"},
           "resolution" => %{"amount" => 240, "unit" => "minutes", "basis" => "elapsed"}
         }}
      end)

    %{"priority_rules" => rules, "sla_targets" => targets, "reopen_resolution" => "new_cycle"}
  end

  defp install_reference_data(workspace, user_id) do
    transitions = Schema.incident_transitions()
    assert length(transitions) == 10

    assert {:ok, _} =
             Store.transaction(workspace, fn tx ->
               Enum.each(transitions, fn {type, from, to} ->
                 assert {:ok, _} =
                          Store.put(tx, :ticket_transition, %{
                            "id" => type <> "__" <> from <> "__" <> to,
                            "ticket_type" => type,
                            "from_state" => from,
                            "to_state" => to,
                            "requires_approval" => false,
                            "sla_effect" => "none"
                          })
               end)

               assert {:ok, user} = Store.fetch(tx, :user, user_id)

               Store.put(
                 tx,
                 :user,
                 Map.merge(user, %{
                   "disabled" => false,
                   "display_name" => "Synthetic manual-journey reference user"
                 })
               )
             end)
  end

  defp remove_memory_workspace(workspace) do
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
