defmodule Veritas.Web.DeliveryLive.Show do
  @moduledoc """
  One Program: its Milestones, and the Work Items under them.

  `docs/04` §Screens gives this screen one action — *"Update milestone"* —
  and says the burn-up is planned against actual. So the page carries the
  Program's Milestones with their planned and actual dates, the Work Items
  under each, and the links those items hold to the Configuration Items and
  the Changes they touch.

  ## Every write is a policy decision and an audit entry

  Adding a Milestone, adding a Work Item and moving a Milestone are all
  `delivery:write` — the role matrix decides — and each goes through
  `Veritas.Core.Delivery`, which writes the row and the Audit Log entry in
  one transaction.
  """
  use Veritas.Web, :live_view

  alias Veritas.Core.{CI, Delivery, Policy, Principal, Tickets}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Program",
       workspace: nil,
       id: nil,
       program: nil,
       milestones: [],
       work_items: [],
       links: %{ci: [], change: []},
       states: Delivery.delivery_states(),
       can_write: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The Workspace is the Principal's, not the URL's.
    workspace = socket.assigns[:principal_workspace]
    id = params["id"] || ""

    program = one(Delivery.get_program(workspace, id))
    milestones = rows(Delivery.list_milestones(workspace, id))

    work_items =
      Enum.flat_map(milestones, fn milestone ->
        rows(Delivery.list_work_items(workspace, milestone["id"]))
      end)

    {:noreply,
     socket
     |> assign(id: id, program: program, milestones: milestones, work_items: work_items)
     |> load_links()
     |> load_permission()}
  end

  @impl true
  def handle_event("add_milestone", params, socket) do
    workspace = socket.assigns[:principal_workspace]

    with :ok <- authorized(socket),
         {:ok, _milestone} <-
           Delivery.create_milestone(workspace, socket.assigns.id, %{
             "name" => params["name"],
             "planned_date" => params["planned_date"],
             "status" => params["status"] || "planned",
             "actor" => audit_actor(socket.assigns[:principal])
           }) do
      {:noreply, socket |> put_flash(:info, "The Milestone was added.") |> reload()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The Milestone was refused: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("update_milestone", params, socket) do
    workspace = socket.assigns[:principal_workspace]

    with :ok <- authorized(socket),
         {:ok, _milestone} <-
           Delivery.update_milestone(workspace, params["milestone_id"], %{
             "status" => params["status"],
             "actual_date" => params["actual_date"],
             "actor" => audit_actor(socket.assigns[:principal])
           }) do
      {:noreply, socket |> put_flash(:info, "The Milestone was saved.") |> reload()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The Milestone was refused: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("add_work_item", params, socket) do
    workspace = socket.assigns[:principal_workspace]

    with :ok <- authorized(socket),
         {:ok, _item} <-
           Delivery.create_work_item(workspace, params["milestone_id"], %{
             "title" => params["title"],
             "description" => params["description"] || "",
             "state" => params["state"] || "planned",
             "ci_refs" => split_refs(params["ci_refs"]),
             "change_refs" => split_refs(params["change_refs"]),
             "actor" => audit_actor(socket.assigns[:principal])
           }) do
      {:noreply, socket |> put_flash(:info, "The Work Item was added.") |> reload()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The Work Item was refused: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6 flex flex-wrap items-baseline justify-between gap-4">
        <div>
          <h1 class="text-3xl font-semibold tracking-tight">{@program["name"] || "Program"}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            <span class="font-mono">{@id}</span>
            <span class="ml-2 rounded border border-base-300 px-1.5 py-px text-[10px] uppercase tracking-wide text-base-content/60">
              {@program["status"]}
            </span>
          </p>
        </div>
        <a href={~p"/programs"} class="text-sm text-base-content/60 hover:underline">
          &larr; Delivery
        </a>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Milestones</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          Planned against actual, which is what the burn-up reads.
        </p>

        <ul :if={@milestones != []} class="mt-3 divide-y divide-base-300/60">
          <li :for={milestone <- @milestones} class="py-3">
            <div class="flex flex-wrap items-baseline justify-between gap-4">
              <div>
                <p class="font-medium">{milestone["name"]}</p>
                <p class="mt-1 text-[12px] text-base-content/60">
                  {milestone["status"]}
                  <span :if={milestone["planned_date"]} class="ml-2">
                    planned {milestone["planned_date"]}
                  </span>
                  <span :if={milestone["actual_date"]} class="ml-2">
                    actual {milestone["actual_date"]}
                  </span>
                </p>
              </div>
            </div>

            <ul class="mt-2 space-y-1">
              <li :for={item <- items_of(@work_items, milestone["id"])} class="text-[13px]">
                <a href={~p"/work-items/#{item["id"]}"} class="hover:underline">
                  {item["title"]}
                </a>
                <span class="ml-2 text-[11px] text-base-content/55">{item["state"]}</span>
              </li>
            </ul>

            <form
              :if={@can_write}
              phx-submit="update_milestone"
              class="mt-3 flex flex-wrap items-end gap-3"
            >
              <input type="hidden" name="milestone_id" value={milestone["id"]} />
              <label class="text-sm text-base-content/75">
                <span class="block text-xs uppercase tracking-wide text-base-content/70">status</span>
                <select name="status" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
                  <option
                    :for={state <- @states}
                    value={state}
                    selected={state == milestone["status"]}
                  >
                    {state}
                  </option>
                </select>
              </label>
              <label class="text-sm text-base-content/75">
                <span class="block text-xs uppercase tracking-wide text-base-content/70">actual</span>
                <input
                  type="text"
                  name="actual_date"
                  value={milestone["actual_date"]}
                  class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
                />
              </label>
              <button
                type="submit"
                class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
              >
                save milestone
              </button>
            </form>
          </li>
        </ul>

        <p :if={@milestones == []} class="mt-3 text-sm text-base-content/60">
          No Milestones yet. A Milestone is a dated point the Program is
          moving towards.
        </p>

        <form
          :if={@can_write}
          id="milestone-create"
          phx-submit="add_milestone"
          class="mt-4 flex flex-wrap items-end gap-3"
        >
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">milestone</span>
            <input
              type="text"
              name="name"
              required
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">planned</span>
            <input
              type="text"
              name="planned_date"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>
          <button
            type="submit"
            class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
          >
            add milestone
          </button>
        </form>
      </section>

      <section :if={@can_write and @milestones != []} class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Add a Work Item</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          A Work Item is linked to the Configuration Items it touches and the
          Changes that implement it.
        </p>

        <form
          id="work-item-create"
          phx-submit="add_work_item"
          class="mt-3 flex flex-wrap items-end gap-3"
        >
          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">milestone</span>
            <select name="milestone_id" class="mt-1 rounded border border-base-300 px-2 py-1 text-sm">
              <option :for={milestone <- @milestones} value={milestone["id"]}>
                {milestone["name"]}
              </option>
            </select>
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">title</span>
            <input
              type="text"
              name="title"
              required
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">CI ids</span>
            <input
              type="text"
              name="ci_refs"
              placeholder="comma separated"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <label class="text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">Change ids</span>
            <input
              type="text"
              name="change_refs"
              placeholder="comma separated"
              class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>

          <button
            type="submit"
            class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
          >
            add work item
          </button>
        </form>
      </section>

      <section :if={@links.ci != [] or @links.change != []} class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">What this Program touches</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          The Configuration Items and the Changes its Work Items link to.
        </p>
        <ul class="mt-3 space-y-1 text-[13px]">
          <li :for={ci <- @links.ci}>
            {ci["name"]} <span class="font-mono text-[11px] text-base-content/45">{ci["id"]}</span>
          </li>
          <li :for={change <- @links.change}>
            {change["title"]}
            <span class="font-mono text-[11px] text-base-content/45">{change["id"]}</span>
          </li>
        </ul>
      </section>
    </main>
    """
  end

  # The domain answers with a tuple; the screen wants the rows.
  defp rows({:ok, rows}), do: rows
  defp rows(_error), do: []

  defp one({:ok, row}), do: row
  defp one(_error), do: nil

  defp reload(socket) do
    workspace = socket.assigns[:principal_workspace]
    id = socket.assigns.id

    milestones = rows(Delivery.list_milestones(workspace, id))

    work_items =
      Enum.flat_map(milestones, fn milestone ->
        rows(Delivery.list_work_items(workspace, milestone["id"]))
      end)

    socket
    |> assign(milestones: milestones, work_items: work_items)
    |> load_links()
  end

  # The links the Work Items hold, resolved through the domain — the same
  # reads a person gets.
  defp load_links(socket) do
    workspace = socket.assigns[:principal_workspace]

    ci_refs =
      socket.assigns[:work_items]
      |> Enum.flat_map(&(&1["ci_refs"] || []))
      |> Enum.uniq()

    change_refs =
      socket.assigns[:work_items]
      |> Enum.flat_map(&(&1["change_refs"] || []))
      |> Enum.uniq()

    cis =
      Enum.flat_map(ci_refs, fn ci_id ->
        case CI.get(workspace, ci_id) do
          {:ok, ci} when is_map(ci) -> [ci]
          _ -> []
        end
      end)

    changes =
      Enum.flat_map(change_refs, fn change_id ->
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

  defp authorized(socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "delivery:write", %{workspace: workspace}) do
      :allow -> :ok
      {:deny, reason} -> {:error, reason}
    end
  end

  defp items_of(items, milestone_id) do
    Enum.filter(items, &(&1["milestone"] == milestone_id))
  end

  defp split_refs(nil), do: []

  defp split_refs(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp audit_actor(nil), do: %{type: "user", id: "local"}
  defp audit_actor(principal), do: Principal.audit_actor(principal)
end
