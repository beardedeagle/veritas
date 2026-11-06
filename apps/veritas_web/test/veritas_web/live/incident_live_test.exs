defmodule Veritas.Web.IncidentLiveTest do
  @moduledoc """
  The Incident LiveViews, tested on behaviour.

  Three claims are checked here:

    * **the view offers only what the service layer will accept.** The legal
      transitions are read from the `ticket_transition` table, so the buttons
      on the page and the transitions the service layer permits are the same
      set. A button for a transition the service layer would refuse is a
      defect, and so is a missing button for one it would accept.

    * **a click moves the ticket.** The assertions are made against the
      domain's own state and the Audit Log, not against what the page says
      afterwards. A view that re-rendered optimistically without the domain
      moving anything would pass a markup test and fail these.

    * **an edit changes the content, or it changes nothing.** The same rule:
      the row in the store and the Audit Log are what the assertions are made
      against, and a refusal is a refusal — a flash message and an untouched
      store — not a crash and not a silent no-op.

  ## Waiting for the connected render

  `live/2` returns the **static** render — the markup before the LiveView has
  mounted, which cannot know the Workspace or the Incident. The render the
  user sees is the **connected** one, and it arrives later. `render/1` waits
  for it; `has_element?/2` does not, so a selector asserted straight after
  `live/2` can inspect the static render and find nothing.

  Every test here therefore takes the connected render first and asserts on
  that. The DOM is asserted through ids and values — `phx-value-to-state`,
  `id="flash-error"`, `role="alert"` — rather than through class names, so a
  restyle cannot break a behavioural test.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.{Audit, Tickets}
  alias Veritas.Core.Test.Itil

  # A LiveView is authorised at mount, so the socket needs a signed-in
  # Principal: the connection carries the session's cookies.
  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in, principal: principal} = sign_in(conn, workspace)
    %{conn: signed_in, principal: principal}
  end

  describe "the index" do
    test "lists the Incidents in the Workspace", %{conn: conn, workspace: workspace} do
      open_incident(workspace, %{"title" => "Checkout is down"})

      {:ok, view, _static} = live(conn, ~p"/incidents?workspace=#{workspace}")
      html = render(view)

      assert html =~ "Checkout is down"
      assert html =~ "Incidents"
    end

    test "shows the state of each Incident", %{conn: conn, workspace: workspace} do
      open_incident(workspace, %{"title" => "Checkout is down"})

      {:ok, view, _static} = live(conn, ~p"/incidents?workspace=#{workspace}")
      html = render(view)

      assert html =~ "new"
    end
  end

  describe "the show view" do
    setup %{conn: conn, workspace: workspace} do
      ticket = open_incident(workspace, %{"title" => "Checkout is down"})
      {:ok, view, _static} = live(conn, ~p"/incidents/#{ticket["id"]}?workspace=#{workspace}")

      # The connected render is the one that knows the Workspace and the
      # Incident; the static render cannot.
      connected = render(view)

      %{view: view, ticket: ticket, connected: connected}
    end

    test "shows the Incident", %{connected: connected, ticket: ticket} do
      assert connected =~ "Checkout is down"
      assert connected =~ ticket["id"]
    end

    test "the view and the service layer agree on the Workspace", %{
      connected: connected,
      ticket: ticket,
      workspace: workspace
    } do
      # The view must be reading the Workspace the test migrated and opened
      # the Incident in. If it resolved a different one, it would show no
      # ticket at all, and the buttons would be missing for a reason that has
      # nothing to do with the service layer.
      assert connected =~ ticket["id"], "the view did not find the Incident"

      legal = Tickets.available_transitions(workspace, "incident", "new")

      for to_state <- legal do
        assert connected =~ ~s{phx-value-to-state="#{to_state}"},
               "the view must offer #{to_state}, which the service layer accepts"
      end
    end

    test "offers exactly the transitions the service layer will accept", %{
      connected: connected,
      workspace: workspace
    } do
      legal = Tickets.available_transitions(workspace, "incident", "new")

      assert legal == ["acknowledged", "cancelled"]

      for to_state <- legal do
        assert connected =~ ~s{phx-value-to-state="#{to_state}"},
               "the view must offer #{to_state}, which the service layer accepts"
      end

      # Every state that is not legal from here has no button. The state space
      # is the whole model, so this is exhaustive rather than a sample.
      for to_state <- Itil.state_space(), to_state not in legal do
        refute connected =~ ~s{phx-value-to-state="#{to_state}"},
               "the view must not offer #{to_state}, which the service layer refuses"
      end
    end

    test "a legal transition moves the ticket and extends the chain", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      # The BUTTON is clicked, not a hand-built event. The event a real click
      # sends carries the key Phoenix derives from the attribute name:
      # `phx-value-to-state` becomes `"to-state"`. A test that hand-builds the
      # payload with `"to_state"` matches the handler and passes while every
      # button in the product raises a FunctionClauseError.
      view
      |> element(~s{button[phx-value-to-state="acknowledged"]})
      |> render_click()

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "acknowledged"

      events = ticket_events(workspace)
      assert length(events) == 2
      assert Enum.at(events, 1)["prev_hash"] == Enum.at(events, 0)["hash"]
      assert {:ok, :intact} = Audit.verify(workspace)

      # And the view now shows the new state.
      assert render(view) =~ "acknowledged"
    end

    test "an illegal transition is refused and writes nothing", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      before = ticket_events(workspace)

      # There is no button for an illegal transition — the view does not offer
      # one — so this event has to be built by hand. It carries the same key
      # the real button would send, so the handler sees what it would see.
      render_click(view, "transition", %{"to-state" => "closed"})
      html = render(view)

      # The refusal is visible to the user, as an alert.
      assert html =~ ~s{id="flash-error"}
      assert html =~ ~s{role="alert"}
      assert html =~ "Refused"

      # And nothing was written: the ticket did not move and the chain did
      # not grow.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "new"

      assert length(ticket_events(workspace)) == length(before)
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "editing a ticket" do
    setup %{conn: conn, workspace: workspace} do
      ticket = open_incident(workspace, %{"title" => "Checkout is down"})
      {:ok, view, _static} = live(conn, ~p"/incidents/#{ticket["id"]}?workspace=#{workspace}")

      %{view: view, ticket: ticket, connected: render(view)}
    end

    test "the edit control is offered to a Principal who may write", %{connected: connected} do
      # The form carries the fields the update reads, and names the event it
      # submits. The contract between the form and the update is here in the
      # markup, where a change to it shows.
      assert connected =~ ~s{phx-submit="update"}
      assert connected =~ ~s{name="title"}
      assert connected =~ ~s{name="description"}
    end

    test "editing the title changes the ticket and the screen shows it", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      # The FORM is submitted, and the payload is the form's own: the keys
      # come from the form and the title is typed into the field the form
      # calls "title". A test that chose the keys itself would pass even when
      # the form had drifted away from the update.
      payload = form_payload(view, %{"title" => "Checkout is failing for every customer"}, ticket)

      view
      |> element(~s{form[phx-submit="update"]})
      |> render_submit(payload)

      # The row the store holds says the same thing.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == "Checkout is failing for every customer"

      # And the page shows what the store holds.
      assert render(view) =~ "Checkout is failing for every customer"
    end

    test "editing the description changes the ticket", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      payload = form_payload(view, %{"description" => "The primary is gone"}, ticket)

      view
      |> element(~s{form[phx-submit="update"]})
      |> render_submit(payload)

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["description"] == "The primary is gone"

      assert render(view) =~ "The primary is gone"
    end

    test "the Audit Log records the change, with the actor", %{
      view: view,
      ticket: ticket,
      workspace: workspace,
      principal: principal
    } do
      payload = form_payload(view, %{"title" => "Checkout is failing for every customer"}, ticket)

      view
      |> element(~s{form[phx-submit="update"]})
      |> render_submit(payload)

      assert [open_event, update_event] = ticket_events(workspace)

      assert update_event["subject"] == ticket["id"]
      assert update_event["subject_table"] == "ticket"
      assert update_event["actor_type"] == "user"
      assert update_event["actor_id"] == principal.id
      assert update_event["diff"]["title"] == "Checkout is failing for every customer"

      # The ticket did not move: the update says so, and the chain says the
      # update followed the opening.
      assert update_event["from_state"] == ticket["state"]
      assert update_event["to_state"] == ticket["state"]
      assert update_event["prev_hash"] == open_event["hash"]

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "an edit that changes nothing is refused and writes nothing", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      before = ticket_events(workspace)

      # The form submitted as it stands: the operator pressed save without
      # typing anything, so the payload is what the form already holds.
      payload = form_payload(view, %{}, ticket)

      view
      |> element(~s{form[phx-submit="update"]})
      |> render_submit(payload)

      html = render(view)

      # The refusal is visible to the user, as an alert — and it is the
      # *no change* refusal, not a denial by the policy. The words are the
      # shared vocabulary's, so this screen reads the same as the CLI and the
      # GraphQL schema read the same refusal.
      assert html =~ ~s{id="flash-error"}
      assert html =~ ~s{role="alert"}
      assert html =~ "Refused"
      assert html =~ "the update changes nothing"

      # And nothing was written: the ticket did not change and the chain did
      # not grow.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == ticket["title"]
      assert row["description"] == ticket["description"]

      assert length(ticket_events(workspace)) == length(before)
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "a Principal who may not write tickets" do
    setup %{conn: conn, workspace: workspace} do
      # A second account in the same Workspace, so the ticket is the same one
      # the Service Desk Agent above sees. The Auditor holds no R and no A on
      # any ticket type: it may read a ticket and not write one.
      %{conn: auditor_conn} =
        sign_in(conn, workspace, roles: ["Auditor"], email: "auditor@example.test")

      ticket = open_incident(workspace, %{"title" => "Checkout is down"})

      {:ok, view, _static} =
        live(auditor_conn, ~p"/incidents/#{ticket["id"]}?workspace=#{workspace}")

      %{view: view, ticket: ticket, connected: render(view)}
    end

    test "sees the control, inert, and is told why", %{connected: connected} do
      # The action is **shown** — a control that vanishes is a dead end — and
      # the screen says which role may perform it.
      assert connected =~ ~s{phx-submit="update"}
      assert connected =~ "Your role may not edit tickets of this type"
    end

    test "is refused when a submission reaches the screen anyway", %{
      view: view,
      ticket: ticket,
      workspace: workspace
    } do
      before = ticket_events(workspace)

      payload = form_payload(view, %{"title" => "Checkout is failing for every customer"}, ticket)

      view
      |> element(~s{form[phx-submit="update"]})
      |> render_submit(payload)

      # Nothing was written: the policy refused before the service layer was
      # asked.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == "Checkout is down"

      assert length(ticket_events(workspace)) == length(before)
      assert render(view) =~ "Refused"
    end
  end

  describe "navigating from the index" do
    test "the link to an Incident carries its Workspace", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = open_incident(workspace, %{"title" => "Checkout is down"})

      {:ok, view, _static} = live(conn, ~p"/incidents?workspace=#{workspace}")
      html = render(view)

      [_all, href] = Regex.run(~r/href="([^"]+)"/, html)

      # Following the link must land on the Incident, in its Workspace.
      {:ok, show, _show_static} = live(conn, href)
      show_html = render(show)

      assert show_html =~ "Checkout is down"
      assert show_html =~ ticket["id"]
    end
  end

  # The payload the browser sends when it submits the edit form: the form's
  # own field names, with `typed` carrying what the operator typed into them
  # and every other field at the value the ticket already holds.
  #
  # The keys come from the **form**, not from the test. A test that chose the
  # keys itself proved only that the update reads them: the form could have
  # drifted away from the update and the suite would still have been green,
  # which is how this screen's transition buttons stayed broken for a week
  # while every test passed.
  defp form_payload(view, typed, ticket) do
    form = view |> element(~s{form[phx-submit="update"]}) |> render()

    ~r/name="([^"]+)"/
    |> Regex.scan(form)
    |> Enum.map(fn [_match, name] -> name end)
    |> Map.new(fn name -> {name, Map.get(typed, name, ticket[name])} end)
  end
end
