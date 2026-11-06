defmodule Veritas.Core.ProviderRegistryCapabilityFloorTest do
  @moduledoc """
  The contractual floor, as a **record** and never as a condition.

  The owner's ruling (2026-10-31): a provider that trains on customer data
  is **never refused**. The risk is surfaced when the provider is set up, the
  operator accepts it, and the acceptance is recorded — with **who** accepted
  it and **when** — in the provider's own row and in the Audit Log.

  What must never happen: a provider whose floor has not been acknowledged
  being refused. That would refuse the provider over the absence of a
  signature rather than over anything the operator did, and it would make the
  one field that records the decision into a switch.

  ## The store these tests run against

  The registry's **store path** runs against the in-memory Adapter, because
  the SurrealDB Adapter cannot write the `:provider` table: the table is not
  declared in the schema, so the Adapter has no field list for it and the
  write raises before it reaches the engine. The in-memory Adapter is the
  port's second implementation and it passes the conformance suite
  (`store/memory_conformance_test.exs`), so it is a store the contract is
  written against. The Audit Log chain is exercised on the **shipped** engine
  as well, so the diff this registry builds is proved to survive it.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider.Registry
  alias Veritas.Core.Audit
  alias Veritas.Core.Store.Conformance
  alias Veritas.Store

  @alice %{type: "user", id: "alice"}
  @bob %{type: "user", id: "bob"}

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

  setup do
    # The catalogue holds the adapter ids the host knows. The probe stands in
    # for a shipped adapter, so the test does not depend on which
    # applications a given run starts.
    AdapterRegistry.register(:capability_floor_probe, __MODULE__)

    :ok
  end

  # A scratch Workspace on the in-memory Adapter, with the Adapter put back
  # when the test ends.
  defp memory_store do
    {:ok, ctx} = Conformance.prepare(Veritas.Store.Memory)
    on_exit(fn -> Conformance.cleanup(ctx) end)
    ctx.workspace
  end

  defp audit_events(workspace) do
    {:ok, events} = Audit.entries(workspace)
    events
  end

  defp rows(workspace, table) do
    {:ok, listed} =
      Store.transaction(workspace, fn tx ->
        Store.list(tx, table, %{where: [], order_by: []})
      end)

    listed
  end

  describe "an accepted provider" do
    test "can be stored with the acknowledgement true" do
      workspace = memory_store()

      assert {:ok, stored} =
               Registry.put(
                 workspace,
                 %{@hosted | capability_floor_acknowledged: true},
                 actor: @alice
               )

      assert stored.capability_floor_acknowledged == true
      assert stored.capability_floor_acknowledged_by == @alice
      assert %DateTime{} = stored.capability_floor_acknowledged_at
    end

    test "reads its attribution back" do
      workspace = memory_store()

      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      assert {:ok, fetched} = Registry.fetch(workspace, "eu_hosted")
      assert fetched.capability_floor_acknowledged == true
      assert fetched.capability_floor_acknowledged_by == @alice
      assert %DateTime{} = fetched.capability_floor_acknowledged_at
    end

    test "the acceptance is audited, attributed to the accepting principal" do
      workspace = memory_store()

      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      assert [entry] = audit_events(workspace)
      assert entry["subject_table"] == "provider"
      assert entry["subject"] == "eu_hosted"
      assert entry["actor_id"] == "alice"
      assert entry["actor_type"] == "user"
      assert entry["from_state"] == "not_acknowledged"
      assert entry["to_state"] == "acknowledged"
      assert entry["diff"]["capability_floor_acknowledged"] == true
      assert entry["diff"]["acknowledged_by"] == "user:alice"
    end

    test "the chain still verifies after an acceptance" do
      workspace = memory_store()

      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a re-save by the same principal is not a new acceptance" do
      workspace = memory_store()

      {:ok, first} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      {:ok, second} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      assert second.capability_floor_acknowledged_at == first.capability_floor_acknowledged_at
      assert second.capability_floor_acknowledged_by == @alice
      assert length(audit_events(workspace)) == 1
    end

    test "withdrawing the acceptance is audited too" do
      workspace = memory_store()

      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: false}, actor: @bob)

      assert [accept, withdraw] = audit_events(workspace)
      assert accept["to_state"] == "acknowledged"
      assert withdraw["from_state"] == "acknowledged"
      assert withdraw["to_state"] == "not_acknowledged"
      assert withdraw["actor_id"] == "bob"

      assert {:ok, fetched} = Registry.fetch(workspace, "eu_hosted")
      assert fetched.capability_floor_acknowledged == false
      assert fetched.capability_floor_acknowledged_by == nil
    end
  end

  describe "a provider whose floor has not been acknowledged" do
    test "is still perfectly usable" do
      # The owner's ruling: nothing refuses a provider over this field. It is
      # a record of the operator's decision, not a condition on the provider.
      workspace = memory_store()

      assert {:ok, stored} = Registry.put(workspace, @hosted)
      assert stored.capability_floor_acknowledged == false
      assert stored.capability_floor_acknowledged_by == nil

      assert {:ok, provider, tier} = Registry.select(workspace, workspace_provider: "eu_hosted")
      assert provider.id == "eu_hosted"
      assert tier == :workspace_setting

      # And nothing pretends an acceptance was made.
      assert audit_events(workspace) == []
    end
  end

  describe "the global tier" do
    setup do
      previous = Application.get_env(:veritas_core, :providers)
      on_exit(fn -> Application.put_env(:veritas_core, :providers, previous) end)
      :ok
    end

    test "carries the acknowledgement from the configuration" do
      Application.put_env(:veritas_core, :providers, [
        {"eu_hosted",
         [
           kind: :hosted,
           adapter: :capability_floor_probe,
           base_url: "https://api.example",
           model: "gpt-4o",
           capability_floor_acknowledged: true,
           capability_floor_acknowledged_by: "the operator"
         ]}
      ])

      assert [provider] = Registry.global()
      assert provider.capability_floor_acknowledged == true
      assert provider.capability_floor_acknowledged_by == %{type: "operator", id: "the operator"}
    end

    test "defaults to false" do
      Application.put_env(:veritas_core, :providers, [
        {"eu_hosted",
         [
           kind: :hosted,
           adapter: :capability_floor_probe,
           base_url: "https://api.example",
           model: "gpt-4o"
         ]}
      ])

      assert [provider] = Registry.global()
      assert provider.capability_floor_acknowledged == false
      assert provider.capability_floor_acknowledged_by == nil
    end
  end

  describe "a store holding pre-existing provider rows" do
    test "still verifies, and the stored rows are not rewritten" do
      workspace = memory_store()

      # A provider row written before the acknowledgement carried an
      # attribution: the old shape, with no "by" and no "at" on it.
      {:ok, _row} =
        Store.transaction(workspace, fn tx ->
          Store.put(tx, :provider, %{
            "id" => "legacy",
            "workspace" => workspace,
            "kind" => "hosted",
            "adapter" => "capability_floor_probe",
            "base_url" => "https://api.example",
            "model" => "gpt-4o",
            "credential_env" => "EXAMPLE_KEY",
            "capability_floor_acknowledged" => true,
            "capabilities" => [:tools]
          })
        end)

      assert {:ok, legacy} = Registry.fetch(workspace, "legacy")
      assert legacy.capability_floor_acknowledged == true
      assert legacy.capability_floor_acknowledged_by == nil

      assert {:ok, :intact} = Audit.verify(workspace)

      # A new acceptance joins the chain without disturbing what is stored.
      {:ok, _} =
        Registry.put(workspace, %{@hosted | capability_floor_acknowledged: true}, actor: @alice)

      assert {:ok, :intact} = Audit.verify(workspace)

      [legacy_row] = Enum.filter(rows(workspace, :provider), &(&1["id"] == "legacy"))
      assert legacy_row["capability_floor_acknowledged"] == true
      refute Map.has_key?(legacy_row, "capability_floor_acknowledged_by")
    end
  end

  describe "the acceptance diff" do
    test "survives the shipped engine, and the chain still verifies" do
      # The diff is the one this registry builds, taken from a real run, so
      # what the engine is given is what the code produces.
      {:ok, ctx} = Conformance.prepare(Veritas.Store.Memory)

      {:ok, _} =
        Registry.put(ctx.workspace, %{@hosted | capability_floor_acknowledged: true},
          actor: @alice
        )

      assert [entry] = audit_events(ctx.workspace)
      diff = entry["diff"]

      assert is_map(diff)
      refute Enum.any?(diff, fn {_key, value} -> is_nil(value) end)

      Conformance.cleanup(ctx)

      # The same diff, written to the engine Veritas ships with.
      {:ok, surreal_ctx} = Conformance.prepare(Veritas.Store.Surreal)
      on_exit(fn -> Conformance.cleanup(surreal_ctx) end)

      {:ok, _audit} =
        Store.transaction(surreal_ctx.workspace, fn tx ->
          Audit.append(tx, surreal_ctx.workspace, %{
            subject: "eu_hosted",
            subject_table: "provider",
            from_state: "not_acknowledged",
            to_state: "acknowledged",
            actor: @alice,
            reason: "the operator accepted the provider's contractual floor",
            correlation_id: nil,
            diff: diff
          })
        end)

      assert {:ok, :intact} = Audit.verify(surreal_ctx.workspace)
    end
  end

  describe "the disclosure" do
    test "names the training risk in plain words" do
      text = Registry.capability_floor_disclosure(@hosted)

      assert text =~ "train"
      assert text =~ "retain"
      assert text =~ "subprocessors"
    end
  end
end
