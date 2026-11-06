defmodule Veritas.Web.CILive.Index do
  @moduledoc """
  The CMDB: the list of Configuration Items.

  The second LiveView surface. It calls `Veritas.Core.CI` and nothing else,
  so every operation here is available in GraphQL and the CLI without a second
  implementation (INV-8).
  """
  use Veritas.Web, :live_view

  # The shell owns the design system. The pills here are the system's, not
  # hand-rolled, so a lifecycle and a criticality mean the same thing on
  # every screen.
  import Veritas.Web.ShellComponents, only: [lifecycle_pill: 1, criticality_badge: 1]

  alias Veritas.Core.{CI, Policy, Principal}
  alias Veritas.Store.Error

  @impl true
  def mount(_params, _session, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace]

    {:ok,
     socket
     |> assign(
       page_title: "CMDB",
       cis: [],
       filters: %{ci_type: nil, lifecycle_state: nil, criticality: nil},
       workspace: workspace,
       ci_types: [],
       selected_type: nil,
       can_write: false
     )
     |> load_types()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      ci_type: filter_value(params["type"]),
      lifecycle_state: filter_value(params["lifecycle"]),
      criticality: filter_value(params["criticality"])
    }

    {:noreply, socket |> assign(filters: filters) |> load_cis(filters)}
  end

  @impl true
  def handle_event("choose_type", %{"ci_type" => ci_type}, socket) do
    # The attribute fields belong to the type, so choosing another type
    # changes the form. Choosing the same one does not: the operator's
    # typing must survive a change event on another field.
    if ci_type == socket.assigns.selected_type do
      {:noreply, socket}
    else
      {:noreply, assign(socket, selected_type: ci_type)}
    end
  end

  @impl true
  def handle_event("create", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    # `docs/09` §4's enforcement table: the LiveView authorises at **every**
    # `handle_event`. Only a CI Steward writes CI records, and the check is
    # the policy's, not the screen's.
    case Policy.authorize(principal, "ci:write", %{workspace: workspace}) do
      :allow ->
        attrs = %{
          "ci_type" => params["ci_type"],
          "name" => params["name"],
          "lifecycle_state" => params["lifecycle_state"],
          "criticality" => params["criticality"],
          "owner" => params["owner"],
          "attributes" => attributes(params),
          "actor" => Principal.audit_actor(principal)
        }

        case CI.create(workspace, attrs) do
          {:ok, ci} ->
            {:noreply,
             socket
             |> put_flash(:info, "Created #{ci["name"]}.")
             |> assign(selected_type: nil)
             |> load_cis(socket.assigns.filters)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{Error.message(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  # The form's "any" options submit ""; CI.list/2 uses nil for unset filters.
  defp filter_value(""), do: nil
  defp filter_value(value), do: value

  defp load_types(socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    types =
      case CI.types(workspace) do
        {:ok, rows} -> rows
        {:error, _reason} -> []
      end

    selected =
      socket.assigns.selected_type ||
        case types do
          [first | _] -> first["id"]
          [] -> nil
        end

    assign(socket,
      ci_types: types,
      selected_type: selected,
      can_write: Policy.permitted?(principal, "ci:write", %{workspace: workspace})
    )
  end

  defp load_cis(socket, filters) do
    workspace = socket.assigns.workspace

    # `Veritas.Core.CI.list/2` takes a keyword list of options — that is its
    # contract (`@spec list(workspace(), keyword())`), and the CLI passes one
    # too. The map above is for the template, which reads `@filters.ci_type`.
    list_opts = [
      ci_type: filters.ci_type,
      lifecycle_state: filters.lifecycle_state,
      criticality: filters.criticality
    ]

    cis =
      case CI.list(workspace, list_opts) do
        {:ok, rows} -> rows
        {:error, reason} -> [%{"id" => "error", "name" => inspect(reason), "relations" => 0}]
      end

    # The relation counts of every row, in one pass.
    #
    # Asking per row is the N+1 the corpus names — one query per row per
    # relation — and the list page has fifty rows. The counts come from one
    # batched query per relation kind for the whole page.
    #
    # A count that fails is **unknown**, not zero. A page that says "0
    # relations" when it could not ask is lying about the CMDB, and the
    # difference matters: zero is a fact about the Workspace, and a failure is
    # a fact about this request.
    counts =
      case CI.relation_counts(workspace, Enum.map(cis, & &1["id"])) do
        {:ok, counts} -> counts
        {:error, _reason} -> nil
      end

    cis =
      Enum.map(cis, fn ci -> Map.put(ci, "relations", counts && Map.get(counts, ci["id"])) end)

    assign(socket, cis: cis, workspace: workspace)
  end

  # The type's own attributes come from the form as a map. An empty field is
  # not an attribute: the type's schema says what it requires, and it says
  # nothing about a blank string.
  defp attributes(params) do
    params
    |> Map.get("attributes", %{})
    |> Enum.reject(fn {_name, value} -> value == "" end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-8 flex items-baseline justify-between">
        <h1 class="text-3xl font-semibold tracking-tight">CMDB</h1>
        <p class="text-sm text-base-content/60">
          workspace <span class="font-mono">{@workspace}</span>
        </p>
      </header>

      <form class="mb-6 flex flex-wrap items-end gap-3" method="get" action="/cmdb/cis">
        <input type="hidden" name="workspace" value={@workspace} />

        <label class="text-sm text-base-content/75">
          <span class="block text-xs uppercase tracking-wide text-base-content/70">type</span>
          <select name="type" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
            <option value="">any</option>
            <option value="server" selected={@filters.ci_type == "server"}>server</option>
            <option value="application" selected={@filters.ci_type == "application"}>
              application
            </option>
            <option value="service" selected={@filters.ci_type == "service"}>service</option>
            <option value="database" selected={@filters.ci_type == "database"}>database</option>
            <option value="container" selected={@filters.ci_type == "container"}>container</option>
            <option value="network_device" selected={@filters.ci_type == "network_device"}>
              network_device
            </option>
          </select>
        </label>

        <label class="text-sm text-base-content/75">
          <span class="block text-xs uppercase tracking-wide text-base-content/70">lifecycle</span>
          <select name="lifecycle" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
            <option value="">any</option>
            <option value="proposed" selected={@filters.lifecycle_state == "proposed"}>
              proposed
            </option>
            <option value="active" selected={@filters.lifecycle_state == "active"}>active</option>
            <option value="in_maintenance" selected={@filters.lifecycle_state == "in_maintenance"}>
              in_maintenance
            </option>
            <option value="retired" selected={@filters.lifecycle_state == "retired"}>retired</option>
            <option value="disposed" selected={@filters.lifecycle_state == "disposed"}>
              disposed
            </option>
          </select>
        </label>

        <label class="text-sm text-base-content/75">
          <span class="block text-xs uppercase tracking-wide text-base-content/70">criticality</span>
          <select name="criticality" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
            <option value="">any</option>
            <option value="low" selected={@filters.criticality == "low"}>low</option>
            <option value="medium" selected={@filters.criticality == "medium"}>medium</option>
            <option value="high" selected={@filters.criticality == "high"}>high</option>
            <option value="tier1" selected={@filters.criticality == "tier1"}>tier1</option>
          </select>
        </label>

        <button
          type="submit"
          class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
        >
          filter
        </button>
      </form>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Add a Configuration Item</h2>

        <Veritas.Web.CoreComponents.withheld
          capability="ci:write"
          allowed={@can_write}
          action="write Configuration Items"
        >
          <p class="mt-1 text-xs leading-5 text-base-content/55">
            The type carries the attributes it requires. The CMDB is a record of
            what exists, so an item is added here and never removed.
          </p>

          <form
            id="ci-create"
            phx-submit="create"
            phx-change="choose_type"
            class="mt-3 flex flex-wrap items-end gap-3"
          >
            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">type</span>
              <select name="ci_type" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                <option
                  :for={type <- @ci_types}
                  value={type["id"]}
                  selected={type["id"] == @selected_type}
                >
                  {type["id"]}
                </option>
              </select>
            </label>

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
              <span class="block text-xs uppercase tracking-wide text-base-content/70">lifecycle</span>
              <select
                name="lifecycle_state"
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              >
                <option value="proposed">proposed</option>
                <option value="active" selected>active</option>
                <option value="in_maintenance">in_maintenance</option>
                <option value="retired">retired</option>
                <option value="disposed">disposed</option>
              </select>
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">criticality</span>
              <select name="criticality" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                <option value="low">low</option>
                <option value="medium" selected>medium</option>
                <option value="high">high</option>
                <option value="tier1">tier1</option>
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

            <label
              :for={attribute <- required_attributes(@ci_types, @selected_type)}
              class="text-sm text-base-content/75"
            >
              <span class="block text-xs uppercase tracking-wide text-base-content/70">
                {attribute}
              </span>
              <input
                type="text"
                name={"attributes[#{attribute}]"}
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              create
            </button>
          </form>
        </Veritas.Web.CoreComponents.withheld>
      </section>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={ci <- @cis} class="flex items-baseline justify-between gap-6 py-4">
          <div class="min-w-0">
            <a
              href={"/cmdb/cis/#{ci["id"]}?workspace=#{@workspace}"}
              class="font-medium hover:underline"
            >
              {ci["name"]}
            </a>
            <p class="mt-1 font-mono text-xs text-base-content/60">{ci["id"]}</p>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <span class="text-sm text-base-content/60">{ci["ci_type"]}</span>
            <.lifecycle_pill lifecycle={ci["lifecycle_state"]} />
            <.criticality_badge criticality={ci["criticality"]} />
            <span class="text-sm text-base-content/60">{ci["owner"] || "—"}</span>
            <span class="text-sm text-base-content/60">
              {case ci["relations"] do
                nil -> "—"
                count -> "#{count} #{if count == 1, do: "relation", else: "relations"}"
              end}
            </span>
          </div>
        </li>
      </ul>

      <p :if={@cis == []} class="py-10 text-center text-base-content/60">
        No configuration items in this workspace yet.
      </p>
    </main>
    """
  end

  # How many relations a CI has. The count comes from the store's batched
  # relation counts, the same question the CI's own page answers.

  # The attributes the selected type requires. The type is data, so the form
  # asks the registry rather than carrying a list of its own.
  defp required_attributes(types, selected_type) do
    case Enum.find(types, &(&1["id"] == selected_type)) do
      nil -> []
      type -> type["required"] || []
    end
  end
end
