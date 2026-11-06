defmodule Veritas.Core.Store.SurrealServerPortTest do
  @moduledoc """
  The harness's port, and the race it has to win.

  Two suites each ask the operating system for a free port, and the operating
  system may hand them the same one before either has bound it. The suite that
  lost then talks to the winner's store — or to nothing at all, when the
  winner's store has already been stopped — and a suite that had nothing
  wrong with it fails. On this project there is always another suite running,
  because there is always another agent working, so the suite's reliability
  depends on nothing it controls.

  These are the tests that say the harness **wins** the race:

    * **a store that cannot take its port is retried on a fresh one**, and
      the retry is **said** — a green run that hid a collision is a lie;
    * **two stores started at the same time get different ports**, and both
      answer.

  When the SurrealDB binary cannot be found, the module is excluded and the
  reason is printed. It is never reported as a pass.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Veritas.Core.Test.SurrealServer

  @moduletag :integration

  test "a store that cannot take its port is retried on a fresh one, and the retry is said" do
    # A port that is already taken: the store cannot have it, whatever the
    # harness does. The listener binds the **same address the store binds** —
    # a listener on the wildcard address does not stand in the way of a store
    # that binds the loopback.
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, taken} = :inet.port(socket)

    log =
      capture_log(fn ->
        assert {:ok, server} = SurrealServer.start(port: taken)

        # The retry moved the store off the port that was held.
        assert server.port != taken
        assert SurrealServer.healthy?(SurrealServer.url(server))

        SurrealServer.stop(server)
      end)

    # And the collision was said, not swallowed.
    assert log =~ "did not take port"
    assert log =~ "Retrying on a fresh port"
  end

  test "two stores started at the same time get different ports, and both answer" do
    task = Task.async(fn -> SurrealServer.start() end)

    {:ok, first} = SurrealServer.start()
    {:ok, second} = Task.await(task, 60_000)

    try do
      assert first.port != second.port
      assert SurrealServer.healthy?(SurrealServer.url(first))
      assert SurrealServer.healthy?(SurrealServer.url(second))
    after
      SurrealServer.stop(first)
      SurrealServer.stop(second)
    end
  end
end

# The gate. When the binary cannot be found, the integration tests are
# excluded and the reason is printed — never reported as a pass.
case Veritas.Core.Test.SurrealServer.binary() do
  {:ok, path} ->
    IO.puts(:stderr, "[integration] SurrealDB found at #{path} — the port tests will run")

  :error ->
    ExUnit.configure(exclude: [integration: true])

    IO.puts(:stderr, """

    [integration] EXCLUDED — the SurrealDB binary was not found.

    The port tests did not run, and they are not counted as passing.
    Looked in $SURREAL_BIN, /tmp/sdb/surreal and $PATH.
    Set SURREAL_BIN to the binary to run them.
    """)
end
