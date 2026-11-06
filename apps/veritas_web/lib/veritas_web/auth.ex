defmodule Veritas.Web.Auth do
  @moduledoc """
  The HTTP surface's authentication.

  `docs/09` §4 gives the enforcement table, and this module is the row for
  the two surfaces that serve a browser:

    * **GraphQL** — the middleware resolves the Principal, and every field
      resolver calls the guard before it touches data.
    * **LiveView** — the socket is authorised at mount and at every event.

  Both surfaces get their Principal the same way, and both get it from the
  same place: a **server-side session** held in the datastore, identified by
  an opaque token in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie. The
  browser cannot read the token, the store holds only its digest, and a Node
  restart cannot invalidate it (`docs/09` §3, `docs/05`).

  ## The Workspace is part of the lookup

  A session lives in one Workspace and the store is scoped to it, so the
  Workspace has to be known before the session can be found. It travels in
  its own cookie, set at sign-in. A request that names a different
  Workspace finds no session there — and the Policy refuses a request whose
  Workspace is not the Principal's own, so the two checks together mean a
  token is useless outside the Workspace that issued it.

  ## What a refusal looks like

  An unauthenticated request is **refused**, not redirected and then
  allowed. The API answers `401`; the browser is sent to the sign-in page.
  Neither serves the protected resource without a Principal.

  ## The CSRF token

  `docs/09` §3: the GraphQL `POST` requires an `X-Veritas-CSRF` header that
  matches the session. The token is handed to the client at sign-in and
  rotates with the session. Forms and the LiveView socket use Phoenix's own
  per-session CSRF protection, which is what the corpus asks for there.
  """

  alias Veritas.Authn
  alias Veritas.Core.Session

  @session_cookie "_veritas_session"
  @workspace_cookie "_veritas_workspace"
  @csrf_header "x-veritas-csrf"
  @scope_key "veritas_scope"
  @workspace_key "veritas_workspace"

  @behaviour Plug

  @doc "The cookie that carries the session token."
  @spec session_cookie() :: String.t()
  def session_cookie, do: @session_cookie

  @doc "The cookie that names the Workspace a session belongs to."
  @spec workspace_cookie() :: String.t()
  def workspace_cookie, do: @workspace_cookie

  @doc "The header a GraphQL `POST` must carry."
  @spec csrf_header() :: String.t()
  def csrf_header, do: @csrf_header

  @doc "The key the LiveView's scope-bound token is kept under."
  @spec scope_key() :: String.t()
  def scope_key, do: @scope_key

  @doc "The key the LiveView's Workspace is kept under."
  @spec workspace_key() :: String.t()
  def workspace_key, do: @workspace_key

  @impl Plug
  def init(:resolve_session), do: {:resolve_session, :json}
  def init(:require_session), do: {:require_session, :json}
  def init(:require_csrf), do: {:require_csrf, :json}
  def init(:require_signout_csrf), do: {:require_signout_csrf, :json}
  def init({:require_session, mode}), do: {:require_session, mode}
  def init(opts), do: {:require_session, opts}

  @impl Plug
  def call(conn, {:resolve_session, _mode}), do: resolve(conn)
  def call(conn, {:require_session, mode}), do: require_session(conn, mode)
  def call(conn, {:require_csrf, _mode}), do: require_csrf(conn)
  def call(conn, {:require_signout_csrf, _mode}), do: require_signout_csrf(conn)
  def call(conn, :resolve_session), do: resolve(conn)
  def call(conn, :require_session), do: require_session(conn, :json)
  def call(conn, :require_csrf), do: require_csrf(conn)
  def call(conn, :require_signout_csrf), do: require_signout_csrf(conn)

  @doc """
  Puts the cookies and the LiveView's scope token on a signed-in connection.

  The session cookie carries the opaque token; the workspace cookie names
  the Workspace the session lives in; the scope-bound token goes into the
  Phoenix session, where the LiveView socket's handshake can find it.
  """
  @spec sign_in(Plug.Conn.t(), Session.t()) :: Plug.Conn.t()
  def sign_in(conn, %Session{} = session) do
    conn
    |> Plug.Conn.put_resp_cookie(@session_cookie, session.token, cookie_options())
    |> Plug.Conn.put_resp_cookie(@workspace_cookie, session.workspace, cookie_options())
    |> put_scope_token(session)
  end

  @doc """
  Ends the session and clears what the browser holds.

  The session is revoked on the server, by the **token the browser
  presented**: only the digest of a token is stored, so a session that was
  read back cannot name its own row. The cookie is what names it.
  """
  @spec sign_out(Plug.Conn.t(), Session.t() | nil) :: Plug.Conn.t()
  def sign_out(conn, %Session{} = session) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.cookies[@session_cookie] do
      token when is_binary(token) -> Authn.revoke_session(session.workspace, token)
      _ -> :ok
    end

    clear(conn)
  end

  def sign_out(conn, nil), do: clear(conn)

  @doc """
  Clears what the browser holds, without ending the session.
  """
  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn) do
    conn
    |> Plug.Conn.delete_resp_cookie(@session_cookie)
    |> Plug.Conn.delete_resp_cookie(@workspace_cookie)
    |> delete_scope_token()
  end

  @doc """
  The Workspace a request is about.
  """
  @spec workspace(Plug.Conn.t()) :: String.t()
  def workspace(conn) do
    conn = Plug.Conn.fetch_cookies(conn)
    conn = Plug.Conn.fetch_query_params(conn)

    conn.cookies[@workspace_cookie] || conn.params["workspace"] || "default"
  end

  @doc """
  The CSRF token a connection's session expects, if it has one.
  """
  @spec csrf_token(Plug.Conn.t()) :: String.t() | nil
  def csrf_token(conn), do: get_in(conn.assigns, [:veritas_session, :csrf_token])

  # ── the plugs ──────────────────────────────────────────────────────────────

  # Resolve the session, if there is one. A request with no session is not
  # an error here: the sign-in page itself has no session.
  defp resolve(conn) do
    conn = Plug.Conn.fetch_cookies(conn)
    workspace = workspace(conn)
    token = conn.cookies[@session_cookie]

    case token && Authn.resolve_session(workspace, token) do
      {:ok, session} ->
        conn
        |> Plug.Conn.assign(:principal, Session.principal(session))
        |> Plug.Conn.assign(:veritas_session, session)
        |> refresh(session)

      _ ->
        conn
    end
  end

  # A session that rotated while it was being resolved is written back to the
  # browser in the same response. That is how a privileged session's
  # thirty-minute rotation and a privilege change both reach the client
  # without the client having to ask for a new token.
  defp refresh(conn, %Session{token: nil}), do: conn

  defp refresh(conn, %Session{} = session) do
    conn
    |> Plug.Conn.put_resp_cookie(@session_cookie, session.token, cookie_options())
    |> Plug.Conn.put_resp_cookie(@workspace_cookie, session.workspace, cookie_options())
    |> put_scope_token(session)
    |> put_rotated_csrf(session)
  end

  # A rotation changes the CSRF secret as well as the session and scope
  # tokens. The response header is the same delivery mechanism sign-in uses,
  # so a GraphQL client can send the new token with its next request.
  defp put_rotated_csrf(conn, %Session{csrf_token: csrf_token}) when is_binary(csrf_token) do
    Plug.Conn.put_resp_header(conn, @csrf_header, csrf_token)
  end

  defp put_rotated_csrf(conn, _session), do: conn

  defp require_session(conn, mode) do
    conn = resolve(conn)

    if conn.assigns[:principal] do
      conn
    else
      refuse(conn, mode)
    end
  end

  # The API is refused with a status; the browser is sent to the sign-in
  # page. Neither is allowed through: the protected resource is not served
  # either way.
  defp refuse(conn, :redirect) do
    conn
    |> Phoenix.Controller.redirect(to: "/session")
    |> Plug.Conn.halt()
  end

  defp refuse(conn, _mode) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      401,
      Jason.encode!(%{
        "errors" => [%{"message" => "this request needs a signed-in principal"}]
      })
    )
    |> Plug.Conn.halt()
  end

  @doc """
  Refuses a GraphQL `POST` that does not carry the session's CSRF token.

  `docs/09` §3: the GraphQL endpoint requires `X-Veritas-CSRF` matching the
  session. A request that changes nothing is not checked: the rule is about
  the state-changing method, and a `GET` changes nothing.
  """
  @spec require_csrf(Plug.Conn.t()) :: Plug.Conn.t()
  def require_csrf(conn) do
    if conn.method == "POST" do
      check_session_csrf(conn)
    else
      conn
    end
  end

  @doc """
  Refuses a sign-out that carries no proof that the caller means it.

  A sign-out is a state change, and a state change a browser can be made
  to perform without the holder's knowledge is a denial-of-service tool:
  anyone can sign a person out of their session at will.

  So **every** way to reach the sign-out route has to carry a proof, and
  there are two, because there are two kinds of caller:

    * a **browser**, which sends the form's own CSRF token — the one the
      page already carries, and the same idiom the density control in the
      account menu uses;
    * a **client**, which sends the `X-Veritas-CSRF` header that names the
      session, the same header the GraphQL endpoint requires.

  A request with neither is refused with a status, not an exception.
  """
  @spec require_signout_csrf(Plug.Conn.t()) :: Plug.Conn.t()
  def require_signout_csrf(conn) do
    if form_csrf_token?(conn) do
      # Phoenix's own protection, against the token in the session.
      Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
    else
      # The header that names the session. A sign-out is a state change on
      # any method, so this is checked on every method that is not safe.
      if conn.method in ["GET", "HEAD", "OPTIONS"] do
        conn
      else
        check_session_csrf(conn)
      end
    end
  end

  # Whether the request carries the form's own CSRF token, in the body or
  # in the header Phoenix accepts it in.
  defp form_csrf_token?(conn) do
    is_binary(Map.get(conn.body_params, "_csrf_token")) or
      conn |> Plug.Conn.get_req_header("x-csrf-token") |> Enum.any?(&is_binary/1)
  end

  # The check the GraphQL endpoint and the sign-out share: the header must
  # name the session.
  defp check_session_csrf(conn) do
    session = conn.assigns[:veritas_session]
    presented = conn |> Plug.Conn.get_req_header(@csrf_header) |> List.first()

    if session && presented && Session.csrf_match?(session, presented) do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{
          "errors" => [%{"message" => "this request needs the session's CSRF token"}]
        })
      )
      |> Plug.Conn.halt()
    end
  end

  # ── the cookies ────────────────────────────────────────────────────────────

  # `docs/09` §3: HttpOnly, Secure and SameSite=Lax.
  #
  # `secure` is a **Default**: the corpus says Secure, and a deployment
  # serving plain HTTP to a home lab turns it off in configuration. It is
  # never on by accident in the other direction — the default is Secure.
  defp cookie_options do
    [
      http_only: true,
      secure: secure?(),
      same_site: "Lax",
      max_age: Session.absolute_timeout()
    ]
  end

  defp secure?, do: Application.get_env(:veritas_web, :session_cookie_secure, true) == true

  # The scope-bound token rides in the Phoenix session, which the LiveView
  # socket's handshake reads. It is scoped to the session, so it is not the
  # session's own token and cannot be used against the HTTP API.
  defp put_scope_token(conn, %Session{scope_token: scope_token, workspace: workspace})
       when is_binary(scope_token) do
    if conn.private[:plug_session_fetch] == :done do
      conn
      |> Plug.Conn.put_session(@scope_key, scope_token)
      |> Plug.Conn.put_session(@workspace_key, workspace)
    else
      conn
    end
  end

  defp put_scope_token(conn, _session), do: conn

  defp delete_scope_token(conn) do
    if conn.private[:plug_session_fetch] == :done do
      Plug.Conn.delete_session(conn, @scope_key)
    else
      conn
    end
  end
end
