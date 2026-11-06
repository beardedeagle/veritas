defmodule Veritas.Web.AgentConsole.Providers do
  @moduledoc """
  The Provider registry: which provider this Workspace uses.

  ## The operator chooses, per Workspace

  Neither tier is a default (`docs/39` §3.1): a self-hosted runtime needs
  no key and no account, and a hosted provider needs one. The registry
  starts **empty**, and the choice made here is per Workspace.

  ## The credential is a reference, never a value

  The form asks for the **name of the environment variable** that holds the
  provider's key — `OPENAI_API_KEY`, say — and the adapter reads that variable
  when it calls the provider. The key itself is never typed into this screen,
  never stored, and never carried in the registry: what the registry holds is
  the variable's *name*.

  ## There is no credential store in this build

  There is no credential store in this build, and this screen does not pretend
  there is one. The environment **is** the credential store: the operator
  sets the variable on the host, Veritas reads it when it calls the provider,
  and a provider that needs no key names no variable at all.
  """
  use Veritas.Web, :live_view

  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider.Registry
  alias Veritas.Store

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns[:principal_workspace]
    {providers, workspace_error} = providers(workspace)

    {:ok,
     assign(socket,
       page_title: "Providers",
       workspace: workspace,
       providers: providers,
       workspace_error: workspace_error,
       global: Registry.global(),
       global_refusals: Registry.global_refusals(),
       adapters: AdapterRegistry.ids(),
       form: %{}
     )}
  end

  @impl true
  def handle_event("test", %{"id" => id}, socket) do
    provider = Enum.find(socket.assigns.providers ++ Registry.global(), &(&1.id == id))

    result =
      case provider do
        nil ->
          {:error, :no_provider}

        provider ->
          with {:ok, adapter} <- fetch_adapter(provider.adapter),
               {:ok, token} <- Registry.resolve_credential(provider),
               {:ok, config} <- adapter.init(%{base_url: provider.base_url, token: token}) do
            adapter.models(config)
          end
      end

    case result do
      {:ok, models} ->
        {:noreply, put_flash(socket, :info, "#{id} answered: #{length(models)} models")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "#{id} did not answer: #{describe(reason)}")}
    end
  end

  @impl true
  def handle_event("add", params, socket) do
    workspace = socket.assigns.workspace
    kind = kind(params["kind"])
    accepted = params["capability_floor_acknowledged"] in [true, "true", "on"]

    provider = %{
      # The field is named `_id`, not `id`: a form field called `id` overrides
      # the ID of its own form element, which Phoenix refuses at compile time.
      # The name is remapped here, and the old spelling is still read so that
      # a caller that posts the previous name is not silently ignored.
      id: params["_id"] || params["id"] || "local",
      kind: kind,
      adapter: adapter_id(params["adapter"]),
      base_url: params["base_url"],
      model: params["model"],
      credential_env: params["credential_env"],
      capability_floor_acknowledged: kind == :hosted and accepted,
      capabilities: []
    }

    # This gate belongs to this setup form, not to provider use. The registry
    # remains free to store and select an unacknowledged hosted provider.
    if kind == :hosted and not accepted do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Setup is incomplete: read the hosted-provider data-handling disclosure and check the acceptance box."
       )}
    else
      case Registry.put(workspace, provider, actor: socket.assigns.principal) do
        {:ok, _stored} ->
          {:noreply, socket |> put_flash(:info, "#{provider.id} is configured.") |> load()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "The registry refused it: #{describe(reason)}")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6">
        <h1 class="text-3xl font-semibold tracking-tight">Providers</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Which provider this Workspace uses. workspace <span class="font-mono">{@workspace}</span>
        </p>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">This Workspace's providers</h2>

        <ul :if={@providers != []} class="mt-3 divide-y divide-base-300/60">
          <li :for={provider <- @providers} class="flex items-baseline justify-between gap-4 py-2">
            <div>
              <p class="font-mono text-sm">{provider.id}</p>
              <p class="text-[12px] text-base-content/60">
                {provider.kind} &middot; {provider.adapter}
                <span :if={provider.model} class="ml-1">&middot; {provider.model}</span>
              </p>
              <.acknowledgement provider={provider} />
              <p :if={provider_refusal(provider)} class="mt-1 text-[12px] font-medium text-warning">
                {describe_global_refusal(provider_refusal(provider))}
              </p>
            </div>
            <button
              phx-click="test"
              phx-value-id={provider.id}
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              test
            </button>
          </li>
        </ul>

        <p :if={@workspace_error} class="mt-3 text-sm font-medium text-warning">
          {describe_workspace_error(@workspace_error)}
        </p>

        <p
          :if={@providers == [] and is_nil(@workspace_error)}
          class="mt-3 text-sm text-base-content/60"
        >
          This Workspace has no provider configured.
          Veritas does not choose one for you — add a self-hosted provider
          (Ollama, or any OpenAI-compatible endpoint) or a hosted provider.
        </p>
      </section>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">The deployment's providers</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          The global tier: the operator's configuration, used when a Workspace
          names no provider of its own.
        </p>

        <ul :if={@global != []} class="mt-3 divide-y divide-base-300/60">
          <li :for={provider <- @global} class="flex items-baseline justify-between gap-4 py-2">
            <div>
              <p class="font-mono text-sm">{provider.id}</p>
              <p class="text-[12px] text-base-content/60">
                {provider.kind} &middot; {provider.adapter}
              </p>
              <.acknowledgement provider={provider} />
              <p :if={provider_refusal(provider)} class="mt-1 text-[12px] font-medium text-warning">
                {describe_global_refusal(provider_refusal(provider))}
              </p>
            </div>
            <button
              phx-click="test"
              phx-value-id={provider.id}
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              test
            </button>
          </li>
        </ul>

        <ul :if={@global_refusals != []} class="mt-3 divide-y divide-base-300/60">
          <li :for={refusal <- @global_refusals} class="py-2">
            <p class="font-mono text-sm">{refusal.id}</p>
            <p class="text-[12px] text-base-content/60">{describe_global_refusal(refusal.reason)}</p>
          </li>
        </ul>

        <p :if={@global == [] and @global_refusals == []} class="mt-3 text-sm text-base-content/60">
          None configured.
        </p>
      </section>

      <section class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Add a provider</h2>

        <form phx-submit="add" id="provider-add" class="mt-3 flex flex-wrap items-end gap-3">
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">id</span>
            <input
              type="text"
              name="_id"
              required
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">kind</span>
            <select name="kind" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
              <option value="self_hosted">self_hosted</option>
              <option value="hosted">hosted</option>
            </select>
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">adapter</span>
            <select name="adapter" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
              <option :for={adapter <- @adapters} value={adapter}>{adapter}</option>
            </select>
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">address</span>
            <input
              type="text"
              name="base_url"
              placeholder="http://127.0.0.1:11434"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">model</span>
            <input
              type="text"
              name="model"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">
              key environment variable
            </span>
            <input
              type="text"
              name="credential_env"
              placeholder="OPENAI_API_KEY"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <section class="mt-4 w-full rounded-md border-2 border-warning bg-warning/10 p-4">
            <h3 class="text-base font-semibold">Hosted providers: data-handling decision required</h3>
            <p class="mt-2 whitespace-pre-line text-sm font-medium leading-6 text-base-content">
              {Registry.capability_floor_disclosure()}
            </p>
            <label class="mt-4 flex items-start gap-3 text-sm font-semibold">
              <input
                type="checkbox"
                name="capability_floor_acknowledged"
                value="true"
                class="mt-1"
              />
              <span>I understand and accept these data-handling risks for a hosted provider.</span>
            </label>
          </section>

          <button
            type="submit"
            class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
          >
            add
          </button>
        </form>

        <p class="mt-3 text-xs leading-5 text-base-content/55">
          This build has no credential store. Name the environment variable that
          holds the key — <span class="font-mono">OPENAI_API_KEY</span>, say — and
          Veritas reads it from the environment when it calls the provider. The key
          itself is never typed here, never stored, and never shown again. A
          self-hosted provider needs no key: leave this empty.
        </p>
      </section>
    </main>
    """
  end

  defp acknowledgement(
         %{provider: %{kind: :hosted, capability_floor_acknowledged: true}} = assigns
       ) do
    ~H"""
    <p class="mt-1 text-[12px] font-medium text-success">
      Contractual floor acknowledged by
      <span class="font-mono">{acknowledged_by(@provider.capability_floor_acknowledged_by)}</span>
      at <time>{acknowledged_at(@provider.capability_floor_acknowledged_at)}</time>.
    </p>
    """
  end

  defp acknowledgement(%{provider: %{kind: :hosted}} = assigns) do
    ~H"""
    <p class="mt-1 text-[12px] font-semibold text-warning">
      Contractual floor not acknowledged.
    </p>
    """
  end

  defp acknowledgement(assigns), do: ~H""

  defp acknowledged_by(%{type: type, id: id}), do: "#{type}:#{id}"
  defp acknowledged_by(_actor), do: "an unidentified operator"

  defp acknowledged_at(%DateTime{} = acknowledged_at), do: DateTime.to_string(acknowledged_at)
  defp acknowledged_at(_acknowledged_at), do: "an unrecorded time"

  defp load(socket) do
    workspace = socket.assigns.workspace
    {providers, workspace_error} = providers(workspace)

    assign(socket,
      providers: providers,
      workspace_error: workspace_error,
      global: Registry.global(),
      global_refusals: Registry.global_refusals()
    )
  end

  # An unreadable registry is not an empty registry. Carry the failure to the
  # screen rather than collapsing it into the Workspace's empty state.
  defp providers(workspace) do
    case Registry.list(workspace) do
      {:ok, providers} -> {providers, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp provider_refusal(provider) do
    with {:ok, adapter_id} <- AdapterRegistry.resolve_id(provider.adapter),
         {:ok, _adapter} <- fetch_adapter(adapter_id) do
      nil
    else
      {:error, reason} -> reason
    end
  end

  defp fetch_adapter(id) do
    case AdapterRegistry.fetch(id) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :unknown_adapter}
    end
  end

  defp kind("hosted"), do: :hosted
  defp kind(_other), do: :self_hosted

  defp adapter_id(nil), do: :ollama
  defp adapter_id(id) when is_binary(id), do: String.to_existing_atom(id)
  defp adapter_id(id), do: id

  defp describe_workspace_error(%Store.Error{code: :not_found}),
    do:
      "This Workspace's provider registry could not be read because its storage table is missing. Run the store migration, then reload this screen."

  defp describe_workspace_error(_reason),
    do:
      "This Workspace's providers could not be read. Restore the provider store, then reload this screen."

  # A refused global provider is configured, but unusable. Keep that distinct
  # from an empty tier, and give the operator the correction they can make.
  defp describe_global_refusal({:unknown_adapter, name}),
    do: "#{name} is not an adapter this build registers; name a registered adapter."

  defp describe_global_refusal(:not_a_provider_entry),
    do: "This entry is not a provider configuration; give a provider name and its settings."

  defp describe_global_refusal({:unsupported_configuration, _configuration}),
    do:
      "The provider configuration is not readable; use provider names with lists or maps of settings."

  defp describe_global_refusal(reason) when is_binary(reason),
    do: "The provider cannot be used: #{reason}. Correct the provider configuration."

  defp describe_global_refusal(_reason),
    do:
      "The provider cannot be used because its configuration is not valid for this build. Correct the provider configuration."

  defp describe({:environment_variable_not_set, name}),
    do: "the environment variable #{name} is not set on this host"

  defp describe(%LLM.Error{message: message}), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
