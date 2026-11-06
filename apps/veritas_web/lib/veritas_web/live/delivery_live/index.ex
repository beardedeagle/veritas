defmodule Veritas.Web.DeliveryLive.Index do
  @moduledoc """
  Delivery: the Programs.

  `docs/04` §Navigation Model gives the Delivery section *"Programs,
  milestones, work items linked to CIs and Changes"*, and this is the front
  of it — the Programs a Workspace is running.

  ## A Program is a record somebody changes

  The create form is gated by `Policy.authorize(principal, "delivery:write")`
  — the role matrix decides, not the screen — and the write goes through
  `Veritas.Core.Delivery`, so the row and its Audit Log entry are written
  together.
  """
  use Veritas.Web, :live_view

  alias Veritas.Core.{Delivery, Policy, Principal}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Delivery",
       workspace: nil,
       programs: [],
       statuses: Delivery.program_statuses(),
       can_write: false
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace]

    {:noreply, socket |> assign(workspace: workspace) |> load()}
  end

  @impl true
  def handle_event("create", params, socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "delivery:write", %{workspace: workspace}) do
      :allow ->
        attrs = %{
          "name" => params["name"],
          "description" => params["description"] || "",
          "status" => params["status"] || "amber",
          "owner" => params["owner"],
          "actor" => audit_actor(principal)
        }

        case Delivery.create_program(workspace, attrs) do
          {:ok, program} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{program["name"]} is open.")
             |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "The Program was refused: #{inspect(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6">
        <h1 class="text-3xl font-semibold tracking-tight">Delivery</h1>
        <p class="mt-1 text-sm text-base-content/60">
          The Programs this workspace is running.
          workspace <span class="font-mono">{@workspace}</span>
        </p>
      </header>

      <section :if={@can_write} class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Open a Program</h2>

        <form id="program-create" phx-submit="create" class="mt-3 flex flex-wrap items-end gap-3">
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">name</span>
            <input
              type="text"
              name="name"
              required
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">status</span>
            <select name="status" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
              <option :for={status <- @statuses} value={status}>{status}</option>
            </select>
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">owner</span>
            <input
              type="text"
              name="owner"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <button
            type="submit"
            class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
          >
            open
          </button>
        </form>
      </section>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={program <- @programs} class="flex items-baseline justify-between gap-6 py-4">
          <div class="min-w-0">
            <a href={~p"/programs/#{program["id"]}"} class="font-medium hover:underline">
              {program["name"]}
            </a>
            <p class="mt-1 font-mono text-xs text-base-content/60">{program["id"]}</p>
          </div>
          <span class="shrink-0 rounded border border-base-300 px-1.5 py-px text-[10px] uppercase tracking-wide text-base-content/60">
            {program["status"]}
          </span>
        </li>
      </ul>

      <p :if={@programs == []} class="py-10 text-center text-base-content/60">
        No Programs yet. The work that is bigger than a ticket — an ITIL
        transformation, a CMDB build-out, a service-catalogue set — belongs
        here.
      </p>
    </main>
    """
  end

  defp load(socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    programs =
      case Delivery.list_programs(workspace) do
        {:ok, rows} -> rows
        {:error, _reason} -> []
      end

    assign(socket,
      programs: programs,
      can_write: Policy.permitted?(principal, "delivery:write", %{workspace: workspace})
    )
  end

  defp audit_actor(nil), do: %{type: "user", id: "local"}
  defp audit_actor(principal), do: Principal.audit_actor(principal)
end
