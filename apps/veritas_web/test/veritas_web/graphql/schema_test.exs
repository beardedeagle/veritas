defmodule Veritas.Web.GraphQL.SchemaTest do
  @moduledoc """
  The GraphQL surface, tested on behaviour.

  `docs/00` INV-8 says the LiveView UI, the GraphQL API and the CLI are three
  surfaces over one service layer, and that every operation available in one
  is available in all three. That is a property of the code, and these tests
  are what hold it to account: a transition or an update made through GraphQL
  is asserted against **the domain's own state and the Audit Log**, never
  against the shape of the response alone.

  A GraphQL surface that returned a cheerful `state: "acknowledged"` without
  moving the ticket would pass a markup test and fail these.

  ## Reading a response

  `Absinthe.run/3` answers with the shape a GraphQL client sees: the top
  level is a map with the atoms `:data` and `:errors`, and the payload under
  `:data` uses the field names as strings. So a mutation's payload is at
  `result[:data]["openTicket"]` — not at `result["openTicket"]`.

  ## The Principal

  Every resolver calls `Veritas.Core.Policy` before it touches data
  (`docs/09` §4), and the Policy decides about the Principal the request was
  signed in as. These tests run the schema directly rather than over HTTP,
  so the Principal is put into the Absinthe context by hand — which is
  exactly what the HTTP plug does.

  The actor is the Principal. There is no `actorId` argument: a caller that
  could name the actor could act as somebody else.
  """
  use Veritas.Web.StoreCase

  alias Veritas.Core.{Audit, Tickets}
  alias Veritas.Web.GraphQL.Schema

  setup %{workspace: workspace} do
    # A Service Desk Agent may open and move an Incident — the `docs/02`
    # matrix gives the role R on both.
    %{principal: principal(workspace, roles: ["Service Desk Agent"])}
  end

  describe "opening a ticket" do
    test "the ticket exists in the domain afterwards", %{
      workspace: workspace,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   openTicket(
                     workspace: "#{workspace}"
                     ticketType: "incident"
                     title: "Checkout is down"
                     requester: "u1"
                   ) { id state ticketType title priority }
                 }
                 """,
                 principal
               )

      ticket = result[:data]["openTicket"]

      assert ticket,
             "the mutation returned no ticket; adapter: #{inspect(Veritas.Store.adapter())}; " <>
               "result: #{inspect(result)}"

      assert ticket["state"] == "new"
      assert ticket["ticketType"] == "incident"
      assert ticket["title"] == "Checkout is down"

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "new"
      assert row["title"] == "Checkout is down"
    end

    test "the opening is recorded in the Audit Log", %{workspace: workspace, principal: principal} do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   openTicket(
                     workspace: "#{workspace}"
                     ticketType: "incident"
                     title: "Checkout is down"
                     requester: "u1"
                   ) { id }
                 }
                 """,
                 principal
               )

      id = result[:data]["openTicket"]["id"]

      assert [event] = ticket_events(workspace)
      assert event["subject"] == id
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "transitioning a ticket" do
    setup %{workspace: workspace, principal: principal} do
      {:ok, result} =
        run(
          """
          mutation {
            openTicket(
              workspace: "#{workspace}"
              ticketType: "incident"
              title: "Checkout is down"
              requester: "u1"
            ) { id }
          }
          """,
          principal
        )

      %{id: result[:data]["openTicket"]["id"]}
    end

    test "a legal transition moves the ticket and extends the chain", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   transitionTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     toState: "acknowledged"
                   ) { id state }
                 }
                 """,
                 principal
               )

      assert result[:data]["transitionTicket"]["state"] == "acknowledged"

      # The domain moved the ticket. The GraphQL layer did not.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["state"] == "acknowledged"

      # And the Audit Log grew by exactly one ticket event, linked to its
      # predecessor.
      events = ticket_events(workspace)
      assert length(events) == 2
      assert Enum.at(events, 1)["prev_hash"] == Enum.at(events, 0)["hash"]
      assert Enum.at(events, 1)["from_state"] == "new"
      assert Enum.at(events, 1)["to_state"] == "acknowledged"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "the actor is the signed-in Principal, not an argument", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   transitionTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     toState: "acknowledged"
                   ) { id state }
                 }
                 """,
                 principal
               )

      assert result[:data]["transitionTicket"]["state"] == "acknowledged"

      [_, event] = ticket_events(workspace)

      # The Audit Log names the Principal that acted.
      assert event["actor_id"] == principal.id
      assert event["actor_type"] == "user"
    end

    test "an illegal transition is refused and writes nothing", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      before = ticket_events(workspace)

      assert {:ok, result} =
               run(
                 """
                 mutation {
                   transitionTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     toState: "closed"
                   ) { id state }
                 }
                 """,
                 principal
               )

      # The surface reports the refusal rather than a transition.
      assert result[:errors] != nil
      assert result[:data] == nil or result[:data]["transitionTicket"] == nil

      # And nothing was written: the ticket did not move, and the chain did
      # not grow.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["state"] == "new"

      assert length(ticket_events(workspace)) == length(before)
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a transition on a ticket that does not exist is refused", %{
      workspace: workspace,
      principal: principal
    } do
      # The Workspace already holds the Incident opened by the setup; the
      # refusal must add nothing to it.
      before = ticket_events(workspace)

      assert {:ok, result} =
               run(
                 """
                 mutation {
                   transitionTicket(
                     workspace: "#{workspace}"
                     id: "no_such_ticket"
                     toState: "acknowledged"
                   ) { id state }
                 }
                 """,
                 principal
               )

      assert result[:errors] != nil
      assert length(ticket_events(workspace)) == length(before)
    end
  end

  describe "updating a ticket" do
    setup %{workspace: workspace, principal: principal} do
      {:ok, result} =
        run(
          """
          mutation {
            openTicket(
              workspace: "#{workspace}"
              ticketType: "incident"
              title: "Checkout is down"
              requester: "u1"
            ) { id }
          }
          """,
          principal
        )

      %{id: result[:data]["openTicket"]["id"]}
    end

    test "the content changes and the ticket comes back", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     title: "Checkout is failing for every customer"
                     description: "The primary is gone"
                   ) { id title description state }
                 }
                 """,
                 principal
               )

      ticket = result[:data]["updateTicket"]

      assert ticket["title"] == "Checkout is failing for every customer"
      assert ticket["description"] == "The primary is gone"

      # The ticket did not move: the content moved, and that is all.
      assert ticket["state"] == "new"

      # The domain wrote the content. The GraphQL layer did not.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["title"] == "Checkout is failing for every customer"
      assert row["description"] == "The primary is gone"
    end

    test "a title-only update leaves the description alone", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     title: "Checkout is failing for every customer"
                   ) { id title description }
                 }
                 """,
                 principal
               )

      ticket = result[:data]["updateTicket"]

      assert ticket["title"] == "Checkout is failing for every customer"
      assert ticket["description"] == ""

      # The field the caller did not name still holds what it held.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["title"] == "Checkout is failing for every customer"
      assert row["description"] == ""
    end

    test "a description-only update leaves the title alone", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     description: "The primary is gone"
                   ) { id title description }
                 }
                 """,
                 principal
               )

      ticket = result[:data]["updateTicket"]

      assert ticket["description"] == "The primary is gone"
      assert ticket["title"] == "Checkout is down"

      # The field the caller did not name still holds what it held.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["description"] == "The primary is gone"
      assert row["title"] == "Checkout is down"
    end

    test "the change is recorded in the Audit Log", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     title: "Checkout is failing"
                   ) { id }
                 }
                 """,
                 principal
               )

      assert result[:data]["updateTicket"]["id"] == id

      [open_event, update_event] = ticket_events(workspace)

      assert update_event["subject"] == id
      assert update_event["subject_table"] == "ticket"
      assert update_event["diff"]["title"] == "Checkout is failing"

      # The ticket did not move, and the Log says so: the entry carries the
      # state the ticket already held.
      assert update_event["from_state"] == "new"
      assert update_event["to_state"] == "new"

      # The actor is the signed-in Principal, not an argument.
      assert update_event["actor_type"] == "user"
      assert update_event["actor_id"] == principal.id

      # And the chain still holds.
      assert update_event["prev_hash"] == open_event["hash"]
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "an update that changes nothing is refused", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      before = ticket_events(workspace)

      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     title: "Checkout is down"
                   ) { id title }
                 }
                 """,
                 principal
               )

      # The refusal is an answer, not a crash, and it says what was wrong.
      assert result[:errors] != nil
      assert error_message(result) =~ "changes nothing"
      assert result[:data] == nil or result[:data]["updateTicket"] == nil

      # And nothing was written: the content is as it was, and the Log did
      # not grow.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["title"] == "Checkout is down"
      assert length(ticket_events(workspace)) == length(before)
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a field the update does not own is refused by name", %{
      workspace: workspace,
      id: id,
      principal: principal
    } do
      before = ticket_events(workspace)

      # The state belongs to the workflow: `transitionTicket` moves it. This
      # mutation does not carry it, and refuses it by name rather than
      # ignoring it.
      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "#{id}"
                     state: "acknowledged"
                   ) { id state }
                 }
                 """,
                 principal
               )

      assert result[:errors] != nil
      assert error_message(result) =~ "state is not updatable"

      # The ticket did not move, and nothing was recorded.
      assert {:ok, row} = Tickets.read(workspace, id)
      assert row["state"] == "new"
      assert length(ticket_events(workspace)) == length(before)
    end

    test "an update to a ticket that does not exist is refused", %{
      workspace: workspace,
      principal: principal
    } do
      before = ticket_events(workspace)

      assert {:ok, result} =
               run(
                 """
                 mutation {
                   updateTicket(
                     workspace: "#{workspace}"
                     id: "no_such_ticket"
                     title: "Nothing to update"
                   ) { id }
                 }
                 """,
                 principal
               )

      assert result[:errors] != nil
      assert error_message(result) =~ "does not exist"
      assert length(ticket_events(workspace)) == length(before)
    end
  end

  describe "reading" do
    test "the ticket query returns the ticket", %{workspace: workspace, principal: principal} do
      ticket = open_incident(workspace)

      assert {:ok, result} =
               run(
                 """
                 query {
                   ticket(workspace: "#{workspace}", id: "#{ticket["id"]}") {
                     id state title priority
                   }
                 }
                 """,
                 principal
               )

      assert result[:data]["ticket"]["id"] == ticket["id"]
      assert result[:data]["ticket"]["state"] == "new"
    end

    test "the list query filters by type", %{workspace: workspace, principal: principal} do
      open_incident(workspace)

      assert {:ok, result} =
               run(
                 """
                 query {
                   tickets(workspace: "#{workspace}", ticketType: "incident") {
                     id state
                   }
                 }
                 """,
                 principal
               )

      assert length(result[:data]["tickets"]) == 1
      assert hd(result[:data]["tickets"])["state"] == "new"
    end

    test "the audit verification query reports an intact chain", %{
      workspace: workspace
    } do
      open_incident(workspace)

      # The Audit Log is the Auditor's and the Platform Admin's: the
      # `docs/09` §4 field-level rule keeps the Log's internals away from
      # everybody else.
      auditor = principal(workspace, roles: ["Auditor"], email: "auditor@example.test")

      assert {:ok, result} =
               run(
                 """
                 query {
                   auditVerification(workspace: "#{workspace}") { intact firstBreakIndex }
                 }
                 """,
                 auditor
               )

      assert result[:data]["auditVerification"]["intact"] == true
      assert result[:data]["auditVerification"]["firstBreakIndex"] == nil
    end
  end

  defp run(query, principal) do
    Absinthe.run(query, Schema, variables: %{}, context: %{principal: principal})
  end

  # The message a client reads, from the errors Absinthe answered with.
  #
  # A refusal is only useful if the caller can read why: the surface hands
  # back a binary, and this is that binary as the client sees it. Absinthe's
  # error entries are keyed by atoms, unlike the payload's field names.
  defp error_message(result) do
    result
    |> Map.get(:errors, [])
    |> Enum.map_join("; ", & &1[:message])
  end
end
