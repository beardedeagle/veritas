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
  alias Veritas.Store.Error
  alias Veritas.Web.TicketQueue
  import Veritas.Web.WorkflowLive.Components

  @create_sections incident_form_sections()

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
       surface_error: nil,
       create_open: false,
       create_section: "overview",
       create_params: %{"ticket_type" => List.first(queue.types)},
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
  def handle_event("open-create", _params, socket) do
    {:noreply,
     assign(socket,
       create_open: socket.assigns.can_raise,
       create_section: "overview",
       create_params: %{"ticket_type" => List.first(socket.assigns.queue.types)},
       surface_error: nil
     )}
  end

  def handle_event("cancel-create", _params, socket) do
    {:noreply,
     assign(socket,
       create_open: false,
       create_section: "overview",
       surface_error: nil,
       create_params: %{}
     )}
  end

  def handle_event("create-section", %{"section" => section}, socket) do
    if Enum.any?(@create_sections, fn {key, _, _} -> key == section end),
      do: {:noreply, assign(socket, :create_section, section)},
      else: {:noreply, socket}
  end

  def handle_event("change-create", params, socket) do
    section =
      if (params["ticket_type"] || List.first(socket.assigns.queue.types)) == "incident",
        do: socket.assigns.create_section,
        else: "overview"

    {:noreply,
     assign(socket, create_params: Map.drop(params, ["_target"]), create_section: section)}
  end

  def handle_event("raise_ticket", params, socket) do
    socket = assign(socket, :create_params, params)
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]
    ticket_type = params["ticket_type"] || List.first(socket.assigns.queue.types)

    # `docs/09` §4's enforcement table: the LiveView authorises at **every**
    # `handle_event`. The role matrix decides who may write a ticket of this
    # type, not the screen.
    case raise_authority(principal, workspace, ticket_type) do
      :allow ->
        attrs = %{
          "title" => params["title"],
          "description" => params["description"] || "",
          "requester" => presence(params["requester"]) || principal_id(principal)
        }

        actor = Principal.audit_actor(principal)

        fields = if is_map(params["domain_fields"] || %{}), do: incident_creation_fields(params)

        result =
          cond do
            is_nil(fields) ->
              {:error, :invalid_request}

            ticket_type != "incident" and map_size(fields) > 0 ->
              {:error, :invalid_request}

            true ->
              Tickets.open(
                workspace,
                ticket_type,
                Map.put(attrs, "domain_fields", fields),
                principal,
                actor,
                []
              )
          end

        case result do
          {:ok, ticket} ->
            {:noreply,
             socket
             |> assign(:surface_error, nil)
             |> assign(create_open: false, create_section: "overview", create_params: %{})
             |> put_flash(:info, "#{Tickets.reference(ticket)} is open.")
             |> assign(
               tickets: TicketQueue.load(workspace, socket.assigns.queue, socket.assigns.filter)
             )}

          {:error, reason} ->
            error = Error.public(reason)
            fields = Map.keys(Map.get(error, :fields, %{})) ++ Map.get(error, :missing, [])

            section =
              Enum.find_value(@create_sections, socket.assigns.create_section, fn {key, _, names} ->
                if Enum.any?(fields, &(&1 in names)), do: key
              end)

            {:noreply, assign(socket, surface_error: error, create_section: section)}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  # The Incident transaction owns checked authorization and denial auditing.
  defp raise_authority(_principal, _workspace, "incident"), do: :allow

  defp raise_authority(principal, workspace, type),
    do: Policy.authorize(principal, "ticket:write", %{workspace: workspace, ticket_type: type})

  # May this principal raise a ticket of any type the queue holds? The
  # answer comes from the role matrix.
  defp can_raise?(queue, principal, workspace) do
    Enum.any?(queue.types, fn type ->
      context = %{workspace: workspace, ticket_type: type}

      if type == "incident" do
        Policy.permitted_incident?(
          principal,
          "ticket:write",
          Map.merge(context, %{operation: :create, fields: []})
        )
      else
        Policy.permitted?(principal, "ticket:write", context)
      end
    end)
  end

  defp principal_id(nil), do: "unknown"
  defp principal_id(principal), do: principal.id

  # A field the operator left empty is not a value: an empty requester is
  # not a requester, and the store would refuse an empty record id.
  defp presence(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp presence(value), do: value

  defp ticket_label("incident"), do: "Incident"
  defp ticket_label("problem"), do: "Problem"
  defp ticket_label("service_request"), do: "Service Request"
  defp ticket_label("change"), do: "Change"
  defp ticket_label("vulnerability"), do: "Vulnerability"

  @impl true
  def render(assigns) do
    type = assigns.create_params["ticket_type"] || List.first(assigns.queue.types)
    sections = if type == "incident", do: @create_sections, else: Enum.take(@create_sections, 1)
    assigns = assign(assigns, :create_sections, sections)

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <h1 class="flex items-center gap-2 text-3xl font-semibold tracking-tight">
            <.icon name={@queue.icon} class="size-5" />
            {@queue.label}
          </h1>
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

      <Veritas.Web.CoreComponents.withheld
        capability="ticket:write"
        allowed={@can_raise}
        action="raise tickets of this type"
      >
        <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
          <button
            id="create-ticket"
            type="button"
            phx-click="open-create"
            disabled={!@can_raise}
            class="btn btn-primary gap-2"
          >
            <.icon name="hero-plus" class="size-4" /> Create {ticket_label(List.first(@queue.types))}
          </button>
          <.link navigate={~p"/workflows"} class="text-sm text-primary hover:underline">
            Create from a workflow →
          </.link>
        </div>
      </Veritas.Web.CoreComponents.withheld>

      <div
        :if={@create_open}
        id="create-ticket-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="create-ticket-title"
        aria-describedby="create-ticket-description"
        phx-window-keydown="cancel-create"
        phx-key="escape"
        phx-mounted={
          JS.push_focus(to: "#create-ticket")
          |> JS.add_class("overflow-hidden", to: "body")
          |> JS.focus(to: "#create-ticket-title-input")
        }
        phx-remove={JS.remove_class("overflow-hidden", to: "body") |> JS.pop_focus()}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-3 backdrop-blur-sm sm:p-6"
      >
        <.focus_wrap
          id="create-ticket-dialog"
          phx-click-away="cancel-create"
          class={[
            "flex max-h-[90dvh] w-full flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl",
            if(length(@create_sections) > 1,
              do: "h-[min(46rem,90dvh)] max-w-6xl",
              else: "max-w-5xl"
            )
          ]}
        >
          <header class="shrink-0 border-b border-base-300 px-5 py-5 sm:px-7">
            <h2 id="create-ticket-title" class="text-xl font-semibold tracking-tight">
              Create {ticket_label(@create_params["ticket_type"] || List.first(@queue.types))}
            </h2>
            <p id="create-ticket-description" class="mt-1 text-sm text-base-content/65">
              Describe the issue, then add any details you know. Optional fields can be left blank.
            </p>
          </header>

          <form
            id="raise-ticket"
            phx-hook=".CreateSections"
            phx-submit="raise_ticket"
            phx-change="change-create"
            class="flex min-h-0 flex-1 flex-col"
          >
            <div class="flex min-h-0 flex-1 flex-col md:flex-row">
              <nav
                :if={length(@create_sections) > 1}
                aria-label="Incident creation sections"
                class="flex shrink-0 gap-1 overflow-x-auto border-b border-base-300 bg-base-200/30 p-3 md:w-48 md:flex-col md:overflow-y-auto md:border-b-0 md:border-r"
              >
                <button
                  :for={{key, label, _} <- @create_sections}
                  id={"create-nav-#{key}"}
                  type="button"
                  phx-click="create-section"
                  phx-value-section={key}
                  aria-controls={"create-section-#{key}"}
                  aria-current={if @create_section == key, do: "page", else: nil}
                  class={[
                    "shrink-0 rounded-lg px-3 py-3 text-left text-sm font-medium transition-colors",
                    if(@create_section == key,
                      do: "bg-primary/15 text-primary",
                      else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                    )
                  ]}
                >
                  {label}
                </button>
              </nav>
              <div class="min-h-0 min-w-0 flex-1 overflow-y-auto px-5 py-5 sm:px-7">
                <.public_error error={@surface_error} />
                <section
                  id="create-section-overview"
                  data-create-section="overview"
                  hidden={@create_section != "overview"}
                  class="space-y-4"
                  aria-labelledby="incident-overview-title"
                >
                  <h3 id="incident-overview-title" class="text-base font-semibold">Overview</h3>
                  <div class="grid gap-4 sm:grid-cols-2">
                    <label :if={length(@queue.types) > 1} class="block text-sm font-medium">
                      Ticket type
                      <select name="ticket_type" class="select select-bordered mt-1 w-full">
                        <option
                          :for={type <- @queue.types}
                          value={type}
                          selected={
                            type == (@create_params["ticket_type"] || List.first(@queue.types))
                          }
                        >
                          {ticket_label(type)}
                        </option>
                      </select>
                      <span class="mt-1 block text-xs font-normal text-base-content/60">
                        An incident restores service; a problem investigates an underlying cause.
                      </span>
                    </label>
                    <label class="block text-sm font-medium">
                      Reported by
                      <input
                        name="requester"
                        value={@create_params["requester"]}
                        type="text"
                        class="input input-bordered mt-1 w-full"
                      />
                      <span class="mt-1 block text-xs font-normal text-base-content/60">
                        Requester identifier. Leave blank to report this as yourself.
                      </span>
                    </label>
                  </div>
                  <label class="block text-sm font-medium">
                    Title <span class="text-error" aria-hidden="true">*</span>
                    <input
                      id="create-ticket-title-input"
                      name="title"
                      type="text"
                      required
                      value={@create_params["title"] || ""}
                      placeholder="A short summary of the issue"
                      class="input input-bordered mt-1 w-full"
                    />
                    <span class="mt-1 block text-xs font-normal text-base-content/60">
                      Name the affected service and what went wrong.
                    </span>
                  </label>
                  <label class="block text-sm font-medium">
                    Description <textarea
                      name="description"
                      rows="4"
                      class="textarea textarea-bordered mt-1 w-full"
                      placeholder="What happened, who is affected, and what have you tried?"
                    >{@create_params["description"]}</textarea>
                    <span class="mt-1 block text-xs font-normal text-base-content/60">
                      Include symptoms, when the issue began, and useful context for the responder.
                    </span>
                  </label>
                </section>

                <section
                  :for={{key, label, fields} <- @create_sections}
                  :if={key != "overview"}
                  id={"create-section-#{key}"}
                  data-create-section={key}
                  aria-label={label}
                  hidden={@create_section != key}
                >
                  <.incident_controls
                    mode={:create}
                    only={fields}
                    values={
                      if is_map(@create_params["domain_fields"]),
                        do: @create_params["domain_fields"],
                        else: %{}
                    }
                    errors={Map.get(@surface_error || %{}, :fields, %{})}
                  />
                </section>
              </div>
            </div>
            <footer class="flex shrink-0 justify-end gap-3 border-t border-base-300 bg-base-100 px-5 py-4 sm:px-7">
              <button
                id="cancel-create-ticket"
                type="button"
                phx-click="cancel-create"
                class="btn btn-ghost"
              >Cancel</button>
              <button type="submit" phx-disable-with="Submitting…" class="btn btn-primary">Submit</button>
            </footer>
          </form>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CreateSections">
            export default {
              mounted() {
                this.section = this.el.querySelector("[data-create-section]:not([hidden])")?.id
                this.invalid = event => {
                  const section = event.target.closest("[data-create-section]")
                  if (section?.hidden) {
                    event.preventDefault()
                    this.pushEvent("create-section", {section: section.dataset.createSection}, () => {
                      event.target.focus()
                      event.target.reportValidity()
                    })
                  }
                }
                this.el.addEventListener("invalid", this.invalid, true)
              },
              updated() {
                const section = this.el.querySelector("[data-create-section]:not([hidden])")
                if (section && section.id !== this.section) {
                  this.section = section.id
                  section.parentElement.scrollTop = 0
                }
              },
              destroyed() {
                this.el.removeEventListener("invalid", this.invalid, true)
              }
            }
          </script>
        </.focus_wrap>
      </div>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={ticket <- @tickets} class="flex items-baseline justify-between gap-6 py-4">
          <div class="min-w-0">
            <a href={detail_path(@queue.path, ticket["id"])} class="font-medium hover:underline">
              {ticket["title"]}
            </a>
            <p class="mt-1 font-mono text-xs text-base-content/60">
              <a href={~p"/#{Tickets.reference(ticket)}"} class="hover:text-primary hover:underline">{Tickets.reference(
                ticket
              )}</a>
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
