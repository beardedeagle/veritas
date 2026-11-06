defmodule Veritas.Core.CliTicketUpdateTest do
  @moduledoc """
  `mix veritas.cli update`: a ticket's content, changed from the command line.

  The parity contract puts *update* on every surface (`docs/04`, "CLI/API
  Parity"), and the command line is one of them. What is proved here is that
  the command is the same operation as the domain's and not a second, looser
  one: it changes the ticket, it records the change in the Audit Log against
  the actor the operator named, and it refuses — by name — a field the domain
  does not let an update own.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Tickets}

  setup %{workspace: workspace} do
    {:ok, ticket: open_incident(workspace)}
  end

  describe "the update" do
    test "changes the title and the description", %{workspace: workspace, ticket: ticket} do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          "Checkout is failing for every customer",
          "--description",
          "The primary is gone",
          "--actor",
          "u1"
        ])

      assert code == 0, output
      assert Enum.join(output, "\n") =~ "updated"

      # The row the store holds says the same thing.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == "Checkout is failing for every customer"
      assert row["description"] == "The primary is gone"
    end

    test "leaves the state where the workflow put it", %{workspace: workspace, ticket: ticket} do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          "Something else"
        ])

      assert code == 0, output

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == ticket["state"]
    end

    test "records the change against the actor the operator named", %{
      workspace: workspace,
      ticket: ticket
    } do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          "Something else",
          "--actor",
          "u-42"
        ])

      assert code == 0, output

      assert [open_event, update_event] = audit_events(workspace)

      assert update_event["subject"] == ticket["id"]
      assert update_event["subject_table"] == "ticket"
      assert update_event["actor_type"] == "user"
      assert update_event["actor_id"] == "u-42"

      # The ticket did not move: the update says so, and the chain says the
      # update followed the opening.
      assert update_event["from_state"] == ticket["state"]
      assert update_event["to_state"] == ticket["state"]
      assert update_event["prev_hash"] == open_event["hash"]
      assert update_event["diff"]["title"] == "Something else"

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "answers in JSON when it is asked to", %{workspace: workspace, ticket: ticket} do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          "Something else",
          "--json"
        ])

      assert code == 0, output

      assert %{"ticket" => %{"title" => "Something else"}} = json_payload(output)
    end
  end

  describe "the refusals" do
    test "an update that changes nothing is refused", %{workspace: workspace, ticket: ticket} do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          ticket["title"],
          "--actor",
          "u1"
        ])

      assert code == 2
      printed = Enum.join(output, "\n")
      assert printed =~ "refused"
      assert printed =~ "the update changes nothing"

      # Nothing was written, and nothing was recorded.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == ticket["title"]
      assert length(audit_events(workspace)) == 1
    end

    test "a field the domain does not own is refused, and named", %{
      workspace: workspace,
      ticket: ticket
    } do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--state",
          "acknowledged",
          "--actor",
          "u1"
        ])

      assert code == 2

      printed = Enum.join(output, "\n")
      assert printed =~ "state"
      assert printed =~ "not updatable"

      # Nothing was written, and nothing was recorded.
      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == ticket["state"]
      assert length(audit_events(workspace)) == 1
    end

    test "a named to-state is refused without changing the title or the state", %{
      workspace: workspace,
      ticket: ticket
    } do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          ticket["id"],
          "--title",
          "This title must not be written",
          "--to-state",
          "acknowledged",
          "--actor",
          "u1"
        ])

      assert code == 2

      printed = Enum.join(output, "\n")
      assert printed =~ "to_state"
      assert printed =~ "not updatable"

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["title"] == ticket["title"]
      assert row["state"] == ticket["state"]
      assert length(audit_events(workspace)) == 1
    end

    test "a ticket that does not exist is refused", %{workspace: workspace} do
      {code, output} =
        cli([
          "update",
          "--workspace",
          workspace,
          "--id",
          "nope",
          "--title",
          "Something else",
          "--actor",
          "u1"
        ])

      assert code == 2
      assert Enum.join(output, "\n") =~ "no such record"

      # The opening is the only entry: the refused update wrote nothing.
      assert length(audit_events(workspace)) == 1
    end
  end

  describe "the help" do
    test "names the verb" do
      {code, output} = cli([])

      assert code == 1

      printed = Enum.join(output, "\n")
      assert printed =~ ~r/^\s+update\s+--workspace/m
      assert printed =~ "--description"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Runs the CLI and returns its exit code and the messages it printed.
  defp cli(args) do
    Process.register(self(), :mix_shell)
    Mix.shell(Mix.Shell.Process)

    try do
      code =
        try do
          Mix.Tasks.Veritas.Cli.run(args)
          0
        catch
          :exit, {:shutdown, code} -> code
          :exit, {reason, _} -> reason
          :exit, reason -> reason
        end

      {code, collect()}
    after
      case Process.info(self(), :registered_name) do
        {:registered_name, :mix_shell} -> Process.unregister(:mix_shell)
        _ -> :ok
      end
    end
  end

  defp collect do
    receive do
      {:mix_shell, :info, [message]} -> [message | collect()]
      {:mix_shell, :error, [message]} -> [message | collect()]
    after
      0 -> []
    end
  end

  # The JSON the command printed, out of everything it printed.
  defp json_payload(messages) do
    Enum.find_value(messages, fn message ->
      case Jason.decode(message) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> nil
      end
    end)
  end
end
