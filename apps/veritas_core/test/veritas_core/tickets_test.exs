defmodule Veritas.Core.TicketsTest do
  @moduledoc """
  The contract the ticket context must honour.

  These tests run against the **shipped** Adapter — SurrealDB — which the
  suite starts for the run, or which `VERITAS_SURREAL_URL` names. The
  datastore is a **Default**, so swapping the engine is a configuration change
  and no domain code changes; the in-memory Adapter is held to the same port
  contract by its own conformance run
  (`veritas_core/store/memory_conformance_test.exs`).
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Tickets}

  @actor %{type: "user", id: "u1"}

  describe "opening a ticket" do
    test "writes the ticket, its detail row and its audit entry", %{workspace: workspace} do
      assert {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert ticket["ticket_type"] == "incident"
      assert ticket["state"] == "new"
      assert ticket["sequence"] |> is_integer()

      # The detail row exists and points at the ticket.
      assert [detail] = rows(workspace, :incident)
      assert detail["ticket_id"] == ticket["id"]

      # And the Audit Log has exactly one event, about that ticket.
      assert [event] = audit_events(workspace)
      assert event["subject"] == ticket["id"]
      assert event["from_state"] == nil
      assert event["to_state"] == "new"
      assert event["prev_hash"] == nil
      assert is_binary(event["hash"])
    end

    test "records the first audit event with no prior hash", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert [event] = audit_events(workspace)
      assert event["subject"] == ticket["id"]
      assert event["from_state"] == nil
      assert event["to_state"] == "new"
      assert event["prev_hash"] == nil
      assert is_binary(event["hash"])
    end

    test "refuses an unknown ticket type without writing anything", %{workspace: workspace} do
      assert {:error, :unknown_ticket_type} =
               Tickets.open(workspace, "not_a_type", attrs(), @actor)

      assert audit_events(workspace) == []
      assert rows(workspace, :ticket) == []
    end
  end

  describe "transitioning a ticket" do
    setup %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      %{ticket: ticket}
    end

    test "moves the ticket and appends to the audit chain", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:ok, moved} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "acknowledged",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      assert moved["state"] == "acknowledged"

      assert [first, second] = audit_events(workspace)
      assert second["from_state"] == "new"
      assert second["to_state"] == "acknowledged"
      assert second["prev_hash"] == first["hash"]
      assert second["sequence"] > first["sequence"]
    end

    test "refuses an illegal transition and writes nothing", %{
      workspace: workspace,
      ticket: ticket
    } do
      before = audit_events(workspace)

      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "closed",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      assert length(audit_events(workspace)) == length(before),
             "a refused transition must not append to the audit chain"

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "new"
    end

    test "refuses a transition to a state the ticket type does not define", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "scheduled",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )
    end

    test "reports a missing ticket rather than inventing one", %{workspace: workspace} do
      assert {:error, :not_found} =
               Tickets.transition(
                 workspace,
                 "nope",
                 "acknowledged",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )
    end
  end

  describe "updating a ticket's content" do
    setup %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      %{ticket: ticket}
    end

    test "changes the title and the description", %{workspace: workspace, ticket: ticket} do
      assert {:ok, updated} =
               Tickets.update(
                 workspace,
                 ticket["id"],
                 %{
                   "title" => "Checkout is failing for every customer",
                   "description" => "The primary is gone"
                 },
                 @actor
               )

      assert updated["title"] == "Checkout is failing for every customer"
      assert updated["description"] == "The primary is gone"

      # The row the store holds says the same thing.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == "Checkout is failing for every customer"
      assert row["description"] == "The primary is gone"
    end

    test "leaves the state where the workflow put it", %{workspace: workspace, ticket: ticket} do
      assert {:ok, updated} =
               Tickets.update(workspace, ticket["id"], %{"title" => "Something else"}, @actor)

      assert updated["state"] == ticket["state"]
    end

    test "records the change in the Audit Log as a change and not a move", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:ok, _updated} =
               Tickets.update(workspace, ticket["id"], %{"title" => "Something else"}, @actor)

      assert [open_event, update_event] = audit_events(workspace)

      assert update_event["subject"] == ticket["id"]
      assert update_event["subject_table"] == "ticket"
      assert update_event["actor_type"] == "user"
      assert update_event["actor_id"] == "u1"

      # The ticket did not move: the update says so, and the chain says the
      # update followed the opening.
      assert update_event["from_state"] == ticket["state"]
      assert update_event["to_state"] == ticket["state"]
      assert update_event["prev_hash"] == open_event["hash"]
      assert update_event["diff"]["title"] == "Something else"

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "refuses a field the workflow owns, and names it", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:error, {:not_updatable, "state"}} =
               Tickets.update(workspace, ticket["id"], %{"state" => "acknowledged"}, @actor)

      # Nothing was written, and nothing was recorded.
      assert length(audit_events(workspace)) == 1

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "new"
    end

    test "refuses an update that changes nothing", %{workspace: workspace, ticket: ticket} do
      assert {:error, :no_change} =
               Tickets.update(workspace, ticket["id"], %{"title" => ticket["title"]}, @actor)

      assert length(audit_events(workspace)) == 1
    end

    test "a value that is not set is not a change", %{workspace: workspace, ticket: ticket} do
      assert {:error, :no_change} =
               Tickets.update(workspace, ticket["id"], %{"title" => nil}, @actor)

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == ticket["title"]
    end

    test "takes the field names the module takes everywhere else", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:ok, updated} = Tickets.update(workspace, ticket["id"], %{title: "By atom"}, @actor)
      assert updated["title"] == "By atom"
    end

    test "reports a missing ticket rather than inventing one", %{workspace: workspace} do
      assert {:error, :not_found} =
               Tickets.update(workspace, "nope", %{"title" => "x"}, @actor)
    end
  end

  describe "assigning a ticket" do
    setup %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      %{ticket: ticket}
    end

    test "sets the assignee and appends to the audit chain", %{
      workspace: workspace,
      ticket: ticket
    } do
      assert {:ok, assigned} = Tickets.assign(workspace, ticket["id"], "u2", @actor)
      assert assigned["assignee"] == "u2"

      # The row the store holds says the same thing.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["assignee"] == "u2"

      assert [open_event, assign_event] = audit_events(workspace)
      assert assign_event["subject"] == ticket["id"]
      assert assign_event["subject_table"] == "ticket"
      assert assign_event["actor_type"] == "user"
      assert assign_event["actor_id"] == "u1"
      assert assign_event["diff"]["assignee"] == "u2"
      assert assign_event["prev_hash"] == open_event["hash"]

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "leaves the state where the workflow put it", %{workspace: workspace, ticket: ticket} do
      assert {:ok, assigned} = Tickets.assign(workspace, ticket["id"], "u2", @actor)
      assert assigned["state"] == ticket["state"]

      # The Audit Log says the same: the ticket did not move.
      assert [_open_event, assign_event] = audit_events(workspace)
      assert assign_event["from_state"] == ticket["state"]
      assert assign_event["to_state"] == ticket["state"]
    end

    test "records the reason and the correlation id", %{workspace: workspace, ticket: ticket} do
      assert {:ok, _assigned} =
               Tickets.assign(workspace, ticket["id"], "u2", @actor,
                 reason: "out of hours handover",
                 correlation_id: "corr-1"
               )

      assert [_open_event, assign_event] = audit_events(workspace)
      assert assign_event["reason"] == "out of hours handover"
      assert assign_event["correlation_id"] == "corr-1"
    end

    test "refuses an assignment that changes nothing", %{workspace: workspace, ticket: ticket} do
      assert {:ok, _assigned} = Tickets.assign(workspace, ticket["id"], "u2", @actor)

      assert {:error, :no_change} = Tickets.assign(workspace, ticket["id"], "u2", @actor)

      # Nothing was recorded: an operation that changed nothing must not append
      # an entry claiming that it did.
      assert length(audit_events(workspace)) == 2
    end

    test "reports a missing ticket rather than inventing one", %{workspace: workspace} do
      assert {:error, :not_found} = Tickets.assign(workspace, "nope", "u2", @actor)
    end
  end

  describe "the transition table" do
    test "is the only source of legal transitions", %{workspace: workspace} do
      assert Tickets.available_transitions(workspace, "incident", "new") ==
               ["acknowledged", "cancelled"]

      assert Tickets.available_transitions(workspace, "incident", "resolved") ==
               ["closed", "in_progress"]

      assert Tickets.available_transitions(workspace, "incident", "closed") == []
    end

    test "is scoped by ticket type", %{workspace: workspace} do
      assert Tickets.available_transitions(workspace, "change", "new") == []
    end
  end

  describe "the audit chain" do
    test "links every event to its predecessor", %{workspace: workspace} do
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

      events = audit_events(workspace)
      assert length(events) == 3

      assert Enum.at(events, 0)["prev_hash"] == nil
      assert Enum.at(events, 1)["prev_hash"] == Enum.at(events, 0)["hash"]
      assert Enum.at(events, 2)["prev_hash"] == Enum.at(events, 1)["hash"]
    end

    test "verifies as intact", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      {:ok, _} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "the port" do
    test "is the only route to the datastore" do
      # The Adapter is a configuration change, not a code change: the suite
      # installed the shipped one, and the domain reaches the datastore only
      # through the port.
      assert Veritas.Store.adapter() == Veritas.Store.Surreal
    end

    test "declares every callback the context relies on" do
      callbacks = Veritas.Store.behaviour_info(:callbacks)
      names = Enum.map(callbacks, fn {name, arity} -> "#{name}/#{arity}" end)

      for required <- [
            "transaction",
            "fetch",
            "put",
            "list",
            "next_sequence",
            "append_audit",
            "describe"
          ] do
        assert Enum.any?(names, &String.starts_with?(&1, required)),
               "the port must declare #{required}/"
      end
    end
  end

  defp attrs do
    %{"title" => "Checkout is down", "requester" => "u1", "priority" => "high"}
  end
end
