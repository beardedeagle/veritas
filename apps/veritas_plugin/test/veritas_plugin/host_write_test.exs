defmodule Veritas.Plugin.HostWriteTest do
  @moduledoc """
  A Plugin writes through the **domain**, and not into the store.

  The host is the host's own data plane: the same Workspace scope, the same
  audit rules, the same transactions as the rest of the product. A Plugin
  that wrote to the store directly would have none of those: it could put a
  record into a state the domain would refuse, write a column the domain
  owns, and leave no trace of either in the Audit Log.

  The Audit Log is what says what happened to a Workspace. A write that is
  not in it did not happen as far as anyone can tell — so the write path
  that a Plugin uses has to be the one the domain writes through.

  These tests run against the in-memory Adapter, because what is being
  proved is the **path** the write takes, not the engine underneath it.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.CI
  alias Veritas.Core.Tickets
  alias Veritas.Plugin.Host.Default
  alias Veritas.Store

  setup do
    # Each test has a Workspace of its own: the Audit Log is the Workspace's,
    # and a shared one would mix the tests' writes together.
    workspace = "plugin_write_#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    previous = Application.get_env(:veritas_core, :store)
    Application.put_env(:veritas_core, :store, Veritas.Store.Memory)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:veritas_core, :store)
        value -> Application.put_env(:veritas_core, :store, value)
      end
    end)

    # The registries the domain reads: the CI type, and the one workflow
    # move these tests use.
    {:ok, _type} = CI.register_type(workspace, %{"id" => "server", "name" => "Server"})

    {:ok, _transition} =
      Store.transaction(workspace, fn tx ->
        Store.put(tx, :ticket_transition, %{
          "id" => "incident__new__triaged",
          "ticket_type" => "incident",
          "from_state" => "new",
          "to_state" => "triaged"
        })
      end)

    {:ok,
     workspace: workspace, context: %{plugin_id: "integration.example", workspace: workspace}}
  end

  # Who each Audit Log entry says wrote it: the subject table, the actor's
  # type and the actor's id.
  defp audit_actors(rows) do
    Enum.map(rows, fn row ->
      {row["subject_table"], row["actor_type"], row["actor_id"]}
    end)
  end

  describe "a Configuration Item" do
    test "is written through the domain, and the Audit Log records it", %{
      context: context,
      workspace: workspace
    } do
      assert {:ok, [ci]} =
               Default.write_records(context, :ci, [
                 %{"ci_type" => "server", "name" => "Web 01", "criticality" => "high"}
               ])

      assert ci["name"] == "Web 01"

      # The Audit Log knows the write happened, and who made it: a Plugin
      # cannot write an Audit Log entry in somebody else's name.
      assert {:ok, rows} = Audit.entries(workspace)

      assert [{"ci", "plugin", "integration.example"}] = audit_actors(rows)
    end

    test "a lifecycle state the domain refuses is refused", %{
      context: context,
      workspace: workspace
    } do
      assert {:error, reason} =
               Default.write_records(context, :ci, [
                 %{"ci_type" => "server", "name" => "Web 01", "lifecycle_state" => "not_a_state"}
               ])

      assert reason =~ "lifecycle"

      # Nothing was written, and nothing was recorded.
      assert {:ok, rows} = Audit.entries(workspace)
      assert rows == []
    end

    test "a column the domain owns is not the Plugin's to write", %{
      context: context,
      workspace: workspace
    } do
      assert {:ok, [ci]} =
               Default.write_records(context, :ci, [
                 %{"ci_type" => "server", "name" => "Web 01", "workspace" => "another_workspace"}
               ])

      # The Workspace is the Adapter's business, not the Plugin's.
      assert ci["workspace"] == workspace
    end
  end

  describe "a ticket" do
    test "is opened by the domain, and the Audit Log records it", %{
      context: context,
      workspace: workspace
    } do
      assert {:ok, [ticket]} =
               Default.write_records(context, :ticket, [
                 %{"ticket_type" => "incident", "title" => "Latency", "requester" => "ops"}
               ])

      # The host minted the identifier: a Plugin does not choose it. And the
      # state is the type's initial state, not the Plugin's.
      assert is_binary(ticket["id"])
      assert ticket["state"] == "new"

      assert {:ok, rows} = Audit.entries(workspace)
      assert [{"ticket", "plugin", "integration.example"}] = audit_actors(rows)
    end

    test "is refused without transition authority", %{context: context, workspace: workspace} do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "state" => "triaged"}
               ])

      assert reason =~ "role"
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"
      assert stored["requester"] == "unknown"
      assert {:ok, [_opened, denial]} = Audit.entries(workspace)
      assert denial["to_state"] == "refused"
      assert denial["actor_id"] == "integration.example"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a move the workflow refuses is refused", %{context: context} do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, :illegal_transition} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "state" => "closed"}
               ])
    end

    test "a ticket that does not exist is not created by a write", %{context: context} do
      assert {:error, :not_found} =
               Default.write_records(context, :ticket, [
                 %{"id" => "no_such_ticket", "state" => "triaged"}
               ])
    end
  end

  describe "a ticket write" do
    test "that names content and no state corrects the ticket, and the Audit Log records it", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:ok, [corrected]} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "title" => "Latency in checkout",
                   "description" => "p99 over 2s"
                 }
               ])

      # The ticket says the new thing, and it did not move: a correction is
      # not a move.
      assert corrected["title"] == "Latency in checkout"
      assert corrected["description"] == "p99 over 2s"
      assert corrected["state"] == "new"

      # The store holds it, not only the row the Plugin was handed.
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["title"] == "Latency in checkout"
      assert stored["description"] == "p99 over 2s"

      # The Audit Log records the correction, and says the ticket did not
      # move.
      assert {:ok, rows} = Audit.entries(workspace)
      assert length(rows) == 2

      assert [_opened, correction] = rows
      assert correction["from_state"] == "new"
      assert correction["to_state"] == "new"

      assert correction["diff"] == %{
               "title" => "Latency in checkout",
               "description" => "p99 over 2s"
             }

      assert {"ticket", "plugin", "integration.example"} in audit_actors(rows)
    end

    test "that names to_state still requires transition authority", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "to_state" => "triaged"}
               ])

      assert reason =~ "role"
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"
      assert stored["requester"] == "unknown"
      assert {:ok, [_opened, denial]} = Audit.entries(workspace)
      assert denial["to_state"] == "refused"
      assert denial["actor_id"] == "integration.example"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "that names content and the write's own fields corrects the ticket", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:ok, [corrected]} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "title" => "Latency in checkout",
                   "reason" => "the operator asked",
                   "correlation_id" => "corr-1",
                   "actor" => "someone-else"
                 }
               ])

      assert corrected["title"] == "Latency in checkout"

      assert {:ok, rows} = Audit.entries(workspace)
      assert [_opened, correction] = rows

      # The fields that describe the write are the write's, not the
      # ticket's: they are recorded against the correction, not written
      # onto the ticket.
      assert correction["diff"] == %{"title" => "Latency in checkout"}
      assert correction["reason"] == "the operator asked"
      assert correction["correlation_id"] == "corr-1"

      # And a Plugin cannot write an Audit Log entry in somebody else's
      # name, not by sending an actor of its own.
      assert correction["actor_type"] == "plugin"
      assert correction["actor_id"] == "integration.example"
    end

    test "that names content for a ticket that does not exist is refused", %{context: context} do
      assert {:error, :not_found} =
               Default.write_records(context, :ticket, [
                 %{"id" => "no_such_ticket", "title" => "Latency"}
               ])
    end

    test "cannot smuggle policy notes or authority through record fields", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "state" => "triaged",
                   "title" => "Changed",
                   "requester" => "ops",
                   "actor" => "admin",
                   "note" => %{"separation_of_duty" => "bypass"}
                 }
               ])

      assert reason =~ "role"
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"
      assert stored["requester"] == "unknown"
      assert {:ok, [_opened, denial]} = Audit.entries(workspace)
      assert denial["to_state"] == "refused"
      assert denial["actor_id"] == "integration.example"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "that requests a move and content changes writes neither without authority", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "state" => "triaged",
                   "title" => "Changed",
                   "requester" => "ops",
                   "actor" => "admin",
                   "note" => %{"separation_of_duty" => "bypass"}
                 }
               ])

      assert reason =~ "role"
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"
      assert stored["requester"] == "unknown"
      assert {:ok, [_opened, denial]} = Audit.entries(workspace)
      assert denial["to_state"] == "refused"
      assert denial["actor_id"] == "integration.example"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "that names a state the workflow refuses is refused, and writes nothing", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, :illegal_transition} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "state" => "closed", "title" => "Not written"}
               ])

      # Neither the move nor the content it carried was written.
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"

      assert {:ok, rows} = Audit.entries(workspace)
      assert length(rows) == 1
    end

    test "that repeats existing content still requires authority for the move", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "state" => "triaged"}
               ])

      assert reason =~ "role"
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["state"] == "new"
      assert stored["title"] == "Latency"
      assert stored["requester"] == "unknown"
      assert {:ok, [_opened, denial]} = Audit.entries(workspace)
      assert denial["to_state"] == "refused"
      assert denial["actor_id"] == "integration.example"
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "that names no state and a field the domain does not own is refused by name", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency", "requester" => "ops"}
        ])

      assert {:error, {:not_updatable, "requester"}} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "requester" => "someone else"}
               ])

      # The requester is not the Plugin's to write, and nothing was written.
      assert {:ok, stored} = Tickets.read(workspace, ticket["id"])
      assert stored["requester"] == "ops"

      assert {:ok, rows} = Audit.entries(workspace)
      assert length(rows) == 1
    end

    test "that names content the ticket already holds is refused as a no-change", %{
      context: context,
      workspace: workspace
    } do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, :no_change} =
               Default.write_records(context, :ticket, [
                 %{"id" => ticket["id"], "title" => "Latency"}
               ])

      assert {:ok, rows} = Audit.entries(workspace)
      assert length(rows) == 1
    end

    test "that names nothing at all is still refused", %{context: context, workspace: workspace} do
      {:ok, [ticket]} =
        Default.write_records(context, :ticket, [
          %{"ticket_type" => "incident", "title" => "Latency"}
        ])

      assert {:error, :no_state} =
               Default.write_records(context, :ticket, [%{"id" => ticket["id"]}])

      assert {:ok, rows} = Audit.entries(workspace)
      assert length(rows) == 1
    end
  end
end
