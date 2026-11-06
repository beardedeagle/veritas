# The runner for the harness's own tests.
#
# The harness is loaded at runtime from bench/harness/, so it is not in the
# product's compiled path and `mix test` does not compile it. Its tests are
# not in the product's suite either — they are run here:
#
#     MIX_ENV=test mix run --no-start bench/harness/test/run.exs
#
# The store is set up the way apps/veritas_core/test/test_helper.exs sets it
# up: a store that is already running if one is named, a store of the
# suite's own if not, and the tests that need a store **excluded** — not
# silently passed — if there is no store to test against.

harness = Path.expand("..", __DIR__)

order = [
  "stats.ex",
  "budget.ex",
  "raw.ex",
  "counters.ex",
  "explain.ex",
  "web.ex",
  "scenarios.ex",
  "gate.ex",
  "report.ex",
  "fixture.ex",
  "cli.ex"
]

known = Enum.map(order, &Path.join(harness, &1))
rest = harness |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort() |> Kernel.--(known)

for file <- known ++ rest do
  Code.require_file(file)
end

ExUnit.start()

alias Veritas.Core.Test.SurrealServer

server =
  case System.get_env("VERITAS_SURREAL_URL") do
    url when is_binary(url) and url != "" ->
      Veritas.Store.Config.configure({Veritas.Store.Surreal, []})
      IO.puts(:stderr, "[bench] using the store at #{url} (scratch Workspaces, cleaned up)")
      nil

    _ ->
      case SurrealServer.binary() do
        {:ok, path} ->
          {:ok, started} = SurrealServer.start()

          Application.put_env(:veritas_core, :surreal,
            url: SurrealServer.url(started),
            user: "root",
            pass: "root"
          )

          Veritas.Store.Config.configure({Veritas.Store.Surreal, []})
          IO.puts(:stderr, "[bench] SurrealDB (#{path}) started at #{SurrealServer.url(started)}")
          started

        :error ->
          ExUnit.configure(exclude: [needs_store: true])

          IO.puts(:stderr, """
          [bench] EXCLUDED — no store to test against.
          The tests that need a store did not run, and they are not counted as
          passing.
          """)

          nil
      end
  end

# The store this runner started is stopped when the suite is done. A runner
# that leaves a database running behind it is a runner that leaks a process
# every time it is used.
if server do
  ExUnit.after_suite(fn _results -> SurrealServer.stop(server) end)
end

# The store is configured, so the application may be started: its pool opens
# its connections when it boots, and it must open them against the store
# the tests are about to use.
{:ok, _started} = Application.ensure_all_started(:veritas_core)

for file <- Path.wildcard(Path.join(__DIR__, "*_test.exs")) do
  Code.require_file(file)
end
