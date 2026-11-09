# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :veritas_web,
  generators: [context_app: :veritas]

# Configures the endpoint
config :veritas_web, Veritas.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # A fault is rendered as a small body, never as a page that carries the
  # request parameters, the internal namespace names or the raw engine error
  # body. `config/dev.exs` turns this on for a developer laptop and nowhere
  # else.
  debug_errors: false,
  render_errors: [
    formats: [html: Veritas.Web.ErrorHTML, json: Veritas.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Veritas.Web.PubSub,
  live_view: [signing_salt: "6Dfpsw9W"]

# The cost controls on the GraphQL surface. Each is a **Default**: an
# operator may change it. What is **Fixed** is that the limits are enforced
# at the edge of the API rather than left to the caller.
#
#   * `max_complexity` — the most a single document may cost. A list field
#     declares its own cost, so the cost of a document is the work it may
#     cause. 5_000 permits one list of a few hundred rows and refuses a
#     document that multiplies one query by aliasing it forty times.
#   * `token_limit` — the most tokens a document may lex. It bounds the cost
#     of parsing, which happens before the complexity analysis.
#   * `graphql_introspection` — whether the schema may be read back. On in
#     development, where the IDE needs it; off everywhere else.
config :veritas_web,
  graphql_max_complexity: 5_000,
  graphql_token_limit: 1_000,
  graphql_introspection: false

# Whether the session cookie carries `Secure` (`docs/09` §3).
#
# It is on by default, because the corpus says the cookie is `HttpOnly`,
# `Secure` and `SameSite=Lax`. A deployment serving plain HTTP to a home
# lab — which is not the internet — turns it off here, and the setting is
# recorded in the Audit Log of the deployment rather than hidden.
config :veritas_web, session_cookie_secure: true

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  veritas_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/veritas_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  veritas_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/veritas_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The Incident clock's replaceable timezone provider, pinned by the owner's
# approved dependency tranche. tz 0.28.4 bundles tzdata2026d. This configures
# the existing Incident seam only; no global Calendar database is set, and no
# UTC-only or fixed-offset fallback is introduced.
#
# Automatic updates are disabled by omission: no Tz.UpdatePeriodically or
# Tz.WatchPeriodically child is started. The bundled data therefore remains
# pinned until an explicit package update is chosen. Do not set
# :tz, :iana_version — forcing a version requires a custom :data_dir, while
# this install uses the package's bundled data.
config :veritas_core,
  incident_timezone_database: Tz.TimeZoneDatabase,
  incident_timezone_rules_version: "2026d"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# The datastore connection lives in `config/runtime.exs` and nowhere else.
#
# It used to be configured twice: once here and once there, both with the
# same shipped defaults. Two places to change a password is one place too
# many, and the copy in this file was the one a reader found first. The
# runtime configuration writes the same values to the port's `:store` options
# and to the Adapter's own fallback key, so the Adapter still finds a URL
# when an option is missing, and there is still only one set of values.
