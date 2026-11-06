defmodule Veritas.Web.IncidentLive.Show do
  @moduledoc """
  One Incident, and the transitions it is allowed to make.

  The list of legal transitions comes from the `ticket_transition` lookup
  table, not from a hard-coded list in the view, so the UI cannot offer a
  transition the service layer would refuse.

  ## Why the page is loaded in `mount/3`

  A LiveView's **static render** — the HTML the browser receives before the
  socket connects — runs `mount/3` and *not* `handle_params/3`. A page that
  loads its content in `handle_params/3` therefore renders empty on the first
  paint: the ticket is missing and the transition buttons are not there.
  `handle_params/3` is for the *second* navigation, when the socket is
  already connected and the URL changes.

  So the content is loaded in `mount/3`, and `handle_params/3` reloads it when
  the parameters change. The load is idempotent, so the connect — which
  replays `handle_params/3` — does not double the work beyond one read.
  """
  use Veritas.Web, :live_view

  # The shell owns the design system. The pills here are the system's, not
  # hand-rolled, so a state means the same thing on every screen.
  import Veritas.Web.ShellComponents, only: [state_pill: 1, severity_badge: 1]

  alias Veritas.Core.{Policy, Principal, Tickets}
  alias Veritas.Store.Error
  alias Veritas.Web.TicketQueue

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace]

    {:ok,
     socket
     |> assign(
       page_title: "Ticket",
       id: id,
       workspace: workspace,
       ticket: nil,
       transitions: [],
       queue: TicketQueue.queue_for_type(nil)
     )
     |> load(workspace, id)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    workspace = socket.assigns[:principal_workspace]

    {:noreply,
     socket
     |> assign(id: id, workspace: workspace)
     |> load(workspace, id)}
  end

  @impl true
  def handle_event("transition", %{"to-state" => to_state}, socket) do
    workspace = socket.assigns.workspace

    case Tickets.transition(workspace, socket.assigns.id, to_state, socket.assigns[:principal]) do
      {:ok, _ticket} ->
        {:noreply, load(socket, workspace, socket.assigns.id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{Error.message(reason)}")}
    end
  end

  @impl true
  def handle_event("update", params, socket) do
    principal = socket.assigns[:principal]
    workspace = socket.assigns.workspace
    ticket = socket.assigns[:ticket]

    # `docs/09` §4's enforcement table: the LiveView authorises at **every**
    # `handle_event`. The role matrix decides who may write a ticket of this
    # type, not the screen.
    case Policy.authorize(principal, "ticket:write", %{
           workspace: workspace,
           ticket_type: ticket && ticket["ticket_type"]
         }) do
      :allow ->
        # The form edits the ticket's **content** — the title and the
        # description — and nothing else. The service layer refuses every
        # other field by name, so a form that grew a third field would be
        # refused rather than quietly ignored.
        attrs = %{
          "title" => params["title"],
          "description" => params["description"]
        }

        case Tickets.update(workspace, socket.assigns.id, attrs, actor(principal)) do
          {:ok, _ticket} ->
            # The page shows what the store holds, not what the form said.
            {:noreply, socket |> put_flash(:info, "Saved.") |> load(workspace, socket.assigns.id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{Error.message(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  defp actor(%Principal{} = principal), do: Principal.audit_actor(principal)
  defp actor(_principal), do: %{type: "unknown", id: "unknown"}

  defp load(socket, workspace, id) do
    ticket =
      case Tickets.read(workspace, id) do
        {:ok, row} -> row
        _ -> nil
      end

    transitions =
      case ticket do
        %{"ticket_type" => type, "state" => state} ->
          Tickets.available_transitions(workspace, type, state)

        _ ->
          []
      end

    # The back link follows the ticket, not the URL: a Service Request that
    # was opened from the Service Desk queue goes back to the Service Desk
    # queue, whichever route carried it here.
    queue = TicketQueue.queue_for_type(ticket && ticket["ticket_type"])

    assign(socket,
      ticket: ticket,
      transitions: transitions,
      workspace: workspace,
      queue: queue,
      # Whether the edit control is live. The role matrix answers, and the
      # answer is asked for the ticket's **own** type: authority over a
      # Service Request is not authority over a Change.
      can_write:
        Policy.permitted?(socket.assigns[:principal], "ticket:write", %{
          workspace: workspace,
          ticket_type: ticket && ticket["ticket_type"]
        })
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-3xl px-6 py-10">
      <p class="mb-6 text-sm text-base-content/60">
        <a href={back_path(@queue.path)} class="hover:underline">&larr; {@queue.label}</a>
      </p>

      <div :if={@ticket}>
        <h1 class="text-3xl font-semibold tracking-tight">{@ticket["title"]}</h1>
        <p class="mt-2 font-mono text-sm text-base-content/60">{@ticket["id"]}</p>

        <p
          :if={@ticket["description"] not in [nil, ""]}
          class="mt-4 text-sm leading-6 text-base-content/75"
        >
          {@ticket["description"]}
        </p>

        <dl class="mt-8 grid grid-cols-3 gap-4 border-y border-base-300 py-6">
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/60">State</dt>
            <dd class="mt-1"><.state_pill state={@ticket["state"]} /></dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/60">Priority</dt>
            <dd class="mt-1"><.severity_badge priority={@ticket["priority"]} /></dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/60">Opened</dt>
            <dd class="mt-1 font-mono">{@ticket["opened_at"]}</dd>
          </div>
        </dl>

        <h2 class="mt-10 text-lg font-semibold">Legal transitions</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Read from the <span class="font-mono">ticket_transition</span>
          table. An illegal transition is refused
          by the service layer before anything is written.
        </p>

        <div class="mt-4 flex flex-wrap gap-2">
          <button
            :for={to_state <- @transitions}
            phx-click="transition"
            phx-value-to-state={to_state}
            class="rounded-lg border border-base-300 px-4 py-2 text-sm hover:bg-base-100"
          >
            &rarr; {to_state}
          </button>

          <p :if={@transitions == []} class="text-sm text-base-content/60">
            No further transitions from this state.
          </p>
        </div>

        <h2 class="mt-10 text-lg font-semibold">Edit this ticket</h2>
        <p class="mt-1 text-sm text-base-content/60">
          The content of a ticket — its title and its description. The state is
          not edited here: it moves through the transitions above.
        </p>

        <Veritas.Web.CoreComponents.withheld
          capability="ticket:write"
          allowed={@can_write}
          action="edit tickets of this type"
        >
          <form id="ticket-update" phx-submit="update" class="mt-4 space-y-3">
            <label class="block text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">title</span>
              <input
                type="text"
                name="title"
                value={@ticket["title"]}
                required
                class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="block text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">
                description
              </span>
              <input
                type="text"
                name="description"
                value={@ticket["description"] || ""}
                class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              save
            </button>
          </form>
        </Veritas.Web.CoreComponents.withheld>
      </div>

      <p :if={!@ticket} class="py-10 text-base-content/60">
        No such ticket in this workspace.
      </p>
    </main>
    """
  end

  # The four queue routes, written out so that each is a *verified* route: a
  # path that does not exist is a compile error, not a dead link.
  defp back_path("/requests"), do: ~p"/requests"
  defp back_path("/changes"), do: ~p"/changes"
  defp back_path("/vulnerabilities"), do: ~p"/vulnerabilities"
  defp back_path(_path), do: ~p"/incidents"
end
