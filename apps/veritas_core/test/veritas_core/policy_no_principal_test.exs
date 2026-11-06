defmodule Veritas.Core.PolicyNoPrincipalTest do
  @moduledoc """
  A request that carries **no principal** is refused, and the refusal is
  recorded.

  `Policy.authorize/3` says a Principal may be `nil`, and an unauthenticated
  request is refused — but the refusal was written to the Audit Log by
  `record_denial/4`, whose only clause head matched a `%Principal{}`. A guard
  that fails at a clause head raises **at the call site**, so the `rescue` in
  the body never ran: the refusal crashed the caller instead of being
  returned. An unauthenticated GraphQL request could take the request
  pipeline down.

  These tests are about the observable contract: a refusal comes back, and
  the Audit Log has it.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Policy}

  describe "a request that carries no principal" do
    test "is refused, and not a crash", %{workspace: workspace} do
      assert {:deny, reason} = Policy.authorize(nil, "ticket:write", %{workspace: workspace})

      assert reason == "the request carries no principal"
    end

    test "is refused with no Workspace either" do
      # Nothing to attribute it to and nowhere to write it: the refusal still
      # comes back, and the Log says it could not be written.
      assert {:deny, reason} = Policy.authorize(nil, "ticket:write", %{})

      assert reason == "the request carries no principal"
    end

    test "the refusal is recorded in the Audit Log", %{workspace: workspace} do
      {:ok, before} = Audit.entries(workspace)

      assert {:deny, _reason} = Policy.authorize(nil, "ticket:write", %{workspace: workspace})

      {:ok, after_entries} = Audit.entries(workspace)

      # The new row is the one the refusal added.
      denial = Enum.find(after_entries -- before, &(&1["to_state"] == "refused"))

      assert denial, "the refusal was not written to the Audit Log"
      assert denial["reason"] == "the request carries no principal"

      # And it is attributed to nobody, in the shape the core already uses.
      assert denial["actor_type"] == "unknown"
      assert denial["actor_id"] == "unknown"
      assert denial["subject"] == "unknown"
      assert denial["subject_table"] == "principal"
    end

    test "every capability is refused, not just one" do
      for capability <- ["ticket:write", "ticket:transition", "account:administrate"] do
        assert {:deny, reason} = Policy.authorize(nil, capability, %{})

        assert reason == "the request carries no principal"
      end
    end
  end
end
