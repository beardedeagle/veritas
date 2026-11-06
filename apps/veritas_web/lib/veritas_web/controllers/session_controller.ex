defmodule Veritas.Web.SessionController do
  @moduledoc """
  Signing in and out.

  `docs/09` §3: the credential is exchanged for a **server-side session**,
  and the browser is given an opaque token in an `HttpOnly`, `Secure`,
  `SameSite=Lax` cookie. The controller does not decide what a session is —
  that is `Veritas.Authn` — and it does not decide what a signed-in person
  may do — that is `Veritas.Core.Policy`. It hands the credential to the
  port and puts the answer on the connection.

  ## What the answer says

  A JSON client is told the Principal's identity, the roles it holds, and
  the **CSRF token** it must send with every GraphQL `POST`. A browser is
  sent to the page it asked for.

  ## What a refusal says

  The same thing whatever went wrong: *"the credentials were refused"*. The
  Audit Log records which of the two it was, because that difference is
  useful to an operator and dangerous to disclose.
  """

  use Veritas.Web, :controller

  alias Veritas.Authn
  alias Veritas.Core.{Principal, Session}

  @doc """
  The sign-in page.
  """
  def new(conn, params) do
    conn
    |> put_layout(false)
    |> put_root_layout(false)
    |> render(:new,
      workspace: params["workspace"] || "default",
      density: density(conn)
    )
  end

  # The density is a person\'s preference and it lives in the session, so
  # the sign-in page honours it like every other page does.
  defp density(conn) do
    case get_session(conn, "veritas_density") do
      "compact" -> "compact"
      _ -> "comfortable"
    end
  end

  @doc """
  Exchanges a credential for a session.
  """
  def create(conn, params) do
    workspace = params["workspace"] || "default"

    credentials = %{
      email: params["email"],
      password: params["password"]
    }

    case Authn.authenticate(workspace, credentials) do
      {:ok, principal} ->
        case Authn.establish_session(workspace, principal) do
          {:ok, session} ->
            conn
            |> Veritas.Web.Auth.sign_in(session)
            |> respond(principal, session)

          {:error, _reason} ->
            refused(conn)
        end

      {:error, _reason} ->
        refused(conn)
    end
  end

  @doc """
  Ends the session.

  A browser is sent back to the front door; a client is told the session is
  gone. Either way the session is revoked on the server, not just forgotten
  by the browser.
  """
  def delete(conn, _params) do
    conn = Veritas.Web.Auth.sign_out(conn, conn.assigns[:veritas_session])

    if browser?(conn) do
      conn
      # The status is set before the redirect: `redirect/2` sends the
      # response, so a status change after it would be a change to a
      # response that has already gone out.
      |> put_status(:see_other)
      |> redirect(to: "/")
    else
      # A client is told the session is gone. The response is **sent**, not
      # only given a status: a connection that is never sent a response is
      # a fault, not a 204.
      conn
      |> put_status(:no_content)
      |> send_resp(204, "")
    end
  end

  # A browser asked for a page; a client did not.
  defp browser?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.join(",")
    |> String.contains?("text/html")
  end

  defp respond(conn, principal, session) do
    conn = Plug.Conn.put_resp_header(conn, Veritas.Web.Auth.csrf_header(), session.csrf_token)

    if json?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "principal" => %{
            "id" => principal.id,
            "workspace" => principal.workspace,
            "roles" => Principal.role_strings(principal)
          },
          "csrf_token" => session.csrf_token,
          "expires_in" => Session.absolute_timeout()
        })
      )
    else
      conn
      # The status is set **before** the redirect: `redirect/2` sends the
      # response, so a status change after it would be a change to a
      # response that has already gone out.
      |> put_status(:see_other)
      |> redirect(to: "/")
    end
  end

  defp refused(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{"errors" => [%{"message" => "the credentials were refused"}]})
    )
  end

  # A JSON client is answered with JSON; a browser is answered with a
  # redirect. The accept header says which.
  defp json?(conn) do
    accepts =
      conn
      |> Plug.Conn.get_req_header("accept")
      |> Enum.join(",")

    String.contains?(accepts, "application/json") or
      String.contains?(Plug.Conn.get_req_header(conn, "content-type") |> Enum.join(","), "json")
  end
end
