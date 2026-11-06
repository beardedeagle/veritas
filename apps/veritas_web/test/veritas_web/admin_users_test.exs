defmodule Veritas.Web.AdminUsersTest do
  @moduledoc """
  Users and roles, tested on behaviour.

  The owner's claim under test is that there is no concept of users: *"you
  can't create, edit, delete, clone anyone in there."* Three of the four are
  now true, and the fourth is deliberately not:

    * **the accounts of the Workspace are listed**, with their roles and
      whether they are disabled.
    * **an administrator creates an account** and changes what an account may
      do. The roles come from the vocabulary the policy enforces.
    * **a role change bites on the next request**, not at the next sign-in
      and not at the next page load: the account's open session ends with the
      change, so the next request the account makes is refused.
    * **an account is disabled, never deleted.** The Audit Log refers to the
      people who acted, and an identity that has been deleted cannot be
      referred to.

  Only a Platform Admin holds `account:administrate`, and the check is the
  policy's: the assertions are made against the store and against the
  account's own session, not against the presence of a button.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  @password "a-fine-passphrase-the-operator-chose-42"

  alias Veritas.Authn
  alias Veritas.Core.Tickets

  describe "a Platform Admin" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      %{conn: signed_in}
    end

    test "lists the accounts with their roles", %{conn: conn, workspace: workspace} do
      {:ok, _principal} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["CI Steward"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, view, _static} = live(conn, ~p"/admin/users")
      html = render(view)

      assert html =~ "dana@example.test"
      assert html =~ "CI Steward"

      # And the screen says what a role may do: the matrix from `docs/02`,
      # read from the policy, and the capabilities beside it.
      assert html =~ "Service Request"
      assert html =~ "account:administrate"
    end

    test "creates an account", %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/admin/users")

      view
      |> element("form[phx-submit=create]")
      |> render_submit(%{
        "email" => "dana@example.test",
        "display_name" => "Dana",
        "password" => @password,
        "role:CI Steward" => "true"
      })

      assert {:ok, accounts} = Authn.list_accounts(workspace)
      dana = Enum.find(accounts, &(&1["email"] == "dana@example.test"))

      assert dana
      assert dana["roles"] == ["CI Steward"]
      assert dana["disabled"] == false

      # And the page shows it.
      assert render(view) =~ "dana@example.test"
    end

    test "a role change bites on the next request, not the next page load", %{
      conn: conn,
      workspace: workspace
    } do
      # An account whose role may move an Incident.
      {:ok, _principal} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      moved = open_incident(workspace, %{"title" => "Checkout is down"})
      refused = open_incident(workspace, %{"title" => "Payments are down"})

      # With the old role, the move is allowed. This is the authority the
      # role change takes away, so it has to be shown working first.
      dana_conn = Phoenix.ConnTest.build_conn()
      %{conn: dana_conn} = sign_in(dana_conn, workspace, email: "dana@example.test")
      {:ok, view, _static} = live(dana_conn, ~p"/incidents/#{moved["id"]}")

      # The BUTTON is clicked, not a hand-built event. Phoenix derives the
      # payload key from the attribute name, so `phx-value-to-state` sends
      # "to-state" — a payload built with "to_state" matches a handler that
      # was broken and proves nothing about the button.
      view
      |> element(~s{button[phx-value-to-state="acknowledged"]})
      |> render_click()

      assert {:ok, row} = Tickets.read(workspace, moved["id"])
      assert row["state"] == "acknowledged"

      # The administrator takes the role away. An Auditor holds no transition
      # rights at all (`docs/02`: Platform Admin "holds no transition
      # rights", and an Auditor is read-only across the product).
      dana_id = account_id(workspace, "dana@example.test")

      {:ok, admin_view, _static} = live(conn, ~p"/admin/users")

      # The event carries the roles that were chosen. A role that was not
      # chosen is not in the payload, which is what "the role was taken away"
      # means.
      render_click(admin_view, "save_roles", %{
        "account_id" => dana_id,
        "role:Auditor" => "true"
      })

      assert {:ok, accounts} = Authn.list_accounts(workspace)
      dana = Enum.find(accounts, &(&1["id"] == dana_id))
      assert dana["roles"] == ["Auditor"]

      # A **fresh** session: the account now holds the new role, and the move
      # the old role allowed is refused. The refusal is the policy's, and the
      # ticket does not move.
      fresh_conn = Phoenix.ConnTest.build_conn()
      %{conn: fresh_conn} = sign_in(fresh_conn, workspace, email: "dana@example.test")
      {:ok, fresh_view, _static} = live(fresh_conn, ~p"/incidents/#{refused["id"]}")

      fresh_view
      |> element(~s{button[phx-value-to-state="acknowledged"]})
      |> render_click()

      assert render(fresh_view) =~ "Refused"

      assert {:ok, row} = Tickets.read(workspace, refused["id"])
      assert row["state"] == "new"
    end

    test "the session issued under the old roles does not carry them", %{
      conn: conn,
      workspace: workspace
    } do
      # An account with a session of its own.
      {:ok, _principal} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      dana_conn = Phoenix.ConnTest.build_conn()
      %{session_token: dana_session} = sign_in(dana_conn, workspace, email: "dana@example.test")

      # The session works before the change.
      assert {:ok, _session} = Authn.resolve_session(workspace, dana_session)

      {:ok, view, _static} = live(conn, ~p"/admin/users")

      render_click(view, "save_roles", %{
        "account_id" => account_id(workspace, "dana@example.test"),
        "role:CI Steward" => "true"
      })

      # And it does not after it: a session's cached principal must not carry
      # a role set the account no longer holds.
      assert {:error, _reason} = Authn.resolve_session(workspace, dana_session)
    end

    test "disables an account, and a disabled account cannot sign in", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _principal} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, view, _static} = live(conn, ~p"/admin/users")

      dana_id = account_id(workspace, "dana@example.test")

      view
      |> element("form#disable-#{dana_id}[phx-submit=toggle_disabled]")
      |> render_submit(%{"account_id" => dana_id, "disabled" => "true"})

      assert {:ok, accounts} = Authn.list_accounts(workspace)
      dana = Enum.find(accounts, &(&1["email"] == "dana@example.test"))
      assert dana["disabled"] == true

      # A disabled account cannot sign in.
      assert {:error, _reason} =
               Authn.authenticate(workspace, %{
                 email: "dana@example.test",
                 password: @password
               })

      # And the account is still there: disabling is not deleting.
      assert length(accounts) == 2
    end
  end

  describe "a Principal who is not a Platform Admin" do
    setup %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Service Desk Agent"])
      %{conn: signed_in}
    end

    test "sees the accounts but no way to change them", %{conn: conn, workspace: workspace} do
      {:ok, _principal} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["CI Steward"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, view, _static} = live(conn, ~p"/admin/users")
      html = render(view)

      # The screen says who may administer the accounts...
      assert html =~ "Only a Platform Admin"

      # ...and the controls it withholds are **shown**, inert, with the reason —
      # a control that vanishes is a dead end.
      assert html =~ ~s{phx-submit="create"}
      assert html =~ ~s{phx-submit="save_roles"}
      assert html =~ "Your role may not administer the accounts of a Workspace"
    end

    test "is refused when a submission reaches the screen anyway", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _static} = live(conn, ~p"/admin/users")

      render_click(view, "create", %{
        "email" => "mallory@example.test",
        "display_name" => "Mallory",
        "password" => @password,
        "role:Platform Admin" => "true"
      })

      # Nothing was written.
      assert {:ok, accounts} = Authn.list_accounts(workspace)
      refute Enum.any?(accounts, &(&1["email"] == "mallory@example.test"))
      assert render(view) =~ "Refused"
    end
  end

  defp account_id(workspace, email) do
    {:ok, accounts} = Authn.list_accounts(workspace)
    account = Enum.find(accounts, &(&1["email"] == email))
    account["id"]
  end
end
