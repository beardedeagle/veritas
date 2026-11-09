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
  import Veritas.Web.WorkflowLive.Components

  @record_sections incident_form_sections() ++ [{"history", "History", []}]

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
       domain_view: nil,
       surface_error: nil,
       transitions: [],
       record_section: "overview",
       record_sections: @record_sections,
       record_params: %{},
       record_dirty: false,
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
  def handle_event("transition", params, socket) do
    workspace = socket.assigns.workspace
    to_state = params["to-state"] || params["to_state"] || ""
    principal = socket.assigns[:principal]

    case Tickets.transition(
           workspace,
           socket.assigns.id,
           to_state,
           principal,
           actor(principal),
           domain_opts(socket) ++ [domain_fields: incident_fields(params)]
         ) do
      {:ok, _ticket} ->
        {:noreply, load(socket, workspace, socket.assigns.id)}

      {:error, reason} ->
        {:noreply, assign(socket, :surface_error, Error.public(reason))}
    end
  end

  @impl true
  def handle_event("update", params, socket) do
    principal = socket.assigns[:principal]
    workspace = socket.assigns.workspace
    ticket = socket.assigns[:ticket]

    decision =
      if ticket && ticket["ticket_type"] == "incident",
        do: :allow,
        else:
          Policy.authorize(principal, "ticket:write", %{
            workspace: workspace,
            ticket_type: ticket && ticket["ticket_type"]
          })

    case decision do
      :allow ->
        # The form edits the ticket's **content** — the title and the
        # description — and nothing else. The service layer refuses every
        # other field by name, so a form that grew a third field would be
        # refused rather than quietly ignored.
        attrs = %{
          "title" => params["title"],
          "description" => params["description"]
        }

        case Tickets.update(
               workspace,
               socket.assigns.id,
               attrs,
               principal,
               actor(principal),
               domain_opts(socket)
             ) do
          {:ok, _ticket} ->
            # The page shows what the store holds, not what the form said.
            {:noreply, socket |> put_flash(:info, "Saved.") |> load(workspace, socket.assigns.id)}

          {:error, reason} ->
            {:noreply, assign(socket, :surface_error, Error.public(reason))}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  def handle_event("correct-domain", params, socket) do
    case Tickets.update_domain(
           socket.assigns.workspace,
           socket.assigns.id,
           incident_fields(params),
           socket.assigns.principal,
           domain_opts(socket)
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load(socket.assigns.workspace, socket.assigns.id)
         |> put_flash(
           :info,
           "Incident facts corrected; workflow step and approved history unchanged."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :surface_error, Error.public(reason))}
    end
  end

  def handle_event("record-section", %{"section" => section}, socket) do
    if Enum.any?(@record_sections, fn {key, _, _} -> key == section end),
      do: {:noreply, assign(socket, :record_section, section)},
      else: {:noreply, socket}
  end

  def handle_event(event, %{"domain_fields" => fields}, socket)
      when event in ["record-change", "save-record"] and not is_map(fields) do
    {:noreply, assign(socket, :surface_error, Error.public(:invalid_request))}
  end

  def handle_event("record-change", params, socket) do
    changes = incident_record_fields(params, socket.assigns.domain_view.domain)

    {:noreply,
     assign(socket, record_params: Map.drop(params, ["_target"]), record_dirty: changes != %{})}
  end

  def handle_event("save-record", params, socket) do
    fields = incident_record_fields(params, socket.assigns.domain_view.domain)
    socket = assign(socket, record_params: params, record_dirty: fields != %{})

    if fields == %{} do
      {:noreply, socket}
    else
      case Tickets.update_domain(
             socket.assigns.workspace,
             socket.assigns.id,
             fields,
             socket.assigns.principal,
             domain_opts(socket)
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load(socket.assigns.workspace, socket.assigns.id)
           |> put_flash(:info, "Incident saved.")}

        {:error, reason} ->
          error = Error.public(reason)
          fields = Map.keys(Map.get(error, :fields, %{})) ++ Map.get(error, :missing, [])

          section =
            Enum.find_value(@record_sections, socket.assigns.record_section, fn {key, _, names} ->
              if Enum.any?(fields, &(&1 in names)), do: key
            end)

          {:noreply, assign(socket, surface_error: error, record_section: section)}
      end
    end
  end

  def handle_event("cancel-record", _, socket),
    do: {:noreply, load(socket, socket.assigns.workspace, socket.assigns.id)}

  def handle_event("reload-domain", _, socket),
    do: {:noreply, load(socket, socket.assigns.workspace, socket.assigns.id)}

  defp domain_opts(%{assigns: %{domain_view: nil}}), do: []

  defp domain_opts(%{assigns: %{domain_view: view}}),
    do: [
      expected_domain_revision: view.domain_revision,
      expected_revision: view.workflow_revision,
      expected_policy_version: view.policy.active_version
    ]

  defp actor(%Principal{} = principal), do: Principal.audit_actor(principal)
  defp actor(_principal), do: %{type: "unknown", id: "unknown"}

  defp load(socket, workspace, id) do
    {ticket, view, error} =
      case Tickets.read_domain(workspace, id, socket.assigns.principal) do
        {:ok, view} ->
          {view.ticket, view, nil}

        {:error, :not_found} ->
          case Policy.authorize(socket.assigns.principal, "ticket:read", %{workspace: workspace}) do
            :allow ->
              case Tickets.read(workspace, id) do
                {:ok, row} -> {row, nil, nil}
                {:error, reason} -> {nil, nil, Error.public(reason)}
              end

            {:deny, reason} ->
              {nil, nil, Error.public(reason)}
          end

        {:error, reason} ->
          {nil, nil, Error.public(reason)}
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
      domain_view: view,
      surface_error: error,
      transitions: transitions,
      workspace: workspace,
      queue: queue,
      record_params:
        if(view,
          do: %{
            "title" => ticket["title"],
            "description" => ticket["description"] || "",
            "domain_fields" => Map.drop(view.domain, ~w(title description))
          },
          else: %{}
        ),
      record_dirty: false,
      # Whether the edit control is live. The role matrix answers, and the
      # answer is asked for the ticket's **own** type: authority over a
      # Service Request is not authority over a Change.
      can_write:
        not is_nil(view) or
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

    <main class="mx-auto max-w-6xl px-6 py-8">
      <p class="mb-6 text-sm text-base-content/60">
        <a href={back_path(@queue.path)} class="hover:underline">&larr; {@queue.label}</a>
      </p>

      <.public_error error={@surface_error} />
      <div :if={@domain_view}>
        <header class="mb-7 border-b border-base-300 pb-6">
          <p class="mb-2 flex flex-wrap items-center gap-2 text-xs font-medium tracking-widest text-base-content/55">
            Incident
            <a href={~p"/#{Tickets.reference(@ticket)}"} class="hover:text-primary hover:underline">{Tickets.reference(
              @ticket
            )}</a>
            <span
              id="incident-reference-copy"
              phx-hook=".CopyReference"
              data-reference={Tickets.reference(@ticket)}
              class="inline-flex items-center gap-2 tracking-normal"
            >
              <button
                type="button"
                aria-label={"Copy #{Tickets.reference(@ticket)}"}
                title="Copy incident reference"
                class="inline-flex rounded p-1 hover:bg-base-200 hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary"
              >
                <.icon name="hero-document-duplicate" class="size-4" />
              </button>
              <span data-copy-status role="status" aria-live="polite"></span>
            </span>
          </p>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyReference">
            export default {
              mounted() {
                this.button = this.el.querySelector("button")
                this.copy = async () => {
                  const status = this.el.querySelector("[data-copy-status]")
                  status.textContent = ""
                  try {
                    await navigator.clipboard.writeText(this.el.dataset.reference)
                    status.textContent = "Copied"
                  } catch {
                    status.textContent = "Copy failed. Select the reference and copy it manually."
                  }
                }
                this.button.addEventListener("click", this.copy)
              },
              destroyed() {
                this.button.removeEventListener("click", this.copy)
              }
            }
          </script>
          <h1 class="text-2xl font-semibold tracking-tight">{@ticket["title"]}</h1>
          <div class="mt-4 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm">
            <.state_pill state={@ticket["state"]} />
            <.severity_badge :if={@domain_view.domain["priority"]} priority={@ticket["priority"]} />
            <span :if={!@domain_view.domain["priority"]} class="text-base-content/60">Priority awaiting policy</span>
            <span class="text-base-content/60">Opened {record_time(@ticket["opened_at"])}</span>
            <.link
              :if={@domain_view.workflow_revision}
              navigate={~p"/workflows/tickets/#{@id}"}
              class="text-primary"
            >Open workflow →</.link>
          </div>
        </header>

        <div class="grid items-start gap-6 md:grid-cols-[13rem_minmax(0,1fr)]">
          <aside class="space-y-7 md:sticky md:top-6">
            <nav aria-label="Incident sections" class="flex flex-wrap gap-1 md:flex-col">
              <button
                :for={{key, label, _} <- @record_sections}
                id={"incident-nav-#{key}"}
                type="button"
                phx-click="record-section"
                phx-value-section={key}
                aria-controls={"incident-section-#{key}"}
                aria-current={if @record_section == key, do: "page", else: nil}
                class={[
                  "rounded-lg px-4 py-3 text-left text-sm font-medium transition-colors",
                  if(@record_section == key,
                    do: "bg-primary/15 text-primary",
                    else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                  )
                ]}
              >{label}</button>
            </nav>
            <div class="rounded-xl border border-base-300 p-4">
              <h2 class="mb-3 text-sm font-semibold">Update status</h2>
              <form id="incident-transition" phx-submit="transition" class="space-y-3">
                <label class="block text-xs text-base-content/65" for="incident-next-state">Next status</label>
                <select
                  id="incident-next-state"
                  name="to_state"
                  required
                  class="select select-bordered w-full"
                >
                  <option value="">Choose…</option><option :for={state <- @transitions} value={state}>
                    {state |> String.replace("_", " ") |> String.capitalize()}
                  </option>
                </select>
                <button type="submit" class="btn btn-outline btn-sm w-full" disabled={@record_dirty}>Update status</button>
              </form>
              <p :if={@record_dirty} class="mt-3 text-xs text-base-content/60">
                Save or cancel your field changes before updating status.
              </p>
              <p :if={@domain_view.workflow_revision} class="mt-3 text-xs text-base-content/60">
                Managed workflows advance through their current step.
              </p>
            </div>
          </aside>

          <form
            id="incident-record"
            phx-submit="save-record"
            phx-change="record-change"
            novalidate
            class="min-w-0 rounded-xl border border-base-300 bg-base-100"
          >
            <section
              :for={{key, label, fields} <- @record_sections}
              id={"incident-section-#{key}"}
              aria-labelledby={"incident-nav-#{key}"}
              hidden={@record_section != key}
              class={["space-y-6 p-5 sm:p-7", @record_section != key && "hidden"]}
            >
              <div>
                <h2 class="text-lg font-semibold">{label}</h2>
                <p class="mt-1 text-sm text-base-content/60">{section_description(key)}</p>
              </div>
              <div :if={key == "overview"} class="space-y-5">
                <label class="block space-y-2 text-sm font-medium">
                  <span>Reported by</span>
                  <input
                    id="incident-reported-by"
                    type="text"
                    value={
                      if @ticket["requester"] in [nil, ""],
                        do: "Not recorded",
                        else: @ticket["requester"]
                    }
                    readonly
                    aria-describedby="incident-reported-by-help"
                    class="input input-bordered w-full"
                  />
                  <span
                    id="incident-reported-by-help"
                    class="block text-xs font-normal text-base-content/60"
                  >
                    The requester recorded when this incident was created.
                  </span>
                </label>
                <label class="block space-y-2 text-sm font-medium">
                  <span>Short description <span class="text-error">*</span></span>
                  <input
                    name="title"
                    value={@record_params["title"]}
                    required
                    class="input input-bordered w-full"
                  />
                </label>
                <label class="block space-y-2 text-sm font-medium">
                  <span>Description</span>
                  <textarea
                    name="description"
                    rows="6"
                    class="textarea textarea-bordered w-full leading-6"
                  >{@record_params["description"]}</textarea>
                </label>
                <p
                  :if={!@domain_view.policy.active_version}
                  class="rounded-lg bg-base-200 px-4 py-3 text-xs leading-5 text-base-content/65"
                >
                  Priority is awaiting the Workspace's Incident policy. The original legacy priority remains preserved in History.
                </p>
              </div>
              <.incident_controls
                :if={key not in ~w(overview history)}
                mode={:record}
                only={fields}
                values={@record_params["domain_fields"] || %{}}
                errors={Map.get(@surface_error || %{}, :fields, %{})}
              />
              <div :if={key == "history"} class="space-y-6">
                <.incident_activity view={@domain_view} />
                <details class="rounded-lg border border-base-300 p-4">
                  <summary class="cursor-pointer text-sm font-medium">
                    Technical record details
                  </summary>
                  <div class="mt-4"><.incident_readback view={@domain_view} /></div>
                </details>
              </div>
            </section>
            <footer class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 px-5 py-4 sm:px-7">
              <p class="text-xs text-base-content/60">
                {if @record_dirty, do: "Unsaved changes", else: "All changes saved"}
              </p>
              <div class="flex justify-end gap-2">
                <button
                  id="cancel-incident-record"
                  type="button"
                  phx-click="cancel-record"
                  class="btn btn-ghost"
                  disabled={!@record_dirty}
                >Cancel</button>
                <button
                  id="save-incident-record"
                  type="submit"
                  class="btn btn-primary"
                  disabled={!@record_dirty}
                >Save changes</button>
              </div>
            </footer>
          </form>
        </div>
      </div>

      <div :if={@ticket && !@domain_view} class="mx-auto max-w-3xl">
        <h1 class="text-3xl font-semibold tracking-tight">{@ticket["title"]}</h1>
        <p class="mt-2 font-mono text-sm text-base-content/60">
          <a href={~p"/#{Tickets.reference(@ticket)}"} class="hover:underline">{Tickets.reference(
            @ticket
          )}</a>
        </p>

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

  defp section_description("overview"), do: "The saved report and the person who reported it."

  defp section_description("priority"), do: "Impact, urgency, severity and the priority decision."

  defp section_description("ownership"),
    do: "Assignment and links to affected systems or a related problem."

  defp section_description("response"),
    do: "Restoration, investigation, workarounds and recovery evidence."

  defp section_description("communications"),
    do: "Saved notification, response and requester confirmation records."

  defp section_description("hold"),
    do: "Why work is paused, who will unblock it and when it can resume."

  defp section_description("resolution"), do: "The resolution outcome or reason for cancellation."

  defp section_description("history"),
    do: "Recorded field updates, attribution and the original record history."

  # The four queue routes, written out so that each is a *verified* route: a
  # path that does not exist is a compile error, not a dead link.
  defp back_path("/requests"), do: ~p"/requests"
  defp back_path("/changes"), do: ~p"/changes"
  defp back_path("/vulnerabilities"), do: ~p"/vulnerabilities"
  defp back_path(_path), do: ~p"/incidents"
end
