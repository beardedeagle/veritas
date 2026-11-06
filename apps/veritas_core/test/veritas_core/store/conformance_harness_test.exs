defmodule Veritas.Core.Store.ConformanceHarnessTest do
  @moduledoc """
  The harness stops only what it started.

  The conformance harness installs an Adapter, runs the contract against it,
  and puts everything back. An Adapter may need a process of its own, and the
  harness starts it — and then stops it, because a process the harness started
  is the harness's to stop.

  The trap is an Adapter whose `start_link/1` is **idempotent**. The in-memory
  Adapter's is, by its own promise, and the application starts that Adapter's
  process at boot: so the process is already there, `start_link/1` answers
  `{:ok, pid}` for it, and a harness that reads ownership off the return shape
  stops a process it did not start — the application's supervised child.

  Stopping that child is a restart, and a supervisor allows three restarts in
  five seconds. The fourth takes the application down, and every test after it
  fails with a store it cannot reach: a harness defect that reads as a
  hundred broken tests.

  So the rule the harness keeps is the one that matters: **a process that was
  already running when the Adapter was installed survives the cleanup.**
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Store.Conformance

  # An Adapter with a process of its own, for the harness to start and stop.
  #
  # The process is **not linked**: a process the harness stops with `:shutdown`
  # would take the test down with it if the test were linked to it, and what is
  # under test here is the harness's bookkeeping, not a signal.
  defmodule Adapter do
    @moduledoc false

    def start_link(_opts) do
      Agent.start(fn -> :started end)
    end
  end

  describe "a process that was already running" do
    test "survives the cleanup, and so does the application" do
      supervisor = Process.whereis(Veritas.Core.Supervisor)
      server = Process.whereis(Veritas.Store.Memory.Server)

      assert is_pid(supervisor), "the application is not running"
      assert is_pid(server), "the application does not run the in-memory store"

      # Five cycles in quick succession. The in-memory Adapter's process is
      # started by the **application**, so every cycle is the harness stopping
      # a process it did not start — and three restarts in five seconds is all
      # a supervisor allows.
      for _ <- 1..5 do
        {:ok, ctx} = Conformance.prepare(Veritas.Store.Memory)
        Conformance.cleanup(ctx)
      end

      assert Process.whereis(Veritas.Core.Supervisor) == supervisor,
             "the application's supervisor is gone: the harness stopped a process it did not start"

      assert Process.whereis(Veritas.Store.Memory.Server) == server,
             "the application's in-memory store was restarted: the harness stopped a process it did not start"
    end
  end

  describe "a process the harness did start" do
    test "is stopped by the cleanup" do
      {:ok, ctx} = Conformance.prepare(Adapter)
      pid = ctx.pid

      assert is_pid(pid), "the harness did not start the Adapter's process"
      assert Process.alive?(pid)

      Conformance.cleanup(ctx)

      refute Process.alive?(pid),
             "the harness started this process, so the harness must stop it: the cleanup left it running"
    end
  end
end
