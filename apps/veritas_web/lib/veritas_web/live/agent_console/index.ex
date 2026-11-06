defmodule Veritas.Web.AgentConsole.Index do
  @moduledoc """
  The Agent Console: ask a question about the configuration items.

  The screen is **LiveViews only** (`docs/39` §8.3). It never imports an
  adapter and never holds a credential: it asks the host-owned runner, and
  the runner resolves the provider, checks the scopes, runs the tools and
  writes the Audit Log.

  ## What a run shows

  The answer, and the steps the agent took to reach it — each step naming
  the tool, the scope it needed and its outcome. The steps are the same
  Audit Log entries the run wrote, so what the operator reads here is the
  record, not a second story about it.
  """
  use Veritas.Web, :live_view

  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.Provider.Registry
  alias Veritas.Agentic.Runner

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns[:principal_workspace]

    {:ok,
     assign(socket,
       page_title: "Agent Console",
       workspace: workspace,
       question: "",
       answer: nil,
       steps: [],
       run_id: nil,
       busy: false,
       models: [],
       model: ""
     )}
  end

  @impl true
  def handle_event("ask", _params, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("ask", params, socket) do
    workspace = socket.assigns.workspace
    question = params["question"] || ""
    run_id = "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    actor = socket.assigns[:principal]
    model = if params["model"] in [nil, ""], do: nil, else: params["model"]

    if String.trim(question) == "" do
      {:noreply, put_flash(socket, :error, "Enter a question for the agent.")}
    else
      {:noreply,
       socket
       |> assign(busy: true, question: question, run_id: run_id, answer: nil, steps: [])
       |> start_async(:ask, fn ->
         Runner.ask(workspace, question,
           actor: actor,
           run_id: run_id,
           correlation_id: run_id,
           workspace_provider: Registry.workspace_provider(workspace),
           model: model,
           timeout: 90_000
         )
       end)}
    end
  end

  def handle_event("models", _params, socket) do
    workspace = socket.assigns.workspace
    {:noreply, start_async(socket, :models, fn -> Runner.models(workspace) end)}
  end

  @impl true
  def handle_async(:ask, {:ok, result}, socket) do
    socket = assign(socket, :busy, false)

    case result do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(
           answer: result.answer,
           steps: result.steps,
           run_id: socket.assigns.run_id
         )
         |> put_flash(
           :info,
           "The agent answered with #{result.provider}/#{result.model}, using #{Enum.join(result.tools_used, ", ")}."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The agent could not answer: #{describe(reason)}")}
    end
  end

  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, :models, Enum.sort_by(models, & &1.id))}

  def handle_async(:models, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, "Could not load models: #{describe(reason)}")}

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(:busy, false)
       |> put_flash(:error, "The request stopped. Try again; no action was applied.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6">
        <h1 class="text-3xl font-semibold tracking-tight">Agent Console</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Ask about the configuration. The agent answers with the same tools a
          person uses, and every step it takes is recorded in the Audit Log.
        </p>
      </header>

      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <.link navigate={~p"/workflows"} class="text-sm font-medium text-primary">Design and run ticket workflows →</.link><button
          phx-click="models"
          class="btn btn-ghost btn-xs"
        >Load available models</button>
      </div>

      <form phx-submit="ask" id="agent-ask" class="v-panel flex flex-wrap items-end gap-3 px-3 py-3">
        <label class="min-w-0 flex-1 text-sm text-base-content/75">
          <span class="block text-xs uppercase tracking-wide text-base-content/70">question</span>
          <input
            type="text"
            name="question"
            value={@question}
            placeholder="Which CIs depend on the checkout service?"
            class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
          />
        </label>
        <label class="text-xs text-base-content/60">Model<select
          name="model"
          class="select select-bordered select-sm mt-1 block"
        ><option value="">Provider's configured model</option><option
          :for={model <- @models}
          value={model.id}
        >
          {model.id}
        </option></select></label>
        <button
          type="submit"
          disabled={@busy}
          class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
        >
          {if @busy, do: "Working…", else: "Ask"}
        </button>
      </form>

      <p :if={@busy} role="status" class="mt-4 text-sm text-primary">
        The agent is reading the available context and tools…
      </p>

      <section :if={@answer} class="mt-6">
        <h2 class="text-[13px] font-semibold tracking-tight">The answer</h2>
        <p class="mt-2 whitespace-pre-wrap text-[13px] leading-6">{@answer}</p>
        <p class="mt-2 font-mono text-[11px] text-base-content/50">run {@run_id}</p>
      </section>

      <section :if={@steps != []} class="mt-8">
        <h2 class="text-[13px] font-semibold tracking-tight">The steps</h2>
        <ul class="mt-2 divide-y divide-base-300/60 border-y border-base-300/60">
          <li :for={step <- @steps} class="flex items-baseline justify-between gap-4 py-2">
            <span class="font-mono text-[12px]">{step.tool}</span>
            <span class="text-[11px] text-base-content/60">
              {step.scope |> Enum.join(", ")} &middot; {step.outcome}
            </span>
          </li>
        </ul>
      </section>

      <p class="mt-8 text-xs leading-5 text-base-content/55">
        <a href={~p"/agents/tools"} class="underline">What the agent can reach</a>
        &middot;
        <a href={~p"/agents/providers"} class="underline">Which provider this Workspace uses</a>
      </p>
    </main>
    """
  end

  # The refusal in plain words. A raw struct or atom in a flash tells the
  # operator nothing they can act on, and an `%LLM.Error{}` carries the
  # provider's raw body, which does not belong on the screen.
  defp describe(%LLM.Error{message: message}), do: message
  defp describe(:no_provider), do: "this Workspace has no provider configured"

  defp describe(:no_model),
    do: "the provider names no model; load the catalogue and choose one"

  defp describe(:unknown_adapter), do: "the provider's adapter is not registered in this build"

  defp describe({:environment_variable_not_set, name}),
    do: "the environment variable #{name} is not set on this host"

  defp describe(reason) when is_binary(reason), do: reason

  # Anything else is a fault the operator cannot act on, and its inspected
  # form can carry a provider's body or the store's internals. The detail goes
  # to the server log; the screen gets a sentence.
  defp describe(reason) do
    Logger.warning("agent console: unexpected failure: " <> inspect(reason))
    "an unexpected error; the server log has the detail"
  end
end
