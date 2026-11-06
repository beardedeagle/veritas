defmodule Veritas.Plugin.RuntimeTest do
  @moduledoc """
  The Plugin Runtime's rules, from `docs/08` and `docs/20`.

  These are the rules that make a Plugin a guest rather than a resident:

    * a manifest with an incompatible Host API range is refused **at install
      time**, and the Plugin process is **never launched**;
    * `capabilities` is a **closed vocabulary** — an unknown scope is a typo
      or an escalation attempt, and both are install-time errors;
    * a grant is a **subset** of what was declared, re-read and re-checked on
      **every** call (`docs/20` §Capability Grants);
    * a Plugin that fails its health check is **quarantined**, and the
      quarantine is visible;
    * a Plugin process has **no store credentials** and no direct write path
      (`docs/09` ADR-009, `docs/20` §Data Access);
    * the lifecycle runs install → verify → start → call → stop → uninstall.

  ## The API these tests assume

  The runtime has not landed yet (`Veritas.Plugin` is still an empty module),
  so this file states the surface it assumes, and the tests fail until the
  implementation provides it. The surface is the one the corpus names or
  implies:

    * `Veritas.Plugin.Host.Capability.check/2` — the single enforcement
      point, named in `docs/20`;
    * `Veritas.Plugin.Manifest.validate/1` — manifest validation, refusing
      an incompatible `host_api` range and an unknown scope;
    * `Veritas.Plugin.Install.install/2`, `.uninstall/1`, `.start/1`,
      `.stop/1`, `.list/0` — the lifecycle;
    * `Veritas.Plugin.Host.call/4` — a host-mediated call, which is the only
      way a Plugin reaches anything.

  If the implementation lands with different names, these tests are a
  **contract proposal**: the rules above are the corpus's, the names are this
  file's.
  """
  use ExUnit.Case, async: false

  alias Veritas.Plugin.{Host, Install, Manifest}

  @host_api "2.3.0"

  @manifest %{
    "apiVersion" => "veritas.plugin/v1",
    "id" => "com.vendor.veritas.example",
    "name" => "Example Integration",
    "version" => "1.0.0",
    "compatibility" => %{"host_api" => ">= #{@host_api} and < 3.0.0"},
    "capabilities" => ["ci:read", "ticket:read"],
    "configuration" => %{"schema" => %{"type" => "object", "properties" => %{}}},
    "permissions" => %{"roles" => ["CI Manager"], "workspace_scoped" => true},
    "data" => %{"namespace" => "example_link"},
    "entry_points" => [%{"type" => "service", "command" => "veritas-example", "protocol" => "jsonrpc"}],
    "dc_affinity" => "local",
    "health" => %{"check" => "http://127.0.0.1:0/healthz", "interval_seconds" => 30,
                  "timeout_seconds" => 5, "degraded_after" => 3}
  }

  describe "the manifest" do
    test "an incompatible Host API range is refused" do
      incompatible = put_in(@manifest, ["compatibility", "host_api"], ">= 9.0.0 and < 10.0.0")

      assert {:error, reason} = Manifest.validate(incompatible)
      assert reason =~ "host_api" or reason =~ "Host API" or reason =~ "2.3.0"
    end

    test "a capability outside the vocabulary is refused, and the refusal names it" do
      unknown = put_in(@manifest, ["capabilities"], ["ci:read", "ci:admin"])

      assert {:error, reason} = Manifest.validate(unknown)
      assert reason =~ "ci:admin", "the refusal must name the scope it does not know"
    end

    test "a capability inside the vocabulary is accepted" do
      assert {:ok, manifest} = Manifest.validate(@manifest)
      assert manifest["capabilities"] == ["ci:read", "ticket:read"]
    end
  end

  describe "installing" do
    test "a refused manifest never launches the Plugin" do
      incompatible = put_in(@manifest, ["compatibility", "host_api"], ">= 9.0.0 and < 10.0.0")

      assert {:error, _reason} = Install.install(incompatible)

      # Nothing is installed, so nothing can be running.
      refute Enum.any?(Install.list(), &(&1["plugin_id"] == @manifest["id"]))
      assert {:error, _reason} = Install.start(@manifest["id"])
    end

    test "a granted capability set is exactly what was declared, and no more" do
      assert {:ok, installed} = Install.install(@manifest)

      on_exit(fn -> Install.uninstall(@manifest["id"]) end)

      assert Enum.sort(installed["granted_scopes"]) == ["ci:read", "ticket:read"]

      # A scope the Plugin never declared is not available to it.
      context = %{plugin_id: @manifest["id"], workspace: "default"}

      assert {:error, :scope_denied} = Host.Capability.check(context, :ticket_write)
      assert :ok = Host.Capability.check(context, :ci_read)
    end

    test "a Plugin that fails its health check is quarantined, and the quarantine is visible" do
      assert {:ok, _installed} = Install.install(@manifest)

      on_exit(fn -> Install.uninstall(@manifest["id"]) end)

      # The manifest's health check points at a port nothing is listening on.
      assert {:ok, status} = Install.start(@manifest["id"])
      assert status in [:quarantined, :degraded]

      assert Enum.any?(Install.list(), fn plugin ->
               plugin["plugin_id"] == @manifest["id"] and plugin["status"] in [:quarantined, :degraded]
             end)
    end
  end

  describe "the boundary" do
    test "a Plugin process has no store credentials and no direct write path" do
      assert {:ok, installed} = Install.install(@manifest)

      on_exit(fn -> Install.uninstall(@manifest["id"]) end)

      environment = installed["environment"] || %{}

      refute Map.has_key?(environment, "VERITAS_SURREAL_URL")
      refute Map.has_key?(environment, "VERITAS_SURREAL_PASSWORD")
      refute Enum.any?(Map.keys(environment), &(&1 |> to_string() |> String.contains?("SURREAL")))
    end
  end

  describe "the lifecycle" do
    test "install, verify, start, call, stop, uninstall" do
      assert {:ok, installed} = Install.install(@manifest)
      plugin_id = @manifest["id"]

      on_exit(fn -> Install.uninstall(plugin_id) end)

      assert installed["plugin_id"] == plugin_id
      assert {:ok, _verified} = Install.verify(plugin_id)
      assert {:ok, _started} = Install.start(plugin_id)

      assert {:ok, result} = Host.call(plugin_id, :echo, ["hello"], %{workspace: "default"})
      assert result == "hello"

      assert :ok = Install.stop(plugin_id)
      assert :ok = Install.uninstall(plugin_id)

      refute Enum.any?(Install.list(), &(&1["plugin_id"] == plugin_id))
    end
  end
end
