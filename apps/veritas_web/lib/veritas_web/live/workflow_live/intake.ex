defmodule Veritas.Web.WorkflowLive.Intake do
  use Veritas.Web, :live_view
  import Veritas.Web.WorkflowLive.Components
  alias Veritas.Core.Workflows
  alias Veritas.Store.Error

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, workflow: nil, intake: nil, error: nil, page_title: "Create ticket")}

  def handle_params(%{"id" => id}, _uri, socket) do
    case Workflows.get(socket.assigns.principal_workspace, id, socket.assigns.principal) do
      {:ok, %{"published_definition" => %{} = definition} = workflow} ->
        {:noreply,
         assign(socket,
           workflow: workflow,
           definition: definition,
           intake: hd(definition["steps"]),
           error: nil
         )}

      {:ok, _} ->
        {:noreply, assign(socket, :error, Error.message(:workflow_not_published))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, Error.message(reason))}
    end
  end

  def handle_event("create", params, socket) do
    case Workflows.start(
           socket.assigns.principal_workspace,
           socket.assigns.workflow["id"],
           params,
           socket.assigns.principal
         ) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket created. Your workflow is ready.")
         |> push_navigate(to: ~p"/workflows/tickets/#{run["ticket"]}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Error.message(reason))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main class="mx-auto max-w-4xl px-6 py-8">
      <.link navigate={~p"/workflows"} class="text-sm text-base-content/60 hover:text-primary">← Workflows</.link>
      <div :if={@error} role="alert" class="alert alert-error mt-6">{@error}</div>
      <div :if={@intake} class="mt-6 grid items-start gap-8 md:grid-cols-[minmax(0,1fr)_220px]">
        <section>
          <p class="text-xs font-semibold uppercase tracking-[0.15em] text-primary">
            New {String.replace(@definition["ticket_type"], "_", " ")}
          </p><h1 class="mt-2 text-3xl font-semibold tracking-tight">{@intake["name"]}</h1><p class="mt-3 text-sm leading-6 text-base-content/60">
            {@intake["instructions"]}
          </p>
          <form id="workflow-intake" phx-submit="create" class="v-panel mt-6 space-y-5 rounded-xl p-6">
            <label class="block text-sm font-medium">Title
            <span class="text-error">*</span><input
              name="title"
              required
              placeholder="What needs attention?"
              class="input input-bordered mt-1.5 w-full"
            /></label>
            <label class="block text-sm font-medium">Description<textarea
              name="description"
              rows="4"
              placeholder="Include the context someone needs to help."
              class="textarea textarea-bordered mt-1.5 w-full"
            /></label>
            <.answer_field :for={field <- @intake["fields"] || []} field={field} />
            <div class="border-t border-base-300 pt-5">
              <button
                type="submit"
                class="btn btn-primary w-full"
                phx-disable-with="Creating ticket…"
              >Create ticket and start workflow →</button>
            </div>
          </form>
        </section>
        <aside>
          <p class="mb-3 text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {@definition["name"]} · v{@workflow["published_revision"]}
          </p><.progress steps={@definition["steps"]} current={@intake["id"]} /><p class="mt-4 text-xs leading-5 text-base-content/50">
            The published version stays with this ticket. Later edits apply to new tickets.
          </p>
        </aside>
      </div>
    </main>
    """
  end
end
