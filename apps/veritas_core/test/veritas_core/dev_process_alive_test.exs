defmodule Veritas.Core.Dev.ProcessAliveTest do
  @moduledoc """
  The liveness probe, proved against **real processes**.

  `kill -0` asks the kernel a question without touching the process: *does a
  process with this id exist?* The question has three answers, and the
  product has to tell them apart:

    * the process exists and this session may signal it — the probe succeeds;
    * the process exists and this session may **not** signal it — the probe
      fails and says "Operation not permitted";
    * the process does not exist — the probe fails and says "No such process".

  The last two both fail, so a probe that reads only the exit status calls a
  running process dead. That is a **false green**: the datastore leak check
  reports no orphans while a store is running, and the guardian that is
  supposed to keep the store alive tears it down instead.

  The tests here run against real processes on the host — one this session
  started, one this session killed, and one the host will not let this
  session signal — because the distinction under test is one no fake can
  make: only the kernel can say "that one exists and you may not touch it".

  The probe is `kill`, which the adapter already requires of the host; a
  host without it has no liveness answer at all, and the Windows adapter is
  the one for that host.
  """
  use ExUnit.Case, async: true

  alias Veritas.Dev.Process.Unix

  # The Unix adapter is proved on Unix: its probe is `kill`, which is POSIX.
  if match?({:win32, _}, :os.type()) do
    @moduletag :skip
  end

  @sleeper System.find_executable("sleep") || "/bin/sleep"

  test "a process this session started is alive" do
    {_port, pid} = start_sleeper()

    assert Unix.alive?(pid),
           "the process this test started (pid #{pid}) is running, so the probe must say so"
  end

  test "a process that has exited is not alive" do
    {port, pid} = start_sleeper()

    kill_and_await_close(port, pid)

    refute Unix.alive?(pid),
           "the process this test killed (pid #{pid}) is gone, so the probe must say so"
  end

  test "a process this session may not signal is alive" do
    # The host's init is the one process every session can see and no
    # ordinary session may signal: it exists, and the probe is refused. A
    # probe that reads only the exit status calls it dead, and a leak check
    # built on that call reports a clean host while a process is running.
    assert Unix.alive?(1),
           "pid 1 exists on every Unix host, so the probe must not call it gone"
  end

  test "the wording is what says the process is gone" do
    # The distinction itself, proved against the wording rather than against
    # a host: the two failures look the same until you read what they say.
    assert Unix.process_absent?("kill: 999999: No such process\n")
    refute Unix.process_absent?("kill: 1: Operation not permitted\n")
  end

  # A real process, started by this test: a `sleep` that would outlive the
  # test if the test did not stop it.
  defp start_sleeper do
    port = Port.open({:spawn_executable, @sleeper}, [{:args, ["30"]}])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      # A process the test started is the test's to stop.
      System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      close_port(port)
    end)

    {port, pid}
  end

  # The process is killed, and the port is waited for.
  #
  # The port closes when the process it started has exited **and** the
  # runtime has reaped it, so once the wait is over the pid is gone for
  # real: the probe is then asked about a pid that is certainly not in use.
  # There is no sleep in this wait — it ends when the port closes, and the
  # deadline is only the bound on how long that may take.
  defp kill_and_await_close(port, pid) do
    reference = Port.monitor(port)

    System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)

    receive do
      {:DOWN, ^reference, :port, ^port, _reason} -> :ok
    after
      5_000 ->
        flunk("the port did not close within 5 seconds, so the pid is not known to be gone")
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _error -> :ok
  end
end
