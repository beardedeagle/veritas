defmodule Veritas.Core.Dev.ProcessReaperTest do
  @moduledoc """
  The process policy, proved as decision-making.

  The three rules `docs/12` §Process Hygiene states are checked here against
  a fake adapter, so the tests do not depend on the host and run unchanged
  on Windows and Linux. The adapter that talks to the host is exercised
  separately, and only where it is safe to do so in CI.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Test.FakeProcess
  alias Veritas.Dev.Process.Reaper

  @root "/Users/dev/veritas"

  setup do
    on_exit(fn ->
      Application.delete_env(:veritas_core, :fake_listeners)
      Application.delete_env(:veritas_core, :fake_stopped)
      Application.delete_env(:veritas_core, :fake_stop_failures)
      Application.delete_env(:veritas_core, :fake_processes)
    end)

    :ok
  end

  test "a process attached under the project root is ours and is stopped" do
    FakeProcess.put_listeners([
      %{
        pid: 100,
        port: 7000,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var/store"]
      }
    ])

    {:ok, decisions} = plan()

    assert [%{action: :stop, pid: 100}] = decisions
  end

  test "a process with no attachment under the root is not ours, whatever it is called" do
    FakeProcess.put_listeners([
      %{
        pid: 101,
        port: 7001,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/other-project/var/store"]
      }
    ])

    {:ok, decisions} = plan()

    assert decisions == []
  end

  test "a process serving a kept port is never stopped" do
    FakeProcess.put_listeners([
      %{
        pid: 102,
        port: 8010,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/other-project"]
      }
    ])

    {:ok, decisions} = plan(keep: [8010])

    assert [%{action: :keep, pid: 102}] = decisions
  end

  test "a BEAM node's distribution port does not make it a candidate, and its own port keeps it" do
    # A BEAM node holds two listening sockets: its own port and the Erlang
    # distribution port on a random high port. The keep decision resolves to
    # the **process**, so the node on :4000 is kept whole.
    FakeProcess.put_listeners([
      %{
        pid: 103,
        port: 4000,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/veritas"]
      },
      %{
        pid: 103,
        port: 45_177,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/veritas"]
      }
    ])

    {:ok, decisions} = plan(keep: [4000])

    # One decision for the node, and it is kept: the distribution port did
    # not make it a candidate, and its own port kept it whole.
    assert [%{action: :keep, pid: 103}] = decisions
    refute Enum.any?(decisions, &(&1.action == :stop))
  end

  test "only beam.smp and surreal are ever candidates" do
    FakeProcess.put_listeners([
      %{
        pid: 104,
        port: 7002,
        executable: "/usr/local/bin/node",
        attachments: ["/Users/dev/veritas"]
      }
    ])

    {:ok, decisions} = plan()

    assert decisions == []
  end

  test "a recorded pid is ours even when its attachments are elsewhere" do
    FakeProcess.put_listeners([
      %{
        pid: 105,
        port: 7003,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/somewhere-else"]
      }
    ])

    {:ok, decisions} = plan(registry: %{105 => {"bench", 1_000_000_000, nil}})

    assert [%{action: :stop, pid: 105}] = decisions
  end

  test "the grace period leaves a process that was just registered alone" do
    FakeProcess.put_listeners([
      %{
        pid: 106,
        port: 7004,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/veritas"]
      }
    ])

    now = System.system_time(:second)
    {:ok, decisions} = plan(grace: 300, registry: %{106 => {"bench", now - 10, nil}})

    assert [%{action: :keep, pid: 106}] = decisions
  end

  test "the operator's list is added to the product's own ports, never replaces them" do
    # The environment is how a scheduler states it, so the test states it too
    # and takes it away again.
    System.delete_env("VERITAS_KEEP_PORTS")
    System.delete_env("VERITAS_SURREAL_PORT")

    on_exit(fn ->
      System.delete_env("VERITAS_KEEP_PORTS")
      System.delete_env("VERITAS_SURREAL_PORT")
    end)

    # The default is the product's own ports.
    assert Reaper.keep_ports() == [4000, 8010]

    # One extra port on the command line, and the product's own are still
    # kept: the operator's list says what **else** to keep, and it does not
    # say what to stop keeping.
    assert Reaper.keep_ports(keep: "4050") == [4000, 8010, 4050]

    # The environment says the same thing, the same way.
    System.put_env("VERITAS_KEEP_PORTS", "4050")
    assert Reaper.keep_ports() == [4000, 8010, 4050]

    # The command line wins over the environment, still additively, and the
    # spaces are the operator's typing.
    assert Reaper.keep_ports(keep: "9000, 9001") == [4000, 8010, 9000, 9001]
  end

  test "a pinned managed store port is kept" do
    # The store reads VERITAS_SURREAL_PORT; the reaper reads the same
    # variable, so a pinned store is kept by the reaper.
    System.delete_env("VERITAS_KEEP_PORTS")
    System.put_env("VERITAS_SURREAL_PORT", "8011")

    on_exit(fn ->
      System.delete_env("VERITAS_KEEP_PORTS")
      System.delete_env("VERITAS_SURREAL_PORT")
    end)

    assert 8011 in Reaper.keep_ports()
  end

  test "the product's own live store is kept, wherever its port is" do
    # The managed store takes a free port, so no fixed list of ports can
    # name it. The receipt says which port this store took, and the reaper
    # keeps the process holding it.
    receipt = write_receipt(51_796, 4242)

    FakeProcess.put_listeners([
      %{
        pid: 4242,
        port: 51_796,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var/surreal"]
      }
    ])

    {:ok, decisions} = plan(receipt: receipt)

    assert [%{action: :keep, pid: 4242, port: 51_796}] = decisions
  end

  test "a stale receipt does not keep a port for ever" do
    # The receipt names the port the store took, and that store is gone: the
    # port is held by something else now, and that something else is a
    # candidate for stopping. A receipt that kept a port for ever would be
    # worse than the defect it fixes.
    receipt = write_receipt(51_796, 4242)

    FakeProcess.put_listeners([
      %{
        pid: 9999,
        port: 51_796,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var/surreal"]
      }
    ])

    {:ok, decisions} = plan(receipt: receipt)

    assert [%{action: :stop, pid: 9999}] = decisions
  end

  test "a store with no receipt is not the product's own store" do
    # A store started on its own — a test, a tool — publishes no receipt, so
    # the reaper does not keep it, and does not keep the wrong thing while
    # stopping the right one.
    FakeProcess.put_listeners([
      %{
        pid: 4243,
        port: 51_797,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var/surreal"]
      }
    ])

    {:ok, decisions} = plan(receipt: write_receipt(51_798, 4244))

    assert [%{action: :stop, pid: 4243}] = decisions
  end

  test "reaping stops what the plan said and nothing else" do
    FakeProcess.put_listeners([
      %{
        pid: 107,
        port: 7005,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var"]
      },
      %{
        pid: 108,
        port: 7006,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/other"]
      }
    ])

    {:ok, stopped} = Reaper.reap(adapter: FakeProcess, root: @root, keep: [])

    assert Enum.count(stopped, &(&1.action == :stopped)) == 1
    assert FakeProcess.stopped() == [107]
  end

  test "a process that could not be stopped is reported as failed, not counted as stopped" do
    # A host that will not let this session signal a process refuses it, and
    # the reaper has to say so: a summary that counts only what it stopped
    # hides the failure behind a green number.
    FakeProcess.put_listeners([
      %{
        pid: 109,
        port: 7007,
        executable: "/opt/homebrew/bin/surreal",
        attachments: ["/Users/dev/veritas/var"]
      }
    ])

    FakeProcess.put_stopping_failures([109])

    {:ok, stopped} = Reaper.reap(adapter: FakeProcess, root: @root, keep: [])

    assert [%{action: :failed, pid: 109}] = stopped
    refute Enum.any?(stopped, &(&1.action == :stopped))
  end

  test "a registered process that holds no socket is still a candidate" do
    # The registry is what covers the processes the attachment scan cannot
    # see: a bench or a worker holds no listening socket, and a reaper that
    # only looked at sockets would leave it running for ever.
    FakeProcess.put_processes(%{
      110 => %{
        pid: 110,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/elsewhere"]
      }
    })

    {:ok, decisions} = plan(registry: %{110 => {"bench", 1_000_000_000, nil}})

    assert [%{action: :stop, pid: 110}] = decisions
  end

  test "a registered pid that is not running is not a candidate" do
    # The registry is a list of pids, and pids are reused; a pid that names
    # nothing is not a process to stop.
    {:ok, decisions} = plan(registry: %{111 => {"bench", 1_000_000_000, nil}})

    assert decisions == []
  end

  test "the reaper never stops the process it is running in" do
    # The reaper is a BEAM attached to this repository, so without this rule
    # it would stop itself the first time it was run with `--go`.
    FakeProcess.put_listeners([
      %{
        pid: Reaper.self_pid(),
        port: 7008,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/veritas"]
      }
    ])

    {:ok, decisions} = plan()

    assert [%{action: :keep, reason: reason}] = decisions
    assert reason == "it is the reaper itself"
  end

  test "a registered pid that has been recycled is not ours" do
    # A pid is reused; a process's **start time** is not. The registry entry
    # names a process that started at one moment, and the process holding the
    # pid now started at another — so it is not the process that was
    # registered, and the reaper must not stop it.
    FakeProcess.put_listeners([
      %{
        pid: 112,
        port: 7009,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/elsewhere"]
      }
    ])

    {:ok, decisions} = plan(registry: %{112 => {"bench", 1_000_000_000, 2_000_000}})

    assert decisions == []
  end

  test "a registered pid whose start time matches is ours" do
    FakeProcess.put_listeners([
      %{
        pid: 113,
        port: 7010,
        executable: "/opt/homebrew/bin/beam.smp",
        attachments: ["/Users/dev/elsewhere"]
      }
    ])

    {:ok, decisions} = plan(registry: %{113 => {"bench", 1_000_000_000, 1_000_000}})

    assert [%{action: :stop, pid: 113}] = decisions
  end

  # A receipt, as the managed store writes it: the port it took and the pid
  # it took it on.
  defp write_receipt(port, pid) do
    path =
      Path.join(
        System.tmp_dir!(),
        "veritas-receipt-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(%{"port" => port, "pid" => pid}))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp plan(opts \\ []) do
    Reaper.plan(
      Keyword.merge(
        [adapter: FakeProcess, root: @root, keep: [], grace: 0, registry: %{}],
        opts
      )
    )
  end
end
