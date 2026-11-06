defmodule Veritas.Web.AdminPluginsTest do
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.Principal
  alias Veritas.Plugin
  alias Veritas.Plugin.{Install, Registry}
  alias Veritas.Store.Error

  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
    %{conn: signed_in}
  end

  test "shows actual requested and granted capabilities only for this workspace", %{
    conn: conn,
    workspace: workspace
  } do
    own = manifest("com.example.#{workspace}")
    other = manifest("com.example.other.#{workspace}")

    assert {:ok, _} = Install.install(own, workspace: workspace, granted_scopes: ["ci:read"])
    assert {:ok, _} = Install.install(other, workspace: "another_#{workspace}")
    on_exit(fn -> Enum.each([own, other], &Install.uninstall(&1["id"])) end)

    {:ok, view, _} = live(conn, ~p"/admin")
    assert has_element?(view, ~s([data-plugin-id="#{own["id"]}"]))
    refute render(view) =~ other["id"]
    assert has_element?(view, "[data-plugin-requested]", "agent:tool")
    assert has_element?(view, "[data-plugin-granted]", "ci:read")
    refute has_element?(view, "[data-plugin-granted]", "agent:tool")
    assert render(view) =~ "Host API 2.3.0"

    assert :ok = Install.stop(own["id"])
    view |> element("#refresh-plugins") |> render_click()
    assert has_element?(view, "[data-plugin-status]", "stopped")
  end

  test "checks a manifest through the host without installing or launching it", %{conn: conn} do
    definition = manifest("com.example.inspected")
    {:ok, view, _} = live(conn, ~p"/admin")

    view
    |> form("#plugin-manifest-form", manifest: %{json: Jason.encode!(definition)})
    |> render_submit()

    assert has_element?(view, "#plugin-manifest-result", "Manifest is compatible with this host")
    assert has_element?(view, "#plugin-manifest-result", "agent:tool")
    assert render(view) =~ "Signature and provenance have not been checked."
    assert :error = Registry.fetch_install(definition["id"])
  end

  test "refuses malformed, incompatible and oversized manifest submissions", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin")
    submit_manifest(view, "not json")
    assert has_element?(view, "#plugin-manifest-error", "valid JSON")

    definition = manifest("com.example.invalid")
    submit_manifest(view, Jason.encode!(%{definition | "capabilities" => ["host:admin"]}))
    assert has_element?(view, "#plugin-manifest-error", "host:admin")

    definition = put_in(definition, ["compatibility", "host_api"], ">= 99.0.0")
    submit_manifest(view, Jason.encode!(definition))
    assert has_element?(view, "#plugin-manifest-error", "does not satisfy")

    render_submit(view, "inspect_manifest", %{
      "manifest" => %{"json" => String.duplicate("x", 65_537)}
    })

    assert has_element?(view, "#plugin-manifest-error", "64 KiB")
    refute has_element?(view, "#plugin-manifest-result")
  end

  test "a forged inspection event cannot bypass the plugin permission", %{
    workspace: workspace
  } do
    %{conn: conn} =
      sign_in(Phoenix.ConnTest.build_conn(), workspace,
        roles: ["Service Desk Agent"],
        email: "desk@example.test"
      )

    definition = manifest("com.example.forbidden")
    assert {:ok, _} = Install.install(definition, workspace: workspace)
    on_exit(fn -> Install.uninstall(definition["id"]) end)
    {:ok, view, _} = live(conn, ~p"/admin")
    refute render(view) =~ definition["id"]
    refute has_element?(view, "#plugin-manifest-form")

    refusals = fn ->
      Enum.count(audit_events(workspace), fn event ->
        event["to_state"] == "refused" and
          get_in(event, ["diff", "capability"]) == "plugin:read"
      end)
    end

    before_event = refusals.()

    render_submit(view, "inspect_manifest", %{
      "manifest" => %{"json" => Jason.encode!(definition)}
    })

    refute has_element?(view, "#plugin-manifest-result")
    assert has_element?(view, "#plugin-manifest-error", "may not inspect plugins")
    assert refusals.() == before_event + 1
  end

  test "an unavailable host is reported distinctly and an authorized manifest check still works",
       %{
         conn: conn
       } do
    registry = Process.whereis(Registry)
    Process.unregister(Registry)

    try do
      {:ok, view, _} = live(conn, ~p"/admin")
      assert render(view) =~ "The plugin host is unavailable"
      refute render(view) =~ "This Workspace has no plugin installed"
      submit_manifest(view, Jason.encode!(manifest("com.example.offline")))
      assert has_element?(view, "#plugin-manifest-result", "Manifest is compatible")
    after
      Process.register(registry, Registry)
    end

    assert :error = Registry.fetch_install("com.example.offline")
  end

  test "the public plugin boundary refuses missing identity and a different workspace", %{
    workspace: workspace
  } do
    admin = Principal.new("plugin-admin", workspace, [:platform_admin])
    other_workspace = "other_#{workspace}"
    migrate(other_workspace)
    on_exit(fn -> remove_workspace(other_workspace) end)

    assert {:error, %Error{code: :permission_denied}} = Plugin.list(workspace, nil)
    assert {:error, %Error{code: :permission_denied}} = Plugin.list(other_workspace, admin)

    assert {:error, %Error{code: :permission_denied}} =
             Plugin.validate_manifest(other_workspace, manifest("com.example.denied"), admin)

    assert Enum.count(audit_events(other_workspace), fn event ->
             event["to_state"] == "refused" and
               get_in(event, ["diff", "capability"]) == "plugin:read"
           end) == 2

    auditor = Principal.new("plugin-auditor", workspace, [:auditor])
    assert {:ok, _} = Plugin.list(workspace, auditor)
  end

  defp submit_manifest(view, json) do
    view |> form("#plugin-manifest-form", manifest: %{json: json}) |> render_submit()
  end

  defp manifest(id) do
    %{
      "apiVersion" => "veritas.plugin/v1",
      "id" => id,
      "name" => "Capability inspection",
      "version" => "1.0.0",
      "compatibility" => %{"host_api" => ">= 2.3.0 and < 3.0.0"},
      "capabilities" => ["ci:read", "agent:tool"],
      "configuration" => %{"schema" => %{"type" => "object", "properties" => %{}}},
      "permissions" => %{"roles" => ["CI Steward"], "workspace_scoped" => true},
      "data" => %{"namespace" => String.replace(id, ".", "_")},
      "entry_points" => [
        %{"type" => "service", "command" => "veritas-example", "protocol" => "jsonrpc"}
      ],
      "dc_affinity" => "local",
      "health" => %{
        "check" => "http://127.0.0.1:0/healthz",
        "interval_seconds" => 30,
        "timeout_seconds" => 5,
        "degraded_after" => 3
      }
    }
  end
end
