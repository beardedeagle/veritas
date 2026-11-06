import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :veritas_web, Veritas.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Zfmr6CfrVUnnp+1fcUFaXxNdhLTAzj0JKQaTxvu3vE8kHaSsZ/g4SKHPQ/wQ2euq",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The suite starts its own store — its own port, its own data directory —
# and points the Adapter at it (see `test/test_helper.exs`). The node's own
# managed store is therefore **off** here: a suite that also had one would be
# a suite with two stores, and the second one would be nobody's.
#
# This is a configuration decision, not a behaviour: the node manages its own
# store by default everywhere else (ADR-048).
config :veritas_core, :store_managed, false
