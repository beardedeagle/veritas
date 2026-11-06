defmodule Veritas.Core.StoreErrorTest do
  @moduledoc """
  A store error must name the statement that failed.

  `docs/32` §Record identity says the port's identifiers are logical and that
  physical record ids are Adapter-internal — so when a write fails, the only
  thing that says *what* failed is the error itself. A store error that names
  no statement can only be diagnosed by reading the wire, which is not a thing
  a test can do.

  This test pins the requirement. It was written while the requirement was
  unmet, and it was red then; the Adapter now carries the failing statement in
  the error's details, and the test is green. It stays, because a requirement
  that nothing tests is a requirement nobody has to keep.

  The assertion is deliberately shape-agnostic. It does not say *where* the
  statement lives in the error — a key, a field of the details, the message
  itself — only that it is there. The Adapter is free to choose.
  """
  use Veritas.Core.Test.StoreCase

  alias Veritas.Core.Tickets

  @actor %{type: "user", id: "u1"}

  describe "the error names the statement" do
    test "a statement the schema refuses is named in the error", %{workspace: workspace} do
      # A priority the schema's ASSERT refuses, so the engine rejects the
      # statement. Deterministic: the same write is refused every time.
      result =
        Veritas.Store.transaction(workspace, fn tx ->
          Veritas.Store.put(tx, :ticket, %{
            "id" => "diagnostic_ticket",
            "workspace" => workspace,
            "ticket_type" => "incident",
            "state" => "new",
            "title" => "A ticket the schema refuses",
            "description" => "",
            "priority" => "not-a-priority",
            "requester" => "u1",
            "sequence" => 1
          })
        end)

      assert {:error, error} = result

      details = inspect(error.details, limit: :infinity, printable_limit: :infinity)

      assert details =~ "UPSERT",
             """
             the store error does not name the statement that failed.

             A store error that names no statement can only be diagnosed by
             reading the wire, and the requirement is that it names it.

             code:    #{inspect(error.code)}
             message: #{inspect(error.message)}
             details: #{details}
             """

      assert details =~ "ticket",
             "the store error does not name the statement that failed: #{details}"
    end

    test "a statement the domain never sends is not a store error", %{workspace: workspace} do
      # The other half of the same requirement: a refusal by the domain is not
      # a store error, and must not be dressed up as one. A refused transition
      # writes nothing, and says so in the domain's own vocabulary.
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "escalated",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )
    end
  end

  defp attrs do
    %{"title" => "A ticket the schema refuses", "requester" => "u1", "priority" => "medium"}
  end
end
