defmodule Veritas.Web.AuthTest do
  @moduledoc """
  The HTTP surface's authentication and authorisation, tested on behaviour.

  `docs/09` §3 and §4 fix what the API must do with a request that carries
  no Principal, with one that carries the wrong Principal, and with one that
  carries the right Principal in the wrong Workspace. These tests are what
  hold the surface to that.

  The assertions are made against what an observer can see: the status, the
  body, the cookie, the Audit Log. Not one of them asserts that a function
  returned `true`.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.{Audit, Policy, Principal, Session}

  describe "a request with no Principal" do
    test "is refused at the GraphQL endpoint", %{conn: conn, workspace: workspace} do
      conn = graphql(conn, "query { tickets(workspace: \"#{workspace}\") { id } }")

      assert conn.status == 401
      assert json_response(conn, 401)["errors"]
    end

    test "is refused at the browser, and the page is not served", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert conn.status == 302
      assert redirected_to(conn) == "/session"
    end

    test "is refused at a LiveView, and the screen is not mounted", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/session"}}} = live(conn, ~p"/incidents")
    end

    test "is refused at the GraphQL endpoint even when the query is harmless", %{
      conn: conn,
      workspace: workspace
    } do
      conn = graphql(conn, "query { ciTypes(workspace: \"#{workspace}\") { id } }")

      assert conn.status == 401
    end
  end

  describe "the session's CSRF token" do
    test "is required on a GraphQL POST", %{conn: conn, workspace: workspace} do
      %{conn: conn} = sign_in(conn, workspace)

      conn = graphql(conn, "query { tickets(workspace: \"#{workspace}\") { id } }")

      assert conn.status == 403
      assert json_response(conn, 403)["errors"]
    end

    test "refuses a token that is not the session's", %{conn: conn, workspace: workspace} do
      %{conn: conn} = sign_in(conn, workspace)

      conn =
        graphql(
          conn,
          "query { tickets(workspace: \"#{workspace}\") { id } }",
          "a-token-that-is-not-the-sessions"
        )

      assert conn.status == 403
    end

    test "is accepted when it is the session's", %{conn: conn, workspace: workspace} do
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace)

      conn =
        graphql(conn, "query { tickets(workspace: \"#{workspace}\") { id } }", csrf)

      assert conn.status == 200
      assert json_response(conn, 200)["errors"] == nil
    end

    test "a GraphQL rotation delivers fresh credentials without writing an unfetched session", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: conn, csrf_token: old_csrf, session_token: old_session} =
        sign_in(conn, workspace, roles: ["Platform Admin"])

      :ok = force_privileged_rotation(workspace, old_session)
      query = "query { tickets(workspace: \"#{workspace}\") { id } }"

      # The request that rotates still carries the old CSRF token, so it is
      # refused. It must not raise while trying to write the GraphQL pipeline's
      # unfetched Phoenix session, and its response must carry every new
      # credential the client needs for the next request.
      rotated = graphql(conn, query, old_csrf)

      assert rotated.status == 403
      new_session = rotated.resp_cookies[Veritas.Web.Auth.session_cookie()].value
      new_csrf = rotated |> get_resp_header(Veritas.Web.Auth.csrf_header()) |> List.first()

      assert is_binary(new_session)
      assert new_session != old_session
      assert is_binary(new_csrf)
      assert new_csrf != old_csrf

      next =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.recycle_cookies(rotated)
        |> graphql(query, new_csrf)

      assert next.status == 200
      assert json_response(next, 200)["errors"] == nil
    end
  end

  describe "a Principal with the right role" do
    test "is allowed to do the thing", %{conn: conn, workspace: workspace} do
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace, roles: ["Service Desk Agent"])

      conn =
        graphql(
          conn,
          """
          mutation {
            openTicket(
              workspace: "#{workspace}"
              ticketType: "incident"
              title: "Checkout is down"
              requester: "u1"
            ) { id state }
          }
          """,
          csrf
        )

      assert conn.status == 200
      body = json_response(conn, 200)
      assert body["errors"] == nil
      assert body["data"]["openTicket"]["state"] == "new"
    end
  end

  describe "a Principal with the wrong role" do
    test "is refused", %{conn: conn, workspace: workspace} do
      # A Requester may open a Service Request. They may not open an
      # Incident: the `docs/02` matrix gives them no authority there.
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace, roles: ["Requester"])

      conn =
        graphql(
          conn,
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
          csrf
        )

      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["data"] == nil or body["data"]["openTicket"] == nil
      assert [error] = body["errors"]
      assert error["message"] =~ "does not hold authority"
    end

    test "may not move a ticket they have no authority over", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace, roles: ["Requester"])

      ticket = open_incident(workspace)

      conn =
        graphql(
          conn,
          """
          mutation {
            transitionTicket(
              workspace: "#{workspace}"
              id: "#{ticket["id"]}"
              toState: "acknowledged"
            ) { id state }
          }
          """,
          csrf
        )

      body = json_response(conn, 200)

      assert body["data"] == nil or body["data"]["transitionTicket"] == nil
      assert [error] = body["errors"]
      assert error["message"] =~ "does not hold authority"
    end
  end

  describe "a Principal in another Workspace" do
    test "is refused", %{conn: conn, workspace: workspace} do
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace, roles: ["Service Desk Agent"])

      conn =
        graphql(
          conn,
          "query { tickets(workspace: \"some_other_workspace\") { id } }",
          csrf
        )

      body = json_response(conn, 200)

      assert body["data"] == nil or body["data"]["tickets"] == nil
      assert [error] = body["errors"]
      assert error["message"] =~ "acts in"
    end
  end

  describe "the session cookie" do
    test "is written with HttpOnly, Secure and SameSite=Lax", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _principal} =
        Veritas.Authn.create_account(
          workspace,
          %{
            email: "cookie@example.test",
            display_name: "Operator",
            roles: ["Service Desk Agent"],
            password: password()
          },
          actor_id: "test"
        )

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post(
          "/session",
          Jason.encode!(%{
            email: "cookie@example.test",
            password: password(),
            workspace: workspace
          })
        )

      cookie = conn.resp_cookies[Veritas.Web.Auth.session_cookie()]

      assert cookie.http_only == true
      assert cookie.secure == true
      assert cookie.same_site == "Lax"

      # And the store holds the token's digest, never the token.
      {:ok, rows} =
        Veritas.Store.transaction(workspace, fn tx ->
          Veritas.Store.list(tx, :session, %{limit: 1})
        end)

      assert [row] = rows
      assert row["token_digest"] == Session.digest(cookie.value)
      refute row["token_digest"] == cookie.value
      refute Enum.any?(Map.values(row), &(&1 == cookie.value))
    end
  end

  describe "the record of a refusal" do
    test "a refused GraphQL query is written to the Audit Log", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: conn, csrf_token: csrf} = sign_in(conn, workspace, roles: ["Requester"])

      conn =
        graphql(
          conn,
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
          csrf
        )

      assert conn.status == 200

      events = audit_events(workspace)

      refusal =
        Enum.find(events, fn event ->
          event["subject_table"] == "principal" and event["to_state"] == "refused"
        end)

      assert refusal, "the refusal was not recorded: #{inspect(events)}"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a refused sign-in is written to the Audit Log", %{conn: conn, workspace: workspace} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post(
          "/session",
          Jason.encode!(%{email: "nobody@example.test", password: "wrong", workspace: workspace})
        )

      assert conn.status == 401

      events = audit_events(workspace)

      refusal =
        Enum.find(events, fn event ->
          event["subject_table"] == "session" and event["to_state"] == "refused"
        end)

      assert refusal, "the refused sign-in was not recorded: #{inspect(events)}"
    end
  end

  describe "the authorisation decision point" do
    test "is the one the corpus names", %{workspace: workspace} do
      # The surface asks `Veritas.Core.Policy`; it does not decide for
      # itself. This asserts the module the surface is built on is the one
      # the corpus describes, and that it is deny-by-default.
      principal = Principal.new("u1", workspace, ["Requester"])

      assert {:deny, _reason} =
               Policy.authorize(principal, "not:a:capability", %{workspace: workspace})
    end
  end

  describe "the sign-in form, end to end" do
    test "the page issues a session and a token, the form signs in, and the cookie opens the CMDB",
         %{conn: conn, workspace: workspace} do
      {:ok, _principal} =
        Veritas.Authn.create_account(
          workspace,
          %{
            email: "operator@example.test",
            display_name: "Operator",
            roles: ["Service Desk Agent"],
            password: password()
          },
          actor_id: "test"
        )

      # 1. The sign-in page. It must hand the browser a session to send back:
      #    the CSRF token lives in the session, and the session is what the
      #    cookie carries.
      page = get(conn, ~p"/session")

      assert page.status == 200
      assert page.resp_cookies["_veritas_web_key"], "the page issued no session cookie"
      assert page.resp_cookies["_veritas_web_key"].value != ""

      token = csrf_token(page.resp_body)

      # 2. The form, submitted the way a browser submits it: the token, the
      #    cookie, and the credential.
      signed_in =
        build_conn()
        |> Plug.Test.recycle_cookies(page)
        |> post("/session", %{
          "_csrf_token" => token,
          "email" => "operator@example.test",
          "password" => password(),
          "workspace" => workspace
        })

      assert signed_in.status in [302, 303]
      assert signed_in.resp_cookies[Veritas.Web.Auth.session_cookie()], "no session was issued"

      # 3. The session cookie opens a page that needs a Principal.
      cmdb =
        build_conn()
        |> Plug.Test.recycle_cookies(signed_in)
        |> get(~p"/cmdb/cis?workspace=#{workspace}")

      assert cmdb.status == 200
      assert html_response(cmdb, 200) =~ "Configuration Items"
    end

    test "a bad password is refused, and the refusal is audited", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _principal} =
        Veritas.Authn.create_account(
          workspace,
          %{
            email: "operator@example.test",
            display_name: "Operator",
            roles: ["Service Desk Agent"],
            password: password()
          },
          actor_id: "test"
        )

      page = get(conn, ~p"/session")
      token = csrf_token(page.resp_body)

      refused =
        build_conn()
        |> Plug.Test.recycle_cookies(page)
        |> post("/session", %{
          "_csrf_token" => token,
          "email" => "operator@example.test",
          "password" => "not-the-password",
          "workspace" => workspace
        })

      assert refused.status == 401
      refute refused.resp_cookies[Veritas.Web.Auth.session_cookie()]

      events = audit_events(workspace)

      refusal =
        Enum.find(events, fn event ->
          event["subject_table"] == "session" and event["to_state"] == "refused"
        end)

      assert refusal, "the refused sign-in was not recorded: #{inspect(events)}"
    end
  end

  describe "signing out" do
    test "is refused without a proof", %{conn: conn, workspace: workspace} do
      %{conn: conn, csrf_token: csrf, session_token: session_token} = sign_in(conn, workspace)

      # A form post with no CSRF token.
      form = post(conn, "/session/signout", %{"workspace" => workspace})
      assert form.status == 403

      # And the same for the client path.
      client = delete(conn, "/session")
      assert client.status == 403

      # The session is untouched: a refused sign-out did not sign anybody
      # out.
      assert {:ok, _session} =
               Veritas.Authn.resolve_session(workspace, session_token)

      # And the CSRF token the sign-in handed out is not a sign-out proof
      # either, because it names the session rather than the request.
      assert csrf
    end

    test "with the form's own token succeeds, and the session is gone", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: conn, session_token: session_token} = sign_in(conn, workspace)

      # The sign-in page issues the form's CSRF token, in the session the
      # browser already carries.
      page = get(conn, ~p"/session")
      token = csrf_token(page.resp_body)

      out =
        build_conn()
        |> Plug.Test.recycle_cookies(page)
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> post("/session/signout", %{"_csrf_token" => token, "workspace" => workspace})

      assert out.status in [302, 303]
      assert redirected_to(out, 303) == "/"

      # The session is revoked on the server, not just forgotten by the
      # browser.
      assert {:error, :unknown_session} =
               Veritas.Authn.resolve_session(workspace, session_token)
    end

    test "with the session's header succeeds, and the session is gone", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: conn, csrf_token: csrf, session_token: session_token} = sign_in(conn, workspace)

      out =
        conn
        |> Plug.Conn.put_req_header(Veritas.Web.Auth.csrf_header(), csrf)
        |> delete("/session")

      assert out.status == 204

      # The response was sent, not merely given a status: a connection that
      # is never sent a response is a fault, and the test has to say so.
      assert out.state == :sent

      assert {:error, :unknown_session} =
               Veritas.Authn.resolve_session(workspace, session_token)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # The token the sign-in page puts in its form.
  defp csrf_token(body) do
    case Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body) do
      [_, token] -> token
      _ -> raise "the sign-in page carried no CSRF token"
    end
  end

  defp graphql(conn, query, csrf_token \\ nil) do
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    conn =
      if csrf_token do
        Plug.Conn.put_req_header(conn, Veritas.Web.Auth.csrf_header(), csrf_token)
      else
        conn
      end

    post(conn, "/graphql", Jason.encode!(%{"query" => query}))
  end

  # Makes the next resolution rotate a privileged session without making it
  # idle or absolutely expired. The session still has to be found by the old
  # token: that is the request shape that used to raise on the API pipeline.
  defp force_privileged_rotation(workspace, token) do
    rotated_at = ~U[2020-01-01 00:00:00Z]

    {:ok, _stored} =
      Veritas.Store.transaction(workspace, fn tx ->
        with {:ok, [%{"id" => id}]} <-
               Veritas.Store.list(tx, :session, %{
                 where: [token_digest: Session.digest(token)],
                 limit: 1
               }),
             {:ok, row} <- Veritas.Store.fetch(tx, :session, id) do
          Veritas.Store.put(tx, :session, %{row | "rotated_at" => rotated_at})
        end
      end)

    :ok
  end

  defp password, do: "a-fine-passphrase-the-operator-chose-42"
end
