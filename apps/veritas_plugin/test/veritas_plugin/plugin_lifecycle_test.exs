defmodule Veritas.Plugin.PluginLifecycleTest do
  @moduledoc """
  The plugin runtime, proven end to end.

  The contract suite (`runtime_test.exs`) pins the rules. This suite runs a
  **real Plugin process** and shows what those rules mean in practice:

    * a Plugin is a separate OS process, it is started, it answers a call
      through the tool registry, and it is stopped;
    * the process it starts is given **no credentials and no inherited
      environment** — the Plugin is asked what it was given, and the answer
      is checked here rather than assumed;
    * a Plugin that **dies mid-call** does not take the host with it, and
      the failure is visible rather than swallowed;
    * the other direction of the boundary works: a Plugin may call the host
      back over the same socket, and the call is checked against the
      Plugin's grant first.
  """

  use ExUnit.Case, async: false

  alias Veritas.Plugin.{Install, Tool}

  @plugin_id "com.vendor.veritas.lifecycle"

  @manifest %{
    "apiVersion" => "veritas.plugin/v1",
    "id" => @plugin_id,
    "name" => "Lifecycle Example",
    "version" => "1.0.0",
    "compatibility" => %{"host_api" => ">= 2.3.0 and < 3.0.0"},
    "capabilities" => ["ci:read", "ticket:read"],
    "configuration" => %{"schema" => %{"type" => "object", "properties" => %{}}},
    "permissions" => %{"roles" => ["CI Manager"], "workspace_scoped" => true},
    "data" => %{"namespace" => "lifecycle_link"},
    "entry_points" => [
      %{"type" => "service", "command" => "veritas-example", "protocol" => "jsonrpc"}
    ],
    "dc_affinity" => "local",
    "health" => %{"check" => "http://127.0.0.1:0/healthz", "interval_seconds" => 30,
                  "timeout_seconds" => 5, "degraded_after" => 3}
  }

  setup do
    on_exit(fn -> Install.uninstall(@plugin_id) end)
    :ok
  end

  test "a Plugin is started, called through the tool registry, and stopped" do
    assert {:ok, installed} = Install.install(@manifest)
    assert installed["plugin_id"] == @plugin_id

    # The manifest's health endpoint is a dead port, so the Plugin is alive
    # but degraded: the protocol is the primary liveness signal.
    assert {:ok, :degraded} = Install.start(@plugin_id)

    # The tool registry knows what the Plugin registered at its handshake.
    tools = Tool.list()
    assert Enum.any?(tools, &(&1["name"] == "echo" and &1["plugin_id"] == @plugin_id))

    # The call crosses the socket and comes back.
    assert {:ok, "hello"} = Tool.call(@plugin_id, "echo", ["hello"], %{workspace: "default"})

    # And the Plugin is stopped.
    assert :ok = Install.stop(@plugin_id)

    assert Enum.any?(Install.list(), fn plugin ->
             plugin["plugin_id"] == @plugin_id and plugin["status"] == :stopped
           end)
  end

  test "the Plugin process is given no credentials and no inherited environment" do
    assert {:ok, _installed} = Install.install(@manifest)
    assert {:ok, _status} = Install.start(@plugin_id)

    assert {:ok, environment} = Tool.call(@plugin_id, "env", [], %{workspace: "default"})

    # The host's facts, and only the host's facts: these five keys are the
    # contract between the host and the Plugin.
    assert Enum.sort(Enum.filter(Map.keys(environment), &String.starts_with?(&1, "VERITAS_"))) ==
             [
               "VERITAS_HOST_API_VERSION",
               "VERITAS_PLUGIN_ID",
               "VERITAS_PLUGIN_NAMESPACE",
               "VERITAS_PLUGIN_PROTOCOL",
               "VERITAS_PLUGIN_VERSION"
             ]

    # The environment is **built**, not inherited. The host's process has
    # these, and the Plugin has none of them.
    assert Map.has_key?(System.get_env(), "HOME")

    for name <- ~w(HOME USER LOGNAME SHELL TMPDIR) do
      refute Map.has_key?(environment, name), "the Plugin was given the host's #{name}"
    end

    # And there is no datastore credential in it, from any source.
    refute Enum.any?(Map.keys(environment), &String.contains?(&1, "SURREAL"))
    refute Enum.any?(Map.keys(environment), &String.contains?(&1, "PASSWORD"))
  end

  test "a Plugin's crash dump is kept out of the working tree" do
    # A Plugin process that dies with an uncaught exception cannot say why
    # it died: the Elixir launcher starts every VM with `-noshell`, so the
    # standard error device a report would be written to is not there — and
    # the failure to report the failure kills the VM and leaves an Erlang
    # crash dump in the working directory, which is the repository.
    #
    # So the host points a Plugin's dumps at a scratch directory, and the
    # Plugin's environment says so.
    assert {:ok, _installed} = Install.install(@manifest)
    assert {:ok, _status} = Install.start(@plugin_id)

    assert {:ok, environment} = Tool.call(@plugin_id, "env", [], %{workspace: "default"})

    dump = Map.get(environment, "ERL_CRASH_DUMP")

    assert is_binary(dump) and dump != "",
           "the Plugin was not told where its crash dump goes"

    refute String.starts_with?(dump, File.cwd!()),
           "the Plugin's crash dump would land in the working tree"

    assert :ok = Install.stop(@plugin_id)
  end

  test "the host survives a Plugin that crashes mid-call, and the crash is visible" do
    assert {:ok, _installed} = Install.install(@manifest)
    assert {:ok, _status} = Install.start(@plugin_id)

    # The Plugin exits while it is serving this call.
    assert {:error, _reason} = Tool.call(@plugin_id, "crash", [], %{workspace: "default"})

    # The host is still serving: it answers, and it still knows what is
    # installed.
    assert is_list(Install.list())
    assert {:error, _reason} = Tool.call(@plugin_id, "echo", ["still here"], %{workspace: "default"})

    # And the crash is not swallowed: the Plugin is quarantined, which is
    # what `docs/20` §Transport asks for.
    assert Enum.any?(Install.list(), fn plugin ->
             plugin["plugin_id"] == @plugin_id and plugin["status"] == :quarantined
           end)
  end

  test "a Plugin calls the host back over the same socket, and the grant is checked" do
    Application.put_env(:veritas_plugin, :host_adapter, Veritas.Plugin.Test.FakeHost)
    on_exit(fn -> Application.delete_env(:veritas_plugin, :host_adapter) end)

    assert {:ok, _installed} = Install.install(@manifest)
    assert {:ok, _status} = Install.start(@plugin_id)

    # The Plugin asks the host for CI records, over the same socket, in the
    # other direction.
    assert {:ok, %{"rows" => rows}} =
             Tool.call(@plugin_id, "ask_host", [%{"table" => "ci"}], %{workspace: "default"})

    assert rows == [%{"id" => "ci-1", "table" => "ci"}]
  end

  test "a Plugin may not call a host operation its grant does not cover" do
    Application.put_env(:veritas_plugin, :host_adapter, Veritas.Plugin.Test.FakeHost)
    on_exit(fn -> Application.delete_env(:veritas_plugin, :host_adapter) end)

    # A grant that covers reading CI but not writing it.
    assert {:ok, _installed} = Install.install(@manifest, granted_scopes: ["ci:read"])
    assert {:ok, _status} = Install.start(@plugin_id)

    # The read is allowed.
    assert {:ok, %{"rows" => _rows}} =
             Tool.call(@plugin_id, "ask_host", [%{"table" => "ci"}], %{workspace: "default"})

    # The read of a kind the grant does not cover is not, and it is refused
    # before the adapter is reached.
    assert {:error, _reason} =
             Tool.call(@plugin_id, "ask_host", [%{"table" => "ticket"}], %{workspace: "default"})
  end
end
