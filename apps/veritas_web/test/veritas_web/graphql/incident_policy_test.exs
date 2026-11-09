defmodule Veritas.Web.GraphQL.IncidentPolicyTest do
  @moduledoc """
  Real Absinthe policy operations with independent Memory persistence checks.

  Variables and result maps cross Jason's JSON boundary. JsonMap payload keys
  follow the shared snake_case response contract, not GraphQL object-field
  camel casing. Omitted variables and explicit null reach Absinthe itself.
  Direct execution with a trusted Principal is not HTTP authentication, CSRF,
  endpoint, real-adapter, concurrency or deployment acceptance.

  Policy values are explicit synthetic elapsed-time inputs, never defaults.
  No policy rows, versions or audit history are seeded, and no timezone provider
  or notification is used. Root owns ordinary compilation and execution.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.{Audit, Principal}
  alias Veritas.Store
  alias Veritas.Store.Memory
  alias Veritas.Web.GraphQL.Schema

  @show """
  query Policy($workspace: String!) {
    incidentPolicy(workspace: $workspace)
  }
  """
  @validate """
  mutation Validate($workspace: String!, $document: String!) {
    validateIncidentPolicy(workspace: $workspace, documentJson: $document)
  }
  """
  @save """
  mutation Save($workspace: String!, $document: String!, $revision: Int) {
    saveIncidentPolicy(workspace: $workspace, documentJson: $document,
      expectedPolicyRevision: $revision)
  }
  """
  @save_without_revision """
  mutation SaveWithoutRevision($workspace: String!, $document: String!) {
    saveIncidentPolicy(workspace: $workspace, documentJson: $document)
  }
  """
  @publish """
  mutation Publish($workspace: String!, $revision: Int!, $approve: Boolean!) {
    publishIncidentPolicy(workspace: $workspace,
      expectedPolicyRevision: $revision, approve: $approve)
  }
  """
  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)

  setup do
    previous = Application.fetch_env(:veritas_core, :store)
    workspace = unique_workspace()
    foreign_workspace = unique_workspace()

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspaces([workspace, foreign_workspace])
      after
        case previous do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    {:ok, workspace: workspace, foreign_workspace: foreign_workspace,
     admin: Principal.new("graphql_policy_admin", workspace, [:platform_admin], kind: :human),
     desk: Principal.new("graphql_policy_desk", workspace, [:service_desk_agent], kind: :human),
     foreign: Principal.new("graphql_foreign_admin", foreign_workspace, [:platform_admin], kind: :human)}
  end

  # Catches dropping the public argument-presence check and treating omission
  # as the explicit first-save null precondition.
  test "omitting the revision argument refuses before the first policy write", ctx do
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    result = execute(@save_without_revision, document_variables(ctx, partial_policy()), ctx.admin)
    assert_error(result, "saveIncidentPolicy", "invalid_request")
    assert policy_state(ctx.workspace) == before
    assert audit(ctx.workspace) == audit_before
  end

  # Same GraphQL document as the explicit-null control: absence of a variable
  # must not acquire a null value during Absinthe input coercion.
  test "an omitted nullable revision variable is not an explicit null", ctx do
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    result = execute(@save, document_variables(ctx, partial_policy()), ctx.admin)
    assert_error(result, "saveIncidentPolicy", "invalid_request")
    assert policy_state(ctx.workspace) == before
    assert audit(ctx.workspace) == audit_before
  end

  # Catches rejecting valid partial drafts, injecting missing operational
  # defaults, or serializing a different CAS/document than actually persisted.
  test "explicit null creates a partial draft with honest absent operational policy", ctx do
    document = partial_policy()
    saved = save(ctx, document, nil)
    assert saved["policy_revision"] == 1
    assert saved["draft"] == %{"revision" => 1, "document" => document}
    assert is_nil(saved["active"])
    assert is_nil(saved["active_version"])
    assert "priority_rules.individual.medium" in saved["readiness"]["operations"]["derive_priority"]

    state = policy_state(ctx.workspace)
    assert [config] = state.configuration
    assert config["id"] == "current"
    assert config["revision"] == 1
    assert config["draft"] == document
    assert is_nil(config["active_policy_version"])
    assert state.versions == []
    assert state.calendars == []
    assert [event] = audit(ctx.workspace)
    assert event["subject_table"] == "incident_configuration"
    assert event["subject"] == "current"
    assert event["actor_id"] == ctx.admin.id
    assert event["diff"]["revision"] == 1
    assert event["diff"]["document"] == document
    assert data(execute(@show, %{"workspace" => ctx.workspace}, ctx.admin), "incidentPolicy") == saved
    assert policy_state(ctx.workspace) == state
    assert audit(ctx.workspace) == [event]
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Catches making absent components invalid, or accepting supplied zero SLA
  # values. Validation is a structured result, not a persisted configuration.
  test "validation separates valid incompleteness from invalid supplied values without writing", ctx do
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    valid = data(execute(@validate, document_variables(ctx, partial_policy()), ctx.admin),
      "validateIncidentPolicy")
    assert valid["document"] == partial_policy()
    assert valid["errors"] == %{}
    assert "sla_targets.P3.resolution" in valid["readiness"]["operations"]["resolution"]
    refute "sla_targets.P3.response" in valid["readiness"]["operations"]["response"]

    invalid = data(execute(@validate, document_variables(ctx, invalid_policy()), ctx.admin),
      "validateIncidentPolicy")
    assert invalid["errors"]["sla_targets.P3.response.amount"] == "positive_integer_required"
    assert policy_state(ctx.workspace) == before
    assert audit(ctx.workspace) == audit_before
  end

  # Catches saving an invalid supplied target, or changing the prior draft
  # before returning the safe GraphQL field-error extension.
  test "invalid supplied target values refuse save without changing a valid draft", ctx do
    save(ctx, partial_policy(), nil)
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    result = save_result(ctx, invalid_policy(), 1, ctx.admin)
    extensions = assert_error(result, "saveIncidentPolicy", "policy_invalid")
    assert extensions["fields"] == %{"sla_targets.P3.response.amount" => "positive_integer_required"}
    assert policy_state(ctx.workspace) == before
    assert audit(ctx.workspace) == audit_before
  end

  # Catches bypassing the public JSON-object decoder or leaking a parser error
  # instead of the stable structured invalid_request result.
  test "malformed and non-object JSON refuse before any policy mutation", ctx do
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    for document <- ["not json", "[]", "null", "42"] do
      result = execute(@save, %{"workspace" => ctx.workspace, "document" => document,
        "revision" => nil}, ctx.admin)
      assert_error(result, "saveIncidentPolicy", "invalid_request")
      assert policy_state(ctx.workspace) == before
      assert audit(ctx.workspace) == audit_before
    end
  end

  # Catches collapsing subsequent null into first-save authority or ignoring
  # an integer CAS mismatch and overwriting a newer draft.
  test "null and stale integer revisions preserve the newer saved draft", ctx do
    save(ctx, partial_policy(), nil)
    newer = partial_policy(23)
    assert save(ctx, newer, 1)["policy_revision"] == 2
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    for revision <- [nil, 1] do
      result = save_result(ctx, partial_policy(), revision, ctx.admin)
      extensions = assert_error(result, "saveIncidentPolicy", "policy_revision_conflict")
      assert extensions["current_revision"] == 2
      assert policy_state(ctx.workspace) == before
      assert audit(ctx.workspace) == audit_before
    end
    assert [config] = before.configuration
    assert config["draft"] == newer
  end

  # Catches treating a configured draft or stale revision as publication
  # approval. A checked approval denial may add audit, never policy rows.
  test "publication requires explicit approval and the current draft revision", ctx do
    save(ctx, elapsed_policy(), nil)
    before = policy_state(ctx.workspace)
    audit_before = audit(ctx.workspace)
    assert_error(publish_result(ctx, 1, false, ctx.admin), "publishIncidentPolicy", "approval_required")
    assert policy_state(ctx.workspace) == before
    assert [refusal] = audit(ctx.workspace) -- audit_before
    assert refusal["to_state"] == "refused"
    assert refusal["actor_id"] == ctx.admin.id
    assert refusal["diff"]["capability"] == "incident_policy_admin"
    assert refusal["diff"]["refusal"] == "approval_required"

    after_denial = audit(ctx.workspace)
    extensions = assert_error(publish_result(ctx, 0, true, ctx.admin),
      "publishIncidentPolicy", "policy_revision_conflict")
    assert extensions["current_revision"] == 1
    assert policy_state(ctx.workspace) == before
    assert audit(ctx.workspace) == after_denial
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Catches partial publication, duplicate replay versions, failure to consume
  # the draft, or a public active pointer inconsistent with committed storage.
  test "publication commits exactly one version and refuses both replay forms", ctx do
    document = elapsed_policy()
    save(ctx, document, nil)
    audit_before = audit(ctx.workspace)
    published = data(publish_result(ctx, 1, true, ctx.admin), "publishIncidentPolicy")
    assert published["policy_revision"] == 2
    assert is_nil(published["draft"])
    assert published["active"] == document
    assert is_binary(published["active_version"])
    assert published["readiness"]["operations"]["acknowledge"] == []

    committed = policy_state(ctx.workspace)
    assert [config] = committed.configuration
    assert [version] = committed.versions
    assert committed.calendars == []
    assert config["revision"] == 2
    assert is_nil(config["draft"])
    assert config["active_policy_version"] == version["id"]
    assert version["id"] == published["active_version"]
    assert version["status"] == "published"
    assert version["version"] == 1
    assert version["revision"] == 1
    assert Map.delete(version["definition"], "calendar_versions") == document
    assert version["definition"]["calendar_versions"] == %{}
    assert version["published_by"] == %{"type" => "user", "id" => ctx.admin.id}
    assert [event] = audit(ctx.workspace) -- audit_before
    assert event["subject_table"] == "incident_configuration"
    assert event["subject"] == "current"
    assert event["diff"]["version"] == version["id"]
    assert event["diff"]["revision"] == 2
    assert event["diff"]["approval"] == version["published_by"]

    audit_after = audit(ctx.workspace)
    stale = assert_error(publish_result(ctx, 1, true, ctx.admin),
      "publishIncidentPolicy", "policy_revision_conflict")
    assert stale["current_revision"] == 2
    consumed = assert_error(publish_result(ctx, 2, true, ctx.admin),
      "publishIncidentPolicy", "policy_unconfigured")
    assert consumed["missing"] == ["draft"]
    assert consumed["operation"] == "publish"
    assert policy_state(ctx.workspace) == committed
    assert audit(ctx.workspace) == audit_after
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Catches resetting CAS after consumption, rewriting an active version while
  # editing a draft, or exposing that private draft to a legitimate desk reader.
  test "configuration revision continues after publication and non-admin reads hide the next draft", ctx do
    document = elapsed_policy()
    save(ctx, document, nil)
    published = data(publish_result(ctx, 1, true, ctx.admin), "publishIncidentPolicy")
    committed = policy_state(ctx.workspace)
    before = audit(ctx.workspace)
    stale = assert_error(save_result(ctx, partial_policy(), nil, ctx.admin),
      "saveIncidentPolicy", "policy_revision_conflict")
    assert stale["current_revision"] == 2
    assert policy_state(ctx.workspace) == committed
    assert audit(ctx.workspace) == before

    next_document = partial_policy(29)
    saved = save(ctx, next_document, 2)
    assert saved["policy_revision"] == 3
    assert saved["draft"] == %{"revision" => 3, "document" => next_document}
    assert saved["active_version"] == published["active_version"]
    assert saved["active"] == document
    current = policy_state(ctx.workspace)
    assert current.versions == committed.versions
    assert [config] = current.configuration
    assert config["revision"] == 3
    assert config["draft"] == next_document

    audit_before_reads = audit(ctx.workspace)
    assert data(execute(@show, %{"workspace" => ctx.workspace}, ctx.admin), "incidentPolicy") == saved
    reader = data(execute(@show, %{"workspace" => ctx.workspace}, ctx.desk), "incidentPolicy")
    assert reader["policy_revision"] == 3
    assert reader["active_version"] == published["active_version"]
    assert reader["active"] == document
    assert is_nil(reader["draft"])
    assert policy_state(ctx.workspace) == current
    assert audit(ctx.workspace) == audit_before_reads
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  # Catches granting policy administration from missing identity, ordinary
  # ticket roles, or Platform Admin authority in another Workspace.
  test "missing insufficient and foreign Principals cannot validate save or publish policy", ctx do
    save(ctx, elapsed_policy(), nil)
    for {principal, code, actor_id, actor_type, refusal_code} <- [
          {nil, "principal_required", "unknown", "unknown", "principal_required"},
          {ctx.desk, "operation_refused", ctx.desk.id, "user", "not_authorised"},
          {ctx.foreign, "operation_refused", ctx.foreign.id, "user", "not_authorised"}
        ], operation <- [:validate, :save, :publish] do
      before = policy_state(ctx.workspace)
      foreign_before = policy_state(ctx.foreign_workspace)
      audit_before = audit(ctx.workspace)
      foreign_audit_before = audit(ctx.foreign_workspace)
      {field, result} = case operation do
        :validate -> {"validateIncidentPolicy",
          execute(@validate, document_variables(ctx, partial_policy()), principal)}
        :save -> {"saveIncidentPolicy", save_result(ctx, partial_policy(), 1, principal)}
        :publish -> {"publishIncidentPolicy", publish_result(ctx, 1, true, principal)}
      end
      extensions = assert_error(result, field, code)
      refute Map.has_key?(extensions, "current_revision")
      refute Map.has_key?(extensions, "current_version")
      refute Map.has_key?(extensions, "fields")
      assert policy_state(ctx.workspace) == before
      assert policy_state(ctx.foreign_workspace) == foreign_before
      assert audit(ctx.foreign_workspace) == foreign_audit_before
      assert [event] = audit(ctx.workspace) -- audit_before
      assert event["workspace"] == ctx.workspace
      assert event["actor_id"] == actor_id
      assert event["actor_type"] == actor_type
      assert event["to_state"] == "refused"
      assert event["diff"]["capability"] == "incident_policy_admin"
      assert event["diff"]["refusal"] == refusal_code
      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end
  end

  # Catches reading configuration before Workspace/principal authorization;
  # legitimate non-admin draft hiding is covered separately above.
  test "unauthenticated and foreign policy reads refuse without policy mutation", ctx do
    save(ctx, elapsed_policy(), nil)
    for {principal, code} <- [{nil, "principal_required"}, {ctx.foreign, "operation_refused"}] do
      before = policy_state(ctx.workspace)
      foreign_before = policy_state(ctx.foreign_workspace)
      audit_before = audit(ctx.workspace)
      foreign_audit_before = audit(ctx.foreign_workspace)
      extensions = assert_error(execute(@show, %{"workspace" => ctx.workspace}, principal),
        "incidentPolicy", code)
      refute Map.has_key?(extensions, "current_revision")
      assert policy_state(ctx.workspace) == before
      assert policy_state(ctx.foreign_workspace) == foreign_before
      assert audit(ctx.foreign_workspace) == foreign_audit_before
      assert [event] = audit(ctx.workspace) -- audit_before
      assert event["to_state"] == "refused"
      assert event["diff"]["capability"] == "ticket:read"
      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end
  end

  defp execute(query, variables, principal) do
    variables = variables |> Jason.encode!() |> Jason.decode!()
    assert {:ok, result} = Absinthe.run(query, Schema,
      variables: variables, context: %{principal: principal})
    result |> Jason.encode!() |> Jason.decode!()
  end

  defp data(result, field) do
    refute Map.has_key?(result, "errors"), inspect(result["errors"])
    payload = get_in(result, ["data", field])
    assert is_map(payload)
    payload
  end

  defp assert_error(result, field, code) do
    assert get_in(result, ["data", field]) == nil
    assert [error] = result["errors"]
    assert error["path"] == [field]
    assert is_binary(error["message"])
    assert error["extensions"]["code"] == code
    error["extensions"]
  end

  defp document_variables(ctx, document) do
    %{"workspace" => ctx.workspace, "document" => Jason.encode!(document)}
  end

  defp save_result(ctx, document, revision, principal) do
    execute(@save, Map.put(document_variables(ctx, document), "revision", revision), principal)
  end

  defp save(ctx, document, revision) do
    data(save_result(ctx, document, revision, ctx.admin), "saveIncidentPolicy")
  end

  defp publish_result(ctx, revision, approve, principal) do
    execute(@publish, %{"workspace" => ctx.workspace, "revision" => revision,
      "approve" => approve}, principal)
  end

  defp policy_state(workspace) do
    assert {:ok, state} = Store.transaction(workspace, fn tx ->
      assert {:ok, configuration} = Store.list(tx, :incident_configuration,
        %{where: [], order_by: [id: :asc]})
      assert {:ok, versions} = Store.list(tx, :incident_policy_version,
        %{where: [], order_by: [id: :asc]})
      assert {:ok, calendars} = Store.list(tx, :incident_calendar_version,
        %{where: [], order_by: [id: :asc]})
      {:ok, %{configuration: configuration, versions: versions, calendars: calendars}}
    end)
    state
  end

  defp audit(workspace) do
    assert {:ok, events} = Audit.entries(workspace)
    events
  end

  defp partial_policy, do: partial_policy(17)

  defp partial_policy(amount) do
    %{"sla_targets" => %{"P3" => %{"response" => %{
      "amount" => amount, "unit" => "minutes", "basis" => "elapsed"
    }}}}
  end

  defp invalid_policy do
    put_in(partial_policy(), ["sla_targets", "P3", "response", "amount"], 0)
  end

  defp elapsed_policy do
    rules = for impact <- @impacts, urgency <- @urgencies,
      do: %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
    targets = Map.new(~w(P1 P2 P3 P4), fn priority ->
      {priority, %{
        "response" => %{"amount" => 17, "unit" => "minutes", "basis" => "elapsed"},
        "resolution" => %{"amount" => 61, "unit" => "minutes", "basis" => "elapsed"}
      }}
    end)
    %{"priority_rules" => rules, "sla_targets" => targets}
  end

  defp unique_workspace do
    "t_graphql_policy_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp remove_memory_workspaces(workspaces) do
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox = state.outbox |> Map.drop(workspaces) |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] in workspaces))
        end)
        %{state | workspaces: Map.drop(state.workspaces, workspaces), outbox: outbox}
      end)
    end
    :ok
  end
end
