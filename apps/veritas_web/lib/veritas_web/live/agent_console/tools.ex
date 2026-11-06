defmodule Veritas.Web.AgentConsole.Tools do
  @moduledoc """
  The tool catalogue — what the agent can reach.

  This screen needs **no provider**: it shows the product's own
  capabilities, their scopes and whether a call needs a human's approval
  (`docs/39` §2.2). It is the honest answer to "what can this thing do",
  and it is true before any provider is configured.

  ## What is shown is the registry

  The list comes from `Veritas.Agentic.Tool.Registry`, so a tool a Plugin
  contributes appears here beside the core ones, with where it came from.
  """
  use Veritas.Web, :live_view

  alias Veritas.Agentic.Tool

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, page_title: "Agent tools", tools: tools(), sources: Tool.Registry.sources())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-6">
        <h1 class="text-3xl font-semibold tracking-tight">Agent tools</h1>
        <p class="mt-1 text-sm text-base-content/60">
          What an agent may reach in this Workspace. A read tool asks for
          nothing; a write tool needs a human's approval.
        </p>
      </header>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={tool <- @tools} class="py-4">
          <div class="flex items-baseline justify-between gap-6">
            <div class="min-w-0">
              <p class="font-mono text-sm font-medium">{tool.name}</p>
              <p class="mt-1 text-[13px] text-base-content/70">{tool.description}</p>
              <p class="mt-1 text-[11px] text-base-content/50">
                scope {Enum.join(tool.scope, ", ")}
                <span :if={source_label(@sources, tool)} class="ml-2">
                  {source_label(@sources, tool)}
                </span>
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <span class="rounded border border-base-300 px-1.5 py-px text-[10px] uppercase tracking-wide text-base-content/60">
                {tool.side_effect}
              </span>
              <span
                :if={tool.approval == :always}
                class="rounded border border-base-content/30 px-1.5 py-px text-[10px] uppercase tracking-wide text-base-content/60"
              >
                needs approval
              </span>
            </div>
          </div>
        </li>
      </ul>

      <p :if={@tools == []} class="py-10 text-center text-base-content/60">
        No tools are registered.
      </p>
    </main>
    """
  end

  defp tools do
    Tool.Registry.all()
  end

  defp source_label(sources, tool) do
    case Map.get(sources, tool.name) do
      :core -> nil
      {:plugin, plugin_id} -> "from the plugin #{plugin_id}"
      {:mcp, server} -> "from the MCP server #{server}"
      _ -> nil
    end
  end
end
