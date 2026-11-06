defmodule Veritas.Web.AdminSurfacesTest do
  @moduledoc """
  The Admin landing page and the Audit Log, mounted.

  A route that answers is not a screen that renders: the rail sent the owner
  to a placeholder, and the placeholder answered with a page that said
  "Admin — Soon" while two Admin screens were live. These tests **mount** the
  two screens and read what they show, because that is the difference between
  a screen and a route.

  The claims under test:

    * the landing page lists the six panels `docs/04` names, and the ones that
      exist are links;
    * the panels that do not exist say so in plain words, rather than shipping
      an empty table pretending to be a panel;
    * the Audit Log shows the chain, its integrity, and the decision that was
      made — and answers a question about a past decision.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.Tickets

  @actor %{type: "user", id: "the-operator"}

  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
    %{conn: signed_in, workspace: workspace}
  end

  describe "the Admin landing page" do
    test "lists the six panels the corpus names, and links the ones that exist", %{conn: conn} do
      {:ok, view, _static} = live(conn, ~p"/admin")
      html = render(view)

      # The labels are the corpus's own (`docs/04` §Navigation Model), and the
      # page renders them as HTML — so the ampersands are escaped.
      for label <- [
            "Audit Log",
            "Plugins &amp; Capabilities",
            "Users &amp; roles",
            "Workspaces",
            "Settings",
            "Agent Console"
          ] do
        assert html =~ label, "the landing page does not name #{label}"
      end

      # The panels that exist are links.
      assert html =~ ~s{href="/audit"}
      assert html =~ ~s{href="/admin/people"}
      assert html =~ ~s{href="/agents"}

      # And the ones that do not say so, in plain words, and say what they
      # will hold.
      assert html =~ "Not built yet"
      assert html =~ "the Workspaces this host has"
    end
  end

  describe "the Audit Log" do
    test "shows the chain, its integrity, and the decision that was made", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, ticket} =
        Tickets.open(
          workspace,
          "incident",
          %{"title" => "Checkout is down", "requester" => "u1"},
          @actor
        )

      {:ok, _moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      {:ok, view, _static} = live(conn, ~p"/audit")
      html = render(view)

      # The chain verifies, and the screen says so.
      assert html =~ "The chain verifies"

      # And the decision is in it: which record, who acted, what changed.
      assert html =~ ticket["id"]
      assert html =~ "the-operator"
      assert html =~ "acknowledged"
    end

    test "answers a question about a past decision", %{conn: conn, workspace: workspace} do
      {:ok, ticket} =
        Tickets.open(
          workspace,
          "incident",
          %{"title" => "Checkout is down", "requester" => "u1"},
          @actor
        )

      {:ok, _moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      {:ok, view, _static} = live(conn, ~p"/audit")

      # A question about something that did not happen matches nothing.
      render_submit(view, "filter", %{"query" => "nobody-did-this"})

      refute render(view) =~ ticket["id"]

      # A question about what did happen finds it.
      render_submit(view, "filter", %{"query" => "the-operator"})

      assert render(view) =~ ticket["id"]
    end

    test "a role that may not read the Audit Log is shown none of it", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, ticket} =
        Tickets.open(
          workspace,
          "incident",
          %{"title" => "Checkout is down", "requester" => "u1"},
          @actor
        )

      agent_conn = Phoenix.ConnTest.build_conn()

      # Its own account: the helper signs in by email, and the administrator
      # above already holds that one.
      %{conn: agent_conn} =
        sign_in(agent_conn, workspace, roles: ["Service Desk Agent"], email: "agent@example.test")

      {:ok, view, _static} = live(agent_conn, ~p"/audit")
      html = render(view)

      refute html =~ ticket["id"]
      assert html =~ "may not read the Audit Log"
    end
  end
end
