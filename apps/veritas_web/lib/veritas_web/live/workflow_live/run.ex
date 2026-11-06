defmodule Veritas.Web.WorkflowLive.Run do
  use Veritas.Web, :live_view
  import Veritas.Web.WorkflowLive.Components
  alias Veritas.Agentic.Runner
  alias Veritas.Core.{Tickets, Workflows}
  alias Veritas.Store.Error

  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         page_title: "Ticket workflow",
         run: nil,
         ticket: nil,
         step: nil,
         busy: false,
         models: [],
         error: nil
       )}

  def handle_params(%{"ticket_id" => id}, _uri, socket), do: {:noreply, load(socket, id)}

  def handle_event("complete", params, socket) do
    run = socket.assigns.run
    %{principal_workspace: workspace, principal: principal} = socket.assigns

    opts = [
      expected_revision: run["revision"],
      next: present(params["next"]),
      approve: params["approved"] == "true"
    ]

    case Workflows.complete(workspace, run["ticket"], params["answers"] || %{}, principal, opts) do
      {:ok, updated} ->
        completed = updated["status"] == "completed"

        message =
          if completed,
            do: "Workflow complete. The work and follow-up are recorded.",
            else: "Step completed."

        {:noreply, socket |> load(updated["ticket"]) |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Error.message(reason))}
    end
  end

  def handle_event("draft", _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("draft", params, socket) do
    workspace = socket.assigns.principal_workspace
    id = socket.assigns.run["ticket"]
    principal = socket.assigns.principal
    model = present(params["model"])

    {:noreply,
     socket
     |> assign(:busy, true)
     |> start_async({:draft, id}, fn ->
       Workflows.draft(workspace, id, principal, model: model, timeout: 90_000)
     end)}
  end

  def handle_event("models", _, socket) do
    workspace = socket.assigns.principal_workspace
    {:noreply, start_async(socket, :models, fn -> Runner.models(workspace) end)}
  end

  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, :models, Enum.sort_by(models, & &1.id))}

  def handle_async({:draft, id}, {:ok, {:ok, _}}, socket) do
    socket = assign(socket, :busy, false)

    if socket.assigns.run["ticket"] == id,
      do:
        {:noreply,
         socket
         |> load(id)
         |> put_flash(:info, "AI proposal ready. Review it before approving this step.")},
      else: {:noreply, socket}
  end

  def handle_async(_name, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(:busy, false) |> put_flash(:error, Error.message(reason))}

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(:busy, false)
       |> put_flash(:error, "The AI request stopped. Ticket progress is unchanged; try again.")}

  defp load(socket, id) do
    with {:ok, run} <-
           Workflows.run(socket.assigns.principal_workspace, id, socket.assigns.principal),
         {:ok, ticket} <- Tickets.read(socket.assigns.principal_workspace, id) do
      assign(socket, run: run, ticket: ticket, step: Workflows.current_step(run), error: nil)
    else
      {:error, reason} -> assign(socket, :error, Error.message(reason))
    end
  end

  defp present(v) when v in [nil, ""], do: nil
  defp present(v), do: v

  # The latest approved output for a step. A pending re-draft is never approved history;
  # earlier approvals stay in the run's approved_outputs and the audit log.
  defp latest_approved(run, step_id) do
    run["data"]["completed_steps"]
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {id, visit} ->
      id == step_id && Workflows.approved_output(run, visit)
    end)
  end

  def render(assigns) do
    # Only a proposal for this visit counts; an earlier visit's approved output stays in the recorded history.
    assigns = assign(assigns, :output, assigns.run && Workflows.current_output(assigns.run))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main class="mx-auto max-w-6xl px-6 py-8">
      <.link navigate={~p"/workflows"} class="text-sm text-base-content/60 hover:text-primary">← Workflows</.link>
      <p :if={@error} role="alert" class="alert alert-error mt-6">{@error}</p>
      <div :if={@run && @ticket}>
        <header class="my-6">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="badge badge-outline">{String.replace(@ticket["ticket_type"], "_", " ")}</span><span class="badge">{@ticket[
              "state"
            ]}</span><span class="text-xs text-base-content/50">{@run["definition"]["name"]} · v{@run[
              "workflow_revision"
            ]}</span>
          </div><h1 class="text-3xl font-semibold tracking-tight">{@ticket["title"]}</h1><p class="mt-2 text-sm text-base-content/60">
            {@ticket["description"]}
          </p><p class="mt-2 font-mono text-[10px] text-base-content/40">{@ticket["id"]}</p>
        </header>
        <div class="grid items-start gap-6 lg:grid-cols-[260px_minmax(0,1fr)]">
          <aside>
            <.progress
              steps={@run["definition"]["steps"]}
              current={@run["data"]["current_step"]}
              completed={@run["data"]["completed_steps"]}
            /><.link navigate={~p"/audit"} class="mt-4 block text-center text-xs text-primary">View the audit trail →</.link>
          </aside>
          <div class="min-w-0 space-y-5">
            <section :if={@step} class="v-panel rounded-xl p-6">
              <p class="text-xs font-semibold uppercase tracking-[0.12em] text-primary">
                Current step · {String.replace(@step["phase"], "_", " ")}
              </p><h2 class="mt-2 text-2xl font-semibold tracking-tight">{@step["name"]}</h2><p class="mt-3 whitespace-pre-wrap text-sm leading-6 text-base-content/65">
                {@step["instructions"]}
              </p>
              <div
                :if={@step["kind"] == "ai"}
                class="mt-5 rounded-xl border border-primary/20 bg-primary/5 p-4"
              >
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-sm font-semibold">AI-assisted step</h3><p class="mt-1 text-xs text-base-content/60">
                      Uses this ticket's recorded context. You review and approve the result.
                    </p>
                  </div><button
                    type="button"
                    id="workflow-load-models"
                    phx-click="models"
                    class="btn btn-ghost btn-xs"
                  >Load models</button>
                </div><form
                  phx-submit="draft"
                  id="workflow-ai"
                  class="mt-4 flex flex-wrap items-end gap-2"
                >
                  <select name="model" class="select select-bordered select-sm min-w-0 flex-1"><option value="">
                    {if @step["model"] in [nil, ""],
                      do: "Provider's configured model",
                      else: "Step default (#{@step["model"]})"}
                  </option><option :for={m <- @models} value={m.id}>{m.id}</option></select><button
                    type="submit"
                    disabled={@busy}
                    phx-disable-with="Running…"
                    class="btn btn-primary btn-sm"
                  >{if @busy,
                    do: "AI is working…",
                    else: if(@output, do: "Regenerate proposal", else: "Run AI step")}</button>
                </form><p :if={@busy} role="status" class="mt-3 text-xs text-primary">
                  Reading the ticket context and generating a proposal…
                </p>
              </div>
              <div :if={@output} class="mt-5 rounded-xl border border-base-300 p-5">
                <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <h3 class="text-sm font-semibold">AI proposal · awaiting your review</h3><span class="font-mono text-[10px] text-base-content/50">{@output[
                    "provider"
                  ]} / {@output["model"]}</span>
                </div><div class="whitespace-pre-wrap text-sm leading-7">{@output["text"]}</div>
              </div>
              <form
                id="workflow-complete"
                phx-submit="complete"
                class="mt-6 space-y-4 border-t border-base-300 pt-5"
              >
                <.answer_field :for={field <- @step["fields"] || []} field={field} />
                <label :if={length(@step["next"]) > 1} class="block text-sm font-medium">Route to<select
                  name="next"
                  required
                  class="select select-bordered mt-1 w-full"
                ><option value="">Choose the next step…</option><option
                  :for={id <- @step["next"]}
                  value={id}
                >
                  {Enum.find(@run["definition"]["steps"], &(&1["id"] == id))["name"]}
                </option></select></label>
                <label
                  :if={@step["kind"] in ["ai", "approval"]}
                  class="flex items-start gap-3 rounded-lg bg-base-200/60 p-4 text-sm"
                ><input
                  type="checkbox"
                  name="approved"
                  value="true"
                  required
                  class="checkbox checkbox-sm mt-0.5"
                /><span>{if @step["kind"] == "ai",
                  do: "I reviewed this AI proposal and approve it as this step's recorded outcome.",
                  else: "I reviewed the evidence and approve completion of this step."}</span></label>
                <button
                  type="submit"
                  disabled={@busy || (@step["kind"] == "ai" && is_nil(@output))}
                  class="btn btn-primary"
                  phx-disable-with="Saving…"
                >{cond do
                  @step["next"] == [] -> "Approve and finish workflow"
                  @step["kind"] in ["ai", "approval"] -> "Approve and continue →"
                  true -> "Complete step →"
                end}</button><p
                  :if={@step["state"] not in [nil, ""]}
                  class="text-xs text-base-content/50"
                >
                  On completion, request ticket state: {@step["state"]}. Domain authorization is enforced.
                </p>
              </form>
            </section>
            <section
              :if={@run["status"] == "completed"}
              class="rounded-xl border border-success/30 bg-success/5 p-8"
            >
              <p class="text-xs font-semibold uppercase tracking-wide text-success">Completed</p><h2 class="mt-2 text-2xl font-semibold">
                The work and follow-up are recorded.
              </h2><p class="mt-3 text-sm text-base-content/65">
                The intake, completed steps, AI proposals and human approvals stay with this ticket.
              </p><.link navigate={~p"/workflows"} class="btn btn-primary btn-sm mt-5">Back to workflows</.link>
            </section>
            <section id="workflow-recorded" class="v-panel rounded-xl p-6">
              <h2 class="text-sm font-semibold">Recorded work</h2><div
                :for={
                  step <-
                    Enum.filter(
                      @run["definition"]["steps"],
                      &(&1["id"] in @run["data"]["completed_steps"])
                    )
                }
                class="mt-5 border-t border-base-300 pt-4"
              >
                <h3 class="text-sm font-semibold">✓ {step["name"]}</h3><dl class="mt-2 space-y-2">
                  <div :for={field <- step["fields"] || []}>
                    <dt class="text-xs text-base-content/50">{field["label"]}</dt><dd class="mt-1 whitespace-pre-wrap text-sm">
                      {to_string(get_in(@run, ["data", "answers", step["id"], field["key"]]) || "—")}
                    </dd>
                  </div>
                </dl><details
                  :for={approved <- List.wrap(latest_approved(@run, step["id"]))}
                  class="mt-3"
                >
                  <summary class="cursor-pointer text-xs text-primary">Approved AI output</summary><p class="mt-3 whitespace-pre-wrap text-sm leading-7">
                    {approved["text"]}
                  </p>
                </details>
              </div>
            </section>
          </div>
        </div>
      </div>
    </main>
    """
  end
end
