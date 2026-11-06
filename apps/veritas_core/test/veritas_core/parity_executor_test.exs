defmodule Veritas.Core.Parity.ExecutorTest do
  use ExUnit.Case, async: false

  alias Veritas.Core.Parity.Executor

  @repo Path.expand("../../../..", __DIR__)

  setup do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(@repo, "_build/codex-instrument-closeout-20261105/fixtures/#{id}")
    File.mkdir_p!(root)
    script = Path.join(root, "tree.exs")
    root_port = Path.join(root, "root.port")
    child_port = Path.join(root, "child.port")
    ready = Path.join(root, "ready")

    File.write!(script, ~S"""
    [portfile | children] = System.argv()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, number} = :inet.port(listener)
    File.write!(portfile, Integer.to_string(number))
    spawn(fn ->
      serve = fn serve ->
        {:ok, socket} = :gen_tcp.accept(listener)
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, "stop"} -> System.halt(0)
          {:ok, "ping"} -> :gen_tcp.send(socket, "pong"); :gen_tcp.close(socket); serve.(serve)
          _ -> :gen_tcp.close(socket); serve.(serve)
        end
      end
      serve.(serve)
    end)

    if children != [] do
      [childfile, readyfile, mode] = children
      Port.open({:spawn_executable, System.find_executable("elixir")},
        [:binary, args: ["--erl", "+S 2:2", __ENV__.file, childfile]])
      deadline = System.monotonic_time(:millisecond) + 5_000
      await = fn await ->
        result = with {:ok, value} <- File.read(childfile),
                      {port, ""} <- Integer.parse(value),
                      {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
          :gen_tcp.send(socket, "ping")
          reply = :gen_tcp.recv(socket, 0, 100)
          :gen_tcp.close(socket)
          reply
        end
        if result != {:ok, "pong"} do
          if System.monotonic_time(:millisecond) >= deadline, do: raise("child not ready")
          Process.sleep(10)
          await.(await)
        end
      end
      await.(await)
      File.write!(readyfile, "child answered ping")
      if mode == "exit", do: System.halt(0)
      if mode == "flood" do
        flood = fn flood -> IO.write(String.duplicate("noise", 1_024)); flood.(flood) end
        flood.(flood)
      end
    end
    Process.sleep(:infinity)
    """)

    # Independent teardown still works when the mechanism under test is broken.
    on_exit(fn -> Enum.each([root_port, child_port], &stop_fixture/1) end)
    {:ok, canary} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(canary) end)

    %{
      root: root,
      script: script,
      root_port: root_port,
      child_port: child_port,
      ready: ready,
      canary: canary
    }
  end

  test "a successful root does not leave its independently started child alive", fixture do
    {_output, status, clean?} = run(fixture, "exit", 10_000)
    assert status == 0
    assert clean?
    assert File.read!(fixture.ready) == "child answered ping"
    assert_closed(fixture.root_port)
    assert_closed(fixture.child_port)
    assert_canary(fixture.canary)
  end

  test "timeout stops the root and nested child without touching an unrelated listener",
       fixture do
    {_output, status, clean?} = run(fixture, "hang", 3_000)
    refute status == 0
    refute clean?
    assert File.read!(fixture.ready) == "child answered ping"
    assert_closed(fixture.root_port)
    assert_closed(fixture.child_port)
    assert_canary(fixture.canary)
  end

  test "caller cancellation stops its workers and preserves an unrelated listener", fixture do
    {caller, monitor} = spawn_monitor(fn -> run(fixture, "hang", 15_000) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    await(fn -> File.exists?(fixture.ready) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
    await(fn -> closed?(fixture.root_port) and closed?(fixture.child_port) end)
    assert_canary(fixture.canary)
  end

  @tag timeout: 10_000
  test "continuous output cannot starve the deadline or leave workers alive", fixture do
    {_output, status, clean?} = run(fixture, "flood", 3_000)
    refute status == 0
    refute clean?
    assert File.read!(fixture.ready) == "child answered ping"
    assert_closed(fixture.root_port)
    assert_closed(fixture.child_port)
    assert_canary(fixture.canary)
  end

  defp run(fixture, mode, timeout) do
    Executor.run(
      System.find_executable("elixir"),
      [
        "--erl",
        "+S 2:2",
        fixture.script,
        fixture.root_port,
        fixture.child_port,
        fixture.ready,
        mode
      ],
      fixture.root,
      timeout
    )
  end

  defp assert_closed(path), do: assert(closed?(path), "fixture still answers: #{path}")

  defp closed?(path) do
    port = path |> File.read!() |> String.to_integer()

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:error, :econnrefused} ->
        true

      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      other ->
        flunk("cannot establish listener closure: #{inspect(other)}")
    end
  end

  defp assert_canary(listener) do
    assert {:ok, port} = :inet.port(listener)
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100)
    :gen_tcp.close(socket)
  end

  defp stop_fixture(path) do
    if File.exists?(path) do
      port = path |> File.read!() |> String.to_integer()

      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :gen_tcp.send(socket, "stop")
          :gen_tcp.close(socket)

        {:error, :econnrefused} ->
          :ok

        error ->
          raise "fixture teardown failed: #{inspect(error)}"
      end
    end
  end

  defp await(condition) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    poll = fn poll ->
      unless condition.() do
        assert System.monotonic_time(:millisecond) < deadline, "lifecycle deadline expired"
        Process.sleep(10)
        poll.(poll)
      end
    end

    poll.(poll)
  end
end
