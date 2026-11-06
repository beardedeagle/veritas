defmodule Veritas.Web.TicketQueueTest do
  @moduledoc """
  The ticket queues, tested on behaviour.

  Three claims are checked here, and each of them is a claim the product
  makes rather than a claim about the markup:

    * **each queue shows its own tickets and nobody else's.** A Service
      Request is on the Service Desk queue; a Change is not. A queue that
      showed another queue's rows would be a queue that lies about what it
      holds.

    * **the route names the queue, not the query string.** A request for
      `/requests?type=change` is answered with the Service Desk queue. The
      Workspace is the Principal's for the same reason: a link carrying
      another Workspace's name must not make the screen read it.

    * **a Problem is a filter over the Incidents queue**, not a screen of
      its own (`docs/04`). The Incidents queue holds Incidents and Problems
      together, and the Problems tab narrows it.

  The assertions are made against the rendered page and against the domain's
  own state, never against the markup alone.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.Tickets

  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in} = sign_in(conn, workspace)
    %{conn: signed_in}
  end

  describe "the Service Desk queue" do
    test "shows the Service Requests and not the other queues' tickets", %{
      conn: conn,
      workspace: workspace
    } do
      open(workspace, "service_request", "A new laptop")
      open(workspace, "change", "Upgrade the database")
      open(workspace, "vulnerability", "CVE-2026-0001")

      {:ok, view, _static} = live(conn, ~p"/requests")
      html = render(view)

      assert html =~ "A new laptop"
      refute html =~ "Upgrade the database"
      refute html =~ "CVE-2026-0001"
    end
  end

  describe "the Changes queue" do
    test "shows the Changes", %{conn: conn, workspace: workspace} do
      open(workspace, "change", "Upgrade the database")
      open(workspace, "service_request", "A new laptop")

      {:ok, view, _static} = live(conn, ~p"/changes")
      html = render(view)

      assert html =~ "Upgrade the database"
      refute html =~ "A new laptop"
    end
  end

  describe "the Security queue" do
    test "shows the Vulnerabilities", %{conn: conn, workspace: workspace} do
      open(workspace, "vulnerability", "CVE-2026-0001")
      open(workspace, "incident", "Checkout is down")

      {:ok, view, _static} = live(conn, ~p"/vulnerabilities")
      html = render(view)

      assert html =~ "CVE-2026-0001"
      refute html =~ "Checkout is down"
    end
  end

  describe "the Incidents queue" do
    test "holds the Incidents and the Problems together", %{conn: conn, workspace: workspace} do
      open(workspace, "incident", "Checkout is down")
      open(workspace, "problem", "Payments fail every Monday")

      {:ok, view, _static} = live(conn, ~p"/incidents")
      html = render(view)

      assert html =~ "Checkout is down"
      assert html =~ "Payments fail every Monday"
    end

    test "the Problems tab narrows the queue to the Problems", %{
      conn: conn,
      workspace: workspace
    } do
      open(workspace, "incident", "Checkout is down")
      open(workspace, "problem", "Payments fail every Monday")

      {:ok, view, _static} = live(conn, ~p"/incidents?filter=problem")
      html = render(view)

      assert html =~ "Payments fail every Monday"
      refute html =~ "Checkout is down"
    end

    test "a filter the queue does not have is ignored", %{conn: conn, workspace: workspace} do
      open(workspace, "incident", "Checkout is down")
      open(workspace, "change", "Upgrade the database")

      {:ok, view, _static} = live(conn, ~p"/incidents?filter=change")
      html = render(view)

      # The change is not in this queue, so the filter cannot bring it in.
      assert html =~ "Checkout is down"
      refute html =~ "Upgrade the database"
    end
  end

  describe "the route names the queue" do
    test "a query string cannot change what the screen shows", %{conn: conn, workspace: workspace} do
      open(workspace, "service_request", "A new laptop")
      open(workspace, "change", "Upgrade the database")

      {:ok, view, _static} = live(conn, ~p"/requests?type=change")
      html = render(view)

      assert html =~ "A new laptop"
      refute html =~ "Upgrade the database"
    end
  end

  describe "the Workspace is the Principal's" do
    test "a ticket in another Workspace is not shown", %{conn: conn, workspace: workspace} do
      elsewhere = unique_workspace()
      migrate(elsewhere)
      on_exit(fn -> remove_workspace(elsewhere) end)

      open(elsewhere, "service_request", "Somebody else's request")

      {:ok, view, _static} = live(conn, ~p"/requests")
      html = render(view)

      refute html =~ "Somebody else's request"
    end

    test "a query string cannot name another Workspace", %{conn: conn, workspace: workspace} do
      elsewhere = unique_workspace()
      migrate(elsewhere)
      on_exit(fn -> remove_workspace(elsewhere) end)

      open(elsewhere, "service_request", "Somebody else's request")
      open(workspace, "service_request", "Our own request")

      {:ok, view, _static} = live(conn, ~p"/requests?workspace=#{elsewhere}")
      html = render(view)

      assert html =~ "Our own request"
      refute html =~ "Somebody else's request"
    end
  end

  defp open(workspace, type, title) do
    attrs = %{"title" => title, "requester" => "u1", "priority" => "medium"}

    {:ok, ticket} = Tickets.open(workspace, type, attrs, %{type: "user", id: "u1"})

    ticket
  end
end
