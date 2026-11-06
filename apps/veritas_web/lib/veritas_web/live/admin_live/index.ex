defmodule Veritas.Web.AdminLive.Index do
  @moduledoc """
  Admin: what this section holds.

  `docs/04` §Navigation Model gives Admin six panels: Audit Log, Plugins &
  Capabilities, Users & roles, Workspaces, Settings and the Agent Console. The
  build had three of them live and the rail pointed at a placeholder — which
  is the same disease as a screen that explains a mechanism this build does
  not have: **the surface says something untrue.**

  So this page says what is true. A panel that exists is a **link**. A panel
  that does not exist is **one plain line** naming what it will hold: an
  honest gap beats an empty table pretending to be a panel.
  """
  use Veritas.Web, :live_view

  alias Veritas.Core.Policy
  alias Veritas.Plugin
  alias Veritas.Plugin.{Capability, Manifest}
  alias Veritas.Store.Error

  @manifest_limit 65_536

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns[:principal_workspace]

    {:ok,
     socket
     |> assign(
       page_title: "Admin",
       workspace: workspace,
       panels: panels(),
       manifest_form: to_form(%{"json" => ""}, as: :manifest),
       manifest_preview: nil,
       manifest_error: nil,
       manifest_limit: @manifest_limit,
       plugin_capabilities: Capability.vocabulary(),
       host_api_version: Manifest.host_api_version()
     )
     |> load_plugins()}
  end

  @impl true
  def handle_event("refresh_plugins", _params, socket), do: {:noreply, load_plugins(socket)}

  def handle_event("inspect_manifest", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    result =
      with :allow <- Policy.authorize(principal, "plugin:read", %{workspace: workspace}),
           {:ok, manifest} <- decode_manifest(params),
           {:ok, manifest} <- Plugin.validate_manifest(workspace, manifest, principal) do
        {:ok, manifest}
      else
        {:deny, _reason} -> {:error, "Your roles may not inspect plugins in this Workspace."}
        {:error, reason} -> {:error, Error.message(reason)}
      end

    socket = assign(socket, manifest_preview: nil, manifest_error: nil)

    case result do
      {:ok, manifest} -> {:noreply, assign(socket, manifest_preview: manifest)}
      {:error, reason} -> {:noreply, assign(socket, manifest_error: reason)}
    end
  end

  defp decode_manifest(%{"manifest" => %{"json" => json}}) when is_binary(json) do
    if byte_size(json) <= @manifest_limit do
      case Jason.decode(json) do
        {:ok, manifest} -> {:ok, manifest}
        {:error, _reason} -> {:error, "Enter a valid JSON manifest."}
      end
    else
      {:error, "A manifest must be no larger than 64 KiB."}
    end
  end

  defp decode_manifest(_params), do: {:error, "Enter a valid JSON manifest."}

  # The six panels the corpus names, and what is true of each.
  #
  # `:link` — the panel has a screen of its own, and it is a link.
  # `:here` — the panel has no screen of its own yet, and this page shows what
  #           it holds.
  # `:planned` — the panel has neither, and it says so in one plain line.
  defp panels do
    [
      %{
        id: :workflows,
        label: "Workflows",
        path: "/workflows",
        state: :link,
        holds:
          "editable ticket intake, processing, AI steps, human approvals and after-action follow-up"
      },
      %{
        id: :audit_log,
        label: "Audit Log",
        path: "/audit",
        state: :link,
        holds: "every decision this Workspace made, and the chain those decisions are in"
      },
      %{
        id: :plugins,
        label: "Plugins & Capabilities",
        path: nil,
        state: :here,
        holds: "the plugins this host has installed, and the capabilities they were granted"
      },
      %{
        id: :users,
        label: "Users & roles",
        path: "/admin/people",
        state: :link,
        holds:
          "the people who may act here — the company's directory and Veritas's own accounts — and the grants over them"
      },
      %{
        id: :workspaces,
        label: "Workspaces",
        path: nil,
        state: :planned,
        holds: "the Workspaces this host has, and who administers each"
      },
      %{
        id: :settings,
        label: "Settings",
        path: nil,
        state: :planned,
        holds:
          "this deployment's configuration: the profile in force, the datastore, the chain key"
      },
      %{
        id: :agent_console,
        label: "Agent Console",
        path: "/agents",
        state: :link,
        holds: "the agent's runs, the tools it may call and the providers it calls them with"
      }
    ]
  end

  defp load_plugins(socket) do
    case Plugin.list(socket.assigns.workspace, socket.assigns[:principal]) do
      {:ok, installs} ->
        assign(socket, installs: installs, plugins_error: nil, can_read_plugins: true)

      {:error, %Error{code: :permission_denied}} ->
        assign(socket,
          installs: [],
          plugins_error: "Your roles may not inspect plugins in this Workspace.",
          can_read_plugins: false
        )

      {:error, reason} ->
        assign(socket,
          installs: [],
          plugins_error: Error.message(reason),
          can_read_plugins:
            Policy.permitted?(socket.assigns[:principal], "plugin:read", %{
              workspace: socket.assigns.workspace
            })
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-8">
        <h1 class="text-3xl font-semibold tracking-tight">Admin</h1>
        <p class="mt-1 text-sm text-base-content/60">
          workspace <span class="font-mono">{@workspace}</span>
        </p>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">The panels</h2>

        <ul class="mt-3 grid gap-2">
          <li :for={panel <- @panels} class="rounded border border-base-200 px-3 py-2">
            <div class="flex flex-wrap items-baseline gap-2">
              <%= if panel.path do %>
                <.link navigate={panel.path} class="text-sm font-medium underline">
                  {panel.label}
                </.link>
              <% else %>
                <span class="text-sm font-medium">{panel.label}</span>
              <% end %>
            </div>
            <p class="mt-1 text-xs leading-5 text-base-content/60">
              <%= case panel.state do %>
                <% :link -> %>
                  {panel.holds}.
                <% :here -> %>
                  There is no screen of its own yet: what it holds is on this page — {panel.holds}.
                <% :planned -> %>
                  Not built yet. It will hold {panel.holds}.
              <% end %>
            </p>
          </li>
        </ul>
      </section>

      <section id="plugins" class="v-panel px-3 py-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-[13px] font-semibold tracking-tight">Plugins &amp; Capabilities</h2>
          <button
            :if={@can_read_plugins}
            id="refresh-plugins"
            type="button"
            phx-click="refresh_plugins"
            class="btn btn-sm btn-ghost"
          >
            Refresh
          </button>
        </div>
        <p :if={@plugins_error} class="mt-3 text-sm" role="alert">{@plugins_error}</p>
        <p :if={@can_read_plugins} class="mt-2 text-xs text-base-content/60">
          Host API {@host_api_version}. Installs and grants for this Workspace.
        </p>

        <table :if={@installs != []} class="mt-3 w-full text-left text-sm">
          <thead class="text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="py-1 pr-3 font-medium">plugin</th>
              <th class="py-1 pr-3 font-medium">version</th>
              <th class="py-1 pr-3 font-medium">status</th>
              <th class="py-1 font-medium">capabilities</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={install <- @installs}
              data-plugin-id={install["plugin_id"]}
              class="border-t border-base-200 align-top"
            >
              <td class="py-2 pr-3">
                <p class="text-xs font-medium">{install["name"]}</p>
                <p class="font-mono text-xs">{install["plugin_id"]}</p>
                <p class="mt-1 text-xs text-base-content/60">{install["namespace"]}</p>
              </td>
              <td class="py-2 pr-3 text-xs text-base-content/70">{install["version"]}</td>
              <td data-plugin-status class="py-2 pr-3 text-xs">{install["status"]}</td>
              <td class="py-2 text-xs">
                <p data-plugin-requested>Requested: {Enum.join(install["requested_scopes"], ", ")}</p>
                <p data-plugin-granted class="mt-1">
                  Granted: {Enum.join(install["granted_scopes"], ", ")}
                </p>
              </td>
            </tr>
          </tbody>
        </table>

        <p
          :if={@can_read_plugins and is_nil(@plugins_error) and @installs == []}
          class="mt-3 text-sm text-base-content/60"
        >
          This Workspace has no plugin installed.
        </p>

        <details :if={@can_read_plugins} class="mt-4 text-sm">
          <summary class="cursor-pointer font-medium">Supported capability scopes</summary>
          <ul class="mt-2 grid gap-1 font-mono text-xs sm:grid-cols-2">
            <li :for={scope <- @plugin_capabilities}>{scope}</li>
          </ul>
        </details>

        <div :if={@can_read_plugins} class="mt-5 border-t border-base-200 pt-4">
          <h3 class="text-sm font-semibold">Inspect a plugin manifest</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Check declared capabilities and compatibility. This does not install or start a plugin.
          </p>
          <.form
            for={@manifest_form}
            id="plugin-manifest-form"
            phx-submit="inspect_manifest"
            class="mt-3"
          >
            <.input
              field={@manifest_form[:json]}
              type="textarea"
              label="Manifest JSON"
              rows="8"
              maxlength={@manifest_limit}
            />
            <button type="submit" class="btn btn-sm btn-primary">Check manifest</button>
          </.form>
        </div>

        <p :if={@manifest_error} id="plugin-manifest-error" class="mt-3 text-sm" role="alert">
          {@manifest_error}
        </p>
        <div :if={@manifest_preview} id="plugin-manifest-result" class="mt-3 text-sm" role="status">
          <p class="font-medium">Manifest is compatible with this host.</p>
          <p class="mt-1">{@manifest_preview["name"]} {@manifest_preview["version"]}</p>
          <p class="mt-1 font-mono text-xs">{@manifest_preview["id"]}</p>
          <p class="mt-1 text-xs">Requested: {Enum.join(@manifest_preview["capabilities"], ", ")}</p>
          <p class="mt-1 text-xs text-base-content/60">
            No capabilities have been granted by this check.
          </p>
          <p class="mt-1 text-xs text-base-content/60">
            Signature and provenance have not been checked.
          </p>
        </div>
      </section>
    </main>
    """
  end
end
