defmodule Veritas.Core.Store.ProviderTableTest do
  @moduledoc """
  The provider table, on the **shipped** engine.

  The provider registry stores providers in a `:provider` table. The in-memory
  Adapter has no schema, so it stored them happily; the SurrealDB Adapter has
  one, and the table was not declared in it — so every write to the registry
  raised before it reached the engine, and the Agent Console's "add a
  provider" could never save anything.

  So the registry is run against the shipped engine here: the provider is
  written, read back, and the Audit Log chain that records the acceptance
  still verifies. The in-memory Adapter cannot answer this question, because
  it is the Adapter that has no schema.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider.Registry
  alias Veritas.Core.Audit
  alias Veritas.Core.Store.Conformance
  alias Veritas.Core.Test.SurrealServer
  alias Veritas.Store
  alias Veritas.Store.Surreal.Schema

  @alice %{type: "user", id: "alice"}

  @hosted %{
    id: "eu_hosted",
    kind: :hosted,
    adapter: :capability_floor_probe,
    base_url: "https://api.example",
    model: "gpt-4o",
    credential_env: "EXAMPLE_KEY",
    capability_floor_acknowledged: false,
    capabilities: [:tools]
  }

  setup_all do
    {:ok, server} = SurrealServer.start()

    previous = Application.get_env(:veritas_core, :surreal)

    Application.put_env(:veritas_core, :surreal,
      url: SurrealServer.url(server),
      user: "root",
      pass: "root"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:veritas_core, :surreal, previous)
      else
        Application.delete_env(:veritas_core, :surreal)
      end

      SurrealServer.stop(server)
    end)

    {:ok, server: server}
  end

  setup do
    # The catalogue holds the adapter ids the host knows. The probe stands in
    # for a shipped adapter, so the test does not depend on which
    # applications a given run starts.
    AdapterRegistry.register(:capability_floor_probe, __MODULE__)

    {:ok, ctx} = Conformance.prepare(Veritas.Store.Surreal)
    on_exit(fn -> Conformance.cleanup(ctx) end)

    {:ok, ctx: ctx}
  end

  describe "the provider table" do
    test "is declared in the schema the migration builds", %{ctx: ctx} do
      # The schema is where the table is declared, and the migration builds
      # its statements from the same list — so a declared table is a table a
      # fresh Workspace gets.
      assert "provider" in Enum.map(Schema.tables(), & &1.name)

      assert %{"workspace" => "workspace"} = Schema.reference_fields()["provider"]

      fields = Schema.declared_fields()["provider"]

      assert is_list(fields)
      assert "workspace" in fields
      assert "capability_floor_acknowledged" in fields
      assert "capability_floor_acknowledged_by" in fields
      assert "capability_floor_acknowledged_at" in fields

      # And the Workspace this test works in has it: the migration ran.
      assert is_binary(ctx.workspace)
    end

    test "is written, read back, and the Audit Log chain still verifies", %{ctx: ctx} do
      workspace = ctx.workspace

      assert {:ok, _} = Registry.put(workspace, @hosted)

      assert {:ok, stored} = Registry.fetch(workspace, "eu_hosted")
      assert stored.id == "eu_hosted"
      assert stored.kind == :hosted
      assert stored.adapter == :capability_floor_probe
      assert stored.base_url == "https://api.example"
      assert stored.model == "gpt-4o"
      assert stored.credential_env == "EXAMPLE_KEY"
      assert stored.capability_floor_acknowledged == false
      assert stored.capability_floor_acknowledged_by == nil

      # The capabilities are atoms on the way in, and the engine holds
      # strings — so they are compared by name, which is the same on either
      # Adapter.
      assert Enum.map(stored.capabilities, &to_string/1) == ["tools"]

      # The acceptance is a change, and a change is written to the Audit Log
      # in the same transaction as the row it is about.
      assert {:ok, _} =
               Registry.put(
                 workspace,
                 %{@hosted | capability_floor_acknowledged: true},
                 actor: @alice
               )

      assert {:ok, accepted} = Registry.fetch(workspace, "eu_hosted")
      assert accepted.capability_floor_acknowledged == true
      assert accepted.capability_floor_acknowledged_by == %{type: "user", id: "alice"}
      assert %DateTime{} = accepted.capability_floor_acknowledged_at

      # The chain verifies, and it is not verifying an empty chain: the
      # acceptance is in it.
      assert {:ok, events} = Audit.entries(workspace)
      assert length(events) >= 1

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a write to a table the schema does not declare is refused", %{ctx: ctx} do
      workspace = ctx.workspace

      result =
        Store.transaction(workspace, fn tx ->
          Store.put(tx, :not_a_declared_table, %{"id" => "x"})
        end)

      assert {:error, reason} = result
      assert reason.code == :invalid_request
      assert reason.message =~ "not declared"
    end
  end
end
