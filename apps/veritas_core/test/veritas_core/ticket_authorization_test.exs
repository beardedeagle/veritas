defmodule Veritas.Core.TicketAuthorizationTest do
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Principal, Tickets}

  setup %{workspace: workspace} do
    {:ok, ticket} =
      Tickets.open(workspace, "incident", %{"requester" => "requester"}, %{
        type: "user",
        id: "author"
      })

    %{ticket: ticket}
  end

  test "raw audit actors cannot authorize transitions", %{workspace: workspace, ticket: ticket} do
    assert {:error, reason} =
             Tickets.transition(workspace, ticket["id"], "acknowledged", %{
               type: "user",
               id: "forged"
             })

    assert reason =~ "no principal"
    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
    assert [_opened, denial] = audit_events(workspace)
    assert denial["to_state"] == "refused"
    assert denial["actor_id"] == "unknown"
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "role and workspace denials are audited without changing the ticket", %{
    workspace: workspace,
    ticket: ticket
  } do
    for principal <- [
          Principal.new("auditor", workspace, [:auditor]),
          Principal.new("agent", workspace, [:incident_manager], kind: :agentic),
          Principal.new("elsewhere", "other", [:incident_manager])
        ] do
      assert {:error, _reason} =
               Tickets.transition(workspace, ticket["id"], "acknowledged", principal)
    end

    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
    assert length(audit_events(workspace)) == 4
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "authorized moves derive attribution from the principal", %{
    workspace: workspace,
    ticket: ticket
  } do
    principal = Principal.new("manager", workspace, [:incident_manager])

    assert {:ok, %{"state" => "acknowledged"}} =
             Tickets.transition(workspace, ticket["id"], "acknowledged", principal)

    assert [_opened, move] = audit_events(workspace)
    assert move["actor_type"] == "user"
    assert move["actor_id"] == "manager"
  end

  test "author and requester cannot approve their own change", %{workspace: workspace} do
    Application.put_env(:veritas_core, :deployment_profile, :enterprise)
    on_exit(fn -> Application.delete_env(:veritas_core, :deployment_profile) end)

    {:ok, ticket} =
      Tickets.open(workspace, "change", %{"requester" => "requester"}, %{
        type: "user",
        id: "author"
      })

    manager = Principal.new("manager", workspace, [:change_manager])
    assert {:ok, _} = Tickets.transition(workspace, ticket["id"], "submitted", manager)

    for id <- ["author", "requester"] do
      principal = Principal.new(id, workspace, [:change_manager])

      assert {:error, reason} =
               Tickets.transition(workspace, ticket["id"], "authorized", principal,
                 note: %{"deployment_profile" => "forged"}
               )

      assert reason =~ "separation of duty"
    end

    assert {:ok, %{"state" => "submitted"}} = Tickets.read(workspace, ticket["id"])
    assert {:ok, _} = Tickets.transition(workspace, ticket["id"], "authorized", manager)
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "the agent write tool cannot bypass the approved-run boundary", %{
    workspace: workspace,
    ticket: ticket
  } do
    tool = Enum.find(Veritas.Agentic.Tool.Core.specs(), &(&1.name == "transition_incident"))

    assert {:error, :approval_required} =
             tool.handler.(%{"id" => ticket["id"], "to_state" => "acknowledged"}, %{
               workspace: workspace,
               actor: %{type: "user", id: "admin"}
             })

    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
  end

  test "the home-lab exception is recorded by the domain", %{workspace: workspace} do
    Application.put_env(:veritas_core, :deployment_profile, :home_lab)
    on_exit(fn -> Application.delete_env(:veritas_core, :deployment_profile) end)

    {:ok, ticket} =
      Tickets.open(workspace, "change", %{"requester" => "admin"}, %{type: "user", id: "admin"})

    admin = Principal.new("admin", workspace, [:platform_admin])
    assert {:ok, _} = Tickets.transition(workspace, ticket["id"], "submitted", admin)

    assert {:ok, _} =
             Tickets.transition(workspace, ticket["id"], "authorized", admin,
               note: %{"deployment_profile" => "forged"}
             )

    move = List.last(audit_events(workspace))
    assert move["diff"]["deployment_profile"] != "forged"
    assert move["diff"]["separation_of_duty"] =~ "not applied"
  end
end
