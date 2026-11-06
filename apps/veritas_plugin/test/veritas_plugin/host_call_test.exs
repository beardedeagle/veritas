defmodule Veritas.Plugin.HostCallTest do
  use ExUnit.Case, async: false

  alias Veritas.Plugin.{Host, Registry}

  setup do
    plugin = "test.host.#{System.unique_integer([:positive])}"

    install = %{
      plugin_id: plugin,
      workspace: "host_test",
      manifest: %{"permissions" => %{"workspace_scoped" => true}},
      registrations: [%{"name" => "read_ci", "required_scopes" => ["ci:read"]}],
      granted_scopes: ["ci:read"]
    }

    :ok = Registry.put_install(install)
    on_exit(fn -> Registry.remove_install(plugin) end)
    %{plugin: plugin, install: install, context: %{workspace: "host_test"}}
  end

  test "revoked scopes return a refusal", %{plugin: plugin, install: install, context: context} do
    :ok = Registry.put_install(%{install | granted_scopes: []})
    assert {:error, :scope_denied} = Host.call(plugin, :read_ci, %{}, context)
  end

  test "workspace mismatch returns a refusal", %{plugin: plugin} do
    assert {:error, :scope_denied} = Host.call(plugin, :read_ci, %{}, %{workspace: "elsewhere"})
  end

  test "unknown methods return an error", %{plugin: plugin, context: context} do
    assert {:error, :unknown_method} = Host.call(plugin, :unknown, %{}, context)
  end

  test "an allowed call without a session returns not_running", %{
    plugin: plugin,
    context: context
  } do
    assert {:error, :not_running} = Host.call(plugin, :read_ci, %{}, context)
  end
end
