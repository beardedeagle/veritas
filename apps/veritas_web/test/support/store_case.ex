defmodule Veritas.Web.StoreCase do
  @moduledoc """
  A case template for the web tests that talk to the domain.

  The web surfaces reach the domain through the store port, so the tests run
  against the store the suite starts itself and exercise the surfaces against
  a real service layer.

  The point of testing a surface this way is that the surface is never
  trusted to have implemented the behaviour itself: a GraphQL mutation and a
  LiveView button both go through `Veritas.Core.Tickets`, and the assertions
  are made against the domain's own state and the Audit Log, not against what
  the surface says.

  ## Isolation

  Each test gets its own Workspace, because the Workspace is the isolation
  unit of the contract. No test can see another's rows, and no test has to
  clean up after itself.
  """
  use ExUnit.CaseTemplate

  # The sign-in helper below talks to the endpoint the way a client does,
  # so it needs the endpoint. `Phoenix.ConnTest`'s request helpers expand
  # `@endpoint` at the call site.
  @endpoint Veritas.Web.Endpoint

  import Phoenix.ConnTest, only: [post: 3, json_response: 2]

  using do
    quote do
      import Veritas.Web.StoreCase

      @tag :needs_store
    end
  end

  setup do
    workspace = unique_workspace()
    migrate(workspace)

    # The Workspace is removed when the test ends, whether it passed or
    # failed. A test run must leave the store as it found it.
    on_exit(fn -> remove_workspace(workspace) end)

    {:ok, workspace: workspace}
  end

  @doc "A Workspace name nobody else is using."
  @spec unique_workspace() :: String.t()
  def unique_workspace do
    "w_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  @doc "Brings a Workspace to the current schema, for the adapters that need it."
  @spec migrate(String.t()) :: :ok
  def migrate(workspace) do
    case Veritas.Store.adapter() do
      Veritas.Store.Surreal -> Veritas.Store.Surreal.migrate(workspace)
      _ -> :ok
    end
  end

  @doc """
  Opens an Incident through the domain, for a surface test that needs one.
  """
  @spec open_incident(String.t(), map()) :: map()
  def open_incident(workspace \\ "default", attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"title" => "Checkout is down", "requester" => "u1", "priority" => "high"},
        attrs
      )

    {:ok, ticket} =
      Veritas.Core.Tickets.open(workspace, "incident", attrs, %{type: "user", id: "u1"})

    ticket
  end

  @doc """
  Removes a scratch Workspace from the store.

  A no-op for an Adapter with no namespace to remove, and idempotent: removing
  a Workspace that is already gone is not an error.
  """
  @spec remove_workspace(String.t()) :: :ok
  def remove_workspace(workspace) do
    settings = Application.get_env(:veritas_core, :surreal, [])

    case Application.get_env(:veritas_core, :store) do
      {Veritas.Store.Surreal, _options} -> remove_surreal_workspace(settings, workspace)
      Veritas.Store.Surreal -> remove_surreal_workspace(settings, workspace)
      _ -> :ok
    end
  end

  defp remove_surreal_workspace(settings, workspace) do
    case settings[:url] do
      url when is_binary(url) ->
        Veritas.Core.Test.SurrealServer.remove_workspace(url, workspace, settings)

      _ ->
        :ok
    end
  end

  @doc "The Audit Log events of a Workspace, oldest first."
  @spec audit_events(String.t()) :: [map()]
  def audit_events(workspace) do
    {:ok, events} = Veritas.Core.Audit.entries(workspace)
    events
  end

  @doc """
  Creates a Principal with the given roles, without signing it in.

  A surface test that runs the schema directly — rather than over HTTP —
  needs a Principal in the Absinthe context, and nothing else. No session is
  issued, so the session events do not appear in the Audit Log.
  """
  @spec principal(String.t(), keyword()) :: Veritas.Core.Principal.t()
  def principal(workspace, opts \\ []) do
    email = Keyword.get(opts, :email, "operator@example.test")
    password = Keyword.get(opts, :password, "a-fine-passphrase-the-operator-chose-42")
    roles = Keyword.get(opts, :roles, ["Service Desk Agent"])

    {:ok, principal} =
      Veritas.Authn.create_account(
        workspace,
        %{email: email, display_name: "Operator", roles: roles, password: password},
        actor_id: "test"
      )

    principal
  end

  @doc """
  The Audit Log events about **tickets**, oldest first.

  The Log holds more than tickets — an account's creation is in it too — so
  a test that counts the events a ticket operation wrote counts the ticket
  events.
  """
  @spec ticket_events(String.t()) :: [map()]
  def ticket_events(workspace) do
    workspace
    |> audit_events()
    |> Enum.filter(fn event -> event["subject_table"] == "ticket" end)
  end

  @doc """
  Signs a Principal in and returns the connection that carries the session.

  The sign-in goes **through the endpoint**, the way a client does it, so the
  test is exercising the real thing: the session cookie, the Workspace
  cookie, and the Phoenix session that holds the LiveView's scope-bound
  token are all set by the product rather than by the test.

  The result is:

    * `:conn` — a connection carrying the session's cookies, ready for the
      next request.
    * `:principal` — who is signed in. A GraphQL test that runs the schema
      directly puts this in the Absinthe context, which is what the
      resolvers' guard reads.
    * `:csrf_token` — the token a GraphQL `POST` must carry.
    * `:session_token` — the session the browser holds, for a test that has
      to look at it.
  """
  @spec sign_in(Plug.Conn.t(), String.t(), keyword()) :: map()
  def sign_in(conn, workspace, opts \\ []) do
    email = Keyword.get(opts, :email, "operator@example.test")
    password = Keyword.get(opts, :password, "a-fine-passphrase-the-operator-chose-42")
    roles = Keyword.get(opts, :roles, ["Service Desk Agent"])

    # The account is created if it is not there, and signed in to if it is.
    # A test that has already made the Principal — to put it in the Absinthe
    # context — does not need a second one.
    principal =
      case Veritas.Authn.create_account(
             workspace,
             %{
               email: email,
               display_name: "Operator",
               roles: roles,
               password: password
             },
             actor_id: "test"
           ) do
        {:ok, principal} ->
          principal

        {:error, :account_exists} ->
          {:ok, principal} =
            Veritas.Authn.authenticate(workspace, %{email: email, password: password})

          principal

        {:error, reason} ->
          raise "the test account could not be created: #{inspect(reason)}"
      end

    signed_in =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> post(
        "/session",
        Jason.encode!(%{email: email, password: password, workspace: workspace})
      )

    body = json_response(signed_in, 200)

    # The next request carries the cookies the sign-in set.
    next = Phoenix.ConnTest.build_conn() |> Plug.Test.recycle_cookies(signed_in)

    # The session the browser now holds: the one the sign-in issued and put
    # in the cookie — not a second one made for the test, which would be a
    # session the browser never had.
    session_token = signed_in.resp_cookies[Veritas.Web.Auth.session_cookie()].value

    %{
      conn: next,
      principal: principal,
      csrf_token: body["csrf_token"],
      session_token: session_token
    }
  end
end
