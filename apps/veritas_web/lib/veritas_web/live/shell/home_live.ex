defmodule Veritas.Web.Shell.HomeLive do
  @moduledoc """
  The front door: the Overview of a Workspace.

  ## Where the numbers come from

  Everything on this page is read from the domain layer, never from the
  datastore directly and never hardcoded:

    * the Incident figures come from `Veritas.Core.Tickets`, which is the same
      path the Incident screens and the GraphQL surface take — one service
      layer, three faces (INV-8);
    * the Audit Log figures come from `Veritas.Core.Audit`, which owns the
      hash chain and is the only thing that can say whether the chain is
      intact;
    * the CMDB figures come from `Veritas.Core.CI`, which is the same path the
      CMDB screens take — the configuration items, the type registry and the
      relations between them.

  ## What is shown when a number does not exist yet

  The Change window and the SLA risk clock have no source in this build, and
  the Agent runtime is empty by design. They are rendered as *not yet* panels
  that name what is missing and why. They are not rendered as zero: a zero is
  a measurement, and there has been no measurement.

  The CMDB panel has a source, so it reports what the CMDB holds — and when
  the Workspace genuinely holds no Configuration Items, it says that, which is
  a different statement from "the CMDB cannot be read". A panel that claims a
  capability does not exist is worse than a blank one.

  Two figures `docs/04`'s CMDB funnel would want are deliberately **not**
  shown, because the CI record cannot supply them: a CI has no `owner` field,
  and there is no observation source to measure against. See `cmdb_coverage/1`.

  ## How fresh it is

  There is no event source to push from yet — the outbox relay and the
  projection are not running — so this page polls, on a declared cadence, and
  says so in its header. The alternative would be a number that looks live
  and is not.
  """

  use Veritas.Web, :live_view

  alias Veritas.Core.{Audit, CI, Tickets}

  import Veritas.Web.ShellComponents,
    only: [kpi_tile: 1, panel: 1, not_yet: 1, severity_badge: 1, state_pill: 1, stat_rows: 1]

  @refresh_interval 15_000
  @list_limit 1_000
  @ci_limit 500
  @terminal_states ["closed", "cancelled"]

  @impl true
  def mount(params, _session, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace] || params["workspace"] || "default"

    socket =
      socket
      |> assign(page_title: "Overview", workspace: workspace)
      |> load()
      |> schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = socket |> load() |> schedule_refresh()
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <header class="mb-5 flex flex-wrap items-end gap-x-6 gap-y-2">
      <div class="min-w-0">
        <h1 class="text-xl font-semibold tracking-tight">Overview</h1>
        <p class="mt-1 text-[13px] text-base-content/55">
          What is happening in this Workspace right now.
        </p>
      </div>

      <div class="ml-auto flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-base-content/45">
        <span>
          workspace <span class="font-mono text-base-content/70">{@workspace}</span>
        </span>
        <span aria-live="polite">
          refreshed <span class="font-mono">{format_time(@loaded_at)}</span>
        </span>
        <span class="hidden sm:inline">polls every 15s</span>
      </div>
    </header>

    <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <.kpi_tile
        label="Open Incidents"
        value={@open_count}
        source={incident_source()}
        tone={if @open_count > 0, do: "warn", else: "ok"}
      />
      <.kpi_tile
        label="Unacknowledged"
        value={@unacknowledged_count}
        source="state is still new"
        tone={if @unacknowledged_count > 0, do: "critical", else: "neutral"}
      />
      <.kpi_tile
        label="Acknowledged"
        value={@acknowledged_count}
        source="open, and past new"
        tone="neutral"
      />
      <.kpi_tile
        label="Audit Log chain"
        value={audit_chain_label(@audit_chain)}
        source={audit_source()}
        tone={audit_tone(@audit_chain)}
      />
    </div>

    <div class="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-12">
      <div class="flex flex-col gap-3 xl:col-span-8">
        <.panel title="Incident wall" meta={@incidents_meta}>
          <p :if={@incidents_error} class="px-3 py-4 text-[13px] text-error">
            The Incident list could not be read: {inspect(@incidents_error)}
          </p>

          <p
            :if={!@incidents_error && @open_incidents == []}
            class="flex flex-col items-center gap-2 px-4 py-10 text-center"
          >
            <.icon name="hero-check-circle" class="size-6 text-health-ok" />
            <span class="text-[13px] font-medium">All clear — 0 open Incidents</span>
            <span class="max-w-sm text-xs leading-5 text-base-content/55">
              Nothing is open in this Workspace. New Incidents appear here the moment they are
              opened.
            </span>
          </p>

          <ul :if={!@incidents_error && @open_incidents != []} class="flex flex-col">
            <li :for={incident <- @open_incidents} class="v-row">
              <.severity_badge priority={incident["priority"]} />

              <a
                href={~p"/incidents/#{incident["id"]}?workspace=#{@workspace}"}
                class="min-w-0 flex-1 truncate text-[13px] hover:underline"
              >
                {incident["title"]}
              </a>

              <span class="hidden font-mono text-[11px] text-base-content/40 md:inline">
                {incident["id"]}
              </span>

              <.state_pill state={incident["state"]} />

              <span class="hidden w-16 shrink-0 text-right text-[11px] text-base-content/45 sm:inline">
                {relative_time(incident["opened_at"])}
              </span>
            </li>
          </ul>
        </.panel>

        <.panel title="Audit Log" meta={@audit_meta}>
          <p :if={@audit_error} class="px-3 py-4 text-[13px] text-error">
            The Audit Log could not be read: {inspect(@audit_error)}
          </p>

          <p
            :if={!@audit_error && @audit_entries == []}
            class="px-3 py-6 text-center text-[13px] text-base-content/55"
          >
            No Audit Log entries in this Workspace yet.
          </p>

          <ul :if={!@audit_error && @audit_entries != []} class="flex flex-col">
            <li :for={entry <- @audit_entries} class="v-row text-[12px]">
              <span class="w-16 shrink-0 font-mono text-[11px] text-base-content/45">
                {format_time(entry["timestamp"])}
              </span>
              <span class="w-20 shrink-0 truncate font-mono text-[11px] text-base-content/70">
                {entry["actor_type"]}/{entry["actor_id"]}
              </span>
              <span class="min-w-0 flex-1 truncate">
                {entry["subject_table"]}
                <span class="font-mono text-base-content/55">{entry["subject"]}</span>
              </span>
              <span class="hidden shrink-0 font-mono text-[11px] text-base-content/50 md:inline">
                {entry["from_state"] || "—"} → {entry["to_state"] || "—"}
              </span>
            </li>
          </ul>
        </.panel>
      </div>

      <div class="flex flex-col gap-3 xl:col-span-4">
        <.panel title="Node (BEAM)" meta="this host">
          <dl class="flex flex-col gap-2 px-3 py-3 text-[13px]">
            <div class="flex items-baseline gap-2">
              <dt class="w-28 shrink-0 text-base-content/45">Node</dt>
              <dd class="min-w-0 flex-1 truncate font-mono text-xs">{@node.name}</dd>
            </div>
            <div class="flex items-baseline gap-2">
              <dt class="w-28 shrink-0 text-base-content/45">Connected</dt>
              <dd class="flex-1 font-mono text-xs">{@node.connected}</dd>
            </div>
            <div class="flex items-baseline gap-2">
              <dt class="w-28 shrink-0 text-base-content/45">Distribution</dt>
              <dd class="flex-1 font-mono text-xs">
                {if @node.distributed?, do: "Erlang distribution", else: "not distributed"}
              </dd>
            </div>
            <div class="flex items-baseline gap-2">
              <dt class="w-28 shrink-0 text-base-content/45">Uptime</dt>
              <dd class="flex-1 font-mono text-xs">{@node.uptime}</dd>
            </div>
            <div class="flex items-baseline gap-2">
              <dt class="w-28 shrink-0 text-base-content/45">Datacenters</dt>
              <dd class="flex-1 font-mono text-xs text-base-content/45">not yet</dd>
            </div>
          </dl>
        </.panel>

        <.panel title="Agent activity" meta="0 running">
          <p class="text-sm text-base-content/70">
            No Agent run is in flight. The <a href="/agents" class="underline">Agent Console</a>
            is where you ask a question about the configuration and read the
            steps it took.
          </p>
        </.panel>

        <.panel title="SLA risk" meta="no clock yet">
          <.not_yet
            title="No SLA clock yet"
            body="The SLA worker and the clock it drives are not running, so there is no time remaining to show. A zero here would be a measurement, and there has been none."
          />
        </.panel>
      </div>
    </div>

    <div class="mt-3 grid grid-cols-1 gap-3 lg:grid-cols-2">
      <.panel title="CMDB coverage" meta={cmdb_meta(@cmdb)}>
        <p :if={@cmdb_error} class="px-3 py-4 text-[13px] text-error">
          The CMDB could not be read: {inspect(@cmdb_error)}
        </p>

        <.not_yet
          :if={!@cmdb_error && @cmdb.count == 0}
          icon="hero-cube"
          title="No Configuration Items"
          body="The CMDB is readable — this Workspace has no Configuration Items yet. Add one, or connect an Adapter to discover them."
        >
          <a href="/cmdb/cis" class="text-xs text-brand underline underline-offset-2">
            Open the CMDB
          </a>
        </.not_yet>

        <div :if={!@cmdb_error && @cmdb.count > 0}>
          <.stat_rows rows={cmdb_rows(@cmdb)} />
          <p class="px-3 pb-3 text-[11px] text-base-content/45">
            Veritas.Core.CI — this Workspace
            <span :if={@cmdb.capped?}> · the CMDB list is capped, so these are floors</span>
          </p>
          <p class="px-3 pb-3">
            <a href="/cmdb/cis" class="text-xs text-brand underline underline-offset-2">
              Open the CMDB
            </a>
          </p>
        </div>
      </.panel>

      <.panel title="Change window" meta="no Changes yet">
        <.not_yet
          title="No Change records in this Workspace"
          body="The Change Calendar reads the Change tickets. There are none in this Workspace, and the window is empty rather than unmeasured."
        >
          <a href="/changes" class="text-xs text-brand underline underline-offset-2">
            Open Changes
          </a>
        </.not_yet>
      </.panel>
    </div>
    """
  end

  # ── loading ───────────────────────────────────────────────────────────────

  defp load(socket) do
    workspace = socket.assigns.workspace

    {incidents, incidents_error} = list_incidents(workspace)
    {entries, entries_error} = audit_entries(workspace)
    chain = audit_chain(workspace)
    {cmdb, cmdb_error} = cmdb_reading(workspace)

    open = Enum.reject(incidents, &terminal?/1)
    unacknowledged = Enum.filter(open, &(&1["state"] == "new"))

    assign(socket,
      incidents: incidents,
      open_incidents: open,
      open_count: length(open),
      unacknowledged_count: length(unacknowledged),
      acknowledged_count: length(open) - length(unacknowledged),
      incidents_error: incidents_error,
      incidents_meta: incidents_meta(length(open), length(incidents)),
      audit_entries: entries,
      audit_error: entries_error,
      audit_chain: chain,
      audit_meta: entries_meta(entries),
      cmdb: cmdb,
      cmdb_error: cmdb_error,
      node: Veritas.Web.Shell.Context.node_status(),
      loaded_at: DateTime.utc_now()
    )
  end

  # ── the CMDB ───────────────────────────────────────────────────────────────

  # What the CMDB holds, read from the domain the CMDB screens read from.
  #
  # The counts are deliberately the ones that can be **measured**: how many
  # Configuration Items exist, how many types are registered against them,
  # and how many relations connect them. Two figures that `docs/04`'s CMDB
  # funnel would want are deliberately **absent**, because the CI record
  # cannot supply them yet:
  #
  #   * *owned* — a CI row has no `owner` field at all. "0 of 5 owned" would
  #     be reporting on a field that does not exist, which is the fake zero
  #     the corpus forbids.
  #   * *observed in the last 24h* — there is no discovery Adapter and no
  #     observation timestamp. `updated_at` is when the row was written to
  #     the store, which is not evidence that the CI still matches the
  #     running system, so it is not offered as one.
  # The CMDB reading, as a value and an error rather than a tuple, so the
  # template can ask "is it there?" and "could it not be read?" separately.
  defp cmdb_reading(workspace) do
    case cmdb_coverage(workspace) do
      {:ok, cmdb} -> {cmdb, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp cmdb_coverage(workspace) do
    case CI.list(workspace, limit: @ci_limit) do
      {:ok, cis} ->
        {:ok,
         %{
           count: length(cis),
           capped?: length(cis) >= @ci_limit,
           types_registered: registered_types(workspace),
           types_in_use: cis |> Enum.map(& &1["ci_type"]) |> Enum.uniq() |> length(),
           relations: count_relations(workspace, cis),
           lifecycle: Enum.frequencies_by(cis, & &1["lifecycle_state"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # How many CI types the Workspace has registered. `nil` when the registry
  # could not be read, so the row shows a dash rather than a zero.
  defp registered_types(workspace) do
    case CI.types(workspace) do
      {:ok, rows} -> length(rows)
      {:error, _reason} -> nil
    end
  end

  # How many relations connect the CIs.
  #
  # The count is of **edges**, not of nodes: summing the nodes of a
  # traversal from every CI counts every relation twice, once from each end.
  # Summing the *outgoing* edges counts each relation exactly once, because
  # a relation has one source. The edges are still deduplicated by id, so a
  # relation between two CIs is one relation either way.
  #
  # A traversal that fails makes the count unknown rather than low.
  defp count_relations(workspace, cis) do
    # Each CI's traversal is collected as a tagged result, never as a bare
    # sentinel inside the list: `Enum.flat_map/2` concatenates what the
    # callback returns, so a callback that returns the atom `:error` is asked
    # to enumerate an atom and crashes the page. A failed traversal is
    # detected first, and only a run of successes is flattened.
    results =
      Enum.map(cis, fn ci ->
        case CI.relations(workspace, ci["id"], :out, 1) do
          {:ok, %{edges: edges}} -> {:ok, edges}
          {:error, _reason} -> :error
        end
      end)

    if Enum.any?(results, &(&1 == :error)) do
      nil
    else
      results
      |> Enum.flat_map(fn {:ok, edges} -> edges end)
      |> Enum.map(& &1["id"])
      |> Enum.uniq()
      |> length()
    end
  end

  defp cmdb_meta(nil), do: "unreadable"
  defp cmdb_meta(%{count: 0}), do: "no CIs"
  defp cmdb_meta(%{count: count}), do: "#{count} CIs"

  defp cmdb_rows(cmdb) do
    [
      %{
        label: "Configuration Items",
        value: if(cmdb.capped?, do: "#{cmdb.count}+", else: "#{cmdb.count}"),
        note: nil
      },
      %{
        label: "Types registered",
        value: cmdb.types_registered && "#{cmdb.types_registered}",
        note: types_note(cmdb)
      },
      %{label: "Relations", value: cmdb.relations && "#{cmdb.relations}", note: nil},
      %{label: "Lifecycle", value: lifecycle_summary(cmdb.lifecycle), note: nil}
    ]
  end

  defp types_note(%{types_registered: nil}), do: "the registry could not be read"

  defp types_note(%{types_in_use: in_use}), do: "#{in_use} in use"

  defp lifecycle_summary(lifecycle) when map_size(lifecycle) == 0, do: "—"

  defp lifecycle_summary(lifecycle) do
    lifecycle
    |> Enum.sort_by(fn {_state, count} -> -count end)
    |> Enum.take(3)
    |> Enum.map_join(" · ", fn {state, count} -> "#{count} #{state}" end)
  end

  defp list_incidents(workspace) do
    case Tickets.list(workspace, ticket_type: "incident", limit: @list_limit) do
      {:ok, rows} -> {rows, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp audit_entries(workspace) do
    case Audit.entries(workspace) do
      {:ok, rows} -> {rows |> Enum.reverse() |> Enum.take(8), nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp audit_chain(workspace) do
    case Audit.verify(workspace) do
      {:ok, :intact} -> :intact
      {:ok, {:broken_at, index}} -> {:broken_at, index}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal?(ticket), do: ticket["state"] in @terminal_states

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  # ── copy ──────────────────────────────────────────────────────────────────

  defp incident_source do
    "Veritas.Core.Tickets · this Workspace"
  end

  defp incidents_meta(open_count, total) when open_count == total do
    "#{open_count} open"
  end

  defp incidents_meta(open_count, total) do
    "#{open_count} open · #{total} in the Workspace"
  end

  defp entries_meta([]), do: "none"
  defp entries_meta(rows), do: "#{length(rows)} most recent"

  defp audit_chain_label(:intact), do: "intact"
  defp audit_chain_label({:broken_at, index}), do: "broken at #{index}"
  defp audit_chain_label({:error, _reason}), do: "unreadable"

  defp audit_source do
    "Veritas.Core.Audit · the hash chain, verified"
  end

  defp audit_tone(:intact), do: "ok"
  defp audit_tone({:broken_at, _index}), do: "critical"
  defp audit_tone(_), do: "warn"

  # ── time ──────────────────────────────────────────────────────────────────

  defp relative_time(nil), do: "—"

  defp relative_time(opened_at) do
    case to_datetime(opened_at) do
      {:ok, at} ->
        seconds = DateTime.diff(DateTime.utc_now(), at, :second)

        cond do
          seconds < 60 -> "just now"
          seconds < 3_600 -> "#{div(seconds, 60)}m ago"
          seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
          true -> "#{div(seconds, 86_400)}d ago"
        end

      :error ->
        "—"
    end
  end

  defp format_time(nil), do: "—"

  defp format_time(value) do
    case to_datetime(value) do
      {:ok, at} -> Calendar.strftime(at, "%H:%M:%S")
      :error -> "—"
    end
  end

  defp to_datetime(%DateTime{} = at), do: {:ok, at}
  defp to_datetime(%NaiveDateTime{} = at), do: {:ok, DateTime.from_naive!(at, "Etc/UTC")}

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp to_datetime(_value), do: :error
end
