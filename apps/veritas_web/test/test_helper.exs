ExUnit.start()

# The store the web tests run against.
#
# `VERITAS_SURREAL_URL` names a store that is already running; the tests use
# it when it is set, each in a scratch Workspace of its own, removed
# afterwards. With no URL, the suite starts its own SurrealDB.
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
        # holds a port nobody chose and memory nobody budgeted for, and it
        # is invisible — which is exactly why it needs a count to catch it.
        #
        # The hook is registered **here**, in the branch that started a
        # store. The branch above uses a store the suite does not own — the
        # operator's own, perhaps — and stopping that one would be stopping
        # something the suite was only lent.
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
