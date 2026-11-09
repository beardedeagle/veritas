defmodule Veritas.Core.Tickets.IncidentProvenanceIntegrityTest do
  @moduledoc """
  Unrun tests-first candidate for malformed stored-provenance safety.

  Stored Incident provenance is operator-corrupted data, not a user capability:
  a non-map `detail["domain_provenance"]`, a non-map `provenance["fields"]`, or
  a non-list `provenance["communications"]` must never crash a legitimate
  public read or amendment, never silently rewrite the record, and never lose
  data. Every public surface — read **and** amend, for all three shapes — must
  answer a typed `{:error, %Store.Error{code: :protocol}}`, never the
  incidental `the transaction raised:` wrap a rescue produces, and never a
  silent success that projects the malformed history.

  The corruption is injected with one real Memory transaction over the row a
  public managed create produced. Principals are legitimate: a Platform Admin
  saves and publishes the workflow definition (the authority `Workflows.save`
  requires), and a desk agent starts, reads and amends — the test subject is
  never elevated. Expectations here are intended outcomes, not run results:
  RED before BEAM's repair is the point of the file. Neither execution nor
  Surreal/three-surface proof is claimed by authoring it.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @state_tables [:ticket, :incident, :sla_clock, :incident_hold_episode, :workflow_run]
  @wrap_marker "the transaction raised:"

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = StoreCase.unique_workspace()

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspace(workspace)
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    # Definition administration and Incident operation are different
    # authorities: save/publish need account:administrate, which only the
    # Platform Admin holds; the desk agent is the legitimate operating subject.
    admin = Principal.new("provenance_fixture_admin", workspace, [:platform_admin], kind: :human)
    desk = Principal.new("provenance_fixture_desk", workspace, [:service_desk_agent], kind: :human)

    assert {:ok, workflow} = Workflows.save(workspace, nil, manual_definition(), admin)
    assert {:ok, _published} = Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)

    assert {:ok, run} =
             Workflows.start(workspace, workflow["id"], %{"title" => "Provenance integrity fixture"}, desk)

    assert run["status"] == "active"

    # The revision the amendment must quote is captured while the stored
    # provenance is still the shape the public create produced — the fixture
    # never interprets the field it is about to corrupt.
    assert {:ok, detail} = created_detail(workspace)
    assert is_map(detail["domain_provenance"])
    assert is_integer(detail["domain_revision"])

    {:ok,
     workspace: workspace,
     desk: desk,
     ticket_id: run["ticket"],
     run_revision: run["revision"],
     domain_revision: detail["domain_revision"]}
  end

  # ── non-map outer provenance ────────────────────────────────────────────────

  test "a non-map stored domain_provenance is refused safely on read", ctx do
    corrupt!(ctx, fn detail -> %{detail | "domain_provenance" => "corrupted: not a map"} end)
    assert_integrity_refusal(ctx, :read)
  end

  test "a non-map stored domain_provenance is refused safely on amendment", ctx do
    corrupt!(ctx, fn detail -> %{detail | "domain_provenance" => "corrupted: not a map"} end)
    assert_integrity_refusal(ctx, amendment())
  end

  # ── non-map provenance fields ───────────────────────────────────────────────

  test "a non-map provenance fields map is refused safely on read", ctx do
    corrupt!(ctx, fn detail ->
      %{detail | "domain_provenance" => %{detail["domain_provenance"] | "fields" => ["corrupted fields"]}}
    end)

    assert_integrity_refusal(ctx, :read)
  end

  test "a non-map provenance fields map is refused safely on amendment", ctx do
    corrupt!(ctx, fn detail ->
      %{detail | "domain_provenance" => %{detail["domain_provenance"] | "fields" => ["corrupted fields"]}}
    end)

    assert_integrity_refusal(ctx, amendment())
  end

  # ── non-list communications history ─────────────────────────────────────────

  test "a non-list provenance communications history is refused safely on read", ctx do
    corrupt!(ctx, fn detail ->
      %{detail | "domain_provenance" => %{detail["domain_provenance"] | "communications" => %{"corrupted" => true}}}
    end)

    assert_integrity_refusal(ctx, :read)
  end

  test "a non-list provenance communications history is refused safely on the appending amendment", ctx do
    corrupt!(ctx, fn detail ->
      %{detail | "domain_provenance" => %{detail["domain_provenance"] | "communications" => %{"corrupted" => true}}}
    end)

    assert_integrity_refusal(ctx, communication_amendment())
  end

  # ── the contract ────────────────────────────────────────────────────────────

  # One public call must return the typed protocol error — never a raise, and
  # never the incidental `the transaction raised:` wrap the Memory rescue
  # produces for an exception that escaped the domain, and never a silent
  # success that exposes the malformed history as if it were data. The message
  # belongs to the repair; the code is the contract.
  defp assert_integrity_refusal(ctx, action) do
    corrupted = persisted_state(ctx.workspace)
    assert {:ok, audit_at_corruption} = Audit.entries(ctx.workspace)

    assert {:error, %Veritas.Store.Error{code: :protocol} = reason} = public_call(ctx, action)
    refute reason.message =~ @wrap_marker

    # No reset, no rewrite, no loss: the corrupted bytes are exactly what the
    # refusal left behind, and the audit chain stays verifiable with every
    # prior event preserved. (An appended integrity refusal is permitted; a
    # rewrite or a drop is not — only the prefix is pinned, not the count.)
    assert persisted_state(ctx.workspace) == corrupted
    assert {:ok, audit_after} = Audit.entries(ctx.workspace)
    assert Enum.take(audit_after, length(audit_at_corruption)) == audit_at_corruption
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp public_call(ctx, :read), do: Tickets.read_domain(ctx.workspace, ctx.ticket_id, ctx.desk)

  defp public_call(ctx, patch) do
    opts = [
      expected_revision: ctx.run_revision,
      expected_domain_revision: ctx.domain_revision,
      expected_policy_version: nil
    ]

    Tickets.update_domain(ctx.workspace, ctx.ticket_id, patch, ctx.desk, opts)
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  # An ordinary content amendment: authorized for the desk principal, and it
  # reaches Incident.facts before any write, which is where a malformed
  # provenance shape is consumed first.
  defp amendment, do: %{"description" => "A legitimate amendment after corruption"}

  # A communication attestation in the exact shape Incident.object_shape
  # accepts for notification_evidence: known keys only, every required key
  # present, and the outbound direction the field demands.
  defp communication_amendment do
    %{
      "notification_evidence" => %{
        "reference" => "fixture-notification-1",
        "channel" => "email",
        "direction" => "outbound",
        "recipient" => "fixture-recipient@example.test",
        "text" => "Fixture outbound notification"
      }
    }
  end

  defp created_detail(workspace) do
    assert {:ok, detail} =
             Store.transaction(workspace, fn tx ->
               assert {:ok, rows} = Store.list(tx, :incident, %{where: [], order_by: [id: :asc]})
               {:ok, rows}
             end)

    assert [row] = detail
    {:ok, row}
  end

  # Exactly one stored field is corrupted, through a real transaction over the
  # row the public create produced. This is fixture surgery on stored data,
  # not a user capability and not a production-path call.
  defp corrupt!(ctx, mutate) do
    assert {:ok, :corrupted} =
             Store.transaction(ctx.workspace, fn tx ->
               assert {:ok, rows} = Store.list(tx, :incident, %{where: [], order_by: [id: :asc]})
               assert [detail] = rows
               assert {:ok, _} = Store.put(tx, :incident, mutate.(detail))
               {:ok, :corrupted}
             end)
  end

  defp persisted_state(workspace) do
    assert {:ok, snapshot} =
             Store.transaction(workspace, fn tx ->
               snapshot =
                 Map.new(@state_tables, fn table ->
                   assert {:ok, rows} = Store.list(tx, table, %{where: [], order_by: [id: :asc]})
                   {table, rows}
                 end)

               {:ok, snapshot}
             end)

    snapshot
  end

  defp manual_definition do
    %{
      "name" => "Manual provenance integrity fixture",
      "ticket_type" => "incident",
      "description" => "Test-only intake and parked manual step; no lifecycle advancement",
      "steps" => [
        %{
          "id" => "intake",
          "name" => "Intake",
          "kind" => "intake",
          "phase" => "intake",
          "fields" => [],
          "next" => ["review"]
        },
        %{
          "id" => "review",
          "name" => "Manual review",
          "kind" => "manual",
          "phase" => "processing",
          "fields" => [],
          "next" => []
        }
      ]
    }
  end

  defp remove_memory_workspace(workspace) do
    # Preserve a shared application's supervised server and every other test's
    # namespace. A server started by this case is instead stopped by ExUnit.
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox =
          state.outbox
          |> Map.delete(workspace)
          |> Map.update(:__all__, [], fn rows ->
            Enum.reject(rows, &(&1["workspace"] == workspace))
          end)

        %{state | workspaces: Map.delete(state.workspaces, workspace), outbox: outbox}
      end)
    end

    :ok
  end
end
