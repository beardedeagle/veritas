defmodule Veritas.Plugin.Host do
  @moduledoc """
  The Port the host offers a Plugin — and the only way a Plugin reaches
  anything.

  A **Port** is the interface a domain depends on rather than an
  implementation. This one is the whole of the plugin boundary's public
  surface: a Plugin is granted capabilities, and the only way it can act on
  them is to call the host.

  ## Plug's idiom, without Plug's request model

  The shape here is Plug's, deliberately, because Plug's shape is the one
  that survives:

    * a **tiny behaviour** — `init/1` and `call/2`, and nothing else. A
      behaviour you can hold in your head is a behaviour you can implement in
      another language, which is the point of a boundary;
    * a **compile-time builder** — `Veritas.Plugin.Host.Builder` turns a
      list of declared operations into a table fixed in the compiled module;
    * **adapter indirection** — the transport is a behaviour
      (`Veritas.Plugin.Transport`) with a shipped Unix socket adapter and a
      shipped test harness, so the same boundary runs against a real socket
      or against a queue;
    * a **shipped test harness** — `Veritas.Plugin.Transport.Test`, in the
      same spirit as `Plug.Test`.

  What is *not* here is Plug's request model. There is no `conn`, no
  `:req`/`:resp`, no adapter chain and no Plug dependency. A Plugin is a
  separate OS process speaking JSON-RPC over a socket; it has no HTTP
  request to model, and pretending otherwise would put a framework type in a
  domain context.

  ## The two directions

    * **Host to Plugin** — `call/4` below. The host invokes a tool a Plugin
      registered, after checking the Plugin's grant for the capability that
      tool needs.
    * **Plugin to Host** — the four operations of
      `Veritas.Plugin.Host.Operations`, invoked by the Plugin as
      `"host.<operation>"` over the same socket. The session checks the
      Plugin's grant for each one, exactly as it does in the other
      direction.

  Both directions pass through `Veritas.Plugin.Host.Capability.check/2`.
  There is exactly one enforcement function, not one per surface.
  """

  alias Veritas.Plugin.{Host.Capability, Registry, Session}

  @typedoc """
  Who is calling, and in which Workspace.

  `plugin_id` names the Plugin; `workspace` names the Workspace the call
  acts in. A Plugin that is workspace-scoped holds its grant in one
  Workspace, and a call that names another is refused.
  """
  @type context :: %{
          required(:plugin_id) => String.t(),
          required(:workspace) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "A request as it crosses the boundary: a method and its parameters."
  @type request :: %{method: String.t(), params: term()}

  @typedoc """
  The adapter's state, built once by `c:init/1`.
  """
  @type state :: term()

  @doc """
  Builds the adapter's state.

  The compile-time half of Plug's idiom: an adapter is configured once,
  when it is built, and the configuration is a plain term.
  """
  @callback init(term()) :: state()

  @doc """
  The one entry point of the adapter.

  `request` names the operation and carries its parameters. `state` is the
  term `c:init/1` returned. The host checks the capability before it gets
  here, so an adapter never has to ask whether it is allowed.
  """
  @callback call(context(), request(), state()) :: {:ok, term()} | {:error, term()}

  @doc """
  Reads records of one kind from the Workspace the context names.

  `filter` is the store's filter: `where`, `order_by`, `limit`, `offset`.
  """
  @callback read_records(context(), :ci | :ticket, map()) ::
              {:ok, %{rows: [map()], cursor: binary() | nil}} | {:error, term()}

  @doc "Writes records of one kind into the Workspace the context names."
  @callback write_records(context(), :ci | :ticket, [map()]) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Traverses the CMDB graph from a root, to a bounded depth.
  """
  @callback query_graph(context(), map()) :: {:ok, [map()]} | {:error, term()}

  @doc "Publishes an event into the host's outbox."
  @callback publish_event(context(), binary(), map()) :: {:ok, binary()} | {:error, term()}

  @call_timeout 15_000

  @doc """
  Calls a tool a Plugin registered.

  The order is the corpus's: the Plugin's registration is read, the grant is
  re-read and checked, and only then is the Plugin spoken to. A denied call
  never reaches the Plugin at all.

  The method may be an atom or a string. The parameters are the JSON-RPC
  `params` of the call: an object, or an array.
  """
  @spec call(String.t(), atom() | String.t(), term(), context()) ::
          {:ok, term()} | {:error, term()}
  def call(plugin_id, method, params, context) do
    name = to_string(method)

    # The context the caller gives says *where* the call is made; the
    # Plugin it is made *for* is the host's own knowledge, and the host is
    # the only party that can be trusted to name it.
    context = Map.put(context, :plugin_id, plugin_id)

    case Registry.fetch_install(plugin_id) do
      :error ->
        {:error, :not_installed}

      {:ok, install} ->
        with {:ok, scopes} <- tool_scopes(install, name),
             :ok <- Capability.check_all(context, scopes),
             {:ok, session} <- Registry.fetch_session(plugin_id) do
          Session.request(session, name, params, @call_timeout)
        else
          :error -> {:error, :not_running}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  The Host API adapter this host runs.

  The adapter is **Default**: the data plane is an implementation choice
  behind this Port, and substituting one is one configuration value.
  """
  @spec adapter() :: {module(), state()}
  def adapter do
    module = Application.get_env(:veritas_plugin, :host_adapter, Veritas.Plugin.Host.Default)
    opts = Application.get_env(:veritas_plugin, :host_adapter_opts, [])

    {module, module.init(opts)}
  end

  # The capabilities a registered tool needs.
  #
  # A tool is registered by the Plugin itself, at the handshake, with the
  # capabilities it needs to run. The host does not trust that list blindly:
  # it is checked against the grant on every call, so a Plugin that claims a
  # capability it was not granted is refused.
  defp tool_scopes(install, name) do
    case Enum.find(install.registrations, fn registration -> registration["name"] == name end) do
      nil ->
        {:error, :unknown_method}

      registration ->
        {:ok, Map.get(registration, "required_scopes") || []}
    end
  end
end
