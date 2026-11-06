defmodule Veritas.Web.CMDBEditingTest do
  @moduledoc """
  The CMDB, tested on what an operator can do to it.

  The claim under test is the owner's: *"we can't edit anything."* The CMDB
  is now writable — a Configuration Item can be created, edited and cloned
  from the screen — and the claims here are about the **service layer's**
  state, not about the markup:

    * **a CI Steward's edit is a CI.** The row in the store carries the new
      name, and the page shows it after a reload.
    * **a clone is a second CI, not a copy of the first.** It has its own
      identity and its own name, and it carries the source's attributes.
    * **nobody else may write.** A Service Desk Agent sees no form, and a
      submission that reaches the screen anyway is refused by the policy and
      writes nothing.

  The policy is the arbiter, not the screen: the screen asks
  `Veritas.Core.Policy` at every event, and the refusal is proved by the
  store, not by the absence of a button.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.CI

  @server_type %{
    "id" => "server",
    "name" => "server",
    "plural" => "servers",
    "required" => ["region"],
    "schema" => %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "enum" => ["eu-west-1", "us-east-1"]},
        "role" => %{"type" => "string"}
      }
    }
  }

  setup %{conn: conn, workspace: workspace} do
    {:ok, _row} = CI.register_type(workspace, @server_type)

    %{conn: conn, workspace: workspace}
  end

  describe "a CI Steward" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      %{conn: signed_in}
    end

    test "creates a Configuration Item", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/cmdb/cis")

      view
      |> element("form[phx-submit=create]")
      |> render_submit(%{
        "ci_type" => "server",
        "name" => "web-01",
        "lifecycle_state" => "active",
        "criticality" => "medium",
        "owner" => "u1",
        "attributes" => %{"region" => "eu-west-1"}
      })

      # The row exists, and it is the row the domain would have written.
      {:ok, rows} = CI.list(workspace, ci_type: "server")
      assert Enum.any?(rows, &(&1["name"] == "web-01"))

      # And the list shows it.
      assert render(view) =~ "web-01"
    end

    test "edits a Configuration Item, and the edit survives a reload", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, ci} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "web-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      {:ok, view, _static} = live(conn, ~p"/cmdb/cis/#{ci["id"]}")

      view
      |> element("form[phx-submit=update]")
      |> render_submit(%{
        "name" => "web-01-renamed",
        "lifecycle_state" => "in_maintenance",
        "criticality" => "tier1",
        "owner" => "u2"
      })

      {:ok, updated} = CI.get(workspace, ci["id"])
      assert updated["name"] == "web-01-renamed"
      assert updated["lifecycle_state"] == "in_maintenance"
      assert updated["criticality"] == "tier1"
      assert updated["owner"] == "u2"

      # The page shows what the store holds.
      assert render(view) =~ "web-01-renamed"
    end

    test "clones a Configuration Item into a second one", %{conn: conn, workspace: workspace} do
      {:ok, ci} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "web-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      {:ok, view, _static} = live(conn, ~p"/cmdb/cis/#{ci["id"]}")

      view
      |> element("form[phx-submit=clone]")
      |> render_submit(%{"name" => "web-02", "ci_type" => "server"})

      {:ok, rows} = CI.list(workspace, ci_type: "server")
      names = Enum.map(rows, & &1["name"])

      assert "web-01" in names
      assert "web-02" in names

      # The clone is a second CI with its own identity, carrying the source's
      # attributes.
      clone = Enum.find(rows, &(&1["name"] == "web-02"))
      refute clone["id"] == ci["id"]
      assert clone["attributes"]["region"] == "eu-west-1"
    end
  end

  describe "a Principal who is not a CI Steward" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Service Desk Agent"])
      %{conn: signed_in}
    end

    test "sees the form, inert, and is told why", %{conn: conn} do
      {:ok, view, _static} = live(conn, ~p"/cmdb/cis")
      html = render(view)

      # The action is **shown** — a control that vanishes is a dead end — and
      # the screen says which role may perform it.
      assert html =~ ~s{phx-submit="create"}
      assert html =~ "Your role may not write Configuration Items"
    end

    test "is refused when a submission reaches the screen anyway", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _static} = live(conn, ~p"/cmdb/cis")

      render_click(view, "create", %{
        "ci_type" => "server",
        "name" => "web-01",
        "lifecycle_state" => "active",
        "criticality" => "medium",
        "owner" => "u1",
        "attributes" => %{"region" => "eu-west-1"}
      })

      # Nothing was written: the policy refused before the service layer was
      # asked.
      {:ok, rows} = CI.list(workspace, ci_type: "server")
      assert rows == []
      assert render(view) =~ "Refused"
    end
  end
end
