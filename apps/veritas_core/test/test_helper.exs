ExUnit.start()

# The store the suite runs against.
#
# `VERITAS_SURREAL_URL` names a store that is already running. The suite uses
# it when it is set, and each test works in a scratch Workspace of its own
# and removes it afterwards, so running against a live store leaves nothing
# behind. With no URL, the suite starts its own SurrealDB: its own port, its
# own data directory.
#
# The in-memory Adapter (`Veritas.Store.Memory`) would be the natural choice
# for a fast suite, but it is the subject of its own conformance run
# (`store/memory_conformance_test.exs`), and until it satisfies the contract
# it is not a store the rest of the suite may depend on.
alias Veritas.Core.Test.SurrealServer

case System.get_env("VERITAS_SURREAL_URL") do
  url when is_binary(url) and url != "" ->
    Veritas.Store.Config.configure({Veritas.Store.Surreal, []})

    IO.puts(:stderr, "[store] using the store at #{url} (scratch Workspaces, cleaned up)")

  _ ->
    case SurrealServer.binary() do
      {:ok, path} ->
        {:ok, server} = SurrealServer.start()

        Application.put_env(:veritas_core, :surreal,
          url: SurrealServer.url(server),
          user: "root",
          pass: "root"
        )

        Veritas.Store.Config.configure({Veritas.Store.Surreal, []})

        IO.puts(
          :stderr,
          "[store] SurrealDB (#{path}) started by the suite at #{SurrealServer.url(server)}"
        )

        # The store this suite started is stopped when the suite ends, and the
        # suite **fails** if one is still running afterwards. A leaked store
        # holds a port nobody chose and memory nobody budgeted for, and it is
        # invisible — which is exactly why it needs a count to catch it.
        ExUnit.after_suite(fn _ ->
          SurrealServer.stop(server)

          case SurrealServer.orphans() do
            [] ->
              :ok

            pids ->
              raise "the suite left #{length(pids)} SurrealDB server(s) running: #{inspect(pids)}"
          end
        end)

      :error ->
        ExUnit.configure(exclude: [needs_store: true])

        IO.puts(:stderr, """

        [store] EXCLUDED — no store to test against.

        Set VERITAS_SURREAL_URL to a running SurrealDB, or make the binary
        available (looked in $SURREAL_BIN, /tmp/sdb/surreal and $PATH).
        The tests that need a store did not run, and they are not counted as
        passing.
        """)
    end
end

# The store this suite runs against, captured before any test runs.
#
# The managed store publishes its URL into the application environment when it
# starts, and the Adapter reads that environment on **every request**. So a
# test that starts a store of its own redirects every other test in the run for
# as long as it holds — and a test that reads a different store reads a
# different transition table and a different Audit Log, which looks like a
# property that is wrong.
#
# The suite keeps its own answer here and puts it back before each test, so a
# test's Workspace is always the one this suite migrated. The seam that would
# remove the need for this is the Adapter resolving its store through the
# supervision tree instead of through a mutable global; that is a product
# change, and it is with the BEAM Engineer.
Application.put_env(
  :veritas_core,
  :test_store_configuration,
  Application.get_env(:veritas_core, :surreal)
)
