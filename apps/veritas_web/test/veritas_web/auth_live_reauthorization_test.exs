defmodule Veritas.Web.AuthLiveReauthorizationTest do
  @moduledoc """
  LiveView re-authorisation against the real session and account domain.

  A mounted socket is deliberately kept alive while the authority underneath
  it changes. The next event or navigation must use the current session, not
  the Principal that happened to be cached at mount.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Authn
  alias Veritas.Core.Session
  alias Veritas.Store

  @password "a-fine-passphrase-the-operator-chose-42"

  describe "an already-mounted administrator" do
    test "cannot act after the ordinary session revocation path", %{
      conn: conn,
      workspace: workspace
    } do
      %{view: view, session_token: session_token} = mount_admin(conn, workspace)

      :ok = Authn.revoke_session(workspace, session_token)
      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session_token)

      result = submit_create(view, "revoked@example.test")

      refute account?(workspace, "revoked@example.test")
      assert {:error, {:redirect, %{to: "/session"}}} = result
    end

    test "cannot act after the account is disabled", %{conn: conn, workspace: workspace} do
      %{view: view, principal: principal} = mount_admin(conn, workspace)

      {:ok, _account} =
        Authn.update_account(workspace, principal.id, %{"disabled" => true}, actor_id: "test")

      assert {:error, {:redirect, %{to: "/session"}}} =
               submit_create(view, "disabled@example.test")

      refute account?(workspace, "disabled@example.test")
    end

    test "a role downgrade is enforced on the very next event", %{
      conn: conn,
      workspace: workspace
    } do
      %{view: view, principal: principal} = mount_admin(conn, workspace)

      # Change authority without taking the session-revocation shortcut: this
      # pins the resolver's promise to return the account's CURRENT roles.
      :ok = put_account(workspace, principal.id, %{"roles" => ["Auditor"]})

      html = submit_create(view, "downgraded@example.test")

      assert html =~ "Refused"
      refute account?(workspace, "downgraded@example.test")
    end

    test "navigation is refused after revocation", %{conn: conn, workspace: workspace} do
      %{conn: conn, session_token: session_token} =
        sign_in(conn, workspace, roles: ["Platform Admin"])

      {:ok, view, _static} = live(conn, ~p"/incidents")
      :ok = Authn.revoke_session(workspace, session_token)

      assert {:error, {:redirect, %{to: "/session"}}} =
               render_patch(view, "/incidents?filter=problem")
    end

    test "a due privileged rotation does not strand the browser or the socket", %{
      conn: conn,
      workspace: workspace
    } do
      %{view: view, session_token: session_token} = mount_admin(conn, workspace)
      :ok = force_privileged_rotation(workspace, session_token)
      before = session_row(workspace, session_token)

      assert is_binary(submit_create(view, "due-rotation@example.test"))
      assert account?(workspace, "due-rotation@example.test")

      after_socket = session_row(workspace, session_token)
      assert after_socket["token_digest"] == before["token_digest"]
      assert after_socket["scope_digest"] == before["scope_digest"]
      assert after_socket["csrf_digest"] == before["csrf_digest"]
      assert after_socket["rotated_at"] == before["rotated_at"]

      # The HTTP resolver still performs the timed rotation and returns the
      # replacement credential it can deliver in its response.
      assert {:ok, rotated} = Authn.resolve_session(workspace, session_token)
      assert is_binary(rotated.token)
      assert rotated.token != session_token
      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session_token)
    end
  end

  defp mount_admin(conn, workspace) do
    %{conn: conn, principal: principal, session_token: session_token} =
      sign_in(conn, workspace, roles: ["Platform Admin"])

    {:ok, view, _static} = live(conn, ~p"/admin/users")
    %{view: view, principal: principal, session_token: session_token}
  end

  defp submit_create(view, email) do
    view
    |> element("form[phx-submit=create]")
    |> render_submit(%{
      "email" => email,
      "display_name" => "Socket Test",
      "password" => @password,
      "role:CI Steward" => "true"
    })
  end

  defp account?(workspace, email) do
    {:ok, accounts} = Authn.list_accounts(workspace)
    Enum.any?(accounts, &(&1["email"] == email))
  end

  defp put_account(workspace, account_id, attrs) do
    {:ok, _stored} =
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- Store.fetch(tx, :user, account_id) do
          Store.put(tx, :user, Map.merge(row, attrs))
        end
      end)

    :ok
  end

  defp force_privileged_rotation(workspace, token) do
    row = session_row(workspace, token)
    now = row["last_seen_at"]

    {:ok, _stored} =
      Store.transaction(workspace, fn tx ->
        Store.put(tx, :session, %{
          row
          | "rotated_at" => DateTime.add(now, -(Session.privileged_rotation() + 60), :second),
            "idle_expires_at" => DateTime.add(now, Session.idle_timeout(), :second)
        })
      end)

    :ok
  end

  defp session_row(workspace, token) do
    {:ok, [%{"id" => id}]} =
      Store.transaction(workspace, fn tx ->
        Store.list(tx, :session, %{where: [token_digest: Session.digest(token)], limit: 1})
      end)

    {:ok, row} = Store.transaction(workspace, fn tx -> Store.fetch(tx, :session, id) end)
    row
  end
end
