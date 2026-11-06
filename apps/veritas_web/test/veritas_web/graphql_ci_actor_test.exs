defmodule Veritas.Web.GraphQLCIActorTest do
  @moduledoc """
  CI creation through GraphQL is attributed to the authenticated Principal.
  The schema deliberately has no caller-supplied actor argument.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  alias Veritas.Core.CI
  alias Veritas.Web.GraphQL.Schema

  test "createCi records the resolved Principal as its actor", %{workspace: workspace} do
    principal = principal(workspace, roles: ["CI Steward"])

    {:ok, result} =
      Absinthe.run(
        """
        mutation {
          createCi(
            workspace: "#{workspace}"
            ciType: "server"
            name: "attributed-01"
          ) { id name }
        }
        """,
        Schema,
        context: %{principal: principal}
      )

    assert result[:errors] == nil
    id = result.data["createCi"]["id"]
    assert {:ok, _row} = CI.get(workspace, id)

    event =
      workspace
      |> audit_events()
      |> Enum.find(&(&1["subject_table"] == "ci" and &1["subject"] == id))

    assert event["actor_type"] == "user"
    assert event["actor_id"] == principal.id
  end

  test "a caller cannot supply or forge the actor", %{workspace: workspace} do
    principal = principal(workspace, roles: ["CI Steward"])

    {:ok, result} =
      Absinthe.run(
        """
        mutation {
          createCi(
            workspace: "#{workspace}"
            ciType: "server"
            name: "forged-01"
            actor: "somebody-else"
          ) { id }
        }
        """,
        Schema,
        context: %{principal: principal}
      )

    assert result[:errors]
    assert result[:data] == nil

    # Nothing was created: not a CI, and not an Audit Log entry. A refused
    # mutation that left a row behind would be a CI nobody asked for.
    assert {:ok, rows} = CI.list(workspace)
    assert Enum.map(rows, & &1["name"]) == []
    assert Enum.all?(audit_events(workspace), &(&1["subject_table"] != "ci"))
  end
end
