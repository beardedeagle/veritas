defmodule Veritas.Store.Surreal.ServerTest do
  @moduledoc """
  The datastore as a child process (ADR-048).

  **Nothing in this file changes the VM's state.**

  Every decision the child makes — the binary, the data directory, the port,
  the readiness deadline, the storage engine, and whether the node manages its
  own store at all — is a **pure function of an environment** that is handed
  in. A test asks the question by handing in the environment it wants to ask
  about, and changes nothing that the rest of the VM shares.

  The integration cases start the child with explicit settings, and the child
  publishes **nothing** into the Adapter's configuration: publishing is the
  node's decision, made by the node alone. While these tests run, every other
  test in the VM still sees the store it expects to see.

  A test that changes the VM's state for the duration of a test is a test
  that changes the VM's state for the duration of a test — whether or not it
  puts it back afterwards. `async: false` does not isolate it: a synchronous
  module can run while asynchronous modules are still in flight.
  """
  use ExUnit.Case, async: false

  alias Veritas.Store.Surreal.Server

  describe "the binary is found, not assumed" do
    test "the path the release bundles wins over SURREAL_BIN and PATH" do
      root = scratch_dir()
      bundled = Path.join([root, "vendor", "surreal", "surreal"])
      write_executable(bundled)

      env = %{
        "RELEASE_ROOT" => root,
        "SURREAL_BIN" => Path.join(root, "nowhere"),
        "PATH" => root
      }

      assert {:ok, ^bundled} = Server.binary(env)
    end

    test "SURREAL_BIN is used when the release bundles nothing" do
      root = scratch_dir()
      binary = Path.join(root, "surreal")
      write_executable(binary)

      env = %{"RELEASE_ROOT" => root, "SURREAL_BIN" => binary, "PATH" => root}

      assert {:ok, ^binary} = Server.binary(env)
    end

    test "PATH is the last resort" do
      root = scratch_dir()
      binary = Path.join(root, "surreal")
      write_executable(binary)

      env = %{
        "RELEASE_ROOT" => root,
        "SURREAL_BIN" => Path.join(root, "nowhere"),
        "PATH" => root
      }

      assert {:ok, ^binary} = Server.binary(env)
    end

    test "a binary that is not there is an answer, not a crash" do
      root = scratch_dir()

      env = %{
        "RELEASE_ROOT" => root,
        "SURREAL_BIN" => Path.join(root, "nowhere"),
        "PATH" => root
      }

      assert {:error, :not_found} = Server.binary(env)
    end
  end

  describe "the data directory is the operator's to choose" do
    test "the operator names it" do
      assert Server.data_dir(%{"VERITAS_DATA_DIR" => "/var/lib/veritas"}) ==
               "/var/lib/veritas/surreal"
    end

    test "the release's data directory is used when the operator names none" do
      assert Server.data_dir(%{"RELEASE_DATA_DIR" => "/var/lib/veritas-release"}) ==
               "/var/lib/veritas-release/surreal"
    end

    test "a development checkout keeps the store in the checkout" do
      assert Server.data_dir(%{}) =~ "var/surreal"
    end
  end

  describe "the port, the deadline and the engine" do
    test "the operator pins the port" do
      assert Server.port(%{"VERITAS_SURREAL_PORT" => "45671"}) == 45_671
    end

    test "a free port is chosen when the operator names none" do
      port = Server.port(%{})

      assert is_integer(port)
      assert port > 0
    end

    test "the operator sets the readiness deadline" do
      assert Server.ready_timeout(%{"VERITAS_SURREAL_READY_TIMEOUT_MS" => "1234"}) == 1234
    end

    test "the storage engine is a Default, not a constant" do
      assert Server.storage(%{"VERITAS_SURREAL_STORAGE" => "surrealkv"}) == "surrealkv"
      assert Server.storage(%{}) == "rocksdb"
    end
  end

  describe "who owns the store" do
    test "the node manages its own store when nobody named one" do
      assert Server.managed?(context()) == true
    end

    test "the node starts no store when the operator named one" do
      context = context(%{"VERITAS_SURREAL_URL" => "http://127.0.0.1:8000"})

      assert Server.managed?(context) == false
    end

    test "a deployment may turn the managed store off" do
      context = %{context() | store_managed?: false}

      assert Server.managed?(context) == false
    end

    test "another Adapter's store is not this child's to start" do
      context = %{context() | adapter: Veritas.Store.Memory}

      assert Server.managed?(context) == false
    end
  end

  describe "the child process" do
    setup do
      case Veritas.Core.Test.SurrealServer.binary() do
        {:ok, binary} ->
          root = scratch_dir()
          data_dir = Path.join(root, "surreal")
          File.mkdir_p!(data_dir)
          port = free_port()

          settings = %{
            binary: binary,
            bind: "127.0.0.1",
            port: port,
            url: "http://127.0.0.1:#{port}",
            data_dir: data_dir,
            ready_timeout: 30_000,
            storage: "rocksdb"
          }

          {:ok, settings: settings, root: root}

        :error ->
          {:ok, skip: "no SurrealDB binary to start"}
      end
    end

    @tag :integration
    test "the store answers, and the child says where it put it", %{
      settings: settings,
      root: root
    } do
      assert {:ok, pid} = start_supervised({Server, settings: settings})

      assert is_pid(pid)

      # The store is up: it answers its own readiness probe.
      assert :ok = health(settings.port)

      # The data directory is where the operator was told it is.
      assert File.dir?(settings.data_dir)
      assert Path.expand(settings.data_dir) == Path.expand(Path.join(root, "surreal"))

      # The status reports the store, and never the credential.
      status = Server.status()
      assert status.url == settings.url
      assert status.data_dir == settings.data_dir
      assert is_integer(status.store_pid)
      assert is_integer(status.guardian_pid)
      refute Map.has_key?(status, :pass)
      refute Map.has_key?(status, :password)
    end

    @tag :integration
    test "the child publishes nothing into the Adapter's configuration", %{
      settings: settings
    } do
      before = Application.get_env(:veritas_core, :surreal)

      assert {:ok, _pid} = start_supervised({Server, settings: settings})

      assert Application.get_env(:veritas_core, :surreal) == before
    end

    @tag :integration
    test "stopping the child stops the store, and leaves nothing running", %{
      settings: settings
    } do
      assert {:ok, _pid} = start_supervised({Server, settings: settings})
      assert :ok = health(settings.port)

      os_pid = Server.status().store_pid
      assert alive?(os_pid)

      stop_supervised(Server)

      # The store is gone: the port is closed and the process is not there.
      refute alive?(os_pid)
      refute health(settings.port) == :ok
    end

    @tag :integration
    test "the store survives the child, and comes back on the same port", %{
      settings: settings
    } do
      assert {:ok, _pid} = start_supervised({Server, settings: settings})
      assert :ok = health(settings.port)

      # A restart of the child is a restart of the store, on the same data
      # directory and the same port — the Adapter was told that port.
      stop_supervised(Server)

      assert {:ok, _pid} = start_supervised({Server, settings: settings})
      assert :ok = health(settings.port)
      assert Server.status().port == settings.port
      assert Server.status().data_dir == settings.data_dir
    end

    @tag :integration
    test "a store that dies is restarted, and the node says what happened", %{
      settings: settings
    } do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _pid} = start_supervised({Server, settings: settings})
          assert :ok = health(settings.port)

          first = Server.status().store_pid
          assert is_integer(first)

          # The store is stopped under the node. It is the store's own crash
          # domain: the node is still there, and the store is not.
          System.cmd("kill", ["-TERM", Integer.to_string(first)], stderr_to_stdout: true)

          # The supervisor starts the store again, on the same port and the
          # same data directory.
          assert eventually(fn -> health(settings.port) == :ok end)
          assert Server.status().store_pid != first
        end)

      # The node says what happened rather than failing silently.
      assert log =~ "the managed SurrealDB server exited with status"
    end

    @tag :integration
    test "a store that dies abruptly is restarted too", %{settings: settings} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _pid} = start_supervised({Server, settings: settings})
          assert :ok = health(settings.port)

          first = Server.status().store_pid
          assert is_integer(first)

          # SIGKILL: the store is gone with no chance to flush. The node
          # notices the same way it notices any other death.
          System.cmd("kill", ["-KILL", Integer.to_string(first)], stderr_to_stdout: true)

          assert eventually(fn -> health(settings.port) == :ok end)
          assert Server.status().store_pid != first
        end)

      assert log =~ "the managed SurrealDB server exited with status"
    end

    test "a binary that cannot be started is said, not swallowed" do
      root = scratch_dir()
      port = free_port()

      settings = %{
        binary: Path.join(root, "no-such-surreal"),
        bind: "127.0.0.1",
        port: port,
        url: "http://127.0.0.1:#{port}",
        data_dir: Path.join(root, "surreal"),
        ready_timeout: 1_000,
        storage: "rocksdb"
      }

      # Unlinked on purpose: the child exits with the reason it was stopped
      # for, and a linked test process would be taken down with it.
      #
      # The shape of the refusal depends on how the store is started: under
      # the guardian the guardian itself starts and the store fails inside
      # it; without a guardian the program cannot be started at all. Both
      # say why.
      assert {:error, reason} = GenServer.start(Server, settings: settings, timeout: 5_000)

      assert match?({:store_exited, _status, _tail}, reason) or
               match?({:store_not_started, _message}, reason)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The decisions the node would read, in an environment the test chooses.
  # The `PATH` is the machine's own, read and not written.
  defp context(env \\ %{}) do
    %{
      adapter: Veritas.Store.Surreal,
      env: Map.merge(%{"PATH" => System.get_env("PATH") || ""}, env),
      store_managed?: true
    }
  end

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "veritas_store_test_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(dir)
    dir
  end

  defp write_executable(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # The store's own readiness probe, asked from outside the child.
  defp health(port) do
    with {:ok, address} <- :inet.parse_address(~c"127.0.0.1"),
         {:ok, socket} <- :gen_tcp.connect(address, port, [:binary, {:active, false}], 1_000) do
      request = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

      case :gen_tcp.send(socket, request) do
        :ok ->
          response = :gen_tcp.recv(socket, 0, 2_000)
          :gen_tcp.close(socket)

          case response do
            {:ok, "HTTP/1.1 200" <> _rest} -> :ok
            _other -> {:error, :not_ready}
          end

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp alive?(os_pid) when is_integer(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp alive?(_other), do: false

  # A bounded wait for a condition. The supervisor restarts the store; the
  # test waits for the store to be back, rather than sleeping for a guess.
  defp eventually(condition, timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(condition, deadline)
  end

  defp do_eventually(condition, deadline) do
    cond do
      condition.() ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(100)
        do_eventually(condition, deadline)

      true ->
        false
    end
  end
end
