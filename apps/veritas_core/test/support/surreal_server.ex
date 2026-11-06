defmodule Veritas.Core.Test.SurrealServer do
  @moduledoc """
  Starts a real SurrealDB for the integration tests.

  The integration test must not depend on a store somebody else started: a
  shared store is shared state, and shared state is how an integration test
  becomes a flake. So this helper starts its own server, on its own port, with
  its own data directory, and stops it afterwards.

  ## When the binary is missing

  The tests are **excluded**, not silently passed. The test file checks
  `binary/0` at compile time; when the binary is absent it excludes the
  integration tag and prints why. A skipped integration test that reports
  itself as a pass is worse than no test at all, because it is a false signal.

  ## Where the binary is looked for

    * `$SURREAL_BIN`
    * `/tmp/sdb/surreal`
    * `surreal` on `$PATH`

  ## Waiting

  The only wait in the suite is here: the server is not up until it answers
  `/health`. That wait is bounded by a deadline and it is a readiness check,
  not a synchronisation sleep — nothing in the tests waits for a duration in
  order to let the product catch up.
  """

  @default_bind "127.0.0.1"
  @ready_deadline_ms 30_000
  @ready_interval_ms 50

  # How long the harness waits for the guardian to name the store. The
  # guardian writes the pidfile as soon as it has spawned the store, so this
  # is the time a machine takes to start one — not a wait for the product.
  @pidfile_deadline_ms 15_000

  require Logger

  alias Veritas.Store.Surreal.Guardian

  @doc """
  The SurrealDB binary, or `:error` when it cannot be found.
  """
  @spec binary() :: {:ok, String.t()} | :error
  def binary do
    candidates = [
      System.get_env("SURREAL_BIN"),
      "/tmp/sdb/surreal",
      System.find_executable("surreal")
    ]

    Enum.find_value(candidates, :error, fn candidate ->
      case candidate do
        nil -> nil
        path -> if File.exists?(path), do: {:ok, path}
      end
    end)
  end

  @doc "Whether the binary is available."
  @spec available?() :: boolean()
  def available?, do: binary() != :error

  @doc """
  Starts a server.

  Returns `{:ok, server}` with the server's url and data directory, or
  `{:error, reason}`.

  ## Options

    * `:port` — the port to use. The harness normally **reserves** a free
      port itself; a test names one to force a collision and prove the retry.

  ## The port race

  Two suites each ask the operating system for a free port, and the operating
  system may hand them the same one before either has bound it. The loser
  then talks to the winner's store — or to nothing at all, when the winner's
  store has already been stopped — and a suite that had nothing wrong with it
  fails.

  So the harness wins the race two ways: the port is **reserved** (the socket
  is held open until the instant before the store starts, which shrinks the
  window to the width of one process launch), and the store is then **proved
  to be ours** (the guardian writes the store's pid beside the data, and a
  store that lost the port leaves no live pid there). A collision is retried
  on a fresh port, and the retry is **said** — a green run that hid a
  collision is a lie.
  """
  @spec start(keyword()) :: {:ok, map()} | {:error, term()}
  def start(opts \\ []) do
    with {:ok, binary} <- binary(),
         {:ok, dir} <- data_dir() do
      start_on_a_port(binary, dir, opts, 1)
    end
  end

  # How many ports the harness will try before it gives up.
  @max_attempts 3

  defp start_on_a_port(binary, dir, opts, attempt) do
    {port, release} = choose_port(opts, attempt)

    # The reservation is released at the last possible instant: the store
    # cannot bind a port this process is still holding.
    release.()

    case start_server(binary, port, dir, opts) do
      {:ok, server} ->
        {:ok, server}

      {:error, reason} when reason in [:port_taken, :not_answering] ->
        retry_on_a_fresh_port(binary, dir, opts, attempt, port, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The first attempt uses the port the caller named — a test names one to
  # force a collision — and every retry a fresh reserved one.
  defp choose_port(opts, 1) do
    case Keyword.get(opts, :port) do
      nil -> reserve_a_port()
      port -> {port, fn -> :ok end}
    end
  end

  defp choose_port(_opts, _attempt), do: reserve_a_port()

  # A free port, **reserved**: the socket is held open until the instant
  # before the store starts, so the operating system cannot hand the same one
  # to another suite in the meantime.
  #
  # The reservation binds the **same address the store binds** — `127.0.0.1`.
  # A reservation on the wildcard address does not reserve anything against a
  # store that binds the loopback: on a BSD, with `SO_REUSEADDR` on both, the
  # second bind succeeds, and the reservation is worth nothing.
  defp reserve_a_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)

    {port, fn -> :gen_tcp.close(socket) end}
  end

  defp retry_on_a_fresh_port(binary, dir, opts, attempt, port, reason) do
    if attempt < @max_attempts do
      Logger.warning(
        "the store did not take port #{port} (#{reason}): something else is holding it, " <>
          "or the store did not come up. Retrying on a fresh port " <>
          "(attempt #{attempt + 1} of #{@max_attempts})."
      )

      start_on_a_port(binary, dir, opts, attempt + 1)
    else
      # The attempts are exhausted, and the data directory goes with them: it
      # was scratch space for a store that was never reached.
      File.rm_rf(dir)

      {:error, reason}
    end
  end

  @doc "Stops a server and removes its data directory."
  @spec stop(map()) :: :ok
  def stop(server) do
    if is_map(server) do
      # Every store started against this data directory is stopped, not only
      # the one the map names: a restart replaces the store's port, and the
      # map the test still holds names the old one. A store that can only be
      # reached through the map it was started with is a store that cannot be
      # stopped.
      for store <- stores_for(server[:dir]) do
        stop_store(store)
      end

      forget_stores(server[:dir])

      if dir = server[:dir] do
        File.rm_rf(dir)
      end
    end

    :ok
  end

  @doc """
  Stops a server and starts it again on the same data directory.

  This is how the durability obligation is proved: an acknowledged write must
  survive the loss of the process that wrote it.
  """
  @spec restart(map()) :: {:ok, map()} | {:error, term()}
  def restart(server) do
    binary = server.binary
    port = server.port
    dir = server.dir

    for store <- stores_for(dir) do
      stop_store(store)
    end

    forget_stores(dir)

    start_server(binary, port, dir, [])
  end

  @doc "The url of a running server."
  @spec url(map()) :: String.t()
  def url(server), do: "http://#{@default_bind}:#{server.port}"

  @doc """
  Whether a store is answering `/health`.

  The readiness check the harness makes, as a question an operator — or a
  test — can ask about a store it has the address of.
  """
  @spec healthy?(String.t()) :: boolean()
  def healthy?(url), do: match?({:ok, _body}, http_get("#{url}/health"))

  @doc """
  Removes a scratch Workspace from the store.

  The suite writes to a Workspace of its own and must not leave it behind.
  Removal is a root-context operation, so it is issued directly rather than
  through the Adapter — the Adapter has no business removing a Workspace.
  """
  @spec remove_workspace(String.t(), String.t(), keyword()) :: :ok
  def remove_workspace(url, workspace, credentials \\ []) do
    user = credentials[:user] || "root"
    pass = credentials[:pass] || "root"

    # The database inside the namespace first — a namespace cannot be removed
    # while a database inside it still exists — and then the namespace. Each
    # statement is issued on its own, so a failure in the first cannot stop
    # the second, and removing a Workspace that is already gone is not an
    # error: the whole thing is idempotent.
    http_post(url, "REMOVE DATABASE #{workspace}/#{workspace};", user, pass)
    http_post(url, "REMOVE NAMESPACE #{workspace};", user, pass)

    :ok
  end

  # A POST to the root context, for the statements the Adapter cannot make.
  #
  # The credentials are not optional: the root-level SQL endpoint refuses an
  # unauthenticated request, and a removal that is refused removes nothing
  # while looking like it worked.
  defp http_post(url, body, user, pass) do
    url = URI.parse(url)
    path = if url.path in [nil, ""], do: "/sql", else: url.path

    with {:ok, address} <- :inet.parse_address(String.to_charlist(url.host)) do
      case :gen_tcp.connect(address, url.port, [:binary, {:active, false}], 2_000) do
        {:ok, socket} ->
          request =
            "POST #{path} HTTP/1.1\r\n" <>
              "Host: #{url.host}\r\n" <>
              "Accept: application/json\r\n" <>
              "Authorization: Basic #{Base.encode64("#{user}:#{pass}")}\r\n" <>
              "Content-Type: text/plain\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n" <>
              "Connection: close\r\n\r\n" <> body

          :gen_tcp.send(socket, request)

          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, _response} ->
              :gen_tcp.close(socket)
              :ok

            {:error, _reason} ->
              :gen_tcp.close(socket)
              :ok
          end

        {:error, _reason} ->
          :ok
      end
    else
      {:error, _reason} -> :ok
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp start_server(binary, port, dir, opts) do
    args = [
      "start",
      "--user",
      Keyword.get(opts, :user, "root"),
      "--pass",
      Keyword.get(opts, :pass, "root"),
      "--bind",
      "#{@default_bind}:#{port}",
      "rocksdb:#{dir}"
    ]

    # The store runs under the **same guardian the node uses**: a program
    # that holds the store and stops it when this VM is gone. Closing a port
    # does not kill the program it started — OTP expects the *program* to
    # notice, and the only way to notice is to read its stdin to EOF, which
    # `surreal` does not do. A bare store is a store that outlives the test
    # run that started it, on a port nobody chose, holding memory nobody
    # budgeted for.
    pidfile = Path.join(dir, "veritas.store.pid")
    {program, arguments} = Guardian.command()

    port_ref =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, arguments},
        {:env, guardian_env(binary, args, pidfile, port)}
      ])

    server = %{binary: binary, handle: port_ref, port: port, dir: dir}

    # The store is **ours** only if the guardian wrote a live pid for it. A
    # store that lost the port to another suite exits at once, and the guardian
    # takes the pidfile with it — and a readiness check on the port would have
    # answered for the *other* store, which is how a suite with nothing wrong
    # with it ends up talking to somebody else's data.
    with {:ok, pid} <- await_our_store(pidfile) do
      case await_ready(port) do
        :ok ->
          server = Map.put(server, :store_pid, pid)
          remember_store(dir, %{handle: port_ref, pid: pid})
          count_store(server)
          {:ok, server}

        {:error, reason} ->
          halt(server)
          {:error, reason}
      end
    else
      {:error, reason} ->
        halt(server)
        {:error, reason}
    end
  end

  # The store is stopped and the data directory is **kept**: a retry needs it.
  defp halt(server) do
    if dir = server[:dir] do
      pid = store_pid(Path.join(dir, "veritas.store.pid"))
      if pid, do: ask_process(pid)
    end

    # The port may already be closed — the guardian exits with the store, and
    # closing a closed port raises.
    if handle = server[:handle] do
      if Port.info(handle), do: Port.close(handle)
    end

    :ok
  end

  # Waits for the guardian to name the store, and checks that the store it
  # names is running. The guardian writes the pidfile as soon as it has
  # spawned the store, so a pid that is already dead is a store that could
  # not take the port.
  defp await_our_store(pidfile) do
    deadline = System.monotonic_time(:millisecond) + @pidfile_deadline_ms

    do_await_our_store(pidfile, deadline)
  end

  defp do_await_our_store(pidfile, deadline) do
    case store_pid(pidfile) do
      pid when is_integer(pid) ->
        if alive?(pid) do
          {:ok, pid}
        else
          {:error, :port_taken}
        end

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@ready_interval_ms)
          do_await_our_store(pidfile, deadline)
        else
          {:error, :port_taken}
        end
    end
  end

  # The stores started against a data directory.
  #
  # A restart replaces the store's port, and the map the test still holds
  # names the old one, so the stores are remembered here — by the directory
  # they serve — and every one of them is stopped when the store is stopped.
  defp stores_for(nil), do: []

  defp stores_for(dir) do
    :persistent_term.get({__MODULE__, :stores, dir}, [])
  end

  defp remember_store(dir, store) do
    :persistent_term.put({__MODULE__, :stores, dir}, [store | stores_for(dir)])
    :ok
  end

  defp forget_stores(nil), do: :ok

  defp forget_stores(dir) do
    :persistent_term.put({__MODULE__, :stores, dir}, [])
    :ok
  end

  # The guardian's environment: the store's own command, the pidfile it
  # writes, the port the store is reached on, and this VM's process id.
  #
  # The names and the values are charlists: that is what a spawned program's
  # environment is made of.
  defp guardian_env(binary, args, pidfile, port) do
    command = Enum.join([binary | args], "\n")

    [
      {~c"VERITAS_STORE_COMMAND", String.to_charlist(command)},
      {~c"VERITAS_STORE_PIDFILE", String.to_charlist(pidfile)},
      {~c"VERITAS_STORE_PORT", String.to_charlist(Integer.to_string(port))},
      {~c"VERITAS_BEAM_PID", String.to_charlist(System.pid())}
    ]
  end

  # Bounded readiness wait. The server is ready when it answers /health.
  #
  # A **timeout** is not a slow store: it is something on the port that is not
  # the store. On a BSD, with `SO_REUSEADDR` on both sides, a store asked to
  # bind a port another socket holds binds it anyway — and the traffic goes to
  # the socket that was there first. The store is running and serving nobody.
  # So a connection that is accepted and never answered is a port that is not
  # ours, and it is reported at once rather than waited out.
  defp await_ready(http_port) do
    deadline = System.monotonic_time(:millisecond) + @ready_deadline_ms
    do_await_ready(http_port, deadline)
  end

  defp do_await_ready(http_port, deadline) do
    url = "http://#{@default_bind}:#{http_port}/health"

    case http_get(url) do
      {:ok, _body} ->
        :ok

      {:error, :timeout} ->
        {:error, :not_answering}

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@ready_interval_ms)
          do_await_ready(http_port, deadline)
        else
          {:error, "the SurrealDB server did not become ready within #{@ready_deadline_ms}ms"}
        end
    end
  end

  defp http_get(url) do
    url = URI.parse(url)

    # `gen_tcp.connect/4` takes an address tuple, not a string: a string
    # address raises :badarg rather than failing to connect.
    with {:ok, address} <- :inet.parse_address(String.to_charlist(url.host)) do
      case :gen_tcp.connect(address, url.port, [:binary, {:active, false}], 1_000) do
        {:ok, socket} ->
          request = "GET #{url.path} HTTP/1.1\r\nHost: #{url.host}\r\nConnection: close\r\n\r\n"

          case :gen_tcp.send(socket, request) do
            :ok ->
              # A store that is still starting accepts the connection and does
              # not answer yet. That is a **not ready**, not a crash: the
              # readiness check asks again, and a crash here would take the
              # whole run with it.
              case :gen_tcp.recv(socket, 0, 2_000) do
                {:ok, _response} ->
                  :gen_tcp.close(socket)
                  {:ok, :ok}

                {:error, reason} ->
                  :gen_tcp.close(socket)
                  {:error, reason}
              end

            {:error, reason} ->
              :gen_tcp.close(socket)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The stores this suite started that are **still running**.

  A store that survived the run is a leak, and a leak is invisible: it holds
  a port nobody chose and memory nobody budgeted for. The count is the only
  thing that catches it, so the suite fails on it.
  """
  @spec orphans() :: [integer()]
  def orphans do
    started_stores()
    |> Enum.filter(&alive?/1)
  end

  @doc "How many stores this suite has started."
  @spec started_count() :: non_neg_integer()
  def started_count, do: length(started_stores())

  defp count_store(server) do
    if pid = server[:store_pid] do
      :persistent_term.put({__MODULE__, :stores}, [pid | started_stores()])
    end

    :ok
  end

  defp started_stores, do: :persistent_term.get({__MODULE__, :stores}, [])

  # The store's liveness goes through the port, so the harness works on
  # every platform the product names: `kill` is POSIX-only, and the Windows
  # adapter asks the task manager instead.
  defp alive?(pid) when is_integer(pid), do: Veritas.Dev.Process.alive?(pid)

  defp alive?(_pid), do: false

  # The store's own process id: the guardian writes it beside the data the
  # store keeps, and it is the store's id and not the guardian's.
  defp store_pid(pidfile) do
    case File.read(pidfile) do
      {:ok, contents} ->
        case contents |> String.trim() |> String.split(" ") |> Enum.at(0) |> Integer.parse() do
          {pid, _rest} -> pid
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # The store is stopped, and it stops.
  #
  # The guardian is asked first, through the channel it has, so that the
  # store flushes its data directory on the way out. The store's own process
  # is asked as well, because the guardian may already be gone: a port is
  # closed when the process that opened it dies, and the `on_exit` that
  # stops a store runs after that process is gone. A store that can only be
  # reached through a closed channel is a store nobody can stop.
  defp stop_store(%{handle: handle, pid: pid}) do
    ask_guardian(handle)
    ask_process(pid)
    await_death(pid, 5_000)

    if Port.info(handle), do: Port.close(handle)

    :ok
  end

  defp ask_guardian(handle) do
    Port.command(handle, "stop\n")
  rescue
    _error -> :ok
  end

  defp ask_process(pid) when is_integer(pid) do
    _ = Veritas.Dev.Process.stop(pid)
    :ok
  end

  defp ask_process(_pid), do: :ok

  # Bounded wait for the store to be gone. It is a readiness check against a
  # deadline, not a sleep.
  defp await_death(pid, timeout) when is_integer(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await_death(pid, deadline)
  end

  defp await_death(_pid, _timeout), do: :ok

  defp do_await_death(pid, deadline) do
    if Veritas.Dev.Process.alive?(pid) do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_await_death(pid, deadline)
      else
        :ok
      end
    else
      :ok
    end
  end

  defp data_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "veritas_test_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end
end
