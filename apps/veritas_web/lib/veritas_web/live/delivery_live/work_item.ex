defmodule Veritas.Web.DeliveryLive.WorkItem do
  @moduledoc """
  One Work Item: what it is, what it touches, and where it stands.

  A Work Item is the unit of delivery work: it belongs to a Milestone, it
  carries a state, and it links to the Configuration Items it touches and
  the Changes that implement it (`docs/04` §Navigation Model). It is edited
  here, under `delivery:write` — the role matrix decides — and the write
  lands in the Audit Log through `Veritas.Core.Delivery`.
  """
  use Veritas.Web, :live_view

  alias Veritas.Core.{CI, Delivery, Policy, Principal, Tickets}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Work Item",
       workspace: nil,
       id: nil,
       item: nil,
       milestone: nil,
       program: nil,
       states: Delivery.delivery_states(),
       links: %{ci: [], change: []},
       can_write: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The Workspace is the Principal's, not the URL's.
    workspace = socket.assigns[:principal_workspace]
    id = params["id"] || ""

    item = one(Delivery.get_work_item(workspace, id))
    milestone = milestone_of(workspace, item)
    program = program_of(workspace, milestone)

    {:noreply,
     socket
     |> assign(id: id, item: item, milestone: milestone, program: program)
     |> load_links()
     |> load_permission()}
  end

  @impl true
  def handle_event("update", params, socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "delivery:write", %{workspace: workspace}) do
      :allow ->
        attrs = %{
          "title" => params["title"],
          "description" => params["description"] || "",
          "state" => params["state"],
          "ci_refs" => split_refs(params["ci_refs"]),
          "change_refs" => split_refs(params["change_refs"]),
          "actor" => audit_actor(principal)
        }

        case Delivery.update_work_item(workspace, socket.assigns.id, attrs) do
          {:ok, _item} ->
            {:noreply, socket |> put_flash(:info, "Saved.") |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "The Work Item was refused: #{inspect(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-4xl px-6 py-10">
      <header class="mb-6 flex flex-wrap items-baseline justify-between gap-4">
        <div class="min-w-0">
          <h1 class="text-3xl font-semibold tracking-tight">
            {@item["title"] || "Work Item"}
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            <span class="font-mono">{@id}</span>
            <span :if={@program} class="ml-2">
              in <span class="font-mono">{@program["name"]}</span>
            </span>
          </p>
        </div>
        <a href={~p"/programs"} class="text-sm text-base-content/60 hover:underline">
          &larr; Delivery
        </a>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">What it touches</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          The Configuration Items and the Changes this Work Item links to.
        </p>
        <ul class="mt-3 space-y-1 text-[13px]">
          <li :for={ci <- @links.ci}>
            {ci["name"]} <span class="font-mono text-[11px] text-base-content/45">{ci["id"]}</span>
          </li>
          <li :for={change <- @links.change}>
            {change["title"]}
            <span class="font-mono text-[11px] text-base-content/45">{change["id"]}</span>
          </li>
          <li :if={@links.ci == [] and @links.change == []} class="text-base-content/60">
            Nothing linked yet.
          </li>
        </ul>
      </section>

      <section :if={@can_write} class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Edit</h2>

        <form id="work-item-edit" phx-submit="update" class="mt-3 flex flex-wrap items-end gap-3">
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">title</span>
            <input
              type="text"
              name="title"
              value={@item["title"]}
              required
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">state</span>
            <select name="state" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
              <option :for={state <- @states} value={state} selected={state == @item["state"]}>
                {state}
              </option>
            </select>
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">CI ids</span>
            <input
              type="text"
              name="ci_refs"
              value={Enum.join(@item["ci_refs"] || [], ", ")}
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">Change ids</span>
            <input
              type="text"
              name="change_refs"
              value={Enum.join(@item["change_refs"] || [], ", ")}
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
      </section>
    </main>
    """
  end

  defp one({:ok, row}), do: row
  defp one(_error), do: nil

  defp reload(socket) do
    workspace = socket.assigns[:principal_workspace]
    item = one(Delivery.get_work_item(workspace, socket.assigns.id))

    socket
    |> assign(item: item)
    |> load_links()
  end

  defp load_links(socket) do
    workspace = socket.assigns[:principal_workspace]
    item = socket.assigns[:item] || %{}

    cis =
      Enum.flat_map(item["ci_refs"] || [], fn ci_id ->
        case CI.get(workspace, ci_id) do
          {:ok, ci} when is_map(ci) -> [ci]
          _ -> []
        end
      end)

    changes =
      Enum.flat_map(item["change_refs"] || [], fn change_id ->
        case Tickets.read(workspace, change_id) do
          {:ok, change} when is_map(change) -> [change]
          _ -> []
        end
      end)

    assign(socket, links: %{ci: cis, change: changes})
  end

  defp load_permission(socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    assign(socket,
      can_write: Policy.permitted?(principal, "delivery:write", %{workspace: workspace})
    )
  end

  defp milestone_of(_workspace, nil), do: nil

  defp milestone_of(workspace, item) do
    case Delivery.get_milestone(workspace, item["milestone"] || "") do
      {:ok, milestone} -> milestone
      _ -> nil
    end
  end

  defp program_of(_workspace, nil), do: nil

  defp program_of(workspace, milestone) do
    case Delivery.get_program(workspace, milestone["program"] || "") do
      {:ok, program} -> program
      _ -> nil
    end
  end

  defp split_refs(nil), do: []

  defp split_refs(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_refs(value) when is_list(value), do: value

  defp audit_actor(nil), do: %{type: "user", id: "local"}
  defp audit_actor(principal), do: Principal.audit_actor(principal)
end
