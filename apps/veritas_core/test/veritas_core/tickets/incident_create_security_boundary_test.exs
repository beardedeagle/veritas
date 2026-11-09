defmodule Veritas.Core.Tickets.IncidentCreateSecurityBoundaryTest do
  @moduledoc """
  Upstream Workspace, live-grant and requester-field creation refusals.

  Calls public Tickets.open/6 with real Principals and Memory transactions.
  In particular, service intake reaches the live-grant gate rather than the
  human-only Workflows precondition. Setup creates no Incident or workflow;
  no role, grant, authorization decision or deployment profile is fabricated.

  Supplements the frozen six-case creation regression; it does not replace
  that RED/GREEN proof. Compilation and execution belong to root. These are
  unrun controls, not real-Surreal or full-candidate acceptance evidence.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @state_tables [:ticket, :incident, :sla_clock, :incident_hold_episode, :workflow_run, :workflow]

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = StoreCase.unique_workspace()
    other_workspace = StoreCase.unique_workspace()

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspaces([workspace, other_workspace])
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    {:ok, workspace: workspace, other_workspace: other_workspace}
  end

  # Discriminates removing/bypassing the Workspace check before human create
  # authorization. The foreign actor otherwise holds legitimate desk authority.
  test "a trusted desk Principal cannot create in a different Workspace", ctx do
    principal =
      Principal.new("foreign_create_desk", ctx.other_workspace, [:service_desk_agent], kind: :human)

    assert principal.workspace != ctx.workspace

    assert_audited_refusal(ctx, principal, intake(), [], "user",
      "The Principal does not act in this Workspace."
    )
  end

  # Discriminates permitting roleless service intake without the host's live
  # verifier. Identity, actor kind and ordinary content are valid; only that
  # verifier is absent. No Workflows human gate or fake successful grant is used.
  test "a roleless machine cannot create a draft without a live grant verifier", ctx do
    principal = Principal.new("unverified_create_service", ctx.workspace, [], kind: :service)
    assert principal.kind == :service
    assert principal.roles == []

    assert_audited_refusal(ctx, principal, intake(), [], "service",
      "A machine grant permits draft intake and ordinary content only."
    )
  end

  # Discriminates allowing top-level priority to bypass the requester's field
  # gate, including a create allow placed ahead of classification authority.
  test "a requester cannot select explicit priority during intake", ctx do
    principal = Principal.new("priority_create_requester", ctx.workspace, [:requester], kind: :human)
    attrs = Map.put(intake(), "priority", "P1")

    assert_audited_refusal(ctx, principal, attrs, [], "user",
      "The requester cannot classify an Incident or select its priority."
    )
  end

  # Discriminates skipping override role authority or treating approve=true as
  # authority. The override object is valid, but this human is not a manager.
  test "a requester cannot submit a priority override even with an approval flag", ctx do
    principal = Principal.new("override_create_requester", ctx.workspace, [:requester], kind: :human)

    attrs =
      Map.put(intake(), "domain_fields", %{
        "priority_override" => %{"reason" => "Test-only unauthorized requester override"}
      })

    assert_audited_refusal(ctx, principal, attrs, [approve: true], "user",
      "A priority override requires Service Desk Manager approval."
    )
  end

  defp assert_audited_refusal(ctx, principal, attrs, opts, actor_type, expected_reason) do
    before = persisted_state(ctx.workspace)
    other_before = persisted_state(ctx.other_workspace)
    Enum.each(before, fn {_table, rows} -> assert rows == [] end)
    Enum.each(other_before, fn {_table, rows} -> assert rows == [] end)
    assert {:ok, audit_before} = Audit.entries(ctx.workspace)
    assert {:ok, other_audit_before} = Audit.entries(ctx.other_workspace)

    # Host-derived attribution is separate from trusted authority. The public
    # wrapper commits the checked denial sentinel, not an Incident creation.
    assert {:error, ^expected_reason} =
             Tickets.open(ctx.workspace, "incident", attrs, principal,
               Principal.audit_actor(principal), opts
             )

    assert persisted_state(ctx.workspace) == before
    assert persisted_state(ctx.other_workspace) == other_before
    assert {:ok, events} = Audit.entries(ctx.workspace)
    assert [refusal] = events -- audit_before
    assert refusal["workspace"] == ctx.workspace
    assert refusal["subject_table"] == "ticket"
    assert is_binary(refusal["subject"]) and refusal["subject"] != ""
    assert refusal["from_state"] == "new"
    assert refusal["to_state"] == "refused"
    assert refusal["actor_type"] == actor_type
    assert refusal["actor_id"] == principal.id
    assert refusal["reason"] == expected_reason
    assert refusal["diff"]["capability"] == "ticket:write"
    assert refusal["diff"]["operation"] == "create"
    assert refusal["diff"]["ticket_type"] == "incident"
    assert refusal["diff"]["refusal"] == "not_authorised"

    # A refused draft has an audit subject ID, not a persisted orphan ticket.
    assert {:ok, nil} =
             Store.transaction(ctx.workspace, fn tx ->
               Store.fetch(tx, :ticket, refusal["subject"])
             end)

    assert {:ok, other_events} = Audit.entries(ctx.other_workspace)
    assert other_events == other_audit_before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp persisted_state(workspace) do
    assert {:ok, snapshot} =
             Store.transaction(workspace, fn tx ->
               snapshot =
                 Map.new(@state_tables, fn table ->
                   assert {:ok, rows} =
                            Store.list(tx, table, %{where: [], order_by: [id: :asc]})

                   {table, rows}
                 end)

               {:ok, snapshot}
             end)

    snapshot
  end

  defp intake do
    %{
      "title" => "Create security boundary fixture",
      "description" => "Test-only ordinary content; no classification or state advancement"
    }
  end

  defp remove_memory_workspaces(workspaces) do
    # Remove only this case's namespaces/outbox rows. ExUnit stops a server
    # started by this case; any pre-existing supervised server is preserved.
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox =
          state.outbox
          |> Map.drop(workspaces)
          |> Map.update(:__all__, [], fn rows ->
            Enum.reject(rows, &(&1["workspace"] in workspaces))
          end)

        %{state | workspaces: Map.drop(state.workspaces, workspaces), outbox: outbox}
      end)
    end

    :ok
  end
end
