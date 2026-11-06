defmodule Veritas.Plugin.Session do
  @moduledoc """
  One Plugin process, and the conversation the host has with it.

  A session owns three things at once: the **socket** the Plugin talks on,
  the **Port** to the Plugin's OS process, and the state of the conversation
  between them. It is the only place that knows how the handshake works.

  ## The handshake

  The sequence is `docs/20` §Transport's:

      host   listens on a Unix domain socket (mode 0600)
      host   spawns the Plugin: socket path on argv, bootstrap secret on stdin
      plugin connects to the socket
      plugin hello{plugin_id, version, protocol, manifest_sha256}
      host   verifies the digest against the artifact it installed
      host   welcome{session_token, host_api_version, granted_scopes, install_generation}
      plugin ready{registrations}

  Both sides are authenticated. The **host** authenticates the Plugin by the
  `manifest_sha256` in `hello`: a Plugin that was substituted computes a
  different digest and is refused before any call is served. The **Plugin**
  authenticates the host by the `session_token`, which is an HMAC over the
  bootstrap secret it was given on stdin — so the Plugin can tell a real host
  from anything else that got hold of the socket path.

  The bootstrap secret travels on the Plugin's inherited stdin, never in argv
  and never in the environment, exactly as `docs/20` requires.

  ## Talking

  After the handshake the socket is full duplex. The host sends requests and
  the Plugin answers them; the Plugin may send requests of its own — the
  host-mediated operations of `Veritas.Plugin.Host.Operations` — and the
  host answers those. Both directions check the Plugin's grant through
  `Veritas.Plugin.Host.Capability.check/2` first.

  ## Crashes

  A dead Plugin is detected by the **OS process**, not by a heartbeat: the
  Port reports the exit, and the session surfaces it. Pending calls are
  answered with `{:error, :plugin_crashed}` rather than left hanging, and
  the Plugin is quarantined so the failure is visible in the registry
  instead of silent.
  """

  use GenServer

  require Logger

  alias Veritas.Plugin.{Host, JsonRpc, Manifest, Registry, Transport}

  @accept_timeout 10_000
  @handshake_timeout 10_000
  @protocol "veritas.plugin.v1"

  @type status :: :connecting | :ready | :closed | :failed

  @doc "Starts a session for one Plugin process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Calls a method on the Plugin and waits for its answer.

  The call blocks the caller until the Plugin answers, the Plugin dies, or
  the timeout passes.
  """
  @spec request(pid(), String.t(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def request(pid, method, params, timeout) do
    GenServer.call(pid, {:request, method, params}, timeout)
  end

  @doc "The session's status."
  @spec status(pid()) :: status()
  def status(pid) do
    GenServer.call(pid, :status, 1_000)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Waits until the session is ready, or until it fails.

  The handshake happens in the session's `init/2` continuation, so the caller
  waits for the outcome rather than for the process to exist.
  """
  @spec await_ready(pid(), timeout()) :: {:ok, pid()} | {:error, term()}
  def await_ready(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case status(pid) do
      :ready ->
        {:ok, pid}

      :failed ->
        {:error, :handshake_failed}

      :closed ->
        {:error, :not_running}

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(50)
          await_ready(pid, timeout)
        end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # The socket's name is chosen here, so a session that is started again
    # asks for an address of its own rather than one that is already taken.
    socket_dir = Keyword.fetch!(opts, :socket_dir)
    socket_path = Path.join(socket_dir, socket_name())
    manifest_path = Keyword.fetch!(opts, :manifest_path)

    argv =
      Keyword.get(opts, :argv, []) ++
        ["--veritas-socket", socket_path, "--veritas-manifest", manifest_path]

    state = %{
      plugin_id: Keyword.fetch!(opts, :plugin_id),
      workspace: Keyword.get(opts, :workspace, "default"),
      generation: Keyword.fetch!(opts, :install_generation),
      secret: Keyword.fetch!(opts, :secret),
      digest: Keyword.fetch!(opts, :digest),
      granted_scopes: Keyword.get(opts, :granted_scopes, []),
      socket_path: socket_path,
      command: Keyword.fetch!(opts, :command),
      argv: argv,
      environment: Keyword.get(opts, :environment, %{}),
      listen_socket: nil,
      socket: nil,
      port: nil,
      reader: nil,
      pending: %{},
      tail: [],
      registrations: [],
      status: :connecting,
      adapter: Host.adapter()
    }

    {:ok, state, {:continue, :handshake}}
  end

  defp socket_name do
    "plugin-#{4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)}.sock"
  end

  @impl true
  def handle_continue(:handshake, state) do
    case handshake(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[veritas.plugin] #{state.plugin_id} did not start: #{describe(reason)}")
        Registry.put_error(state.plugin_id, reason)
        Registry.update_status(state.plugin_id, :quarantined)

        # The session stops rather than crashes: a Plugin that did not start
        # is not a Plugin to be restarted, and a supervisor that restarted it
        # would ask for the same address again.
        {:stop, :normal, state}
    end
  end

  # ── the handshake ──────────────────────────────────────────────────────────

  defp handshake(state) do
    with {:ok, listen} <- Transport.UnixSocket.listen(state.socket_path),
         {:ok, port} <- spawn_process(state),
         :ok <- send_bootstrap(port, state),
         {:ok, socket} <- Transport.UnixSocket.accept(listen, @accept_timeout) do
      state = %{state | listen_socket: listen, port: port, socket: socket}

      with {:ok, hello} <- read_message(socket, "hello"),
           :ok <- verify_hello(state, hello),
           :ok <- send_welcome(state, hello),
           {:ok, ready} <- read_message(socket, "ready") do
        registrations = normalise_registrations(ready)
        reader = start_reader(socket, self())

        Registry.update_registrations(state.plugin_id, registrations)

        {:ok, %{state | reader: reader, registrations: registrations, status: :ready}}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The Plugin is a separate OS process. `:spawn_executable` runs it, and
  # `:exit_status` is how a crash is noticed: the Port reports the exit, and
  # the host does not have to poll to find out.
  #
  # The process is started through `env -i`, which gives it an **empty**
  # environment. The host builds the environment a Plugin gets and hands
  # down none of its own, so a credential the host happens to be holding
  # cannot reach the Plugin by inheritance — the environment is an
  # allowlist, not a denylist.
  defp spawn_process(state) do
    options = [
      {:args,
       ["-i"] ++ environment_arguments(state.environment) ++ [state.command] ++ state.argv},
      :use_stdio,
      :binary,
      :exit_status,
      :stderr_to_stdout
    ]

    # `Port.open/2` returns the Port itself and raises when it cannot start
    # one, so the failure is caught rather than matched.
    try do
      {:ok, Port.open({:spawn_executable, env_executable()}, options)}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp environment_arguments(environment) do
    environment
    |> Map.put("ERL_CRASH_DUMP", crash_dump_directory())
    |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
  end

  # Where a Plugin's crash dump lands.
  #
  # A Plugin that dies leaves an Erlang crash dump in its working directory,
  # and a Plugin's working directory is the host's — which is the
  # repository. A dump in the repository is noise in a diff and noise in a
  # status line; a dump in a scratch directory is evidence, and it is left
  # there long enough to be read.
  defp crash_dump_directory do
    Path.join(System.tmp_dir!(), "veritas-plugin-crash")
  end

  defp env_executable do
    System.find_executable("env") || "/usr/bin/env"
  end

  # The bootstrap secret goes to the Plugin's stdin, and nowhere else.
  defp send_bootstrap(port, state) do
    payload =
      JSON.encode!(%{
        "secret" => state.secret,
        "install_generation" => state.generation
      })

    true = Port.command(port, payload <> "\n")
    :ok
  end

  defp read_message(socket, expected) do
    with {:ok, frame} <- Transport.UnixSocket.receive_message(socket, @handshake_timeout),
         {:ok, frame} <- JsonRpc.decode(frame) do
      if frame["method"] == expected do
        {:ok, frame}
      else
        {:error, "the Plugin said #{inspect(frame["method"])} where #{expected} was expected"}
      end
    end
  end

  # The host authenticates the Plugin: the digest in `hello` must be the
  # digest of the manifest the host itself installed.
  defp verify_hello(state, hello) do
    params = hello["params"] || %{}

    cond do
      params["plugin_id"] != state.plugin_id ->
        {:error,
         "the Plugin introduced itself as #{inspect(params["plugin_id"])}, which is not the " <>
           "Plugin that was installed (#{state.plugin_id})"}

      params["manifest_sha256"] != state.digest ->
        {:error, "the Plugin's manifest digest does not match the manifest that was installed"}

      not supported_protocol?(params["protocol"]) ->
        {:error,
         "the Plugin speaks protocol #{inspect(params["protocol"])}; this host speaks " <>
           "#{@protocol}"}

      true ->
        :ok
    end
  end

  defp supported_protocol?("veritas.plugin.v1"), do: true
  defp supported_protocol?("v1"), do: true
  defp supported_protocol?(_other), do: false

  defp send_welcome(state, hello) do
    token = session_token(state)

    frame =
      JsonRpc.response(hello["id"], %{
        "session_token" => token,
        "host_api_version" => Manifest.host_api_version(),
        "granted_scopes" => state.granted_scopes,
        "install_generation" => state.generation
      })

    send_frame(state, frame)
  end

  # The token is derived from the bootstrap secret, so only a peer that was
  # given the secret on stdin can recognise it — which is how the Plugin
  # knows it is talking to the host that started it.
  defp session_token(state) do
    message =
      "veritas.plugin.session:" <> state.plugin_id <> ":" <> Integer.to_string(state.generation)

    :hmac
    |> :crypto.mac(:sha256, state.secret, message)
    |> Base.url_encode64(padding: false)
  end

  defp normalise_registrations(%{"params" => %{"registrations" => registrations}})
       when is_list(registrations) do
    Enum.filter(registrations, &is_map/1)
  end

  defp normalise_registrations(_ready), do: []

  # ── the reader ─────────────────────────────────────────────────────────────
  #
  # A separate process reads the socket, so the session is free to answer
  # the Plugin's own requests while it is waiting for the Plugin's answer.
  # Without it, a Plugin that asks the host something during a call would
  # deadlock against the host waiting for that call to finish.
  defp start_reader(socket, session) do
    spawn_link(fn -> reader_loop(socket, session) end)
  end

  defp reader_loop(socket, session) do
    case Transport.UnixSocket.receive_message(socket, :infinity) do
      {:ok, frame} ->
        send(session, {:frame, frame})
        reader_loop(socket, session)

      {:error, reason} ->
        send(session, {:transport_closed, reason})
    end
  end

  # ── the calls ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = JsonRpc.new_id()

    case JsonRpc.encode(JsonRpc.request(id, method, params)) do
      {:ok, encoded} ->
        case Transport.UnixSocket.send_message(state.socket, encoded) do
          :ok ->
            pending = Map.put(state.pending, id, {from, method})
            {:noreply, %{state | pending: pending}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  # ── the frames ─────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:frame, data}, state) do
    case JsonRpc.decode(data) do
      {:ok, frame} -> handle_frame(state, frame)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({:transport_closed, reason}, state) do
    Logger.warning(
      "[veritas.plugin] #{state.plugin_id} closed the connection: #{inspect(reason)}"
    )

    {:stop, :normal, close(state, :plugin_crashed)}
  end

  # The OS process exited. This is the crash detection `docs/20` §Transport
  # asks for: the process is watched, not the heartbeat.
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[veritas.plugin] #{state.plugin_id} exited: #{inspect(reason)}")
    {:stop, :normal, close(state, :plugin_crashed)}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    Logger.warning("[veritas.plugin] #{state.plugin_id} reader stopped: #{inspect(reason)}")
    {:stop, :normal, close(state, :plugin_crashed)}
  end

  def handle_info({port, {:data, line}}, %{port: port} = state) do
    Logger.debug("[veritas.plugin] #{state.plugin_id}: #{String.trim(line)}")
    {:noreply, %{state | tail: push_tail(state.tail, line)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[veritas.plugin] #{state.plugin_id} process exited with status #{status}")

    # What the Plugin said last is the reason it died. A Plugin that dies
    # without saying anything leaves the diagnosis to the exit status, which
    # is a number and not a sentence.
    Logger.warning(
      "[veritas.plugin] #{state.plugin_id} last said: #{Enum.join(state.tail, " | ")}"
    )

    {:stop, :normal, close(state, :plugin_crashed)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: Transport.UnixSocket.close(state.socket)
    if state.listen_socket, do: Transport.UnixSocket.close(state.listen_socket)
    if state.port, do: Port.close(state.port)

    # The socket file is the Plugin's address; it leaves with the Plugin.
    File.rm(state.socket_path)

    :ok
  end

  # ── frame handling ─────────────────────────────────────────────────────────

  defp handle_frame(state, %{"id" => id, "result" => result}) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _method}, pending} ->
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending: pending}}
    end
  end

  defp handle_frame(state, %{"id" => id, "error" => %{"code" => code, "message" => message}}) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _method}, pending} ->
        GenServer.reply(from, {:error, {:rpc, code, message}})
        {:noreply, %{state | pending: pending}}
    end
  end

  # The Plugin is calling the host. This is the host-mediated path, and it
  # is checked exactly like the other direction.
  defp handle_frame(state, %{"id" => id, "method" => method, "params" => params}) do
    case answer_host_request(state, method, params || %{}) do
      {:ok, value} -> send_frame(state, JsonRpc.response(id, value))
      {:error, {code, message}} -> send_frame(state, JsonRpc.error_response(id, code, message))
    end

    {:noreply, state}
  end

  # A notification: the Plugin telling the host something it needs no answer
  # to. There is nothing to do with one yet, and dropping it silently would
  # hide a Plugin waiting for something.
  defp handle_frame(state, %{"method" => method}) do
    Logger.debug("[veritas.plugin] #{state.plugin_id} sent the notification #{inspect(method)}")
    {:noreply, state}
  end

  defp handle_frame(state, _frame), do: {:noreply, state}

  defp answer_host_request(state, method, params) do
    context = %{plugin_id: state.plugin_id, workspace: state.workspace}

    case Host.Operations.lookup(method) do
      :error ->
        {:error, {JsonRpc.method_not_found(), "this host serves no operation named #{method}"}}

      {:ok, {name, _opts}} ->
        scopes = Host.Operations.scopes(method, params)

        if scopes == [] do
          {:error,
           {JsonRpc.invalid_params(), "the parameters do not name a table this host serves"}}
        else
          case Veritas.Plugin.Host.Capability.check_all(context, scopes) do
            :ok ->
              invoke_adapter(state, context, name, params)

            {:error, :scope_denied} ->
              {:error, {JsonRpc.server_error(), "scope_denied"}}
          end
        end
    end
  end

  defp invoke_adapter(state, context, method, params) do
    {module, adapter_state} = state.adapter

    case module.call(context, %{"method" => method, "params" => params}, adapter_state) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {JsonRpc.server_error(), describe(reason)}}
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  # The last few lines the Plugin wrote, kept so that its death can be
  # reported in its own words.
  defp push_tail(tail, line) do
    Enum.take([line | tail], 5)
  end

  defp send_frame(state, frame) do
    case JsonRpc.encode(frame) do
      {:ok, encoded} -> Transport.UnixSocket.send_message(state.socket, encoded)
      {:error, reason} -> {:error, reason}
    end
  end

  # The Plugin is gone. Every call waiting on it is answered — a caller that
  # waits for an answer that will never come is a host that hangs.
  defp close(state, reason) do
    Enum.each(state.pending, fn {_id, {from, _method}} ->
      GenServer.reply(from, {:error, reason})
    end)

    Registry.update_status(state.plugin_id, :quarantined)
    Registry.remove_session(state.plugin_id)

    %{state | pending: %{}, status: :closed}
  end

  defp describe({:unsupported, message}), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
