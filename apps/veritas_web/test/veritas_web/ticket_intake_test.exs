defmodule Veritas.Web.TicketIntakeTest do
  @moduledoc """
  Raising a ticket from the screen, tested on behaviour.

  The owner said *"we can't edit anything"* and *"there's still no way to
  raise a ticket"*, so the claim here is that a ticket raised through the
  queue is a ticket the domain holds:

    * **the domain opened it**, not the screen — the row and the Audit Log
      entry are the ones `Veritas.Core.Tickets.open/4` writes;
    * **the role matrix decided** — a principal who may not write that type
      of ticket is refused, and nothing is written;
    * **the requester never chooses the priority.** `docs/02` says the
      service desk sets it, so the form does not offer it.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.{Audit, Principal, Tickets}
  alias Veritas.Store

  test "typed short links cover all five ticket types and preserve existing detail routes", %{
    conn: conn,
    workspace: workspace
  } do
    %{conn: signed_in, principal: principal} =
      sign_in(conn, workspace, roles: ["Platform Admin", "Incident Manager"])

    for type <- Tickets.ticket_types() do
      assert {:ok, ticket} =
               Tickets.open(
                 workspace,
                 type,
                 %{"title" => "Reference #{type}"},
                 principal,
                 Principal.audit_actor(principal),
                 []
               )

      reference = Tickets.reference(ticket)
      path = Veritas.Web.TicketQueue.path_for_type(type) <> "/" <> ticket["id"]
      assert redirected_to(get(signed_in, "/" <> reference)) == path
      {:ok, detail, _} = live(signed_in, path)
      assert has_element?(detail, ~s(a[href="/#{reference}"]), reference)
      {:ok, queue, _} = live(signed_in, Veritas.Web.TicketQueue.path_for_type(type))
      assert has_element?(queue, ~s(a[href="/#{reference}"]), reference)
      assert redirected_to(get(build_conn(), "/" <> reference)) == "/session"
      assert redirected_to(get(signed_in, "/" <> reference <> "missing")) == "/"
      other_prefix = if type == "change", do: "INC", else: "CHG"
      assert redirected_to(get(signed_in, "/" <> other_prefix <> ticket["id"])) == "/"
    end

    assert redirected_to(get(signed_in, "/cmdb")) == "/cmdb/cis"
    assert redirected_to(get(signed_in, "/unrecognised-section")) == "/"
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "a short reference cannot select another Workspace", %{conn: conn, workspace: workspace} do
    elsewhere = unique_workspace()
    migrate(elsewhere)
    on_exit(fn -> remove_workspace(elsewhere) end)
    other_principal = principal(elsewhere, roles: ["Platform Admin"])

    assert {:ok, ticket} =
             Tickets.open(
               elsewhere,
               "service_request",
               %{"title" => "Private request"},
               other_principal,
               Principal.audit_actor(other_principal),
               []
             )

    %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])

    assert redirected_to(
             get(signed_in, "/" <> Tickets.reference(ticket) <> "?workspace=" <> elsewhere)
           ) == "/"
  end

  test "a legacy Incident accepts canonical edits and preserves its original values", %{
    conn: conn,
    workspace: workspace
  } do
    %{principal: principal, conn: signed_in} =
      sign_in(conn, workspace, roles: ["Platform Admin", "Incident Manager"])

    assert {:ok, :intact} = Audit.verify(workspace)
    id = "legacy_incident"
    opened_at = DateTime.utc_now()

    assert {:ok, _} =
             Store.transaction(workspace, fn tx ->
               with {:ok, sequence} <- Store.next_sequence(tx, "ticket"),
                    {:ok, ticket} <-
                      Store.put(tx, :ticket, %{
                        "id" => id,
                        "ticket_type" => "incident",
                        "state" => "new",
                        "title" => "Legacy outage",
                        "description" => "Original report",
                        "requester" => principal.id,
                        "priority" => "medium",
                        "opened_at" => opened_at,
                        "sequence" => sequence
                      }),
                    {:ok, _} <- Store.put(tx, :incident, %{"id" => id, "ticket_id" => id}) do
                 {:ok, ticket}
               end
             end)

    assert {:ok, updated} =
             Tickets.update(
               workspace,
               id,
               %{"title" => "Mock host outage", "description" => "A realistic demonstration"},
               principal,
               Principal.audit_actor(principal),
               expected_domain_revision: nil
             )

    assert updated["id"] == id
    assert updated["state"] == "new"
    assert updated["opened_at"] == opened_at
    assert updated["domain_revision"] == 1
    assert {:ok, :intact} = Audit.verify(workspace)

    assert {:ok, view} = Tickets.read_domain(workspace, id, principal)
    assert view.domain["title"] == "Mock host outage"
    assert view.raw_legacy.ticket["priority"] == "medium"

    assert {:ok, corrected} =
             Tickets.update_domain(
               workspace,
               id,
               %{
                 "impact" => "team",
                 "urgency" => "high",
                 "severity" => "major",
                 "incident_class" => "minor",
                 "priority_justification" => "Five lab users blocked"
               },
               principal,
               expected_domain_revision: 1
             )

    assert corrected["domain_revision"] == 2
    assert {:ok, readback} = Tickets.read_domain(workspace, id, principal)
    assert readback.domain["impact"] == "team"
    assert readback.domain["urgency"] == "high"
    assert readback.raw_legacy == view.raw_legacy

    {:ok, record, _} = live(signed_in, "/incidents/#{id}")

    record
    |> form("#incident-record", %{"description" => "Edited in the populated form"})
    |> render_submit()

    assert {:ok, edited} = Tickets.read_domain(workspace, id, principal)
    assert edited.domain["description"] == "Edited in the populated form"
    assert edited.domain["impact"] == "team"
    assert edited.domain_revision == 3
    assert edited.raw_legacy == view.raw_legacy

    assert {:ok, created} =
             Tickets.open(
               workspace,
               "incident",
               %{"title" => "New mock outage"},
               principal,
               Principal.audit_actor(principal),
               []
             )

    assert created["domain_revision"] == 1
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  describe "a Service Desk Agent" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Service Desk Agent"])
      %{conn: signed_in}
    end

    test "raises a Service Request from the queue", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/requests")

      view |> element("#create-ticket") |> render_click()

      view
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "A new laptop", "description" => "For the new starter"})

      assert render(view) =~ "is open.", "the screen said: #{render(view)}"

      {:ok, rows} = Tickets.list(workspace, ticket_type: "service_request")
      ticket = Enum.find(rows, &(&1["title"] == "A new laptop"))

      assert ticket, "the ticket was not opened"
      assert ticket["requester"]
      # The lifecycle starts where the corpus says a Service Request starts.
      assert ticket["state"] == "submitted"

      # The screen shows it, and the Log has it.
      assert render(view) =~ "A new laptop"
      assert render(view) =~ "is open."

      events = audit_events(workspace)
      assert Enum.any?(events, &(&1["subject"] == ticket["id"]))
    end

    test "cannot raise a ticket of a type the role matrix does not allow", %{
      conn: conn,
      workspace: workspace
    } do
      # A Service Desk Agent may write Service Requests, not Changes.
      {:ok, view, _static} = live(conn, ~p"/changes")

      # The action is **shown**, because a control that vanishes is a dead end —
      # and it says who may perform it.
      html = render(view)
      assert has_element?(view, "#create-ticket[disabled]")
      assert html =~ "Your role may not raise tickets of this type"

      # And a submission that reaches the screen anyway is refused.
      render_click(view, "raise_ticket", %{
        "ticket_type" => "change",
        "title" => "A change nobody may ask for",
        "description" => "",
        "requester" => "u1"
      })

      {:ok, rows} = Tickets.list(workspace, ticket_type: "change")
      assert rows == []
      assert render(view) =~ "Refused"
    end
  end

  describe "a Change Manager" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Change Manager"])
      %{conn: signed_in}
    end

    test "raises a Change from the Changes queue", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/changes")

      view |> element("#create-ticket") |> render_click()

      view
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "Upgrade the database", "description" => "Saturday night"})

      {:ok, rows} = Tickets.list(workspace, ticket_type: "change")
      ticket = Enum.find(rows, &(&1["title"] == "Upgrade the database"))

      assert ticket
      # The lifecycle starts where the corpus says a Change starts.
      assert ticket["state"] == "draft"
      assert render(view) =~ "is open."
    end
  end
end
