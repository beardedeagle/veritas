defmodule Veritas.Core.UpgradeRegressionTest do
  @moduledoc """
  The edges that the CMDB work must not break.

  Two things have to keep working while three teams build on the datastore:

    * **the Audit Log chain has to survive a migration.** The migration is the
      upgrade path (`docs/07`): it applies the current schema and backfills
      the rows an earlier schema wrote. A migration that quietly breaks the
      chain is worse than a migration that fails, because the chain is what
      makes the Audit Log worth keeping.

    * **an illegal transition has to stay illegal, and has to write nothing.**
      The CMDB adds ways to write to the store. If any of them could append
      to the Audit Log, the chain would grow entries that no transition
      produced — and a chain that records something that did not happen is
      not evidence of anything.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Tickets}

  @actor %{type: "user", id: "regression"}

  describe "the Audit Log chain across a migration" do
    test "the chain still verifies after the Workspace is re-migrated", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      {:ok, _} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      {:ok, _} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "in_progress",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      assert {:ok, :intact} = Audit.verify(workspace)

      # The migration runs again over a Workspace that already holds rows and
      # an Audit Log. This is the upgrade path: the same Workspace, the same
      # data, the current schema.
      assert :ok = Veritas.Store.Surreal.migrate(workspace)

      assert {:ok, :intact} = Audit.verify(workspace),
             "the migration must not break the Audit Log chain"

      # And the rows are still there, and still the same rows.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "in_progress"

      assert {:ok, events} = Audit.entries(workspace)
      assert length(events) == 3
    end

    test "the migration is idempotent", %{workspace: workspace} do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert :ok = Veritas.Store.Surreal.migrate(workspace)
      assert :ok = Veritas.Store.Surreal.migrate(workspace)

      assert {:ok, :intact} = Audit.verify(workspace)
      assert {:ok, events} = Audit.entries(workspace)
      assert length(events) == 1
    end
  end

  describe "an illegal transition writes nothing" do
    test "the state, the chain and the store are all untouched", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      before_events = Audit.entries(workspace)
      before_row = Tickets.read(workspace, ticket["id"])

      # `closed` is not reachable from `new`.
      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "closed",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      assert Tickets.read(workspace, ticket["id"]) == before_row
      assert Audit.entries(workspace) == before_events
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a transition to a state that is not a ticket state at all is refused", %{
      workspace: workspace
    } do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      before_events = Audit.entries(workspace)

      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "escalated",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      assert Audit.entries(workspace) == before_events
    end
  end

  defp attrs do
    %{"title" => "Regression ticket", "requester" => "regression", "priority" => "medium"}
  end
end
