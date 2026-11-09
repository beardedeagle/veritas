defmodule Veritas.Plugin.IncidentLiveGrantTest do
  @moduledoc """
  A Plugin's live grant is authority for narrow Incident work, and nothing more.

  These are **direct `Host.Default` adapter** checks, not `Host.call` or
  transport checks. The host supplies a roleless service Principal. The real
  Registry install grants only `ticket:read` and `ticket:write`; the domain
  re-checks that grant inside each mutation. Revoking the write grant between
  host calls therefore refuses the next write without changing the Incident
  or its workflow run.

  The structural content API and the Incident policy boundary are deliberately
  separated. A protected field sent as top-level content is rejected by name
  before Incident authorization. Classification and a self-approved priority
  override are instead supplied through intake `domain_fields`, where the real
  Incident policy path evaluates them and writes a checked refusal audit.

  Progression has its own legal-edge case so a structural mismatch cannot hide
  it. The approval control uses a priority override because the host has no
  generic approval flag to forward. No Policy stub or authority injection is
  used anywhere.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.Tickets
  alias Veritas.Plugin.Host.Capability
  alias Veritas.Plugin.Host.Default
  alias Veritas.Plugin.Registry
  alias Veritas.Store

  setup do
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    workspace = "incident_live_grant_#{suffix}"
    plugin_id = "incident.live_grant.#{suffix}"
    previous_store = Application.get_env(:veritas_core, :store)

    # Cleanup is registered before any configuration, Registry or Store
    # mutation. Restoration still runs if Registry cleanup itself fails.
    on_exit(fn ->
      try do
        if Process.whereis(Registry), do: Registry.remove_install(plugin_id)
      after
        restore_store(previous_store)
        remove_memory_workspace(workspace)
      end
    end)

    # The Plugin test helper only starts ExUnit. The in-memory Adapter's
    # start is idempotent, so an already supervised server is preserved.
    {:ok, _memory} = Veritas.Store.Memory.start_link([])
    Application.put_env(:veritas_core, :store, Veritas.Store.Memory)

    # A unique fixture id makes an accidental overwrite a setup failure
    # rather than destruction of somebody else's live grant.
    assert :error = Registry.fetch_install(plugin_id)

    install = %{
      plugin_id: plugin_id,
      workspace: workspace,
      manifest: %{"permissions" => %{"workspace_scoped" => true}},
      granted_scopes: ["ticket:read", "ticket:write"],
      registrations: []
    }

    :ok = Registry.put_install(install)

    # A legal edge is required to reach the human-only transition refusal;
    # without it the workflow would correctly fail earlier as illegal.
    {:ok, _edge} =
      Store.transaction(workspace, fn tx ->
        Store.put(tx, :ticket_transition, %{
          "id" => "incident__new__acknowledged",
          "ticket_type" => "incident",
          "from_state" => "new",
          "to_state" => "acknowledged"
        })
      end)

    {:ok,
     workspace: workspace,
     install: install,
     context: %{plugin_id: plugin_id, workspace: workspace}}
  end

  describe "a narrowly granted service Principal" do
    test "can intake and edit an Incident, then live revocation refuses the next write", %{
      context: context,
      install: install,
      workspace: workspace
    } do
      assert :ok = Capability.check(context, "ticket:write")

      ticket = open_incident(context)
      assert ticket["ticket_type"] == "incident"
      assert ticket["state"] == "new"
      assert ticket["domain_revision"] == 1

      assert {:ok, [corrected]} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "title" => "Checkout unavailable in EU",
                   "description" => "The EU checkout is returning 503",
                   "expected_domain_revision" => ticket["domain_revision"]
                 }
               ])

      assert corrected["title"] == "Checkout unavailable in EU"
      assert corrected["state"] == "new"
      assert corrected["domain_revision"] == 2

      before_revocation = snapshot(context, ticket["id"])
      assert before_revocation.domain_revision == 2
      assert before_revocation.workflow_revision == nil

      {:ok, before_events} = Audit.entries(workspace)
      assert length(before_events) == 2

      # Revoke only writes. The remaining read grant makes independent host
      # readback possible after the refused mutation.
      :ok = Registry.put_install(%{install | granted_scopes: ["ticket:read"]})
      assert {:error, :scope_denied} = Capability.check(context, "ticket:write")
      assert :ok = Capability.check(context, "ticket:read")

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "title" => "This write must not persist",
                   "expected_domain_revision" => before_revocation.domain_revision
                 }
               ])

      assert reason == "The live machine grant does not permit this Incident operation."

      # The revocation took effect between operations. Neither the domain
      # revision nor the workflow-run revision moved, and the refused title
      # never reached the store.
      assert snapshot(context, ticket["id"]) == before_revocation

      refusal =
        assert_new_refusal(
          workspace,
          before_events,
          ticket["id"],
          "content",
          context.plugin_id
        )

      assert refusal["from_state"] == "new"
      assert refusal["actor_type"] == "service"
      assert refusal["actor_id"] == context.plugin_id
      assert refusal["diff"]["refusal"] == "not_authorised"
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "Incident intake authority" do
    test "classification through domain_fields reaches the live policy refusal", %{
      context: context,
      workspace: workspace
    } do
      {:ok, before_events} = Audit.entries(workspace)
      assert before_events == []

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "ticket_type" => "incident",
                   "title" => "A classified draft",
                   "domain_fields" => %{"incident_class" => "major"}
                 }
               ])

      assert reason == "A machine grant permits draft intake and ordinary content only."

      refusal = assert_new_intake_refusal(workspace, before_events, context.plugin_id)
      assert refusal["from_state"] == "new"
      assert refusal["actor_type"] == "service"
      assert refusal["diff"]["refusal"] == "not_authorised"

      assert_no_incident_records(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a self-approved priority override through domain_fields reaches the live policy refusal", %{
      context: context,
      workspace: workspace
    } do
      {:ok, before_events} = Audit.entries(workspace)
      assert before_events == []

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "ticket_type" => "incident",
                   "title" => "A self-approved draft",
                   "domain_fields" => %{
                     "priority_override" => %{"reason" => "self-approved by the plugin"}
                   }
                 }
               ])

      assert reason == "A machine grant permits draft intake and ordinary content only."

      refusal = assert_new_intake_refusal(workspace, before_events, context.plugin_id)
      assert refusal["actor_type"] == "service"
      assert refusal["actor_id"] == context.plugin_id
      assert refusal["diff"]["refusal"] == "not_authorised"

      assert_no_incident_records(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "human-only progression" do
    test "a legal transition remains refused with ticket:write and changes nothing", %{
      context: context,
      workspace: workspace
    } do
      ticket = open_incident(context)
      before = snapshot(context, ticket["id"])
      {:ok, before_events} = Audit.entries(workspace)
      assert length(before_events) == 1

      assert {:error, reason} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "state" => "acknowledged",
                   "expected_domain_revision" => before.domain_revision
                 }
               ])

      assert reason ==
               "Incident classification, ownership, progression and approval require a human."

      refusal =
        assert_new_refusal(
          workspace,
          before_events,
          ticket["id"],
          "transition",
          context.plugin_id
        )

      assert refusal["from_state"] == "new"
      assert refusal["actor_type"] == "service"
      assert refusal["actor_id"] == context.plugin_id
      assert refusal["diff"]["refusal"] == "not_authorised"

      assert snapshot(context, ticket["id"]) == before
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "unsupported content" do
    test "a protected top-level field is a structural refusal, not an Incident policy denial", %{
      context: context,
      workspace: workspace
    } do
      ticket = open_incident(context)
      before = snapshot(context, ticket["id"])
      {:ok, opened_events} = Audit.entries(workspace)
      assert length(opened_events) == 1

      assert {:error, {:not_updatable, "incident_class"}} =
               Default.write_records(context, :ticket, [
                 %{
                   "id" => ticket["id"],
                   "incident_class" => "major",
                   "expected_domain_revision" => before.domain_revision
                 }
               ])

      # content_changes rejects this field before apply_incident, so there is
      # no policy decision and no refusal event to mistake for one.
      assert snapshot(context, ticket["id"]) == before
      {:ok, after_events} = Audit.entries(workspace)
      assert after_events == opened_events
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "non-Incident compatibility" do
    test "an ordinary Service Request write still succeeds through the same host", %{
      context: context,
      workspace: workspace
    } do
      assert {:ok, [opened]} =
               Default.write_records(context, :ticket, [
                 %{
                   "ticket_type" => "service_request",
                   "title" => "Reset the VPN password",
                   "description" => "A routine Service Request"
                 }
               ])

      assert opened["ticket_type"] == "service_request"
      assert opened["state"] == "submitted"

      assert {:ok, [updated]} =
               Default.write_records(context, :ticket, [
                 %{"id" => opened["id"], "title" => "Reset the VPN password today"}
               ])

      assert updated["title"] == "Reset the VPN password today"
      assert updated["state"] == "submitted"

      assert {:ok, persisted} = Tickets.read(workspace, opened["id"])
      assert persisted["title"] == "Reset the VPN password today"

      assert {:ok, events} = Audit.entries(workspace)
      assert length(events) == 2

      assert Enum.all?(
               events,
               &(&1["actor_type"] == "plugin" and &1["actor_id"] == context.plugin_id)
             )

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  defp open_incident(context) do
    assert {:ok, [ticket]} =
             Default.write_records(context, :ticket, [
               %{
                 "ticket_type" => "incident",
                 "title" => "Checkout unavailable",
                 "description" => "The checkout is returning 503"
               }
             ])

    ticket
  end

  # Read back through the host's live ticket:read grant, not by granting the
  # test a human Principal or bypassing the domain projection. This direct
  # adapter accepts the Store's native filter, not a Host.call JSON filter.
  defp snapshot(context, ticket_id) do
    assert {:ok, %{rows: [row]}} =
             Default.read_records(context, :ticket, %{where: [id: ticket_id]})

    assert row["id"] == ticket_id

    %{
      ticket:
        Map.take(row, ~w(id ticket_type state title description requester assignee priority)),
      domain: row["domain"],
      domain_revision: row["domain_revision"],
      workflow_revision: row["workflow_revision"]
    }
  end

  defp assert_new_intake_refusal(workspace, previous_events, plugin_id) do
    refusal = assert_new_refusal(workspace, previous_events, nil, "create", plugin_id)
    assert is_binary(refusal["subject"])

    # Intake allocated an id for the audit subject, but the refusal committed
    # no ticket under it.
    assert {:ok, nil} =
             Store.transaction(workspace, fn tx ->
               Store.fetch(tx, :ticket, refusal["subject"])
             end)

    refusal
  end

  defp assert_new_refusal(workspace, previous_events, subject_id, operation, plugin_id) do
    {:ok, events} = Audit.entries(workspace)
    assert length(events) == length(previous_events) + 1

    # A committed refusal appends one row. Earlier audit evidence remains
    # byte-for-byte in place rather than being rewritten to fit the result.
    assert Enum.take(events, length(previous_events)) == previous_events

    refusal = List.last(events)
    assert refusal["subject_table"] == "ticket"
    if subject_id, do: assert(refusal["subject"] == subject_id)
    assert refusal["to_state"] == "refused"
    assert refusal["actor_id"] == plugin_id
    assert refusal["diff"]["capability"] == "ticket:write"
    assert refusal["diff"]["operation"] == operation
    assert refusal["diff"]["ticket_type"] == "incident"
    refusal
  end

  defp assert_no_incident_records(workspace) do
    {:ok, records} =
      Store.transaction(workspace, fn tx ->
        with {:ok, tickets} <- Store.list(tx, :ticket, %{where: []}),
             {:ok, incidents} <- Store.list(tx, :incident, %{where: []}),
             {:ok, runs} <- Store.list(tx, :workflow_run, %{where: []}) do
          {:ok, %{tickets: tickets, incidents: incidents, runs: runs}}
        end
      end)

    assert records == %{tickets: [], incidents: [], runs: []}
  end

  defp restore_store(nil), do: Application.delete_env(:veritas_core, :store)

  defp restore_store(previous),
    do: Application.put_env(:veritas_core, :store, previous)

  # Remove only this case's namespace and outbox rows. The in-memory server
  # is shared with other suites, so it is left running and otherwise untouched.
  defp remove_memory_workspace(workspace) do
    if Process.whereis(Veritas.Store.Memory.Server) do
      :sys.replace_state(Veritas.Store.Memory.Server, fn state ->
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
