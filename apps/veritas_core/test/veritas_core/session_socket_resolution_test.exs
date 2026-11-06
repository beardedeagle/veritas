defmodule Veritas.Core.SessionSocketResolutionTest do
  @moduledoc """
  The non-rotating scope resolution used by a LiveView socket.

  The socket must see current authority and every session-ending condition,
  but only the HTTP path may replace credentials: it is the path that can
  deliver the replacements to the browser.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Authn
  alias Veritas.Core.{Audit, Session}
  alias Veritas.Store

  describe "resolve_scope_without_rotation/3" do
    test "returns current roles without rotating, while HTTP still rotates", %{
      workspace: workspace
    } do
      %{principal: principal, session: session} = start_session(workspace, ["Platform Admin"])
      due = DateTime.add(session.rotated_at, Session.privileged_rotation() + 60, :second)

      :ok = put_account(workspace, principal.id, %{"roles" => ["Auditor"]})
      :ok = keep_idle_session_alive(workspace, session.id, due)
      before = session_row(workspace, session.id)

      assert {:ok, resolved} =
               Session.resolve_scope_without_rotation(session.scope_token, workspace, now: due)

      assert resolved.roles == [:auditor]
      assert resolved.token == nil
      assert resolved.scope_token == nil
      assert resolved.csrf_token == nil

      after_socket = session_row(workspace, session.id)

      assert after_socket["token_digest"] == before["token_digest"]
      assert after_socket["scope_digest"] == before["scope_digest"]
      assert after_socket["csrf_digest"] == before["csrf_digest"]
      assert after_socket["roles"] == before["roles"]
      assert after_socket["rotated_at"] == before["rotated_at"]
      assert after_socket["idle_expires_at"] == DateTime.add(due, Session.idle_timeout(), :second)

      # The issued roles remain in the row, so the HTTP path still observes
      # the privilege change and performs the corpus's required rotation.
      assert {:ok, rotated} = Session.resolve(session.token, workspace, now: due)
      assert rotated.roles == [:auditor]
      assert is_binary(rotated.token)
      assert rotated.token != session.token
      assert {:error, :unknown_session} = Session.resolve(session.token, workspace, now: due)
    end

    test "a disabled account is refused, ended and audited", %{workspace: workspace} do
      %{principal: principal, session: session} = start_session(workspace)
      :ok = put_account(workspace, principal.id, %{"disabled" => true})

      assert {:error, :account_disabled} =
               Session.resolve_scope_without_rotation(session.scope_token, workspace)

      assert rows(workspace, :session) == []
      assert {:ok, :intact} = Audit.verify(workspace)

      assert Enum.any?(audit_events(workspace), fn event ->
               event["to_state"] == "refused" and event["reason"] == "the account was disabled"
             end)
    end

    test "absolute expiry is refused, ended and audited", %{workspace: workspace} do
      %{session: session} = start_session(workspace)
      expired = DateTime.add(session.absolute_expires_at, 1, :second)

      assert {:error, :session_expired} =
               Session.resolve_scope_without_rotation(session.scope_token, workspace,
                 now: expired
               )

      assert rows(workspace, :session) == []
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "idle expiry is refused, ended and audited", %{workspace: workspace} do
      %{session: session} = start_session(workspace)
      idle = DateTime.add(session.idle_expires_at, 1, :second)

      assert {:error, :session_idle_expired} =
               Session.resolve_scope_without_rotation(session.scope_token, workspace, now: idle)

      assert rows(workspace, :session) == []
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  defp start_session(workspace, roles \\ ["Service Desk Agent"]) do
    {:ok, principal} =
      Authn.create_account(
        workspace,
        %{
          email: "socket@example.test",
          display_name: "Socket User",
          roles: roles,
          password: "a-fine-passphrase-the-operator-chose-42"
        },
        actor_id: "test"
      )

    {:ok, session} = Authn.establish_session(workspace, principal)
    %{principal: principal, session: session}
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

  defp keep_idle_session_alive(workspace, session_id, now) do
    {:ok, _stored} =
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- Store.fetch(tx, :session, session_id) do
          Store.put(tx, :session, %{
            row
            | "idle_expires_at" => DateTime.add(now, Session.idle_timeout(), :second)
          })
        end
      end)

    :ok
  end

  defp session_row(workspace, session_id) do
    {:ok, row} =
      Store.transaction(workspace, fn tx -> Store.fetch(tx, :session, session_id) end)

    row
  end
end
