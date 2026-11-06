defmodule Veritas.Web.GraphQL.Limits do
  @moduledoc """
  The cost controls on the GraphQL surface.

  Three numbers, all named, all set in `config/config.exs`:

    * `max_complexity` — the most a single document may cost. Every list
      field declares its own cost in the schema, so the cost of a document
      is the work it may cause. The default permits one list of a few
      hundred rows and refuses a document that multiplies one query by
      aliasing it forty times.
    * `token_limit` — the most tokens a document may lex. It bounds the cost
      of *parsing*, which happens before the complexity analysis.
    * `introspection` — whether the schema may be read back. On in
      development, where the IDE needs it; off everywhere else.

  Each is a **Default**: a configuration value an operator may change. What
  is **Fixed** is that they are enforced at the edge of the API rather than
  left to the caller to respect.
  """

  @default_max_complexity 5_000
  @default_token_limit 1_000

  @doc "The most a single GraphQL document may cost."
  @spec max_complexity() :: pos_integer()
  def max_complexity do
    Application.get_env(:veritas_web, :graphql_max_complexity, @default_max_complexity)
  end

  @doc "The most tokens a single GraphQL document may lex."
  @spec token_limit() :: pos_integer()
  def token_limit do
    Application.get_env(:veritas_web, :graphql_token_limit, @default_token_limit)
  end

  @doc "Whether the schema may be read back through introspection."
  @spec introspection?() :: boolean()
  def introspection? do
    Application.get_env(:veritas_web, :graphql_introspection, false) == true
  end
end

defmodule Veritas.Web.GraphQL.Plug do
  @moduledoc """
  The GraphQL endpoint, with the surface's own guards.

  Three things happen here that `Absinthe.Plug` does not do:

    * **Introspection is refused** outside development. The check is on the
      query text, and a GraphQL field name cannot be escaped, so a document
      that asks for `__schema` or `__type` has to spell it out. `__typename`
      is a different field, and keeps working.
    * **A fault cannot render a debug page.** Anything that escapes Absinthe
      becomes a small JSON body, and the detail is logged on the server with
      the request id. The client learns that the request failed and nothing
      else.
    * **The cost limits are re-applied per request**, so an operator can
      change them without a rebuild.

  Everything else is `Absinthe.Plug`: the schema, the context and the
  pipeline are the ones the router passes in.
  """

  require Logger

  # `__schema` and `__type` are the two root fields that read the schema
  # back. The `\b` after `__type` keeps `__typename` — a different field, and
  # a legitimate one — out of the match.
  @introspection_fields ~r/__schema\b|__type\b/

  @behaviour Plug

  @impl Plug
  def init(opts), do: Absinthe.Plug.init(opts)

  @impl Plug
  def call(conn, opts) do
    if introspection_requested?(conn) and not Veritas.Web.GraphQL.Limits.introspection?() do
      refuse_introspection(conn)
    else
      conn
      # The Principal the request was signed in as goes into the Absinthe
      # context, so that every field resolver can ask the guard about it.
      # `docs/09` §4: the middleware resolves the Principal and each field
      # resolver calls the guard before it touches data.
      |> Absinthe.Plug.assign_context(principal: conn.assigns[:principal])
      |> Absinthe.Plug.call(apply_limits(opts))
    end
  rescue
    error ->
      Logger.error(
        "[veritas.web.graphql] the request failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      internal_error(conn)
  end

  # The limits are read again for every request rather than being fixed when
  # the router was compiled, so an operator can change them in the
  # configuration and see the change without a rebuild.
  defp apply_limits(opts) do
    raw =
      opts
      |> Map.get(:raw_options, [])
      |> Keyword.put(:analyze_complexity, true)
      |> Keyword.put(:max_complexity, Veritas.Web.GraphQL.Limits.max_complexity())
      |> Keyword.put(:token_limit, Veritas.Web.GraphQL.Limits.token_limit())

    %{opts | raw_options: raw}
  end

  defp introspection_requested?(conn) do
    conn.body_params
    |> documents()
    |> Enum.any?(fn document ->
      case document do
        %{"query" => query} when is_binary(query) -> Regex.match?(@introspection_fields, query)
        _ -> false
      end
    end)
  end

  # A request is either one document or a batch of them.
  defp documents(%{"query" => _} = document), do: [document]
  defp documents(documents) when is_list(documents), do: documents
  defp documents(_), do: []

  defp refuse_introspection(conn) do
    send_json(conn, 400, %{
      "errors" => [%{"message" => "introspection is not available on this deployment"}]
    })
  end

  defp internal_error(conn) do
    send_json(conn, 500, %{
      "errors" => [%{"message" => "the request could not be completed"}]
    })
  end

  # A response that has already gone out is not sent twice.
  defp send_json(conn, status, body) do
    if conn.state in [:unset, :set] do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    else
      conn
    end
  end
end

defmodule Veritas.Web.Router do
  use Veritas.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Veritas.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # A browser page needs a Principal. The request is refused — sent to the
    # sign-in page — rather than served without one.
    plug Veritas.Web.Auth, {:require_session, :redirect}
    # The shell is chrome: the rail and the top bar are the same on every
    # screen, so they are put on the connection once, here, and rendered by the
    # root layout around whatever the page produced.
    plug Veritas.Web.Shell.Plug
  end

  pipeline :graphql do
    plug :accepts, ["json"]
    # The API needs a Principal, and a GraphQL `POST` needs the session's
    # CSRF token (`docs/09` §3). Both are refusals, not redirections.
    plug Veritas.Web.Auth, {:require_session, :json}
    plug Veritas.Web.Auth, :require_csrf
  end

  # The sign-in route. It is outside the browser pipeline because a person
  # arriving there has no Principal yet, and because the browser pipeline
  # requires one.
  pipeline :signin do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Veritas.Web.Layouts, :root}
    plug :protect_forms
  end

  # The GraphiQL IDE serves its own document, so this pipeline deliberately
  # does not set a root layout. It accepts JSON as well as HTML because the
  # same plug answers a GraphQL query when the client does not ask for HTML.
  pipeline :graphiql do
    plug :accepts, ["html", "json"]
    plug :put_secure_browser_headers
    plug :graphiql_ide
    # The IDE is there to show the schema, and outside development the schema
    # is not published. The IDE is gated separately from the API so that
    # refusing the schema does not mean refusing the API: a deployment that
    # serves no introspection still serves every query.
    plug :require_introspection
  end

  # The sign-in and sign-out routes. They are outside the browser pipeline
  # because the browser pipeline requires a Principal, and signing in is how
  # one gets one.
  scope "/session", Veritas.Web do
    pipe_through :signin

    get "/", SessionController, :new
    post "/", SessionController, :create
  end

  # The sign-out. `POST /session/signout` is the shape a browser form can
  # reach without JavaScript; `DELETE /session` is the shape a client
  # reaches with the `X-Veritas-CSRF` header. Both carry a proof.
  scope "/session", Veritas.Web do
    pipe_through :signout

    post "/signout", SessionController, :delete
    delete "/", SessionController, :delete
  end

  scope "/", Veritas.Web do
    pipe_through :browser

    # The GraphQL endpoint is POST-only. A GET lands here instead of on a
    # bare 404, and is told what to do instead.
    get "/graphql", PageController, :graphql

    # The density preference. It is a session value because it is a user
    # preference, not a per-page thing.
    post "/ui/density", PageController, :density

    # The LiveViews live INSIDE the browser pipeline, not beside it. The
    # pipeline is what puts the root layout (and with it the shell, the
    # stylesheet and the session) on the connection. A `live_session` block
    # declared outside a `scope` that pipes through :browser gets none of
    # that: the page renders, but it renders bare, with no chrome.
    live_session :shell, on_mount: [{Veritas.Web.Auth.Live, :default}] do
      live "/", Shell.HomeLive, :home
      live "/workflows", WorkflowLive.Index, :index
      live "/workflows/tickets/:ticket_id", WorkflowLive.Run, :show
      live "/workflows/:id/intake", WorkflowLive.Intake, :new
      live "/workflows/:id", WorkflowLive.Index, :edit

      # The ticket queues. One LiveView serves all of them: the **route**
      # names the queue, so a link carrying another queue's name cannot
      # change what the screen shows. The Problems view is a filter over the
      # Incidents queue, not a screen of its own (`docs/04`).
      live "/incidents", IncidentLive.Index, :incidents
      live "/incidents/:id", IncidentLive.Show, :show
      live "/requests", IncidentLive.Index, :service_request
      live "/requests/:id", IncidentLive.Show, :service_request
      live "/changes", IncidentLive.Index, :change
      live "/changes/:id", IncidentLive.Show, :change
      live "/vulnerabilities", IncidentLive.Index, :vulnerability
      live "/vulnerabilities/:id", IncidentLive.Show, :vulnerability

      # Delivery: the Programs, their Milestones and the Work Items under
      # them (`docs/04` §Navigation Model).
      live "/programs", DeliveryLive.Index, :index
      live "/programs/:id", DeliveryLive.Show, :show
      live "/work-items/:id", DeliveryLive.WorkItem, :show

      # The CMDB screens. These modules are being written by the BEAM Engineer;
      # the routes are here against their exact module names.
      live "/cmdb/cis", CILive.Index, :index
      live "/cmdb/cis/:id", CILive.Show, :show

      # Admin — the panels `docs/04` §Navigation Model gives the section: the
      # landing page that says which of them exist, the Audit Log, the people
      # (the company's directory and Veritas's own accounts), and the accounts
      # of the Workspace with the roles they hold.
      live "/admin", AdminLive.Index, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/people", AdminLive.People, :people
      live "/audit", AdminLive.Audit, :audit

      # The Agent Console: the visible AI surface. The console, the tool
      # catalogue and the Workspace's providers (`docs/39`).
      live "/agents", AgentConsole.Index, :runs
      live "/agents/tools", AgentConsole.Tools, :tools
      live "/agents/providers", AgentConsole.Providers, :providers

      # The sections that have no screen yet still have a route, so that a rail
      # entry is never a dead link and the shape of the product is visible.
      # The section is the path itself; the LiveView decides what to do with a
      # segment it does not recognise.
      live "/:section", Shell.SectionLive, :section
    end
  end

  # The sign-out routes. A sign-out is a state change, so every way to reach
  # it carries a proof: the form's own CSRF token, or the `X-Veritas-CSRF`
  # header that names the session.
  pipeline :signout do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Veritas.Web.Layouts, :root}
    # Resolve the session, so the sign-out can revoke it, and so the header
    # proof has a session to name.
    plug Veritas.Web.Auth, :resolve_session
    plug Veritas.Web.Auth, :require_signout_csrf
  end

  # The GraphiQL IDE. It is routed before the endpoint below, because the
  # endpoint forwards every path under /graphql and would otherwise swallow
  # /graphql/i. The same plug answers a GraphQL query when the client does
  # not ask for HTML.
  scope "/graphql" do
    pipe_through :graphiql

    forward "/i", Absinthe.Plug.GraphiQL, schema: Veritas.Web.GraphQL.Schema
  end

  # The GraphQL surface. Same service layer as the UI and the CLI (INV-8).
  #
  # The forward goes through `Veritas.Web.GraphQL.Plug`, which is the
  # `Absinthe.Plug` plus this surface's own guards: introspection is refused
  # outside development, a fault cannot render a debug page, and the cost
  # limits are re-applied per request.
  scope "/graphql" do
    pipe_through :graphql

    forward "/", Veritas.Web.GraphQL.Plug,
      schema: Veritas.Web.GraphQL.Schema,
      analyze_complexity: true,
      max_complexity: Veritas.Web.GraphQL.Limits.max_complexity(),
      token_limit: Veritas.Web.GraphQL.Limits.token_limit()
  end

  # `/graphql/i` is the IDE, and the path says so. The GraphiQL plug only
  # serves the IDE when the client asks for HTML, so a client that sends no
  # Accept header — or one that sends a narrow one — would get a GraphQL
  # error instead of the IDE it asked for. A GET there is the IDE; a GET that
  # carries a query is a query; a POST is always a query.
  defp graphiql_ide(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    if conn.method == "GET" and is_nil(conn.params["query"]) do
      Plug.Conn.put_req_header(conn, "accept", "text/html")
    else
      conn
    end
  end

  # A form is protected by Phoenix's own per-session CSRF token; a JSON
  # request is not, because a browser cannot make a cross-origin JSON
  # request without a preflight it has not been given.
  #
  # The token is **issued** on a safe request and **verified** on a form
  # submission, and both halves are here.
  #
  # The issuing half is the one that is easy to miss, and it is what
  # `Plug.CSRFProtection.call/2` does: it puts the token into the session,
  # and the session is what the cookie carries. A `GET` that skipped it
  # produced a form whose token nothing could validate, and a response with
  # no `Set-Cookie` at all — so the sign-in could never be submitted.
  defp protect_forms(conn, _opts) do
    if safe_method?(conn) or form?(conn) do
      Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
    else
      conn
    end
  end

  defp safe_method?(conn), do: conn.method in ["GET", "HEAD", "OPTIONS"]

  defp form?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.contains?(&1, "application/x-www-form-urlencoded")) or
      conn
      |> Plug.Conn.get_req_header("content-type")
      |> Enum.any?(&String.contains?(&1, "multipart/form-data"))
  end

  # The IDE is a development tool. Where the schema is not published, the IDE
  # has nothing to show, so it is a 404 rather than a page that fails when it
  # asks for the schema it is there to display.
  defp require_introspection(conn, _opts) do
    if Veritas.Web.GraphQL.Limits.introspection?() do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(404, "not found\n")
      |> Plug.Conn.halt()
    end
  end
end
