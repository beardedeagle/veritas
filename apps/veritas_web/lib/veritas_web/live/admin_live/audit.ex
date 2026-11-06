defmodule Veritas.Web.AdminLive.Audit do
  @moduledoc """
  The Audit Log, and the chain it is.

  `docs/04` §Navigation Model gives Admin an "Audit Log" screen, and the reason
  the corpus wants one is a question: **whose decision was this?** The screen
  answers it from the running system — the entries of the Workspace, who acted,
  what was decided, and whether the chain those entries are in still verifies.

  The chain's **integrity** is on the same screen, because a list of events
  that is not a chain is a list of claims. `Veritas.Core.Audit.verify/1` is
  the check; the doctor reports it too, and here it is reported next to the
  entries it is about.

  ## The question being asked

  The filter is the question: *who did this*, or *what happened to this
  record*. It matches the actor, the subject, the table, the states and the
  reason — the things a person reading a chain would ask about.
  """
  use Veritas.Web, :live_view

  alias Veritas.Core.{Audit, Policy}

  @impl true
  def mount(_params, _session, socket) do
    # The Workspace is the Principal's, not the URL's.
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    {:ok,
     socket
     |> assign(
       page_title: "Audit Log",
       workspace: workspace,
       can_read: Policy.permitted?(principal, "audit:read", %{workspace: workspace}),
       query: "",
       entries: [],
       integrity: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> load()}
  end

  # The entries and the chain's own verdict, read together: a verdict about a
  # chain the screen is not showing would be a verdict about nothing.
  #
  # A role that may not read the Audit Log is shown nothing: the chain names
  # who did what, and that is not a thing every signed-in person may read.
  defp load(socket) do
    workspace = socket.assigns.workspace

    if socket.assigns.can_read do
      {:ok, entries} = Audit.entries(workspace)

      assign(socket,
        entries: filter(entries, socket.assigns.query),
        integrity: Audit.verify(workspace)
      )
    else
      assign(socket, entries: [], integrity: nil)
    end
  end

  defp filter(entries, query) do
    case String.trim(query) do
      "" ->
        entries

      needle ->
        needle = String.downcase(needle)

        Enum.filter(entries, fn entry ->
          entry
          |> searchable()
          |> String.downcase()
          |> String.contains?(needle)
        end)
    end
  end

  defp searchable(entry) do
    [
      entry["subject"],
      entry["subject_table"],
      entry["actor_id"],
      entry["actor_type"],
      entry["from_state"],
      entry["to_state"],
      entry["reason"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-6xl px-6 py-10">
      <header class="mb-8">
        <h1 class="text-3xl font-semibold tracking-tight">Audit Log</h1>
        <p class="mt-1 text-sm text-base-content/60">
          workspace <span class="font-mono">{@workspace}</span> — every decision this
          Workspace made, and the chain those decisions are in.
        </p>
      </header>

      <section :if={@can_read} class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">The chain</h2>
        <p class={integrity_class(@integrity)}>{integrity_text(@integrity)}</p>
      </section>

      <section :if={@can_read} class="v-panel mb-6 px-3 py-3">
        <form phx-submit="filter" class="flex flex-wrap items-end gap-3">
          <label class="min-w-0 flex-1 text-sm text-base-content/75">
            <span class="block text-xs uppercase tracking-wide text-base-content/70">question</span>
            <input
              type="text"
              name="query"
              value={@query}
              placeholder="Who did this, or what happened to this record?"
              class="mt-1 w-full rounded border border-base-300 px-2 py-1 text-sm"
            />
          </label>
          <button
            type="submit"
            class="rounded border border-base-300 px-3 py-1 text-sm font-medium hover:bg-base-200"
          >
            Show
          </button>
        </form>
      </section>

      <section :if={@can_read} class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">
          Entries <span class="text-base-content/50">({length(@entries)})</span>
        </h2>

        <table class="mt-3 w-full text-left text-sm">
          <thead class="text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="py-1 pr-3 font-medium">#</th>
              <th class="py-1 pr-3 font-medium">when</th>
              <th class="py-1 pr-3 font-medium">actor</th>
              <th class="py-1 pr-3 font-medium">record</th>
              <th class="py-1 pr-3 font-medium">what changed</th>
              <th class="py-1 font-medium">why</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries} class="border-t border-base-200 align-top">
              <td class="py-1 pr-3 font-mono text-xs text-base-content/60">{entry["sequence"]}</td>
              <td class="py-1 pr-3 text-xs text-base-content/70">{timestamp(entry)}</td>
              <td class="py-1 pr-3 font-mono text-xs">{entry["actor_id"]}</td>
              <td class="py-1 pr-3 text-xs">
                <span class="text-base-content/60">{entry["subject_table"]}</span>
                <span class="font-mono">{entry["subject"]}</span>
              </td>
              <td class="py-1 pr-3 text-xs">{change(entry)}</td>
              <td class="py-1 text-xs text-base-content/70">{entry["reason"]}</td>
            </tr>
          </tbody>
        </table>

        <p :if={@entries == []} class="mt-3 text-sm text-base-content/60">
          No entry matches that question.
        </p>
      </section>
      <section :if={!@can_read} class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">The Audit Log</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Your role may not read the Audit Log. The chain names who did what, and
          that is not a thing every signed-in person may read.
        </p>
      </section>
    </main>
    """
  end

  defp integrity_text({:ok, :intact}),
    do: "The chain verifies: every entry is signed and linked to the one before it."

  defp integrity_text({:ok, {:broken_at, index}}),
    do:
      "The chain is broken at entry #{index}. The entries above and below that point cannot both be trusted."

  defp integrity_text({:ok, {:error, reason}}),
    do: "The chain could not be verified: #{inspect(reason)}."

  defp integrity_text({:error, reason}),
    do: "The chain could not be read: #{inspect(reason)}."

  defp integrity_text(_other), do: "The chain could not be verified."

  defp integrity_class({:ok, :intact}), do: "mt-1 text-sm text-base-content/70"
  defp integrity_class(_other), do: "mt-1 text-sm text-error"

  defp timestamp(entry) do
    case entry["timestamp"] do
      nil -> ""
      value -> to_string(value)
    end
  end

  # What changed, in the words the chain uses.
  defp change(entry) do
    case {entry["from_state"], entry["to_state"]} do
      {nil, nil} -> "—"
      {nil, to_state} -> to_string(to_state)
      {from_state, nil} -> "#{from_state} → —"
      {from_state, to_state} -> "#{from_state} → #{to_state}"
    end
  end
end
