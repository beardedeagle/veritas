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

  alias Veritas.Core.Tickets

  describe "a Service Desk Agent" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Service Desk Agent"])
      %{conn: signed_in}
    end

    test "raises a Service Request from the queue", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/requests")

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
      assert html =~ ~s{phx-submit="raise_ticket"}
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
