defmodule Veritas.Web.ShellComponents do
  @moduledoc """
  The Veritas application shell: the primary rail, the global top bar, and the
  primitives the rest of the interface is built from.

  ## Why the shell is chrome and not a page

  The rail and the top bar are identical on every screen, so they are rendered
  once — by the root layout — around whatever the page produced. A page is
  content; the shell is the frame around it. Keeping the chrome out of a
  LiveView's own diff also means a LiveView re-render never re-sends the
  navigation.

  ## The six elements of the top bar

  `docs/04` §Navigation Model names them: the Workspace switcher, the command
  palette, the Node (BEAM) status, the Agent activity indicator, the
  notifications, and the user menu. Each is on every screen, and each either
  does something or says plainly that it cannot yet. An element that neither
  acts nor admits it is unbuilt is a dead end, and dead ends are defects.

  ## Paths are written out here

  The shell is rendered by the root layout, and the router depends on the
  root layout, so a `~p` sigil in this module would close a compile-time
  cycle between the two. The paths below are therefore literals. They are few,
  they are stable, and the route table that owns them is one screen away.
  """

  use Phoenix.Component

  # `get_csrf_token/0` lives in Phoenix.Controller, not Phoenix.Component.
  # The Phoenix formatter adds this import automatically, but the shell is
  # chrome that renders outside any LiveView, so it states its own dependency
  # rather than relying on a formatter to infer it.
  import Phoenix.Controller, only: [get_csrf_token: 0]

  import Veritas.Web.CoreComponents, only: [icon: 1]

  @doc """
  The whole shell: the primary rail, the top bar, and the page content.

  The content is a slot, so a page decides what it is and the shell decides
  where it sits.
  """
  attr :shell, :map, required: true
  attr :conn, :any, required: true
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="v-shell" id="veritas-shell">
      <.rail sections={@shell.sections} />
      <div class="v-main">
        <.top_bar shell={@shell} conn={@conn} />
        <main class="v-content" id="veritas-content">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  The primary rail: the eight sections of the product.

  Every section is here even when it has no screen yet. The owner is looking
  at the shape of the product, and a rail with five of eight entries missing
  shows a smaller product than the one being built.
  """
  attr :sections, :list, required: true

  def rail(assigns) do
    ~H"""
    <nav class="v-rail" id="veritas-rail" aria-label="Primary">
      <a href="/" class="flex items-center gap-2.5 px-2 py-3" aria-label="Veritas, overview">
        <img src="/images/veritas-icon.svg" alt="" width="28" height="28" class="rounded-[7px]" />
        <span class="text-[15px] font-semibold tracking-tight">Veritas</span>
      </a>

      <ul class="flex flex-col gap-0.5">
        <li :for={section <- @sections}>
          <a
            href={section.path}
            class="v-rail-link"
            aria-current={section.current && "page"}
            title={section.hint}
          >
            <span class="text-base-content/60"><.icon name={section.icon} class="size-4" /></span>
            <span class="flex-1 truncate">{section.label}</span>
            <span
              :if={section.status == :planned}
              class="rounded border border-base-300 px-1.5 py-px text-[10px] font-medium uppercase tracking-wide text-base-content/45"
            >
              Soon
            </span>
          </a>
        </li>
      </ul>

      <div class="mt-auto px-2 pt-4 text-[11px] leading-4 text-base-content/40">
        <p>Self-hosted. No account. No phone home.</p>
        <p class="mt-1 font-mono">Apache-2.0</p>
      </div>
    </nav>
    """
  end

  @doc """
  The global top bar: the six elements `docs/04` names.

  Each disclosure is a `<details>` element, so it opens with the keyboard and
  with no JavaScript at all. The command palette's filter is the one thing
  that needs a script, and it only narrows a list that is already there.
  """
  attr :shell, :map, required: true
  attr :conn, :any, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="v-topbar" id="veritas-topbar">
      <.workspace_switcher workspace={@shell.workspace} workspaces={@shell.workspaces} />
      <.command_palette />

      <div class="ml-auto flex items-center gap-1">
        <.node_status node={@shell.node} />
        <.agent_activity agents={@shell.agents} />
        <.notifications notifications={@shell.notifications} />
        <.user_menu shell={@shell} conn={@conn} />
      </div>
    </header>
    """
  end

  @doc """
  The Workspace switcher.

  A Workspace is the unit of multi-tenant isolation, so the one you are
  looking at is always named. Switching sets the scope for the whole
  application; the scope is shown as a chip so a screenshot is never ambiguous
  about which Workspace it came from.
  """
  attr :workspace, :map, required: true
  attr :workspaces, :list, required: true

  def workspace_switcher(assigns) do
    ~H"""
    <details class="dropdown" id="v-workspace-switcher">
      <summary class="flex h-8 cursor-pointer list-none items-center gap-2 rounded-md border border-base-300 bg-base-100 px-2.5 text-sm hover:border-base-content/25 [&::-webkit-details-marker]:hidden">
        <span class="v-dot" style="--dot-color: var(--color-brand-ink)" aria-hidden="true" />
        <span class="max-w-[9rem] truncate font-medium">{@workspace.name}</span>
        <span class="font-mono text-[11px] text-base-content/45">{@workspace.id}</span>
        <.icon name="hero-chevron-down" class="size-3.5 text-base-content/45" />
      </summary>

      <div class="dropdown-content z-50 mt-1 w-72 rounded-md border border-base-300 bg-base-200 p-1 shadow-xl">
        <p class="px-2 py-1.5 text-[11px] uppercase tracking-wide text-base-content/45">Workspace</p>
        <ul class="flex flex-col">
          <li :for={ws <- @workspaces}>
            <a
              href={"?workspace=#{ws.id}"}
              class={[
                "flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300",
                ws.id == @workspace.id && "bg-base-300 font-medium"
              ]}
              aria-current={ws.id == @workspace.id && "true"}
            >
              <span class="v-dot" style="--dot-color: var(--color-brand-ink)" aria-hidden="true" />
              <span class="flex-1 truncate">{ws.name}</span>
              <span class="font-mono text-[11px] text-base-content/45">{ws.id}</span>
            </a>
          </li>
        </ul>
        <p class="mt-1 border-t border-base-300 px-2 py-1.5 text-[11px] leading-4 text-base-content/45">
          One Workspace exists in this build. More arrive with the multi-tenant work.
        </p>
      </div>
    </details>
    """
  end

  @doc """
  The command palette.

  It lists every route and every action the host knows about. Entity search
  across CIs and tickets lands with the CMDB work; until then this says so
  rather than pretending to search.
  """
  def command_palette(assigns) do
    ~H"""
    <details class="dropdown relative min-w-0 flex-1 sm:max-w-xl" id="v-command-palette">
      <summary
        class="flex h-8 cursor-pointer list-none items-center gap-2 rounded-md border border-base-300 bg-base-100 px-2.5 text-sm text-base-content/55 hover:border-base-content/25 [&::-webkit-details-marker]:hidden"
        aria-label="Search routes and commands"
      >
        <.icon name="hero-magnifying-glass" class="size-4" />
        <span class="flex-1 truncate">Search routes and commands</span>
        <kbd class="rounded border border-base-300 px-1.5 py-px font-mono text-[10px] text-base-content/55">
          ⌘K
        </kbd>
      </summary>

      <div class="dropdown-content z-50 mt-1 w-full min-w-[26rem] rounded-md border border-base-300 bg-base-200 p-2 shadow-xl">
        <label for="v-command-input" class="sr-only">Filter routes and commands</label>
        <input
          id="v-command-input"
          type="search"
          autocomplete="off"
          placeholder="Type a route or a command…"
          class="input input-sm w-full border-base-300 bg-base-100"
        />

        <p class="px-1 pb-1 pt-2 text-[11px] uppercase tracking-wide text-base-content/45">Go to</p>
        <ul class="flex flex-col">
          <li data-command="overview dashboard home">
            <a href="/" class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300">
              <.icon name="hero-squares-2x2" class="size-4 text-base-content/55" />
              <span class="flex-1">Overview</span>
              <span class="font-mono text-[11px] text-base-content/40">/</span>
            </a>
          </li>
          <li data-command="incidents queue fire problem">
            <a
              href="/incidents"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-fire" class="size-4 text-base-content/55" />
              <span class="flex-1">Incidents</span>
              <span class="font-mono text-[11px] text-base-content/40">/incidents</span>
            </a>
          </li>
          <li data-command="cmdb ci configuration item inventory">
            <a
              href="/cmdb/cis"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-cube" class="size-4 text-base-content/55" />
              <span class="flex-1">CMDB — Configuration Items</span>
              <span class="font-mono text-[11px] text-base-content/40">/cmdb/cis</span>
            </a>
          </li>
          <li data-command="service desk requests catalogue catalog">
            <a
              href="/requests"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-inbox" class="size-4 text-base-content/55" />
              <span class="flex-1">Service Desk — Service Requests</span>
              <span class="font-mono text-[11px] text-base-content/40">/requests</span>
            </a>
          </li>
          <li data-command="workflows workflow builder automation intake ai processing after action">
            <a
              href="/workflows"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-arrows-right-left" class="size-4 text-base-content/55" />
              <span class="flex-1">Workflows — design and run</span>
              <span class="font-mono text-[11px] text-base-content/40">/workflows</span>
            </a>
          </li>
          <li data-command="changes calendar cab approval">
            <a
              href="/changes"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-calendar-days" class="size-4 text-base-content/55" />
              <span class="flex-1">Changes</span>
              <span class="font-mono text-[11px] text-base-content/40">/changes</span>
            </a>
          </li>
          <li data-command="delivery programs milestones work items">
            <a
              href="/programs"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-clipboard-document-list" class="size-4 text-base-content/55" />
              <span class="flex-1">Delivery</span>
              <span class="font-mono text-[11px] text-base-content/40">/programs</span>
            </a>
          </li>
          <li data-command="security vulnerabilities cve">
            <a
              href="/vulnerabilities"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-shield-check" class="size-4 text-base-content/55" />
              <span class="flex-1">Security — Vulnerabilities</span>
              <span class="font-mono text-[11px] text-base-content/40">/vulnerabilities</span>
            </a>
          </li>
          <li data-command="admin audit log agents plugins users roles settings">
            <a
              href="/audit"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/55" />
              <span class="flex-1">Admin — Audit Log</span>
              <span class="font-mono text-[11px] text-base-content/40">/audit</span>
            </a>
          </li>
          <li data-command="delivery programs milestones work items">
            <a
              href="/programs"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-clipboard-document-list" class="size-4 text-base-content/55" />
              <span class="flex-1">Delivery — Programs</span>
              <span class="font-mono text-[11px] text-base-content/40">/programs</span>
            </a>
          </li>
          <li data-command="admin agent console agents assistant ai tools providers">
            <a
              href="/agents"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-sparkles" class="size-4 text-base-content/55" />
              <span class="flex-1">Admin — Agent Console</span>
              <span class="font-mono text-[11px] text-base-content/40">/agents</span>
            </a>
          </li>
          <li data-command="admin users roles accounts rbac principals">
            <a
              href="/admin/users"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-users" class="size-4 text-base-content/55" />
              <span class="flex-1">Admin — Users and roles</span>
              <span class="font-mono text-[11px] text-base-content/40">/admin/users</span>
            </a>
          </li>
        </ul>

        <p class="px-1 pb-1 pt-2 text-[11px] uppercase tracking-wide text-base-content/45">Tools</p>
        <ul class="flex flex-col">
          <li data-command="graphql graphiql api ide">
            <a
              href="/graphql/i"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-command-line" class="size-4 text-base-content/55" />
              <span class="flex-1">GraphiQL</span>
              <span class="font-mono text-[11px] text-base-content/40">/graphql/i</span>
            </a>
          </li>
          <li data-command="graphql api endpoint reference">
            <a
              href="/graphql"
              class="flex items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-300"
            >
              <.icon name="hero-document-text" class="size-4 text-base-content/55" />
              <span class="flex-1">GraphQL endpoint reference</span>
              <span class="font-mono text-[11px] text-base-content/40">/graphql</span>
            </a>
          </li>
        </ul>

        <p class="mt-2 border-t border-base-300 px-1 pt-2 text-[11px] leading-4 text-base-content/45">
          Searching Incidents, Changes and Configuration Items lands with the CMDB work.
        </p>
      </div>
    </details>
    """
  end

  @doc """
  The Node (BEAM) status.

  A degraded node is never hidden behind an aggregate green, and the count of
  connected Nodes is the count of Nodes that are actually connected — not the
  count the cluster believes in.
  """
  attr :node, :map, required: true

  def node_status(assigns) do
    ~H"""
    <a
      href="/audit"
      id="v-node-status"
      class="flex h-8 items-center gap-2 rounded-md px-2 text-xs text-base-content/70 hover:bg-base-300 hover:text-base-content"
      title={@node.title}
    >
      <span
        class={["v-dot", !@node.alive && "v-dot-unknown"]}
        style={@node.alive && "--dot-color: var(--color-health-ok)"}
        aria-hidden="true"
      />
      <span class="font-mono">{@node.connected}</span>
      <span class="hidden text-base-content/50 sm:inline">
        {if @node.connected == 1, do: "node", else: "nodes"}
      </span>
      <span class="hidden text-base-content/40 lg:inline">· {@node.uptime}</span>
    </a>
    """
  end

  @doc """
  The Agent activity indicator.

  It is non-modal and live by design: an Agent running is something you want
  to know about without opening a screen.
  """
  attr :agents, :map, required: true

  def agent_activity(assigns) do
    ~H"""
    <details class="dropdown dropdown-end" id="v-agent-activity">
      <summary
        class="flex h-8 cursor-pointer list-none items-center gap-1.5 rounded-md px-2 text-xs text-base-content/70 hover:bg-base-300 hover:text-base-content [&::-webkit-details-marker]:hidden"
        title="Agent activity"
      >
        <.icon name="hero-sparkles" class="size-4" />
        <span class="font-mono">{@agents.running}</span>
        <span class="hidden text-base-content/50 sm:inline">running</span>
      </summary>

      <div class="dropdown-content z-50 mt-1 w-80 rounded-md border border-base-300 bg-base-200 p-3 shadow-xl">
        <p class="text-sm font-medium">Agent activity</p>
        <p class="mt-1 text-xs leading-5 text-base-content/60">
          No Agent run is in flight. The Agent Console is at <span class="font-mono">/agents</span>: ask a question
          about the configuration, and read the steps it took.
        </p>
      </div>
    </details>
    """
  end

  @doc """
  The notifications.

  Mentions, approvals awaiting you and SLA risk — and nothing else. An event
  firehose is not a notification system.
  """
  attr :notifications, :map, required: true

  def notifications(assigns) do
    ~H"""
    <details class="dropdown dropdown-end" id="v-notifications">
      <summary
        class="relative flex h-8 cursor-pointer list-none items-center rounded-md px-2 text-base-content/70 hover:bg-base-300 hover:text-base-content [&::-webkit-details-marker]:hidden"
        title="Notifications"
      >
        <.icon name="hero-bell" class="size-4" />
        <span
          :if={@notifications.count > 0}
          class="absolute right-1 top-1 flex size-3.5 items-center justify-center rounded-full bg-error text-[9px] font-semibold text-error-content"
        >
          {@notifications.count}
        </span>
      </summary>

      <div class="dropdown-content z-50 mt-1 w-80 rounded-md border border-base-300 bg-base-200 p-3 shadow-xl">
        <p class="text-sm font-medium">Notifications</p>
        <p class="mt-1 text-xs leading-5 text-base-content/60">
          Nothing is waiting on you. The approval machinery, the mentions stream and the SLA
          risk clock are not built yet, so this list cannot be wrong — it is empty.
        </p>
      </div>
    </details>
    """
  end

  @doc """
  The user menu: theme, density, who is signed in, locale, and sign out.

  Density is a real preference and it persists in the session, because a
  home-lab operator who has chosen compact should never be shown comfortable
  again. The rest says what it is.

  ## The sign-out is a control, not a note

  The session has always been endable — `SessionController` has always ended
  it — and what was missing was a way to reach that from the screen. So the
  menu used to carry the sentence *"Sign out — not built. There is no
  authentication yet, so every request is local."* next to a product that
  could sign a person out, and a reader who believed it would have thought
  the session was a formality.

  The sign-out is now a form, in the same idiom as the density control a few
  lines above it: a plain `POST`, the form's own CSRF token, no JavaScript.
  `DELETE` is not reachable from a form, and a `data-method="delete"` link
  would need a script the shell does not otherwise have.

  ## Who is signed in

  The Principal is **already on the connection** — `Veritas.Web.Auth`
  resolves it for every request that carries a session — so the menu can say
  who is signed in without touching the auth plug or the LiveView mount.

  What it cannot say is the account's **display name**: the session carries
  the Principal's id, its Workspace and its roles, not the name. Reading the
  name would mean a datastore read inside the shell — which reads nothing
  that can time out — or a change to the session, which is not this file's
  to make. So the menu shows the account's id and the roles it holds, which
  are facts, rather than a name it would have to invent.
  """
  attr :shell, :map, required: true
  attr :conn, :any, required: true

  def user_menu(assigns) do
    assigns =
      assign(
        assigns,
        :next_density,
        if(assigns.shell.density == "compact", do: "comfortable", else: "compact")
      )

    assigns = assign(assigns, :account, account_identity(assigns.conn))

    ~H"""
    <details class="dropdown dropdown-end" id="v-user-menu">
      <summary
        class="flex h-8 cursor-pointer list-none items-center gap-1.5 rounded-md px-2 text-xs text-base-content/70 hover:bg-base-300 hover:text-base-content [&::-webkit-details-marker]:hidden"
        title="Account"
      >
        <.icon name="hero-user-circle" class="size-4" />
        <span
          :if={@account}
          class="hidden max-w-[14ch] truncate sm:inline-block"
          title={@account.id}
        >
          {@account.name}
        </span>
      </summary>

      <div class="dropdown-content z-50 mt-1 w-72 rounded-md border border-base-300 bg-base-200 p-2 shadow-xl">
        <p class="px-2 py-1.5 text-[11px] uppercase tracking-wide text-base-content/45">Appearance</p>
        <div class="px-2 pb-2">
          <.theme_toggle />
        </div>

        <p class="px-2 py-1.5 text-[11px] uppercase tracking-wide text-base-content/45">Density</p>
        <form action="/ui/density" method="post" class="px-2 pb-2">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="density" value={@next_density} />
          <input type="hidden" name="return_to" value={request_path(@conn)} />
          <button
            type="submit"
            class="flex w-full items-center gap-2 rounded px-1 py-1.5 text-left text-sm hover:bg-base-300"
          >
            <.icon name="hero-bars-3" class="size-4 text-base-content/55" />
            <span class="flex-1">
              Switch to {@next_density}
            </span>
            <span class="font-mono text-[11px] text-base-content/45">{@shell.density}</span>
          </button>
        </form>

        <p class="px-2 py-1.5 text-[11px] uppercase tracking-wide text-base-content/45">Account</p>
        <div :if={@account} class="px-2 pb-2">
          <div class="flex items-center gap-2">
            <.icon name="hero-user-circle" class="size-4 shrink-0 text-base-content/55" />
            <div class="min-w-0 flex-1">
              <p
                class={["truncate text-xs text-base-content", @account.mono && "font-mono"]}
                title={@account.id}
              >
                {@account.name}
              </p>
              <p :if={@account.detail != ""} class="truncate text-[11px] text-base-content/45">
                {@account.detail}
              </p>
            </div>
          </div>
        </div>
        <ul class="flex flex-col">
          <li class="px-2 py-1.5 text-xs leading-5 text-base-content/55">
            Locale — not built. The corpus is English-only so far.
          </li>
        </ul>
        <form action="/session/signout" method="post" class="px-2 pb-2">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            class="flex w-full items-center gap-2 rounded px-1 py-1.5 text-left text-sm hover:bg-base-300"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4 text-base-content/55" />
            <span class="flex-1">
              Sign out
            </span>
          </button>
        </form>
      </div>
    </details>
    """
  end

  @doc """
  The theme toggle: system, light, dark.

  The shell is rendered by the root layout, outside any LiveView's DOM, so
  these buttons cannot use `phx-click`: LiveView would never see the event.
  They carry `data-phx-theme` instead, and the root layout's script listens
  for them on the document. The theme is a property of the document rather
  than of a LiveView, so it belongs there.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="group"
      aria-label="Colour theme"
      class="relative flex w-full flex-row items-center rounded-full border border-base-300 bg-base-100"
    >
      <div class="absolute h-full w-1/3 rounded-full border border-base-300 bg-base-200 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        type="button"
        class="flex w-1/3 cursor-pointer justify-center p-1.5"
        data-phx-theme="system"
        title="Match the system theme"
      >
        <.icon name="hero-computer-desktop" class="size-4 opacity-75 hover:opacity-100" />
        <span class="sr-only">Match the system theme</span>
      </button>

      <button
        type="button"
        class="flex w-1/3 cursor-pointer justify-center p-1.5"
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun" class="size-4 opacity-75 hover:opacity-100" />
        <span class="sr-only">Light theme</span>
      </button>

      <button
        type="button"
        class="flex w-1/3 cursor-pointer justify-center p-1.5"
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon" class="size-4 opacity-75 hover:opacity-100" />
        <span class="sr-only">Dark theme</span>
      </button>
    </div>
    """
  end

  @doc """
  A panel: the framed surface every dashboard widget sits in.
  """
  attr :title, :string, default: nil
  attr :meta, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def panel(assigns) do
    ~H"""
    <section class="v-panel flex min-w-0 flex-col">
      <header
        :if={@title || @actions != []}
        class="flex items-center gap-3 border-b border-base-300 px-3 py-2"
      >
        <h2 class="flex-1 truncate text-[13px] font-semibold tracking-tight">{@title}</h2>
        <span :if={@meta} class="font-mono text-[11px] text-base-content/45">{@meta}</span>
        {render_slot(@actions)}
      </header>
      <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  A single figure with its label and its source.

  A number is only trustworthy when it says where it came from and when it was
  measured, so the source is part of the tile rather than a tooltip.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :source, :string, default: nil
  attr :tone, :string, default: "neutral"

  def kpi_tile(assigns) do
    ~H"""
    <div class="v-panel px-3 py-2.5">
      <p class="truncate text-[11px] uppercase tracking-wide text-base-content/45">{@label}</p>
      <p class={[
        "mt-1 font-mono text-2xl leading-none font-semibold tracking-tight",
        @tone == "critical" && "text-sev-p1",
        @tone == "ok" && "text-health-ok",
        @tone == "warn" && "text-sev-p2",
        @tone == "neutral" && "text-base-content"
      ]}>
        {@value}
      </p>
      <p :if={@source} class="mt-1.5 truncate text-[11px] text-base-content/45">
        {@source}
      </p>
    </div>
    """
  end

  @doc """
  An honest "not built yet" state.

  `docs/04` principle 5: an empty state names what is missing, why, and the
  next action. A panel whose data source has not shipped says exactly that —
  it does not render a zero, because a zero would be a measurement.

  The icon is an attribute because the meaning is the caller's: the same
  shape says "nothing here yet", and what it is waiting for changes.
  """
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :icon, :string, default: "hero-clock"
  slot :inner_block

  def not_yet(assigns) do
    ~H"""
    <div class="flex h-full min-h-[7rem] flex-col items-center justify-center gap-2 px-4 py-6 text-center">
      <span class="v-hatch flex size-9 items-center justify-center rounded-md border border-base-300">
        <.icon name={@icon} class="size-4 text-base-content/45" />
      </span>
      <p class="text-[13px] font-medium">{@title}</p>
      <p class="max-w-sm text-xs leading-5 text-base-content/55">{@body}</p>
      <div :if={@inner_block != []} class="mt-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  A block of labelled figures inside a panel.

  Each row is a label, a value, and an optional note. A value of `nil` is
  rendered as an em dash rather than a zero: a figure that could not be read
  is not a figure of zero.
  """
  attr :rows, :list, required: true

  def stat_rows(assigns) do
    ~H"""
    <dl class="flex flex-col">
      <div :for={row <- @rows} class="flex items-baseline gap-3 px-3 py-2">
        <dt class="w-36 shrink-0 text-[13px] text-base-content/60">{row.label}</dt>
        <dd class="min-w-0 flex-1 font-mono text-[13px]">
          {if row.value, do: row.value, else: "—"}
          <span :if={row[:note]} class="ml-1 font-sans text-[11px] text-base-content/45">
            {row.note}
          </span>
        </dd>
      </div>
    </dl>
    """
  end

  @doc """
  The severity of a ticket.

  Severity is carried by three things at once — a shape, a label and a colour —
  so it survives a monochrome screenshot and a colour-blind reader. The colour
  is the reinforcement, never the message.
  """
  attr :priority, :string, required: true
  attr :label, :string, default: nil

  def severity_badge(assigns) do
    assigns = assign(assigns, :level, severity_for(assigns.priority))

    assigns =
      assign(assigns, :label, assigns.label || severity_label(assigns.level) || assigns.priority)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 border-l-[3px] pr-1 pl-1.5 text-[11px] font-medium whitespace-nowrap",
      severity_edge(assigns.level),
      severity_text(assigns.level)
    ]}>
      <.icon name={severity_icon(assigns.level)} class="size-3" />
      {@label}
    </span>
    """
  end

  @doc """
  The workflow state of a ticket.

  A pill with a text label. State is never the same channel as severity, so
  the two can never be mistaken for one another.
  """
  attr :state, :string, required: true

  def state_pill(assigns) do
    assigns = assign(assigns, :tone, state_tone(assigns.state))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 font-mono text-[11px] whitespace-nowrap",
      @tone.class
    ]}>
      <.icon name={@tone.icon} class="size-3" />
      {@state}
    </span>
    """
  end

  @doc """
  The lifecycle of a Configuration Item.

  A CI's lifecycle is not a workflow state — it is where the CI sits in its
  life — so it gets its own outlined pill and its own vocabulary. Outlined
  rather than tinted, so the two channels stay apart.
  """
  attr :lifecycle, :string, required: true

  def lifecycle_pill(assigns) do
    assigns = assign(assigns, :tone, lifecycle_tone(assigns.lifecycle))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 font-mono text-[11px] whitespace-nowrap",
      @tone.class
    ]}>
      <.icon name={@tone.icon} class="size-3" />
      {@lifecycle}
    </span>
    """
  end

  @doc """
  The criticality of a Configuration Item.

  Criticality answers the same question as severity — how bad — so it uses
  the same edge channel and the same four tones, and it never appears on a
  row that also shows a severity. The label stays the criticality's own word
  (`tier1`, `high`, `medium`, `low`): it is a different scale from a ticket's
  priority and must not borrow its vocabulary.
  """
  attr :criticality, :string, required: true

  def criticality_badge(assigns) do
    assigns = assign(assigns, :level, criticality_for(assigns.criticality))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 border-l-[3px] pr-1 pl-1.5 text-[11px] font-medium whitespace-nowrap",
      severity_edge(assigns.level),
      severity_text(assigns.level)
    ]}>
      <.icon name={severity_icon(assigns.level)} class="size-3" />
      {@criticality}
    </span>
    """
  end

  @doc """
  A health dot with a text label beside it.

  `unknown` is drawn as an outlined, hollow dot: an absent observation is a
  distinct state, and it is never drawn as healthy.
  """
  attr :health, :atom, required: true
  attr :label, :string, required: true

  def health_dot(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs whitespace-nowrap">
      <span
        class={["v-dot", @health == :unknown && "v-dot-unknown"]}
        style={health_style(@health)}
        aria-hidden="true"
      />
      {@label}
    </span>
    """
  end

  @doc """
  The severity a stored priority maps to.

  The domain stores a free-form `priority`; the interface shows a severity.
  The mapping is explicit and total, and an unrecognised value is shown as
  unrated rather than being rounded up into a band it does not belong to.
  """
  @spec severity_for(String.t() | nil) :: 1..4 | nil
  def severity_for(priority) when is_binary(priority) do
    case String.downcase(String.trim(priority)) do
      p when p in ["p1", "critical", "urgent"] -> 1
      p when p in ["p2", "high"] -> 2
      p when p in ["p3", "medium", "normal"] -> 3
      p when p in ["p4", "low"] -> 4
      _ -> nil
    end
  end

  def severity_for(_), do: nil

  @doc """
  The name of a severity band.

  Severity is a shape and a label; the colour is reinforcement.
  """
  @spec severity_label(1..4 | nil) :: String.t() | nil
  def severity_label(1), do: "P1 Critical"
  def severity_label(2), do: "P2 High"
  def severity_label(3), do: "P3 Medium"
  def severity_label(4), do: "P4 Low"
  def severity_label(_), do: nil

  @doc """
  The severity a CI's criticality maps to.

  Criticality is a different scale from a ticket's priority, so it gets its
  own mapping: `tier1` is the worst, then `high`, `medium` and `low`. The
  label shown is the criticality's own word.
  """
  @spec criticality_for(String.t() | nil) :: 1..4 | nil
  def criticality_for(criticality) when is_binary(criticality) do
    case String.downcase(String.trim(criticality)) do
      c when c in ["tier1", "critical"] -> 1
      c when c in ["high"] -> 2
      c when c in ["medium", "normal"] -> 3
      c when c in ["low"] -> 4
      _ -> nil
    end
  end

  def criticality_for(_), do: nil

  @doc """
  The tone of a workflow state.

  `docs/02` §Incident fixes the states; `docs/04` §Visual Language fixes the
  tones. This is where the two meet:

      new           blue outline  — logged, unclassified, not yet owned
      acknowledged  cyan          — accepted, owner assigned
      in_progress   blue solid    — diagnosis or restoration under way
      on_hold       slate         — blocked on a customer, a third party or a window
      resolved      green         — service restored, or a workaround in place
      closed        slate, muted  — finalised, audit retained
      cancelled     slate, struck — not a reportable incident

  The shape and the state's own name are always present, so the colour is
  reinforcement and never the message. `on_hold` is slate and `closed` is a
  muted slate: they are told apart by their shape, their icon and their name,
  which is exactly why the icon is not optional.
  """
  @spec state_tone(String.t() | nil) :: %{class: String.t(), icon: String.t()}
  def state_tone(state) when is_binary(state) do
    case String.downcase(String.trim(state)) do
      "new" ->
        %{
          class: "border-state-new/50 bg-state-new/10 text-state-new",
          icon: "hero-inbox"
        }

      "acknowledged" ->
        %{
          class: "border-state-acknowledged/50 bg-state-acknowledged/10 text-state-acknowledged",
          icon: "hero-user-circle"
        }

      "in_progress" ->
        %{
          class: "border-state-in-progress/50 bg-state-in-progress/15 text-state-in-progress",
          icon: "hero-arrow-path"
        }

      "on_hold" ->
        %{
          class: "border-state-on-hold/50 bg-state-on-hold/10 text-state-on-hold",
          icon: "hero-pause-circle"
        }

      "resolved" ->
        %{
          class: "border-state-resolved/50 bg-state-resolved/10 text-state-resolved",
          icon: "hero-check-circle"
        }

      "closed" ->
        %{
          class: "border-dashed border-state-closed/40 bg-state-closed/5 text-state-closed/70",
          icon: "hero-lock-closed"
        }

      "cancelled" ->
        %{
          class:
            "border-dashed border-state-cancelled/40 bg-state-cancelled/5 text-state-cancelled/70 line-through",
          icon: "hero-x-circle"
        }

      _ ->
        %{
          class: "border-base-300 bg-base-100 text-base-content/55",
          icon: "hero-question-mark-circle"
        }
    end
  end

  def state_tone(_),
    do: %{
      class: "border-base-300 bg-base-100 text-base-content/55",
      icon: "hero-question-mark-circle"
    }

  @doc """
  The tone of a CI lifecycle.

  A lifecycle is where the CI sits in its life, not where a ticket is in its
  workflow, so it is outlined rather than tinted and carries its own
  vocabulary.
  """
  @spec lifecycle_tone(String.t() | nil) :: %{class: String.t(), icon: String.t()}
  def lifecycle_tone(lifecycle) when is_binary(lifecycle) do
    case String.downcase(String.trim(lifecycle)) do
      "proposed" ->
        %{
          class: "border-lifecycle-proposed/60 text-lifecycle-proposed",
          icon: "hero-sparkles"
        }

      "active" ->
        %{
          class: "border-lifecycle-active/60 text-lifecycle-active",
          icon: "hero-check-circle"
        }

      "in_maintenance" ->
        %{
          class: "border-lifecycle-in_maintenance/60 text-lifecycle-in_maintenance",
          icon: "hero-wrench"
        }

      "retired" ->
        %{
          class: "border-dashed border-lifecycle-retired/50 text-lifecycle-retired/80",
          icon: "hero-archive-box"
        }

      "disposed" ->
        %{
          class:
            "border-dashed border-lifecycle-disposed/50 text-lifecycle-disposed/80 line-through",
          icon: "hero-trash"
        }

      _ ->
        %{class: "border-base-300 text-base-content/55", icon: "hero-question-mark-circle"}
    end
  end

  def lifecycle_tone(_),
    do: %{class: "border-base-300 text-base-content/55", icon: "hero-question-mark-circle"}

  defp severity_edge(1), do: "border-l-sev-p1"
  defp severity_edge(2), do: "border-l-sev-p2"
  defp severity_edge(3), do: "border-l-sev-p3"
  defp severity_edge(4), do: "border-l-sev-p4"
  defp severity_edge(_), do: "border-l-base-300"

  defp severity_text(1), do: "text-sev-p1"
  defp severity_text(2), do: "text-sev-p2"
  defp severity_text(3), do: "text-sev-p3"
  defp severity_text(4), do: "text-sev-p4"
  defp severity_text(_), do: "text-base-content/55"

  defp severity_icon(1), do: "hero-exclamation-triangle"
  defp severity_icon(2), do: "hero-exclamation-circle"
  defp severity_icon(3), do: "hero-information-circle"
  defp severity_icon(_), do: "hero-minus-circle"

  defp health_style(:operational), do: "--dot-color: var(--color-health-ok)"
  defp health_style(:degraded), do: "--dot-color: var(--color-health-degraded)"
  defp health_style(:down), do: "--dot-color: var(--color-health-down)"
  defp health_style(:orphan), do: "--dot-color: var(--color-health-orphan)"
  defp health_style(_), do: "--dot-color: var(--color-health-unknown)"

  defp request_path(conn) do
    case conn do
      %{request_path: path} -> path
      _ -> "/"
    end
  end

  # Who is signed in, read from the connection.
  #
  # The Principal is already there — `Veritas.Web.Auth` resolves it for
  # every request that carries a session — so this costs nothing and reads
  # nothing that can time out. A connection with no Principal has no
  # identity to show, and the menu says nothing rather than guessing.
  defp account_identity(conn) do
    case principal(conn) do
      %{id: id, roles: roles} = principal when is_binary(id) ->
        name = display_name(principal) || id

        %{
          id: id,
          name: name,
          detail: role_detail(roles),
          # The id is a machine token and is set in the shell's mono face;
          # a display name is not.
          mono: name == id
        }

      _ ->
        nil
    end
  end

  defp principal(conn) do
    case conn do
      %{assigns: %{principal: principal}} -> principal
      _ -> nil
    end
  end

  defp display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: nil

  # The roles the session holds, in the corpus's own spelling.
  defp role_detail(roles) when is_list(roles) do
    roles
    |> Enum.map(&Veritas.Core.Principal.role_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp role_detail(_), do: ""
end
