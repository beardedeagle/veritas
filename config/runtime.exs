import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# The runtime configuration is for a **running node**.
#
# The test environment configures its own endpoint — its own port, and
# `server: false` so a suite never opens a listening socket (config/test.exs)
# — and this block must not override it. Runtime configuration is merged
# *after* the environment's own, so an unconditional `http:` here silently
# replaces the suite's port with the operator's, and an unconditional
# `server:` replaces `false` with `true`. The symptom is a suite that fails
# to boot with "port 4000 already in use" — a failure that has nothing to do
# with the code under test, and that can only be reproduced while somebody
# else is using the product.
if config_env() != :test do
  config :veritas_web, Veritas.Web.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# The datastore is a **Default** behind the `Veritas.Store` port (`docs/32`,
# ADR-033). An operator may substitute another Adapter by naming it here:
#
#     config :veritas_core, :store,
#       adapter: MyApp.Store.Postgres,
#       options: [url: "postgres://…"]
#
# The Adapter must implement the `store/1` contract, and the boot check proves
# it before the system serves anything. `VERITAS_STORE_ADAPTER` takes the
# module name, so a release can be pointed at a different datastore without a
# rebuild.
store_adapter =
  case System.get_env("VERITAS_STORE_ADAPTER") do
    nil ->
      case Application.get_env(:veritas_core, :store) do
        {module, _options} -> module
        %{adapter: module} -> module
        _ -> Veritas.Store.Surreal
      end

    name ->
      name |> String.split(".") |> Enum.map(&String.to_atom/1) |> Module.concat()
  end

# The datastore connection. **This is the only place it is configured.**
#
# The password has no default outside development. A shipped default
# credential is a known credential: a self-hosted Veritas that reaches its
# datastore with "root" is a datastore with a known key, and the audience
# for Veritas is exactly the deployments where the datastore is a home
# laptop or a machine on a small office LAN. `Veritas.Store.Config.validate!/0`
# refuses to start in production when the password is absent, empty or the
# shipped default, so the refusal lives in code rather than in this file.
#
# In development the default is kept, so that a single-node local store works
# with nothing to configure, and the boot check warns loudly instead.
store_url = System.get_env("VERITAS_SURREAL_URL", "http://127.0.0.1:8000")
store_user = System.get_env("VERITAS_SURREAL_USER", "root")

store_pass =
  case System.get_env("VERITAS_SURREAL_PASS") do
    nil ->
      if config_env() == :prod do
        nil
      else
        "root"
      end

    pass ->
      pass
  end

store_options = [url: store_url, user: store_user, pass: store_pass]

config :veritas_core, :store,
  adapter: store_adapter,
  options: store_options

# The same values, written to the Adapter's own key. The shipped Adapter
# falls back to it for an option it was not given, so it has to carry the
# same values rather than a second set of defaults.
config :veritas_core, :surreal, store_options

# The Workspace the node brings up at boot, when it manages its own
# datastore (ADR-048). The node that owns a store owns its schema; a node
# pointed at somebody else's store leaves that store's schema alone.
#
# The default is the Workspace a clean checkout serves.
config :veritas_core, :boot_workspace, System.get_env("VERITAS_WORKSPACE", "default")

# The environment the boot check judges the credentials by. `:prod` refuses a
# default credential; every other environment warns.
config :veritas_core, :environment, config_env()

# The schema is published where a person may need to read it, and is not
# published anywhere else. A developer laptop has the GraphiQL IDE, which
# needs it; the test suite asserts that the IDE is mounted; and a deployment
# that can be reached by someone else does not.
#
# This is here rather than in `config/dev.exs` because the decision is
# `config_env()`, and `config_env()` is only right in one place.
config :veritas_web, :graphql_introspection, config_env() in [:dev, :test]

# The named opt-out. An operator who knows what they are doing — a throwaway
# container on a laptop, a datastore the operating system already protects —
# may set `VERITAS_STORE_ALLOW_DEFAULT_CREDENTIALS=true` and be told loudly
# rather than refused.
config :veritas_core,
       :allow_default_credentials,
       System.get_env("VERITAS_STORE_ALLOW_DEFAULT_CREDENTIALS") == "true"

# Whether the session cookie carries `Secure`.
#
# The corpus says the cookie is `HttpOnly`, `Secure` and `SameSite=Lax`, and
# the committed default is `Secure` — so the setting is right by default and a
# deployment has to opt out rather than opt in.
#
# A browser refuses to store a `Secure` cookie over plain HTTP, so a
# home-lab deployment served over HTTP cannot sign in with the default. That
# is the one case the opt-out exists for, and it is an operator's decision,
# so it is taken here — at runtime, per deployment — rather than by editing
# the committed configuration.
#
# The setting is not hidden: the deployment records it in the Audit Log.
cookie_secure =
  case System.get_env("VERITAS_SESSION_COOKIE_SECURE") do
    "false" -> false
    "true" -> true
    _ -> nil
  end

if cookie_secure != nil do
  config :veritas_web, session_cookie_secure: cookie_secure
end

# Whether the code reloader watches the source tree.
#
# A developer wants live reload. An operator watching the product while
# other people are writing code does not: the reloader recompiles on every
# save, so a half-written file makes the compile fail, and then **every
# request answers 500** — the running server cannot compile what it is
# looking at. That is not a broken feature; it is a broken deployment.
#
# The setting is taken at runtime, per deployment, so the same tree serves
# both: a developer reloads live, and an instance someone else is watching
# stays up. It is recorded in the Audit Log like every other setting a
# deployment takes.
code_reloader =
  case System.get_env("VERITAS_CODE_RELOADER") do
    "false" -> false
    "true" -> true
    _ -> nil
  end

if code_reloader == false do
  config :veritas_web, Veritas.Web.Endpoint, code_reloader: false
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :veritas_web, Veritas.Web.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/veritas_web/router\.ex$"E,
        ~r"lib/veritas_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :veritas_web, Veritas.Web.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :veritas_web, Veritas.Web.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :veritas_web, Veritas.Web.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :veritas_web, Veritas.Web.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :veritas, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end

# The role this node plays: `server` serves the web surface, `scheduler` does
# not. It is a **Default** — one variable, and the operator chooses.
#
# The three service roles the corpus names are the same release with
# different roles (docs/10 §Service Definitions).
role = System.get_env("VERITAS_ROLE", "server")

# The same rule as the port above: the test environment owns its own
# `server: false`, so a suite never opens a listening socket.
if config_env() != :test do
  config :veritas_web, Veritas.Web.Endpoint, server: role == "server"
end
