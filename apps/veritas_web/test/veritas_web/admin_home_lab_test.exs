defmodule Veritas.Web.AdminHomeLabTest do
  @moduledoc """
  The admin actions, in the home-lab profile.

  The owner's complaint was *"I have permissions to do almost nothing as the
  platform admin"* and *"Ask the estate. What the fuck does that mean?"*. This
  file is the proof that **one operator can run the product**: a Platform
  Admin, in the home-lab profile, creates and edits a Configuration Item,
  raises a ticket and moves it to closed, authorises a Change, accepts a
  Vulnerability's risk, closes a Problem, changes a role and disables an
  account — and each of those decisions says in the Audit Log that the
  home-lab profile was in force, because "whose decision was this?" has to be
  answerable from the running system.

  The **enterprise** profile is the same account with the separation of duty
  in force, and it is refused the authorisations that rule owns — with a
  refusal that names the rule.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.{CI, Principal, Tickets}

  @password "a-fine-passphrase-the-operator-chose-42"

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
    # The home-lab profile is the default, and the test says so rather than
    # assuming it.
    Application.put_env(:veritas_core, :deployment_profile, :home_lab)

    on_exit(fn -> Application.delete_env(:veritas_core, :deployment_profile) end)

    {:ok, _row} = CI.register_type(workspace, @server_type)

    %{conn: signed_in, principal: principal} =
      sign_in(conn, workspace, roles: ["Platform Admin"])

    %{conn: signed_in, principal: principal, workspace: workspace}
  end

  describe "a Platform Admin in the home-lab profile" do
    test "runs the whole product alone", %{
      conn: conn,
      principal: principal,
      workspace: workspace
    } do
      # ── a Configuration Item, created and edited ──
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

      {:ok, rows} = CI.list(workspace, ci_type: "server")
      ci = Enum.find(rows, &(&1["name"] == "web-01"))
      assert ci, "the Configuration Item was not created"

      {:ok, ci_view, _static} = live(conn, ~p"/cmdb/cis/#{ci["id"]}")

      ci_view
      |> element("form[phx-submit=update]")
      |> render_submit(%{
        "name" => "web-01-renamed",
        "lifecycle_state" => "in_maintenance",
        "criticality" => "tier1",
        "owner" => "u2"
      })

      {:ok, updated} = CI.get(workspace, ci["id"])
      assert updated["name"] == "web-01-renamed"

      # ── a ticket, raised and moved to closed ──
      {:ok, queue, _static} = live(conn, ~p"/incidents")

      queue
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "Checkout is down", "description" => "Nobody can pay"})

      {:ok, tickets} = Tickets.list(workspace, ticket_type: "incident")
      incident = Enum.find(tickets, &(&1["title"] == "Checkout is down"))
      assert incident, "the ticket was not raised"

      {:ok, show, _static} = live(conn, ~p"/incidents/#{incident["id"]}")

      for to_state <- ["acknowledged", "in_progress", "resolved", "closed"] do
        # The BUTTON is clicked, not a hand-built event: Phoenix derives the
        # payload key from the attribute name, so `phx-value-to-state` sends
        # "to-state" and not "to_state".
        show
        |> element(~s{button[phx-value-to-state="#{to_state}"]})
        |> render_click()
      end

      {:ok, moved} = Tickets.read(workspace, incident["id"])
      assert moved["state"] == "closed", "the ticket did not reach closed"

      # ── a Change, authorised by the operator who raised it ──
      {:ok, changes, _static} = live(conn, ~p"/changes")

      changes
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "Upgrade the database", "description" => "Saturday night"})

      {:ok, change_rows} = Tickets.list(workspace, ticket_type: "change")
      change = Enum.find(change_rows, &(&1["title"] == "Upgrade the database"))
      assert change

      {:ok, change_show, _static} = live(conn, ~p"/changes/#{change["id"]}")

      change_show
      |> element(~s{button[phx-value-to-state="submitted"]})
      |> render_click()

      change_show
      |> element(~s{button[phx-value-to-state="authorized"]})
      |> render_click()

      {:ok, authorised} = Tickets.read(workspace, change["id"])
      assert authorised["state"] == "authorized", "the Change was not authorised"

      # ── a Vulnerability's risk, accepted ──
      {:ok, vulnerabilities, _static} = live(conn, ~p"/vulnerabilities")

      vulnerabilities
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "CVE-2026-0001", "description" => "A serious one"})

      {:ok, vulnerability_rows} = Tickets.list(workspace, ticket_type: "vulnerability")
      vulnerability = Enum.find(vulnerability_rows, &(&1["title"] == "CVE-2026-0001"))
      assert vulnerability

      {:ok, vulnerability_show, _static} = live(conn, ~p"/vulnerabilities/#{vulnerability["id"]}")

      vulnerability_show
      |> element(~s{button[phx-value-to-state="triaged"]})
      |> render_click()

      vulnerability_show
      |> element(~s{button[phx-value-to-state="accepted_risk"]})
      |> render_click()

      {:ok, accepted} = Tickets.read(workspace, vulnerability["id"])
      assert accepted["state"] == "accepted_risk", "the risk was not accepted"

      # ── a Problem, closed ──
      # Problems are a filter over the Incidents queue (`docs/04`), so the
      # record is opened by the domain and closed by the same screen every
      # other ticket is closed on.
      {:ok, problem} =
        Tickets.open(
          workspace,
          "problem",
          %{"title" => "Checkout keeps failing", "requester" => principal.id},
          Principal.audit_actor(principal)
        )

      {:ok, problem_show, _static} = live(conn, ~p"/incidents/#{problem["id"]}")

      for to_state <- ["under_investigation", "identified", "root_caused", "closed"] do
        problem_show
        |> element(~s{button[phx-value-to-state="#{to_state}"]})
        |> render_click()
      end

      {:ok, closed} = Tickets.read(workspace, problem["id"])
      assert closed["state"] == "closed", "the Problem was not closed"

      # ── a role, changed, and an account, disabled ──
      {:ok, _account} =
        Veritas.Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, users, _static} = live(conn, ~p"/admin/users")
      dana_id = account_id(workspace, "dana@example.test")

      render_click(users, "save_roles", %{"account_id" => dana_id, "role:Auditor" => "true"})

      {:ok, accounts} = Veritas.Authn.list_accounts(workspace)
      dana = Enum.find(accounts, &(&1["id"] == dana_id))
      assert dana["roles"] == ["Auditor"]

      users
      |> element("form#disable-#{dana_id}[phx-submit=toggle_disabled]")
      |> render_submit(%{"account_id" => dana_id, "disabled" => "true"})

      {:ok, accounts} = Veritas.Authn.list_accounts(workspace)
      dana = Enum.find(accounts, &(&1["id"] == dana_id))
      assert dana["disabled"] == true

      # ── and every decision the operator made alone says which profile it
      # was made under ──
      events = audit_events(workspace)

      for subject <- [change["id"], vulnerability["id"], problem["id"]] do
        event =
          Enum.find(events, fn event ->
            event["subject"] == subject and
              event["to_state"] in [
                "authorized",
                "accepted_risk",
                "closed"
              ]
          end)

        assert event, "no event was written for #{subject}"
        assert event["diff"]["profile"] == "home lab"

        # The rule that did not bind is named, so a later reader knows the
        # decision was one operator's and under which profile.
        assert event["diff"]["separation_of_duty"] =~ "home-lab profile"
      end
    end
  end

  describe "the same account in the enterprise profile" do
    setup %{conn: conn, workspace: workspace} do
      Application.put_env(:veritas_core, :deployment_profile, :enterprise)

      on_exit(fn -> Application.delete_env(:veritas_core, :deployment_profile) end)

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      %{conn: signed_in, workspace: workspace}
    end

    test "is refused the authorisations the separation of duty owns", %{
      conn: conn,
      workspace: workspace
    } do
      # The enterprise profile keeps the corpus's role matrix: a Platform
      # Admin configures policy and holds no transition rights. The refusal
      # says which rule it is enforcing, so the screen is not a dead end.
      {:ok, changes, _static} = live(conn, ~p"/changes")

      changes
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "Upgrade the database", "description" => "Saturday night"})

      {:ok, rows} = Tickets.list(workspace, ticket_type: "change")
      assert rows == [], "the Platform Admin raised a Change the matrix forbids"

      html = render(changes)
      assert html =~ "Refused"
      assert html =~ "role matrix"
      assert html =~ "does not hold authority"
    end

    test "a role that may authorise is still refused its own record", %{
      conn: _conn,
      workspace: workspace
    } do
      # The separation of duty is the enterprise profile's: the approver is
      # distinct from the requester. A CAB Chair may authorise a Change; it
      # may not authorise one it requested itself.
      chair_conn = Phoenix.ConnTest.build_conn()

      %{conn: chair_conn} =
        sign_in(chair_conn, workspace, roles: ["CAB Chair"], email: "chair@example.test")

      {:ok, changes, _static} = live(chair_conn, ~p"/changes")

      changes
      |> form("#raise-ticket")
      |> render_submit(%{"title" => "Upgrade the database", "description" => "Saturday night"})

      {:ok, rows} = Tickets.list(workspace, ticket_type: "change")
      change = Enum.find(rows, &(&1["title"] == "Upgrade the database"))
      assert change

      {:ok, show, _static} = live(chair_conn, ~p"/changes/#{change["id"]}")

      # The first move is not an authorisation, and it is allowed.
      show
      |> element(~s{button[phx-value-to-state="submitted"]})
      |> render_click()

      {:ok, submitted} = Tickets.read(workspace, change["id"])
      assert submitted["state"] == "submitted"

      # The authorisation is the one that demands a second actor.
      show
      |> element(~s{button[phx-value-to-state="authorized"]})
      |> render_click()

      html = render(show)
      assert html =~ "Refused"
      assert html =~ "separation of duty"

      {:ok, unchanged} = Tickets.read(workspace, change["id"])
      assert unchanged["state"] == "submitted", "the Change was authorised by its own requester"
    end
  end

  defp account_id(workspace, email) do
    {:ok, accounts} = Veritas.Authn.list_accounts(workspace)
    account = Enum.find(accounts, &(&1["email"] == email))
    account["id"]
  end
end
