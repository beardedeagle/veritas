defmodule Veritas.Web.Auth.Live do
  @moduledoc """
  Authorises the LiveView socket at mount.

  `docs/09` §4's enforcement table says it plainly: *"LiveView —
  Authorize at mount and at every `handle_event`; the socket carries a
  scope-bound token, not a session."*

  ## The scope-bound token

  The LiveView's socket does not carry the session's own token. It carries a
  **scope-bound token**: a second secret, issued with the session, stored
  only as a digest, and valid only for the LiveView surface. A token that
  leaks out of the socket's handshake is therefore not a credential for the
  HTTP API.

  ## What mount establishes

  The hook resolves the scope token into the session it belongs to, and puts
  two things on the socket:

    * `:principal` — who is acting.
    * `:principal_workspace` — the Workspace they act in.

  The Workspace is the **session's** Workspace, not one the URL asked for.
  That is the cross-workspace boundary for the UI: a link carrying another
  Workspace's name cannot make the screen read that Workspace, because the
  screen reads the Workspace the Principal is in.

  The assign is called `:principal_workspace` rather than `:workspace`
  because a screen's own `mount/3` assigns the Workspace it is showing, and
  that assign must not be able to overwrite the one the session established.

  A request with no valid scope token is **halted** and sent to the sign-in
  page. The screen is not mounted without a Principal.
  """

  alias Veritas.Core.Session

  @doc """
  Authorises the mount and installs the per-event and per-navigation checks.
  """
  def on_mount(:default, params, session, socket) do
    workspace = session[Veritas.Web.Auth.workspace_key()] || params["workspace"] || "default"
    scope_token = session[Veritas.Web.Auth.scope_key()]

    socket =
      socket
      |> Phoenix.Component.assign(:veritas_scope_token, scope_token)
      |> Phoenix.Component.assign(:principal_workspace, workspace)

    case reauthorize(socket) do
      {:ok, socket} ->
        {:cont,
         socket
         |> Phoenix.LiveView.attach_hook(
           :veritas_event_authorization,
           :handle_event,
           fn _event, _params, socket -> authorize_callback(socket) end
         )
         |> Phoenix.LiveView.attach_hook(
           :veritas_navigation_authorization,
           :handle_params,
           fn _params, _uri, socket -> authorize_callback(socket) end
         )}

      {:error, socket} ->
        {:halt, socket}
    end
  end

  # The scope token is resolved again immediately before every event and
  # navigation. Success replaces the cached Principal with the account's
  # current authority; failure halts the callback exactly as a refused mount
  # halts the screen. The non-rotating resolver is essential here: a websocket
  # has no response on which to deliver replacement session cookies.
  defp authorize_callback(socket) do
    case reauthorize(socket) do
      {:ok, socket} -> {:cont, socket}
      {:error, socket} -> {:halt, socket}
    end
  end

  defp reauthorize(socket) do
    workspace = socket.assigns[:principal_workspace]
    scope_token = socket.assigns[:veritas_scope_token]

    case scope_token && Session.resolve_scope_without_rotation(scope_token, workspace) do
      {:ok, veritas_session} ->
        {:ok,
         socket
         |> Phoenix.Component.assign(:principal, Session.principal(veritas_session))
         |> Phoenix.Component.assign(:veritas_session, veritas_session)
         |> Phoenix.Component.assign(:principal_workspace, veritas_session.workspace)}

      _ ->
        {:error, Phoenix.LiveView.redirect(socket, to: "/session")}
    end
  end
end
