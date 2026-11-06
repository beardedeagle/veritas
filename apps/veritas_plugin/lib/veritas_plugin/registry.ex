defmodule Veritas.Plugin.Registry do
  @moduledoc """
  What the host knows about the Plugins it has installed.

  The registry holds two things and nothing else: the **install records**
  (the manifest, the granted capabilities, the generation, the status) and
  the **sessions** (the live connection to each Plugin process). Everything
  else in the runtime reads them from here, which is what makes
  `docs/20` §Capability Grants possible: the grant set is re-read from the
  registry on every call rather than cached in the session, so a revoked
  grant takes effect on the next call and not on the next restart.

  The statuses are atoms, not strings, because a status is a decision the
  host makes and the rest of the host branches on it:

    * `:installed` — validated and granted, not running;
    * `:running` — the process is up and its health check passed;
    * `:degraded` — the process is up but its health check failed, so the
      Plugin is not trusted to be well;
    * `:quarantined` — the process is gone or wedged, and the Plugin's
      capabilities are withdrawn until an operator looks;
    * `:stopped` — stopped on purpose, and still installed.

  This module is **Default** behaviour: the registry is where the host keeps
  its own state, and a different host may keep it elsewhere (a database, a
  file) without changing the boundary.
  """

  use GenServer

  @type status :: :installed | :running | :degraded | :quarantined | :stopped

  @type install :: %{
          plugin_id: String.t(),
          version: String.t(),
          manifest: map(),
          granted_scopes: [String.t()],
          status: status(),
          install_generation: pos_integer(),
          digest: String.t(),
          environment: map(),
          workspace: String.t(),
          namespace: String.t(),
          command: String.t(),
          manifest_path: String.t(),
          registrations: [map()],
          error: term()
        }

  @doc "Starts the registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{installs: %{}, sessions: %{}, monitors: %{}}}
  end

  # ── installs ───────────────────────────────────────────────────────────────

  @doc "The install record for a Plugin, or `:error`."
  @spec fetch_install(String.t()) :: {:ok, install()} | :error
  def fetch_install(plugin_id), do: GenServer.call(__MODULE__, {:fetch_install, plugin_id})

  @doc "Records an install, replacing any earlier one for the same Plugin."
  @spec put_install(install()) :: :ok
  def put_install(install), do: GenServer.call(__MODULE__, {:put_install, install})

  @doc "Forgets an install. Returns `:ok` whether or not it was there."
  @spec remove_install(String.t()) :: :ok
  def remove_install(plugin_id), do: GenServer.call(__MODULE__, {:remove_install, plugin_id})

  @doc "Every install, by Plugin id."
  @spec list_installs() :: [install()]
  def list_installs, do: GenServer.call(__MODULE__, :list_installs)

  @doc "Sets the status of an installed Plugin."
  @spec update_status(String.t(), status()) :: :ok
  def update_status(plugin_id, status),
    do: GenServer.call(__MODULE__, {:update_status, plugin_id, status})

  @doc "Records the tools a Plugin registered at its handshake."
  @spec update_registrations(String.t(), [map()]) :: :ok
  def update_registrations(plugin_id, registrations),
    do: GenServer.call(__MODULE__, {:update_registrations, plugin_id, registrations})

  @doc "Records why an install failed, so the failure can be reported."
  @spec put_error(String.t(), term()) :: :ok
  def put_error(plugin_id, error), do: GenServer.call(__MODULE__, {:put_error, plugin_id, error})

  @doc "The last failure recorded for a Plugin."
  @spec last_error(String.t()) :: term()
  def last_error(plugin_id) do
    case fetch_install(plugin_id) do
      {:ok, install} -> install.error
      :error -> nil
    end
  end

  @doc """
  The granted capabilities of an installed Plugin, re-read from here.

  This is the grant set `docs/20` §Capability Grants says is re-read on
  every call.
  """
  @spec granted_scopes(String.t()) :: [String.t()]
  def granted_scopes(plugin_id) do
    case fetch_install(plugin_id) do
      {:ok, install} -> install.granted_scopes
      :error -> []
    end
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @doc "The session process of a running Plugin."
  @spec fetch_session(String.t()) :: {:ok, pid()} | :error
  def fetch_session(plugin_id), do: GenServer.call(__MODULE__, {:fetch_session, plugin_id})

  @doc """
  Records the session of a running Plugin, and watches it.

  The watch is what makes a crash visible: a Plugin that dies is noticed by
  the process monitor, and the host quarantines it instead of leaving a
  stale session behind.
  """
  @spec put_session(String.t(), pid()) :: :ok
  def put_session(plugin_id, pid), do: GenServer.call(__MODULE__, {:put_session, plugin_id, pid})

  @doc "Forgets the session of a Plugin."
  @spec remove_session(String.t()) :: :ok
  def remove_session(plugin_id), do: GenServer.call(__MODULE__, {:remove_session, plugin_id})

  # ── the server ─────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:fetch_install, plugin_id}, _from, state) do
    {:reply, Map.fetch(state.installs, plugin_id), state}
  end

  def handle_call({:put_install, install}, _from, state) do
    installs = Map.put(state.installs, install.plugin_id, install)
    {:reply, :ok, %{state | installs: installs}}
  end

  def handle_call({:remove_install, plugin_id}, _from, state) do
    installs = Map.delete(state.installs, plugin_id)
    sessions = Map.delete(state.sessions, plugin_id)
    {:reply, :ok, %{state | installs: installs, sessions: sessions}}
  end

  def handle_call(:list_installs, _from, state) do
    installs =
      state.installs
      |> Map.values()
      |> Enum.sort_by(& &1.plugin_id)

    {:reply, installs, state}
  end

  def handle_call({:update_status, plugin_id, status}, _from, state) do
    {:reply, :ok, update_install(state, plugin_id, &%{&1 | status: status})}
  end

  def handle_call({:update_registrations, plugin_id, registrations}, _from, state) do
    {:reply, :ok, update_install(state, plugin_id, &%{&1 | registrations: registrations})}
  end

  def handle_call({:put_error, plugin_id, error}, _from, state) do
    {:reply, :ok, update_install(state, plugin_id, &%{&1 | error: error})}
  end

  def handle_call({:fetch_session, plugin_id}, _from, state) do
    {:reply, Map.fetch(state.sessions, plugin_id), state}
  end

  def handle_call({:put_session, plugin_id, pid}, _from, state) do
    reference = Process.monitor(pid)
    monitors = Map.put(state.monitors, reference, plugin_id)
    sessions = Map.put(state.sessions, plugin_id, pid)

    {:reply, :ok, %{state | sessions: sessions, monitors: monitors}}
  end

  def handle_call({:remove_session, plugin_id}, _from, state) do
    sessions = Map.delete(state.sessions, plugin_id)

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn {reference, watched}, monitors ->
        if watched == plugin_id do
          Process.demonitor(reference, [:flush])
          Map.delete(monitors, reference)
        else
          monitors
        end
      end)

    {:reply, :ok, %{state | sessions: sessions, monitors: monitors}}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {plugin_id, monitors} ->
        # The session is gone. The Plugin is quarantined rather than
        # silently forgotten: `docs/20` §Transport wants a crash surfaced,
        # not swallowed.
        installs =
          case Map.fetch(state.installs, plugin_id) do
            {:ok, install} -> Map.put(state.installs, plugin_id, %{install | status: :quarantined})
            :error -> state.installs
          end

        sessions = Map.delete(state.sessions, plugin_id)

        {:noreply, %{state | installs: installs, sessions: sessions, monitors: monitors}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_install(state, plugin_id, fun) do
    installs =
      case Map.fetch(state.installs, plugin_id) do
        {:ok, install} -> Map.put(state.installs, plugin_id, fun.(install))
        :error -> state.installs
      end

    %{state | installs: installs}
  end
end
