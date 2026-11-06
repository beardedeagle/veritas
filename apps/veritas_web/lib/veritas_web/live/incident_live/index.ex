defmodule Veritas.Web.IncidentLive.Index do
  @moduledoc """
  The ticket queue.

  One screen serves every queue the product has: `/incidents` shows Incidents
  and Problems, `/requests` shows Service Requests, `/changes` shows Changes,
  and `/vulnerabilities` shows Vulnerabilities. The **route** decides which
  queue is shown — never the query string — so a link carrying another
  queue's name cannot change what the screen reads. `Veritas.Web.TicketQueue`
  holds the catalogue and the rule.

  It calls `Veritas.Core.Tickets` and nothing else, so every operation here
  is available in GraphQL and the CLI without a second implementation
  (INV-8).

  ## Problems are a filter over this queue

  `docs/04` puts Problems in the Incidents queue: a Problem is an Incident
  with a linked root cause. The tabs narrow the queue to one ticket type;
  they cannot widen it, and they are only offered where the queue has more
  than one type to narrow to.

  ## The module name

  The module keeps the name the Incidents route has always used. It serves
  more than Incidents now, and the route says which queue is on screen.
  """
  use Veritas.Web, :live_view

  # The shell owns the design system. The pills here are the system's, not
  # hand-rolled, so a state means the same thing on every screen.
  import Veritas.Web.ShellComponents, only: [state_pill: 1, severity_badge: 1]

  alias Veritas.Core.{Policy, Principal, Tickets}
  alias Veritas.Web.TicketQueue

  @impl true
  def mount(params, _session, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace]

    # The route names the queue. The query string may narrow it, never
    # choose it.
    queue = TicketQueue.fetch(socket.assigns[:live_action]) || TicketQueue.fetch(:incidents)
    filter = TicketQueue.selected_filter(queue, params)

    {:ok,
     socket
     |> assign(
       queue: queue,
       filter: filter,
       tickets: TicketQueue.load(workspace, queue, filter),
       workspace: workspace,
       page_title: queue.label,
       can_raise: can_raise?(queue, socket.assigns[:principal], workspace)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The tabs narrow the queue, so a changed filter is a changed screen.
    # The connect replays this with the filter the page was mounted with,
    # and that replay must not ask the store again.
    filter = TicketQueue.selected_filter(socket.assigns.queue, params)

    if filter == socket.assigns.filter do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(filter: filter)
       |> assign(
         tickets: TicketQueue.load(socket.assigns.workspace, socket.assigns.queue, filter)
       )}
    end
  end

  @impl true
  def handle_event("raise_ticket", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]
    ticket_type = params["ticket_type"] || List.first(socket.assigns.queue.types)

    # `docs/09` §4's enforcement table: the LiveView authorises at **every**
    # `handle_event`. The role matrix decides who may write a ticket of this
    # type, not the screen.
    case Policy.authorize(principal, "ticket:write", %{
           workspace: workspace,
           ticket_type: ticket_type
         }) do
      :allow ->
        attrs = %{
          "title" => params["title"],
          "description" => params["description"] || "",
          "requester" => presence(params["requester"]) || principal_id(principal)
        }

        actor = Principal.audit_actor(principal)

        case Tickets.open(workspace, ticket_type, attrs, actor) do
          {:ok, ticket} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{ticket["id"]} is open.")
             |> assign(
               tickets: TicketQueue.load(workspace, socket.assigns.queue, socket.assigns.filter)
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "The ticket was refused: #{inspect(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  # May this principal raise a ticket of any type the queue holds? The
  # answer comes from the role matrix.
  defp can_raise?(queue, principal, workspace) do
    Enum.any?(queue.types, fn type ->
      Policy.permitted?(principal, "ticket:write", %{workspace: workspace, ticket_type: type})
    end)
  end

  defp principal_id(nil), do: "unknown"
  defp principal_id(principal), do: principal.id

  # A field the operator left empty is not a value: an empty requester is
  # not a requester, and the store would refuse an empty record id.
  defp presence(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp presence(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <h1 class="flex items-center gap-2 text-3xl font-semibold tracking-tight">
            <.icon name={@queue.icon} class="size-5" />
            {@queue.label}
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            workspace <span class="font-mono">{@workspace}</span>
          </p>
        </div>

        <nav :if={length(@queue.filters) > 1} class="flex shrink-0 items-center gap-2">
          <.link
            :for={{value, label} <- @queue.filters}
            patch={TicketQueue.path(@queue, value)}
            class={[
              "rounded-full border px-3 py-1 text-[12px]",
              value == @filter && "border-base-content/40 bg-base-200",
              value != @filter && "border-base-300 text-base-content/60 hover:border-base-content/40"
            ]}
          >
            {label}
          </.link>
        </nav>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <.link
          navigate={~p"/workflows"}
          class="float-right text-xs font-medium text-primary hover:underline"
        >Create from a workflow →</.link>
        <h2 class="text-[13px] font-semibold tracking-tight">Raise a ticket</h2>

        <Veritas.Web.CoreComponents.withheld
          capability="ticket:write"
          allowed={@can_raise}
          action="raise tickets of this type"
        >
          <p class="mt-1 text-xs leading-5 text-base-content/55">
            A new {String.downcase(@queue.label)} ticket. Its lifecycle starts
            where the corpus says it starts; the priority is not yours to
            choose — the service desk sets it.
          </p>

          <form
            id="raise-ticket"
            phx-submit="raise_ticket"
            class="mt-3 flex flex-wrap items-end gap-3"
          >
            <label :if={length(@queue.types) > 1} class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">type</span>
              <select name="ticket_type" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                <option :for={type <- @queue.types} value={type}>{type}</option>
              </select>
            </label>

            <label class="min-w-0 flex-1 text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">title</span>
              <input
                type="text"
                name="title"
                required
                class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="min-w-0 flex-1 text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">description</span>
              <input
                type="text"
                name="description"
                class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">requester</span>
              <input
                type="text"
                name="requester"
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              raise
            </button>
          </form>
        </Veritas.Web.CoreComponents.withheld>
      </section>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={ticket <- @tickets} class="flex items-baseline justify-between gap-6 py-4">
          <div class="min-w-0">
            <a href={detail_path(@queue.path, ticket["id"])} class="font-medium hover:underline">
              {ticket["title"]}
            </a>
            <p class="mt-1 font-mono text-xs text-base-content/60">
              {ticket["id"]}
              <span :if={length(@queue.types) > 1} class="ml-2 text-base-content/45">
                {ticket["ticket_type"]}
              </span>
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <.severity_badge priority={ticket["priority"]} />
            <.state_pill state={ticket["state"]} />
          </div>
        </li>
      </ul>

      <p :if={@tickets == []} class="py-10 text-center text-base-content/60">
        Nothing in the {@queue.label} queue for this workspace yet.
      </p>
    </main>
    """
  end

  # The four detail routes, written out so that each is a *verified* route:
  # a path that does not exist is a compile error, not a dead link.
  defp detail_path("/incidents", id), do: ~p"/incidents/#{id}"
  defp detail_path("/requests", id), do: ~p"/requests/#{id}"
  defp detail_path("/changes", id), do: ~p"/changes/#{id}"
  defp detail_path("/vulnerabilities", id), do: ~p"/vulnerabilities/#{id}"
end
