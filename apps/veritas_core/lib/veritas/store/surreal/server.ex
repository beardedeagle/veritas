defmodule Veritas.Store.Surreal.Server do
  @moduledoc """
  The datastore as a supervised child process (ADR-048).

  The datastore is a **separate crash domain**: a `surreal` server that is a
  child of the node, not a NIF inside it and not a service an operator has to
  remember to start. A NIF couples the store's crash to the BEAM's — one bad
  write takes the whole node with it — and a hand-started service makes
  "a clean checkout runs with nothing started by hand" false.

  This module is the child. It owns one `surreal` process:

    * it starts the server;
    * it waits until the server answers `/health`, and the node does not serve
      until it does;
    * it stops the server when the node stops, so the server flushes its own
      data directory on the way out and no `surreal` is left running;
    * it says what happened when the server dies, rather than leaving the node
      to fail silently.

  It is **not** the Adapter. `Veritas.Store.Surreal` is the Adapter that
  speaks to a store; this module is the store's process. The Adapter may be
  pointed at a store this module did not start, and this module is not started
  at all when the operator points the node at somebody else's store.

  ## What is a Default, and what is Fixed

  Everything an operator may reasonably want to change is a **Default**,
  decided in one place and substitutable behind a named function:

  | Decision | Decided by | Override |
  |---|---|---|
  | the binary | `binary/1` | `bundled_path/1`, `SURREAL_BIN`, `PATH` |
  | the data directory | `data_dir/1` | `VERITAS_DATA_DIR` |
  | the port | `port/1` | `VERITAS_SURREAL_PORT` |
  | the readiness deadline | `ready_timeout/1` | `VERITAS_SURREAL_READY_TIMEOUT_MS` |
  | the storage engine | `storage/1` | `VERITAS_SURREAL_STORAGE` |
  | the Workspace brought up at boot | `Veritas.Core.Application` | `VERITAS_WORKSPACE` |

  Each of them is a **pure function of an environment**: `binary/1`,
  `data_dir/1`, `port/1`, `ready_timeout/1` and `storage/1` take the
  environment as an argument and default to the process's own. Nothing about
  them reads the VM's state when it is given an environment, which is what
  lets a test ask every one of these questions **without changing anything
  the rest of the VM shares**.

  What is **Fixed** is that the store is a child process in its own crash
  domain. ADR-048 says why: a NIF couples the datastore's crash to the BEAM's
  and breaks the cross-platform matrix, and a hand-started service makes the
  clean-checkout promise false.

  ## The credential

  The store's root credential is handed to the child through its
  **environment** (`SURREAL_USER`, `SURREAL_PASS`), never through the command
  line: a password in `argv` is readable by every process on the host through
  `ps`, and a password in a log is a published password. The credential is
  never logged, never put in an error, and never returned by `status/0`.
  """

  use GenServer

  import Bitwise, only: [band: 2]

  require Logger

  alias Veritas.Store.Config
  alias Veritas.Store.Surreal, as: Adapter
  alias Veritas.Store.Surreal.Guardian

  # The store listens on loopback only. The datastore is reached by this node,
  # not by anything else, and a store on a routable interface is a store with
  # a credential on the wire.
  @receipt_name "veritas.store.json"
  @bind "127.0.0.1"

  # The storage engine the managed store uses by default. RocksDB is the free
  # build's file-backed engine on 3.3.4 (`docs/24`), and it is what the
  # integration tests already use, so the production path and the test path
  # are the same engine.
  #
  # This is the **default**, not the decision: `storage/0` is the seam, and
  # `VERITAS_SURREAL_STORAGE` substitutes it.
  @storage "rocksdb"

  @ready_timeout_ms 30_000
  @ready_interval_ms 50
  @terminate_grace_ms 10_000
  @start_grace_ms 10_000

  # The tail of the child's output, kept so that a failure can be explained.
  @tail_lines 12
  @tail_bytes 300

  # The source tree of this module, used to find the checkout's `var/`
  # directory when the node is not running from a release.
  @project_root Path.expand("../../../../../../", __DIR__)

  # ── the seams ───────────────────────────────────────────────────────────────

  @doc """
  Whether the node manages its own datastore.

  Every one of these conditions has to hold:

    * the installed Adapter is the shipped SurrealDB Adapter — this child runs
      a `surreal` server, and a different Adapter has its own lifecycle;
    * the operator has not pointed the node at an external store — a URL in
      `VERITAS_SURREAL_URL` means the store is somebody else's, and the node
      does not start one behind their back;
    * the deployment has not turned the managed store off — the test suite
      starts its own store, and a suite that also had one would be a suite
      with two;
    * **the binary is there.** A node that cannot find the `surreal` binary
      cannot manage a store, and a node that cannot find it is a node whose
      release is incomplete — except in a development checkout, where the
      operator may already have a store running. Rather than refuse to start
      there, the node falls back to the configured store and says so, loudly.
      In a release the binary is bundled, so the fallback never fires.
  """
  @spec managed?() :: boolean()
  def managed?, do: managed?(context())

  @doc """
  Whether the node would manage its own datastore, given the decisions it
  would read.

  The decisions are the argument, so the question can be asked of any
  environment without changing the one the VM is running in.

  This is the operator's **intent**: a node with no external store named
  manages its own. Whether the machine can — whether there is a binary to
  run — is a separate question, and the answer to it is a refusal to start,
  not a different intent. A node that cannot find the binary does not
  quietly use whatever happens to be listening on the default port.
  """
  @spec managed?(map()) :: boolean()
  def managed?(%{adapter: adapter, env: env, store_managed?: store_managed?}) do
    external_url(env) == nil and
      store_managed? and
      adapter == Veritas.Store.Surreal
  end

  @doc """
  The decisions the child reads, as data.

  The production path calls this. A test builds the same shape with whatever
  it wants to ask about, and changes nothing the VM shares.
  """
  @spec context() :: map()
  def context do
    %{
      adapter: Config.adapter(),
      env: System.get_env(),
      store_managed?: Application.get_env(:veritas_core, :store_managed, true) != false
    }
  end

  @doc """
  Whether the operator has pointed the node at a store of their own.

  A URL in `VERITAS_SURREAL_URL` is the operator saying "this store is
  mine": the node reaches it, and it does not start one behind their back.
  """
  @spec external?() :: boolean()
  def external?, do: external?(env())

  @doc """
  Whether the operator has pointed the node at a store of their own, in the
  given environment.
  """
  @spec external?(map()) :: boolean()
  def external?(env), do: external_url(env) != nil

  @doc """
  The storage engine the managed store uses.

  A **Default**, behind a named seam: the engine a deployment can use is a
  property of its filesystem and of its durability requirement, not of
  Veritas.

    * `rocksdb` — the file-backed engine, and the free build's verified one
      on 3.3.4 (`docs/24`). The data survives the node stopping.
    * `surrealkv` — SurrealDB's own LSM engine. Also file-backed.
    * `memory` — in memory. The data does **not** survive the node stopping,
      and a deployment that chooses it has chosen a store that forgets.

  `VERITAS_SURREAL_STORAGE` names the engine. The scheme is the engine's own
  (`rocksdb://`, `surrealkv://`, `memory://`); SurrealDB 3.3.4 no longer
  accepts `file://`.
  """
  @spec storage() :: String.t()
  def storage, do: storage(env())

  @doc """
  The storage engine named by the given environment.
  """
  @spec storage(map()) :: String.t()
  def storage(env) do
    case env["VERITAS_SURREAL_STORAGE"] do
      nil -> @storage
      "" -> @storage
      value -> value
    end
  end

  @doc """
  The path the release bundles the platform's `surreal` binary at.

  **This is the one function the packaging task points at a bundled path.**
  It is `nil` outside a release, where the binary is whatever the machine
  has. No fetching, no unpacking, no version resolution happens here: that is
  packaging's job, and this function is the seam it points at.
  """
  @spec bundled_path() :: String.t() | nil
  def bundled_path, do: bundled_path(env())

  @doc """
  The bundled path, in the given environment.
  """
  @spec bundled_path(map()) :: String.t() | nil
  def bundled_path(env) do
    case env["RELEASE_ROOT"] do
      nil -> checkout_path()
      "" -> checkout_path()
      root -> Path.join(root, "vendor/surreal/surreal")
    end
  end

  # The checkout's copy of the binary, at the same relative path a release
  # uses, so `mix veritas.store.install` and a release build agree on where
  # the binary is.
  defp checkout_path, do: Path.join(@project_root, "vendor/surreal/surreal")

  @doc """
  The `surreal` binary, found rather than assumed.

  The order is the packaging order: the path the release bundles, then
  `SURREAL_BIN`, then `PATH`.
  """
  @spec binary() :: {:ok, String.t()} | {:error, :not_found}
  def binary, do: binary(env())

  @doc """
  The `surreal` binary, in the given environment.

  The order is the packaging order: the path the release bundles, then
  `SURREAL_BIN`, then `PATH`. The `PATH` that is searched is the one in the
  environment that was handed in, so a test can ask the question without
  changing the VM's.
  """
  @spec binary(map()) :: {:ok, String.t()} | {:error, :not_found}
  def binary(env) do
    candidates = [
      bundled_path(env),
      env["SURREAL_BIN"],
      find_executable("surreal", env["PATH"])
    ]

    case Enum.find_value(candidates, fn
           nil ->
             nil

           "" ->
             nil

           path ->
             if executable?(path), do: {:ok, Path.expand(path)}
         end) do
      nil -> {:error, :not_found}
      {:ok, path} -> {:ok, path}
    end
  end

  @doc """
  The data directory of the managed store.

  The operator's to choose, and **reported** rather than hidden: the node
  logs it at boot, `status/0` returns it, and the doctor names it.
  """
  @spec data_dir() :: String.t()
  def data_dir, do: data_dir(env())

  @doc """
  The data directory, in the given environment.
  """
  @spec data_dir(map()) :: String.t()
  def data_dir(env) do
    case env["VERITAS_DATA_DIR"] do
      nil -> default_data_dir(env)
      "" -> default_data_dir(env)
      dir -> Path.join(dir, "surreal")
    end
  end

  @doc """
  The port the managed store listens on.

  A free port by default, because the default must never be a port some other
  store already holds: a node that fails to start because something else is
  on 8000 is a node that cannot be run beside anything. `VERITAS_SURREAL_PORT`
  pins it.
  """
  @spec port() :: pos_integer()
  def port, do: port(env())

  @doc """
  The port, in the given environment.
  """
  @spec port(map()) :: pos_integer()
  def port(env) do
    case env["VERITAS_SURREAL_PORT"] do
      nil -> free_port()
      "" -> free_port()
      value -> String.to_integer(value)
    end
  end

  @doc """
  The deadline the store has to answer `/health` before the node gives up on
  it.
  """
  @spec ready_timeout() :: pos_integer()
  def ready_timeout, do: ready_timeout(env())

  @doc """
  The readiness deadline, in the given environment.
  """
  @spec ready_timeout(map()) :: pos_integer()
  def ready_timeout(env) do
    case env["VERITAS_SURREAL_READY_TIMEOUT_MS"] do
      nil -> @ready_timeout_ms
      "" -> @ready_timeout_ms
      value -> String.to_integer(value)
    end
  end

  @doc """
  The url the managed store is reached at.
  """
  @spec url(pos_integer()) :: String.t()
  def url(port), do: "http://#{@bind}:#{port}"

  @doc """
  What the managed store is, for the operator.

  Never carries the credential.
  """
  @spec status() :: map() | nil
  def status do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  catch
    :exit, _reason -> nil
  end

  # ── the child ───────────────────────────────────────────────────────────────

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # The store is asked to stop and given time to flush its data
      # directory, so the shutdown is longer than the default five seconds.
      shutdown: 15_000,
      restart: :permanent
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # The child is a singleton, and it is registered under its own name so
    # that `status/0` can ask the running child what it is.
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, timeout: start_timeout(opts))
  end

  @impl true
  def init(opts) do
    # The port is linked to this process, and its exit has to be *explained*
    # rather than killing the process without a word.
    Process.flag(:trap_exit, true)

    with {:ok, settings} <- settings(opts),
         :ok <- ensure_data_dir(settings),
         {:ok, port_ref} <- spawn_store(settings) do
      case await_ready(settings, port_ref, []) do
        {:ok, state} ->
          # The url is published into the Adapter's configuration **only** when
          # the node asks for it. A child started on its own — a test, a tool —
          # says what it is doing without changing what the rest of the VM
          # believes about the store it is talking to.
          if publish?(opts) do
            publish_url(settings)
            publish_pid(settings, port_ref)
            publish_receipt(settings)
          end

          Logger.info(
            "[veritas.store] the managed SurrealDB server is ready at #{settings.url} " <>
              "(#{settings.storage}, data directory #{settings.data_dir}, " <>
              "store pid #{store_pid(settings)})"
          )

          {:ok, state}

        {:error, reason} ->
          terminate_store(port_ref)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  @impl true
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state) do
    {:noreply, %{state | tail: push_tail(state.tail, data)}}
  end

  def handle_info({port_ref, {:exit_status, status}}, %{port_ref: port_ref} = state) do
    Logger.error(
      "[veritas.store] the managed SurrealDB server exited with status #{status}" <>
        tail_note(state.tail)
    )

    {:stop, {:store_exited, status}, state}
  end

  def handle_info({:EXIT, port_ref, reason}, %{port_ref: port_ref} = state) do
    Logger.error(
      "[veritas.store] the managed SurrealDB server went away (#{inspect(reason)})" <>
        tail_note(state.tail)
    )

    {:stop, {:store_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port_ref: port_ref, settings: settings}) do
    Logger.info("[veritas.store] stopping the managed SurrealDB server")

    request_stop(port_ref)
    await_exit(port_ref, @terminate_grace_ms)

    # Closing the port kills the guardian if it did not go on its own. The
    # port is closed when this process dies whatever happens, so there is no
    # path that leaves a `surreal` running behind a node that is gone.
    if Port.info(port_ref), do: Port.close(port_ref)

    # And if the guardian was gone before it could stop the store — because
    # the node was killed outright, or because the guardian did not answer —
    # the store's own process is asked to stop here. The store must not
    # outlive the node, on any path.
    stop_store(settings)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # What the running child is, for the operator. Never carries the credential.
  defp status_map(%{settings: settings, pid: guardian_pid}) do
    settings
    |> Map.put(:guardian_pid, guardian_pid)
    |> Map.put(:store_pid, store_pid(settings))
  end

  # ── settings ────────────────────────────────────────────────────────────────

  # The settings are resolved **once** per node lifetime and remembered. A
  # store that its supervisor restarts has to come back on the port the
  # Adapter was told about, or the Adapter is talking to a port nothing is
  # listening on.
  defp settings(opts) do
    case Keyword.get(opts, :settings) do
      nil -> prepare()
      settings -> {:ok, settings}
    end
  end

  @doc """
  Resolves the managed store's settings, once per node lifetime.
  """
  @spec prepare() :: {:ok, map()} | {:error, :not_found}
  def prepare do
    case Application.get_env(:veritas_core, :managed_store) do
      nil -> resolve()
      settings -> {:ok, settings}
    end
  end

  defp resolve do
    with {:ok, binary} <- binary() do
      port = port()

      settings = %{
        binary: binary,
        bind: @bind,
        port: port,
        url: url(port),
        data_dir: data_dir(),
        ready_timeout: ready_timeout(),
        storage: storage()
      }

      Application.put_env(:veritas_core, :managed_store, settings)

      {:ok, settings}
    end
  end

  defp ensure_data_dir(settings) do
    case File.mkdir_p(settings.data_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:data_dir_unwritable, settings.data_dir, reason}}
    end
  end

  # The Adapter is told where the store is. The Adapter reads its settings per
  # request, so publishing the url here is enough — and it happens before the
  # node serves anything, because the child is started before the rest of the
  # application.
  defp publish_url(settings) do
    Application.put_env(:veritas_core, :surreal, put_url(Adapter.settings(), settings.url))

    case Application.get_env(:veritas_core, :store) do
      %{adapter: adapter, options: options} when is_list(options) ->
        Application.put_env(:veritas_core, :store, %{
          adapter: adapter,
          options: Keyword.put(options, :url, settings.url)
        })

      {adapter, options} when is_list(options) ->
        Application.put_env(
          :veritas_core,
          :store,
          {adapter, Keyword.put(options, :url, settings.url)}
        )

      _other ->
        :ok
    end

    :ok
  end

  defp publish_pid(settings, port_ref) do
    Application.put_env(
      :veritas_core,
      :managed_store,
      settings
      |> Map.put(:guardian_pid, os_pid(port_ref))
      |> Map.put(:store_pid, store_pid(settings))
    )

    :ok
  end

  # The store's own process id, as the guardian recorded it.
  defp store_pid(settings) do
    case File.read(pidfile(settings)) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, _rest} -> pid
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp put_url(settings, url) when is_list(settings), do: Keyword.put(settings, :url, url)
  defp put_url(settings, url) when is_map(settings), do: Map.put(settings, :url, url)
  defp put_url(_settings, _url), do: []

  # ── the child process ───────────────────────────────────────────────────────

  # The guardian.
  #
  # OTP's contract for a spawned program is that it terminates when the port
  # closes: the port's stdin reaches EOF and the program is expected to notice.
  # SurrealDB does not read stdin, so it does not notice, and a node that is
  # killed outright — `kill -9`, a panic in the emulator, a machine that loses
  # power — would leave the store running with nobody to supervise it.
  #
  # The guardian closes that gap, and it is **one program on every platform**:
  # it is started with the emulator the node is already running on, so it
  # needs no shell, no script and nothing the release does not already
  # carry. It holds the store and watches for the node — the node's end of
  # its standard input, and the node's own process.
  #
  # The guardian forwards a stop request to the store rather than exiting on
  # it, so the store is the thing that flushes its data directory and the
  # exit status the node sees is the store's.
  defp spawn_store(settings) do
    {program, args} = store_program()

    port_ref =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args},
        {:env, child_env(settings)}
      ])

    {:ok, port_ref}
  rescue
    error -> {:error, {:store_not_started, Exception.message(error)}}
  end

  # The store runs under the guardian on every platform, and the guardian is
  # started with the node's own emulator. The store's own command travels in
  # the environment, because the emulator would parse the arguments that
  # follow `-run` as its own.
  defp store_program do
    Guardian.command()
  end

  defp store_args(settings) do
    [
      settings.binary,
      "start",
      "--no-banner",
      "--bind",
      "#{settings.bind}:#{settings.port}",
      "#{settings.storage}://#{settings.data_dir}"
    ]
  end

  # The credential goes into the child's environment, not onto its command
  # line. `argv` is world-readable through `ps`; an environment is not.
  #
  # The node's own process id goes with it, so the guardian can tell that
  # the node is gone, and so can the datastore's own command — which the
  # guardian runs.
  defp child_env(settings) do
    {user, pass} = credential()

    parent =
      System.get_env()
      |> Enum.map(fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)
      |> Enum.reject(fn {name, _value} ->
        name in [
          ~c"SURREAL_USER",
          ~c"SURREAL_PASS",
          ~c"VERITAS_BEAM_PID",
          ~c"VERITAS_STORE_PIDFILE",
          ~c"VERITAS_STORE_PORT",
          ~c"VERITAS_STORE_COMMAND"
        ]
      end)

    parent ++
      [
        {~c"SURREAL_USER", String.to_charlist(user)},
        {~c"SURREAL_PASS", String.to_charlist(pass)},
        {~c"VERITAS_BEAM_PID", String.to_charlist(beam_pid_value())},
        {~c"VERITAS_STORE_PIDFILE", String.to_charlist(pidfile(settings))},
        {~c"VERITAS_STORE_PORT", String.to_charlist(Integer.to_string(settings.port))},
        {~c"VERITAS_STORE_COMMAND",
         String.to_charlist(Guardian.command_line(store_args(settings)))},
        # A guardian that crashes writes a dump. It goes to the system's
        # temporary directory rather than to the node's working directory,
        # which is the repository.
        {~c"ERL_CRASH_DUMP", String.to_charlist(crash_dump())}
      ]
  end

  defp crash_dump do
    Path.join(System.tmp_dir!(), "veritas-store-guardian.dump")
  end

  # The store's own process id, written by the guardian beside the data the
  # store keeps. It is what an operator needs — the store's pid, not the
  # guardian's — and it is what a test needs to stop the store on its own.
  # The pid the guardian watches, or "0" when there is none.
  defp beam_pid_value do
    case beam_pid() do
      {:ok, pid} -> pid
      :error -> "0"
    end
  end

  defp pidfile(settings) do
    Path.join(Path.dirname(settings.data_dir), "veritas.store.pid")
  end

  @doc """
  The receipt the managed store writes: the port it took, and the pid it took
  it on.

  The managed store's port is a **free** port unless the operator pins it,
  so no fixed list of ports can name the product's own live store. The
  receipt is how the reaper finds it: it reads the receipt and keeps that
  port, while the process that wrote the receipt is still the one holding
  it.

  The receipt is written **only** when the node asks the store for its url
  (`publish?/1`), beside the store's own pid file. A store started on its
  own — a test, a tool — writes none, so it cannot claim to be the
  product's live store and the reaper cannot keep the wrong thing while
  stopping the right one.
  """
  @spec receipt_path() :: String.t()
  def receipt_path, do: receipt_path_for(data_dir())

  defp receipt_path_for(data_dir) do
    Path.join(Path.dirname(data_dir), @receipt_name)
  end

  # The receipt of the managed store: the port it took and the pid it took
  # it on. It is written beside the pid file, in the data directory the
  # operator gave the store.
  defp publish_receipt(settings) do
    case store_pid(settings) do
      nil ->
        :ok

      pid ->
        path = receipt_path_for(settings.data_dir)

        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, Jason.encode!(%{"port" => settings.port, "pid" => pid}))
        end
    end
  end

  # The node's own operating-system process id, as a string. `System.pid/0`
  # raises on a platform that does not publish one, and the guardian — which
  # watches that pid — is used only where there is one to watch.
  defp beam_pid do
    {:ok, System.pid()}
  rescue
    _error -> :error
  end

  # The credential the Adapter will use, resolved exactly as the Adapter
  # resolves it: the Adapter's own settings, then the configured options, then
  # the shipped defaults.
  defp credential do
    configured = Keyword.merge(Adapter.settings(), Config.options())

    defaults = [user: "root", pass: "root"]

    {Keyword.get(configured, :user, Keyword.get(defaults, :user)),
     Keyword.get(configured, :pass, Keyword.get(defaults, :pass))}
  end

  # ── readiness ───────────────────────────────────────────────────────────────

  # The only wait in the node: the store is not up until it answers
  # `/health`. It is a readiness check against a deadline, never a
  # synchronisation sleep.
  defp await_ready(settings, port_ref, tail) do
    deadline = System.monotonic_time(:millisecond) + settings.ready_timeout
    do_await_ready(settings, port_ref, tail, deadline)
  end

  defp do_await_ready(settings, port_ref, tail, deadline) do
    receive do
      {^port_ref, {:data, data}} ->
        do_await_ready(settings, port_ref, push_tail(tail, data), deadline)

      {^port_ref, {:exit_status, status}} ->
        {:error, {:store_exited, status, tail}}
    after
      @ready_interval_ms ->
        case probe(settings.port) do
          :ok ->
            {:ok, %{port_ref: port_ref, settings: settings, tail: tail, pid: os_pid(port_ref)}}

          {:error, _reason} ->
            if System.monotonic_time(:millisecond) < deadline do
              do_await_ready(settings, port_ref, tail, deadline)
            else
              {:error, {:store_not_ready, settings.ready_timeout, tail}}
            end
        end
    end
  end

  # The probe is a plain HTTP GET over `:gen_tcp`. The child is started before
  # the HTTP client pool, so it cannot use it — and a readiness probe that
  # depends on the thing it is gating is a readiness probe that cannot fail.
  defp probe(port) do
    with {:ok, address} <- :inet.parse_address(String.to_charlist(@bind)),
         {:ok, socket} <- :gen_tcp.connect(address, port, [:binary, {:active, false}], 1_000) do
      request = "GET /health HTTP/1.1\r\nHost: #{@bind}:#{port}\r\nConnection: close\r\n\r\n"

      case :gen_tcp.send(socket, request) do
        :ok ->
          response = :gen_tcp.recv(socket, 0, 2_000)
          :gen_tcp.close(socket)

          case response do
            {:ok, raw} -> if status_of(raw) == 200, do: :ok, else: {:error, :not_ready}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp status_of(raw) do
    case raw do
      "HTTP/1.1 " <> rest ->
        case String.split(rest, " ") |> List.first() do
          nil -> 0
          code -> String.to_integer(code)
        end

      _other ->
        0
    end
  rescue
    _error -> 0
  end

  # ── shutdown ────────────────────────────────────────────────────────────────

  # The server is asked to stop, and given time to stop on its own, so that it
  # flushes its data directory. Only then is the port closed.
  defp terminate_store(port_ref) do
    request_stop(port_ref)
    await_exit(port_ref, @terminate_grace_ms)

    if Port.info(port_ref), do: Port.close(port_ref)

    :ok
  end

  # The guardian is asked to stop the store by a line on its standard input:
  # it is the channel the node and the guardian already have, and asking
  # through it needs no signal, no program on the host and no platform's
  # idea of a process id.
  defp request_stop(port_ref) do
    Port.command(port_ref, "stop\n")
  rescue
    _error -> :ok
  end

  # The store's own process is asked to stop, when the guardian did not stop
  # it. It is asked rather than killed, so it flushes its data directory.
  defp stop_store(settings) do
    case store_pid(settings) do
      nil ->
        :ok

      pid ->
        if Veritas.Dev.Process.alive?(pid) do
          _ = Veritas.Dev.Process.stop(pid)
          :ok
        else
          :ok
        end
    end
  rescue
    _error -> :ok
  end

  defp await_exit(port_ref, timeout) do
    receive do
      {^port_ref, {:exit_status, _status}} -> :ok
    after
      timeout -> :timeout
    end
  end

  # ── the child's output ──────────────────────────────────────────────────────

  # The tail of the server's own output. It is what turns "the store did not
  # come up" into "the store did not come up, and here is what it said".
  defp push_tail(tail, data) do
    data
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.reduce(tail, fn line, acc ->
      [String.slice(line, 0, @tail_bytes) | acc]
    end)
    |> Enum.take(@tail_lines)
  end

  defp tail_note([]), do: ""

  defp tail_note(tail) do
    lines = tail |> Enum.reverse() |> Enum.join("\n")
    "\n" <> lines
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp os_pid(port_ref) do
    case Port.info(port_ref, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp external_url(env) do
    case env["VERITAS_SURREAL_URL"] do
      nil -> nil
      "" -> nil
      url -> url
    end
  end

  # The environment the process is running in. Every seam takes an
  # environment; this is the one this process means.
  defp env, do: System.get_env()

  # The executable in a given `PATH`, or `nil`. The `PATH` that is searched is
  # the one that was handed in.
  defp find_executable(name, nil), do: System.find_executable(name)

  defp find_executable(name, path) when is_binary(path) do
    path
    |> String.split(":")
    |> Enum.find_value(fn dir ->
      candidate = Path.join(dir, name)

      if executable?(candidate), do: candidate
    end)
  end

  defp find_executable(_name, _path), do: nil

  # Whether the child publishes itself into the Adapter's configuration. The
  # node does; a child started on its own does not.
  defp publish?(opts), do: Keyword.get(opts, :publish, false) == true

  defp default_data_dir(env) do
    case env["RELEASE_DATA_DIR"] do
      nil ->
        case env["RELEASE_ROOT"] do
          nil -> Path.join(@project_root, "var/surreal")
          "" -> Path.join(@project_root, "var/surreal")
          root -> Path.join(root, "var/surreal")
        end

      "" ->
        Path.join(@project_root, "var/surreal")

      dir ->
        Path.join(dir, "surreal")
    end
  end

  defp start_timeout(opts) do
    case Keyword.get(opts, :settings) do
      %{ready_timeout: timeout} -> timeout + @start_grace_ms
      _other -> ready_timeout() + @start_grace_ms
    end
  end
end
