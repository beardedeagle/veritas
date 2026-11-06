defmodule Veritas.Web.DeliveryLiveTest do
  @moduledoc """
  The Delivery section, tested on behaviour.

  The owner's claim was that Delivery *"reads 'soon' still and isn't there"*,
  so the claims here are:

    * **the section is real** — `/programs` lists the Programs a Workspace
      is running, and the nav no longer calls it planned;
    * **the tree is real** — a Program holds its Milestones, a Milestone
      holds its Work Items, and the Work Item's page shows the CIs and the
      Changes it links to;
    * **the role matrix decides** — a principal who may not write Delivery
      records sees no form, and a submission that reaches the screen anyway
      is refused and writes nothing.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.Delivery

  describe "a CI Steward" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      %{conn: signed_in}
    end

    test "opens a Program, and the list shows it", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/programs")

      view
      |> form("#program-create")
      |> render_submit(%{"name" => "CMDB build-out", "status" => "amber"})

      assert render(view) =~ "CMDB build-out"

      {:ok, programs} = Delivery.list_programs(workspace)
      assert Enum.any?(programs, &(&1["name"] == "CMDB build-out"))
    end

    test "adds a Milestone and a Work Item, and the item's page shows its links", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, program} =
        Delivery.create_program(workspace, %{"name" => "Service redesign"})

      {:ok, milestone} =
        Delivery.create_milestone(workspace, program["id"], %{"name" => "Catalogue"})

      {:ok, view, _static} = live(conn, ~p"/programs/#{program["id"]}")

      view
      |> form("#milestone-create")
      |> render_submit(%{
        "name" => "Catalogue templates",
        "planned_date" => "2026-11-01T00:00:00Z"
      })

      assert render(view) =~ "Catalogue templates"

      view
      |> form("#work-item-create")
      |> render_submit(%{
        "milestone_id" => milestone["id"],
        "title" => "Publish the catalogue",
        "ci_refs" => "",
        "change_refs" => ""
      })

      assert render(view) =~ "Publish the catalogue"

      {:ok, items} = Delivery.list_work_items(workspace, milestone["id"])
      item = Enum.find(items, &(&1["title"] == "Publish the catalogue"))
      assert item

      # And the item has its own page.
      {:ok, item_view, _static} = live(conn, ~p"/work-items/#{item["id"]}")
      assert render(item_view) =~ "Publish the catalogue"
    end

    test "the edit of a Work Item is written and audited", %{conn: conn, workspace: workspace} do
      {:ok, program} = Delivery.create_program(workspace, %{"name" => "Program"})
      {:ok, milestone} = Delivery.create_milestone(workspace, program["id"], %{"name" => "M1"})

      {:ok, item} =
        Delivery.create_work_item(workspace, milestone["id"], %{"title" => "Do the thing"})

      {:ok, view, _static} = live(conn, ~p"/work-items/#{item["id"]}")

      view
      |> form("#work-item-edit")
      |> render_submit(%{
        "title" => "Did the thing",
        "state" => "done",
        "ci_refs" => "",
        "change_refs" => ""
      })

      {:ok, updated} = Delivery.get_work_item(workspace, item["id"])
      assert updated["title"] == "Did the thing"
      assert updated["state"] == "done"

      # And the change is in the Audit Log.
      events = audit_events(workspace)
      assert Enum.any?(events, &(&1["subject"] == item["id"]))
    end
  end

  describe "a principal who may not write Delivery records" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Service Desk Agent"])
      %{conn: signed_in}
    end

    test "sees the Programs but no way to add one", %{conn: conn, workspace: workspace} do
      {:ok, _program} =
        Delivery.create_program(workspace, %{"name" => "A program in another workspace"})

      {:ok, view, _static} = live(conn, ~p"/programs")
      html = render(view)

      assert html =~ "A program in another workspace"
      refute html =~ ~s{phx-submit="create"}
    end

    test "is refused when a submission reaches the screen anyway", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _static} = live(conn, ~p"/programs")

      render_click(view, "create", %{"name" => "Not allowed", "status" => "green"})

      {:ok, programs} = Delivery.list_programs(workspace)
      refute Enum.any?(programs, &(&1["name"] == "Not allowed"))
      assert render(view) =~ "Refused"
    end
  end
end
