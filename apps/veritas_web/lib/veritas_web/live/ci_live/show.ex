defmodule Veritas.Web.CILive.Show do
  @moduledoc """
  One CI: what it is, what it carries, and what breaks with it.

  The impact graph is the question the CMDB exists to answer — "what depends
  on this?" — and it is derived from the store's traversal, never from
  anything written here.
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
     assign(socket,
       page_title: "CI",
       id: nil,
       ci: nil,
       types: [],
       dependents: [],
       dependencies: [],
       impact: %{},
       workspace: workspace,
       can_write: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace = socket.assigns.workspace
    id = params["id"] || ""

    # The impact carries the CI and the CIs that depend on it, so the page
    # asks the store once and not twice: the traversal the page used to make
    # for itself is the one the impact already made. The dependencies are the
    # other direction, and the impact does not carry them, so they are one
    # traversal of their own.
    impact = CI.impact(workspace, id, 5)
    dependencies = CI.relations(workspace, id, :out, 5)
    types = CI.types(workspace)

    impact = impact_of(impact)

    {:noreply,
     assign(socket,
       id: id,
       ci: impact["ci"] || %{},
       types: rows(types),
       dependents: impact["dependents"] || [],
       dependencies: nodes(dependencies),
       impact: impact,
       workspace: workspace,
       can_write:
         Policy.permitted?(socket.assigns[:principal], "ci:write", %{workspace: workspace})
     )}
  end

  @impl true
  def handle_event("update", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    # `docs/09` §4's enforcement table: the LiveView authorises at **every**
    # `handle_event`. Only a CI Steward writes CI records.
    case Policy.authorize(principal, "ci:write", %{workspace: workspace}) do
      :allow ->
        attrs = %{
          "name" => params["name"],
          "lifecycle_state" => params["lifecycle_state"],
          "criticality" => params["criticality"],
          "owner" => params["owner"],
          "actor" => Principal.audit_actor(principal)
        }

        case CI.update(workspace, socket.assigns.id, attrs) do
          {:ok, _ci} ->
            {:noreply, socket |> put_flash(:info, "Saved.") |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{Error.message(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def handle_event("clone", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]
    ci = socket.assigns.ci

    case Policy.authorize(principal, "ci:write", %{workspace: workspace}) do
      :allow ->
        # A clone is a creation, not a copy of a row: the new CI carries the
        # source's attributes and gets its own identity. The type is the
        # operator's choice, and the type's schema is the arbiter of whether
        # the carried attributes fit it.
        attrs = %{
          "ci_type" => params["ci_type"] || ci["ci_type"],
          "name" => params["name"],
          "lifecycle_state" => ci["lifecycle_state"],
          "criticality" => ci["criticality"],
          "owner" => ci["owner"],
          "attributes" => ci["attributes"] || %{},
          "actor" => Principal.audit_actor(principal)
        }

        case CI.create(workspace, attrs) do
          {:ok, created} ->
            {:noreply,
             socket
             |> put_flash(:info, "Cloned into #{created["id"]}.")
             |> push_patch(to: ~p"/cmdb/cis/#{created["id"]}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{Error.message(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  # Re-read the CI after a write, so the page shows what the store holds
  # rather than what the form said.
  defp reload(socket) do
    workspace = socket.assigns.workspace
    id = socket.assigns.id

    impact = impact_of(CI.impact(workspace, id, 5))
    dependencies = nodes(CI.relations(workspace, id, :out, 5))

    assign(socket,
      ci: impact["ci"] || %{},
      dependents: impact["dependents"] || [],
      dependencies: dependencies,
      impact: impact
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-8 flex items-baseline justify-between">
        <div>
          <h1 class="text-3xl font-semibold tracking-tight">{@ci["name"] || "CI"}</h1>
          <p class="mt-1 font-mono text-xs text-base-content/60">{@ci["id"]}</p>
        </div>
        <p class="text-sm text-base-content/60">
          workspace <span class="font-mono">{@workspace}</span>
        </p>
      </header>

      <div class="grid gap-8 md:grid-cols-2">
        <section>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">The CI</h2>
          <dl class="mt-3 space-y-2 text-sm">
            <div class="flex justify-between border-b border-base-300 py-1">
              <dt class="text-base-content/60">type</dt>
              <dd class="font-mono">{@ci["ci_type"]}</dd>
            </div>
            <div class="flex justify-between border-b border-base-300 py-1">
              <dt class="text-base-content/60">lifecycle</dt>
              <dd><.lifecycle_pill lifecycle={@ci["lifecycle_state"]} /></dd>
            </div>
            <div class="flex justify-between border-b border-base-300 py-1">
              <dt class="text-base-content/60">criticality</dt>
              <dd><.criticality_badge criticality={@ci["criticality"]} /></dd>
            </div>
            <div class="flex justify-between border-b border-base-300 py-1">
              <dt class="text-base-content/60">owner</dt>
              <dd class="font-mono">{@ci["owner"] || "—"}</dd>
            </div>
          </dl>

          <h2 class="mt-8 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Attributes
          </h2>
          <dl class="mt-3 space-y-2 text-sm">
            <div
              :for={{name, value} <- Map.to_list(@ci["attributes"] || %{})}
              class="flex justify-between border-b border-base-300 py-1"
            >
              <dt class="text-base-content/60">{name}</dt>
              <dd class="font-mono">{to_string(value)}</dd>
            </div>
            <p :if={@ci["attributes"] == nil or @ci["attributes"] == %{}} class="text-base-content/70">
              No attributes.
            </p>
          </dl>
        </section>

        <section>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Impact — what depends on this
          </h2>

          <h3 class="mt-4 text-sm text-base-content/75">Dependents</h3>
          <ul class="mt-1 space-y-1 text-sm">
            <li :for={node <- @dependents} class="flex items-baseline justify-between gap-4">
              <a href={"/cmdb/cis/#{node["id"]}?workspace=#{@workspace}"} class="hover:underline">
                {node["name"]}
              </a>
              <span class="font-mono text-xs text-base-content/60">{node["ci_type"]}</span>
            </li>
          </ul>
          <p :if={@dependents == []} class="mt-1 text-sm text-base-content/70">
            Nothing depends on this.
          </p>

          <h3 class="mt-6 text-sm text-base-content/75">Dependencies</h3>
          <ul class="mt-1 space-y-1 text-sm">
            <li :for={node <- @dependencies} class="flex items-baseline justify-between gap-4">
              <a href={"/cmdb/cis/#{node["id"]}?workspace=#{@workspace}"} class="hover:underline">
                {node["name"]}
              </a>
              <span class="font-mono text-xs text-base-content/60">{node["ci_type"]}</span>
            </li>
          </ul>
          <p :if={@dependencies == []} class="mt-1 text-sm text-base-content/70">
            This depends on nothing.
          </p>

          <h3 class="mt-6 text-sm text-base-content/75">Services in the blast radius</h3>
          <ul class="mt-1 space-y-1 text-sm">
            <li
              :for={service <- @impact["services"]}
              class="flex items-baseline justify-between gap-4"
            >
              <span>{service["name"]}</span>
              <span class="font-mono text-xs text-base-content/60">{service["criticality"]}</span>
            </li>
          </ul>
          <p :if={@impact["services"] == []} class="mt-1 text-sm text-base-content/70">
            No service is in the blast radius.
          </p>
        </section>
      </div>

      <section class="v-panel mt-8 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Edit this CI</h2>

        <Veritas.Web.CoreComponents.withheld
          capability="ci:write"
          allowed={@can_write}
          action="write Configuration Items"
        >
          <form id="ci-update" phx-submit="update" class="mt-3 flex flex-wrap items-end gap-3">
            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">name</span>
              <input
                type="text"
                name="name"
                value={@ci["name"]}
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
                <option value="proposed" selected={@ci["lifecycle_state"] == "proposed"}>
                  proposed
                </option>
                <option value="active" selected={@ci["lifecycle_state"] == "active"}>active</option>
                <option
                  value="in_maintenance"
                  selected={@ci["lifecycle_state"] == "in_maintenance"}
                >
                  in_maintenance
                </option>
                <option value="retired" selected={@ci["lifecycle_state"] == "retired"}>
                  retired
                </option>
                <option value="disposed" selected={@ci["lifecycle_state"] == "disposed"}>
                  disposed
                </option>
              </select>
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">criticality</span>
              <select name="criticality" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                <option value="low" selected={@ci["criticality"] == "low"}>low</option>
                <option value="medium" selected={@ci["criticality"] == "medium"}>medium</option>
                <option value="high" selected={@ci["criticality"] == "high"}>high</option>
                <option value="tier1" selected={@ci["criticality"] == "tier1"}>tier1</option>
              </select>
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">owner</span>
              <input
                type="text"
                name="owner"
                value={@ci["owner"]}
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              save
            </button>
          </form>

          <h2 class="mt-6 text-[13px] font-semibold tracking-tight">Clone this CI</h2>
          <p class="mt-1 text-xs leading-5 text-base-content/55">
            A clone is a new CI that carries this one's attributes and gets its
            own identity. The CMDB is a record of what exists, so nothing is
            removed here.
          </p>
        </Veritas.Web.CoreComponents.withheld>

        <Veritas.Web.CoreComponents.withheld
          capability="ci:write"
          allowed={@can_write}
          action="write Configuration Items"
        >
          <form id="ci-clone" phx-submit="clone" class="mt-3 flex flex-wrap items-end gap-3">
            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">name</span>
              <input
                type="text"
                name="name"
                value={"#{@ci["name"] || ""} copy"}
                required
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">type</span>
              <select name="ci_type" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                <option
                  :for={type <- @types}
                  value={type["id"]}
                  selected={type["id"] == @ci["ci_type"]}
                >
                  {type["id"]}
                </option>
              </select>
            </label>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              clone
            </button>
          </form>
        </Veritas.Web.CoreComponents.withheld>
      </section>

      <section class="mt-10">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          The CI type registry
        </h2>
        <ul class="mt-3 divide-y divide-base-300 border-y border-base-300 text-sm">
          <li :for={type <- @types} class="flex items-baseline justify-between py-2">
            <span class="font-mono">{type["id"]}</span>
            <span class="text-xs text-base-content/60">
              requires {Enum.join(type["required"] || [], ", ")}
            </span>
          </li>
        </ul>
      </section>
    </main>
    """
  end

  defp rows({:ok, rows}), do: rows || []
  defp rows(_other), do: []

  defp nodes({:ok, %{nodes: nodes}}), do: nodes || []
  defp nodes(_other), do: []

  defp impact_of({:ok, impact}), do: normalise_impact(impact)
  defp impact_of(_other), do: %{}

  # `CI.impact/3` hands back the impact map with ATOM keys — `:ci`,
  # `:services`, `:tickets`, `:dependents` — because that is the shape the
  # GraphQL resolver and the CLI both read. Every other domain map this
  # template touches (the CI itself, the relation nodes) comes straight from
  # the store with STRING keys.
  #
  # Reading one shape with the other's key style is what turned this page
  # into a 500: `@impact["services"]` was `nil`, and `:for` over `nil` is
  # `Enum.map(nil, ...)` — a Protocol.UndefinedError, not a blank list.
  #
  # Normalise once, here, and accept either key style so the two halves of
  # the codebase cannot drift apart again.
  defp normalise_impact(impact) when is_map(impact) do
    %{
      "ci" => impact[:ci] || impact["ci"],
      "services" => impact[:services] || impact["services"] || [],
      "tickets" => impact[:tickets] || impact["tickets"] || [],
      "dependents" => impact[:dependents] || impact["dependents"] || []
    }
  end

  defp normalise_impact(_other), do: %{}
end
