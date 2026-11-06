defmodule Veritas.Web.Shell.Context do
  @moduledoc """
  The state the application shell needs before it can render.

  ## What lives here and why

  The shell is chrome: it is the same on every screen, so it is built once per
  request from cheap, always-available facts — the current Workspace, the
  Node (BEAM) status, the density preference. It never reads the datastore.

  That is a deliberate split. The **chrome** must never be slow and never be
  wrong, so it reads nothing that can time out. The **page** behind it is
  where the store is read, and a page that cannot reach the store says so
  rather than rendering a number it did not measure.

  ## The eight sections

  The rail is `docs/04` §Navigation Model, verbatim: Overview, Incidents,
  Service Desk, CMDB, Changes, Delivery, Security, Admin. A section with no
  screen yet is still in the rail and is marked *Soon*, because the owner is
  looking at the shape of the product rather than at a list of what happens to
  be finished.
  """

  @default_workspace "default"

  @sections [
    %{
      id: :overview,
      label: "Overview",
      path: "/",
      icon: "hero-squares-2x2",
      status: :live,
      hint: "Executive, Operations, Service Desk, CMDB, Change Calendar and Delivery dashboards"
    },
    %{
      id: :incidents,
      label: "Incidents",
      path: "/incidents",
      icon: "hero-fire",
      status: :live,
      hint: "Incident queue and Incident detail"
    },
    %{
      id: :service_desk,
      label: "Service Desk",
      path: "/requests",
      icon: "hero-inbox",
      status: :live,
      hint: "Service Request queue and Service Request detail"
    },
    %{
      id: :cmdb,
      label: "CMDB",
      path: "/cmdb/cis",
      icon: "hero-cube",
      status: :live,
      hint: "Configuration Items, impact graph, relationship explorer and discovery"
    },
    %{
      id: :changes,
      label: "Changes",
      path: "/changes",
      icon: "hero-calendar-days",
      status: :live,
      hint: "Change queue and Change detail"
    },
    %{
      id: :delivery,
      label: "Delivery",
      path: "/programs",
      icon: "hero-clipboard-document-list",
      status: :live,
      hint: "Programs, milestones and work items"
    },
    %{
      id: :security,
      label: "Security",
      path: "/vulnerabilities",
      icon: "hero-shield-check",
      status: :live,
      hint: "Vulnerability queue and Vulnerability detail"
    },
    %{
      id: :admin,
      label: "Admin",
      path: "/admin",
      icon: "hero-cog-6-tooth",
      status: :live,
      hint:
        "Audit Log, Plugins and Capabilities, Users and roles, Workspaces, Settings, Agent Console"
    }
  ]

  # Which section a path belongs to. Longest prefix first, so `/cmdb/cis/…`
  # is CMDB and not something else.
  @routes [
    {"/workflows", :service_desk},
    {"/incidents", :incidents},
    {"/cmdb", :cmdb},
    {"/requests", :service_desk},
    {"/catalog", :service_desk},
    {"/changes", :changes},
    {"/programs", :delivery},
    {"/vulnerabilities", :security},
    {"/audit", :admin},
    {"/agents", :admin},
    {"/plugins", :admin},
    {"/admin", :admin},
    {"/settings", :admin}
  ]

  @doc """
  The shell state for a connection.
  """
  @spec state(Plug.Conn.t()) :: map()
  def state(conn) do
    workspace = workspace(conn)
    current = section_for_path(conn.request_path)

    %{
      workspace: workspace,
      workspaces: [workspace],
      user: %{name: "local"},
      density: density(conn),
      node: node_status(),
      agents: %{running: 0, available: false},
      notifications: %{count: 0},
      sections: sections(current),
      current_section: current
    }
  end

  @doc """
  The eight sections of the rail, with the current one marked.
  """
  @spec sections(atom()) :: [map()]
  def sections(current) do
    Enum.map(@sections, fn section ->
      Map.put(section, :current, section.id == current)
    end)
  end

  @doc """
  The section a path belongs to.
  """
  @spec section_for_path(String.t()) :: atom()
  def section_for_path(path) when is_binary(path) do
    Enum.find_value(@routes, :overview, fn {prefix, id} ->
      if String.starts_with?(path, prefix), do: id
    end)
  end

  def section_for_path(_), do: :overview

  @doc """
  The Workspace a request is scoped to.

  A Workspace is the unit of multi-tenant isolation, so it travels in the
  query string — the same way the Incident screens already read it.
  """
  @spec workspace(Plug.Conn.t()) :: map()
  def workspace(conn) do
    id = conn.query_params["workspace"] || @default_workspace
    %{id: id, name: workspace_name(id)}
  end

  @doc """
  The density preference.
  """
  @spec density(Plug.Conn.t()) :: String.t()
  def density(conn) do
    case get_session(conn, "veritas_density") do
      "compact" -> "compact"
      _ -> "comfortable"
    end
  end

  defp workspace_name(@default_workspace), do: "Default"
  defp workspace_name(id), do: id

  defp get_session(conn, key) do
    conn |> Plug.Conn.get_session(key)
  rescue
    _ -> nil
  end

  @doc """
  The Node (BEAM) status.

  This is read from the running VM, not from the store, so it is always
  available — including when the datastore is not.
  """
  @spec node_status() :: map()
  def node_status do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    name = Node.self()
    distributed? = name != :nonode@nohost
    connected = length(Node.list()) + 1
    uptime_s = div(uptime_ms, 1000)

    %{
      name: name,
      connected: connected,
      alive: true,
      distributed?: distributed?,
      uptime_s: uptime_s,
      uptime: uptime(uptime_s),
      title:
        "Node (BEAM): #{name} · #{connected} connected · #{if distributed?, do: "distributed", else: "not distributed"}"
    }
  end

  defp uptime(seconds) when seconds >= 3600 do
    "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  end

  defp uptime(seconds), do: "#{div(seconds, 60)}m"
end
