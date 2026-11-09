defmodule Veritas.Core.Store.IncidentMigrationBootstrapTest do
  @moduledoc """
  Callback dispatch, statement boundaries and failure ordering, without an engine.

  Metadata is synthetic, including the v5 dispatch fixture: these cases do not
  establish authentic v5 upgrade preservation or SurrealQL validity.
  """
  use ExUnit.Case, async: true

  alias Veritas.Store.Error
  alias Veritas.Store.Surreal.{IncidentMigration, Schema}

  for phase <- [:empty, :bootstrap, :v5, :v6], mode <- [:verify, :resign] do
    @tag phase: phase, mode: mode
    test "#{phase} dispatches #{mode} only after metadata validation", ctx do
      {query, events} = fixture(ctx.phase)
      audit = fn mode -> record(events, {:audit, mode}); :ok end

      assert :ok = IncidentMigration.run(query, seeds(), audit, resign?: ctx.mode == :resign)
      trace = Process.get(events) |> Enum.reverse()
      assert Enum.filter(trace, &match?({:audit, _}, &1)) == [{:audit, ctx.mode}]
      audit_index = Enum.find_index(trace, &(&1 == {:audit, ctx.mode}))
      assert Enum.any?(Enum.take(trace, audit_index), &match?({:metadata, _}, &1))

      if ctx.phase == :v6 do
        refute Enum.any?(trace, &match?({:write, _}, &1))
      else
        assert [{:write, marker}] = Enum.drop(trace, audit_index + 1)
        assert marker =~ "UPSERT schema_version:current"
      end

      bootstrap_writes = for {:write, sql} <- trace, sql =~ "CREATE schema_version:incident_v6_bootstrap", do: sql
      assert length(bootstrap_writes) == if(ctx.phase == :empty, do: 1, else: 0)
    end
  end

  for phase <- [:empty, :bootstrap, :v5, :v6] do
    @tag phase: phase
    test "#{phase} propagates an audit refusal without advancing the marker", %{phase: phase} do
      {query, events} = fixture(phase)
      refusal = Error.new(:invalid_request, "injected audit refusal")
      assert {:error, ^refusal} = IncidentMigration.run(query, seeds(), fn _ -> {:error, refusal} end)
      refute Enum.any?(Process.get(events), fn
        {:write, sql} -> String.contains?(sql, "UPSERT schema_version:current")
        _ -> false
      end)
    end
  end

  for result <- [{:ok, :refused}, {:ok, []}, {:ok, :intact}, nil] do
    @tag audit_result: result
    test "rejects non-contract audit return #{inspect(result)}", %{audit_result: result} do
      {query, events} = fixture(:bootstrap)
      assert {:error, %Error{details: %{migration_reason: :invalid_audit_result}}} =
               IncidentMigration.run(query, [], fn _ -> result end)
      refute Enum.any?(Process.get(events), &match?({:write, _}, &1))
    end
  end

  test "terminates mixed fragments exactly and preserves interior semicolons" do
    fragments = ["RETURN 1", "RETURN 2;\n", "RETURN 'a;b'  ", "RETURN 4;\t"]
    expected = "BEGIN TRANSACTION;\nRETURN 1;\nRETURN 2;\nRETURN 'a;b';\nRETURN 4;\n"
    failure = {:error, Error.new(:unavailable, "stop after capturing bootstrap")}
    query = fn
      "INFO FOR DB;" -> {:ok, [%{"tables" => %{}}]}
      sql ->
        assert String.starts_with?(sql, expected)
        assert String.ends_with?(sql, "applied_at = time::now();\nCOMMIT TRANSACTION;")
        failure
    end
    assert ^failure = IncidentMigration.run(query, fragments, fn _ -> flunk("audit after failed DDL") end)
  end

  test "every actual schema and seed fragment has a boundary before its successor" do
    fragments = Schema.statements() ++ seeds()
    query = fn
      "INFO FOR DB;" -> {:ok, [%{"tables" => %{}}]}
      sql ->
        for fragment <- fragments do
          trimmed = String.trim(fragment)
          terminated = if String.ends_with?(trimmed, ";"), do: trimmed, else: trimmed <> ";"
          assert String.contains?(sql, terminated <> "\n")
        end
        {:error, :captured}
    end
    assert {:error, :captured} = IncidentMigration.run(query, fragments, fn _ -> flunk("audit after failed DDL") end)
  end

  test "marker failure is returned after successful audit" do
    failure = {:error, Error.new(:unavailable, "injected marker failure")}
    {query, events} = fixture(:bootstrap, failure)
    assert ^failure = IncidentMigration.run(query, [], fn _ -> record(events, :audited); :ok end)
    assert [{:write, _}, :audited | _] = Process.get(events)
  end

  test "malformed metadata refuses before audit or writes" do
    query = fn "INFO FOR DB;" -> {:ok, [%{"tables" => nil}]} end
    assert {:error, %Error{details: %{migration_reason: :malformed_database_metadata}}} =
             IncidentMigration.run(query, seeds(), fn _ -> flunk("audit after bad inventory") end)
  end

  test "truthy non-boolean options do not authorize re-sign" do
    {query, _events} = fixture(:v6)
    assert :ok = IncidentMigration.run(query, [], fn mode -> assert mode == :verify; :ok end, resign?: :yes)
  end

  # Exact INFO declarations from root's read-only SurrealDB 3.3.4 observation.
  # These are recorded literals, not output synthesized by the comparator.
  @captured_definitions [
    {:fields, "workflow", "published_definition", "DEFINE FIELD published_definition ON workflow TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "workflow_run", "status", "DEFINE FIELD status ON workflow_run TYPE string ASSERT $value INSIDE ['active', 'completed'] PERMISSIONS FULL"},
    {:fields, "workspace", "status", "DEFINE FIELD status ON workspace TYPE string DEFAULT 'active' ASSERT $value INSIDE ['active', 'suspended', 'archived'] PERMISSIONS FULL"},
    {:fields, "user", "password_hash", "DEFINE FIELD password_hash ON user TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "user", "password_changed_at", "DEFINE FIELD password_changed_at ON user TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ci", "lifecycle_state", "DEFINE FIELD lifecycle_state ON ci TYPE string DEFAULT 'active' ASSERT $value INSIDE ['proposed', 'active', 'in_maintenance', 'retired', 'disposed'] PERMISSIONS FULL"},
    {:fields, "ci", "criticality", "DEFINE FIELD criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value INSIDE ['low', 'medium', 'high', 'tier1'] PERMISSIONS FULL"},
    {:fields, "ci", "owner", "DEFINE FIELD owner ON ci TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ci", "created_at", "DEFINE FIELD created_at ON ci TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ci", "updated_at", "DEFINE FIELD updated_at ON ci TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ci", "deleted_at", "DEFINE FIELD deleted_at ON ci TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "program", "status", "DEFINE FIELD status ON program TYPE string DEFAULT 'amber' ASSERT $value INSIDE ['red', 'amber', 'green'] PERMISSIONS FULL"},
    {:fields, "program", "owner", "DEFINE FIELD owner ON program TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "program", "target_date", "DEFINE FIELD target_date ON program TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "program", "started_at", "DEFINE FIELD started_at ON program TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "program", "created_at", "DEFINE FIELD created_at ON program TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "program", "updated_at", "DEFINE FIELD updated_at ON program TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "program", "DEFINE FIELD program ON milestone TYPE record<program> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "status", "DEFINE FIELD status ON milestone TYPE string DEFAULT 'planned' ASSERT $value INSIDE ['planned', 'in_progress', 'blocked', 'done'] PERMISSIONS FULL"},
    {:fields, "milestone", "planned_date", "DEFINE FIELD planned_date ON milestone TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "actual_date", "DEFINE FIELD actual_date ON milestone TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "owner", "DEFINE FIELD owner ON milestone TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "created_at", "DEFINE FIELD created_at ON milestone TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "milestone", "updated_at", "DEFINE FIELD updated_at ON milestone TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "milestone", "DEFINE FIELD milestone ON work_item TYPE record<milestone> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "state", "DEFINE FIELD state ON work_item TYPE string DEFAULT 'planned' ASSERT $value INSIDE ['planned', 'in_progress', 'blocked', 'done'] PERMISSIONS FULL"},
    {:fields, "work_item", "blocked_at", "DEFINE FIELD blocked_at ON work_item TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "owner", "DEFINE FIELD owner ON work_item TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "due_date", "DEFINE FIELD due_date ON work_item TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "created_at", "DEFINE FIELD created_at ON work_item TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "work_item", "updated_at", "DEFINE FIELD updated_at ON work_item TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "benefit", "work_item", "DEFINE FIELD work_item ON benefit TYPE record<work_item> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "benefit", "realised_at", "DEFINE FIELD realised_at ON benefit TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "benefit", "created_at", "DEFINE FIELD created_at ON benefit TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "benefit", "updated_at", "DEFINE FIELD updated_at ON benefit TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "ticket_type", "DEFINE FIELD ticket_type ON ticket TYPE string ASSERT $value INSIDE ['service_request', 'incident', 'change', 'problem', 'vulnerability'] PERMISSIONS FULL"},
    {:fields, "ticket", "assignee", "DEFINE FIELD assignee ON ticket TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "priority", "DEFINE FIELD priority ON ticket TYPE string | none DEFAULT (IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' }) ASSERT $this.ticket_type = 'incident' AND $value = NONE OR $value INSIDE ['low', 'medium', 'high', 'urgent'] PERMISSIONS FULL"},
    {:fields, "ticket", "impact", "DEFINE FIELD impact ON ticket TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 1 AND $value <= 5 PERMISSIONS FULL"},
    {:fields, "ticket", "urgency", "DEFINE FIELD urgency ON ticket TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 1 AND $value <= 5 PERMISSIONS FULL"},
    {:fields, "ticket", "severity", "DEFINE FIELD severity ON ticket TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['sev1', 'sev2', 'sev3', 'sev4', 'sev5'] PERMISSIONS FULL"},
    {:fields, "ticket", "sla_ref", "DEFINE FIELD sla_ref ON ticket TYPE record<sla_policy> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "acknowledged_at", "DEFINE FIELD acknowledged_at ON ticket TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "resolved_at", "DEFINE FIELD resolved_at ON ticket TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "closed_at", "DEFINE FIELD closed_at ON ticket TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "ticket", "deleted_at", "DEFINE FIELD deleted_at ON ticket TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "incident_class", "DEFINE FIELD incident_class ON incident TYPE string DEFAULT 'service_degradation' ASSERT $value INSIDE ['service_degradation', 'service_outage', 'security_incident', 'test_incident'] PERMISSIONS FULL"},
    {:fields, "incident", "resolution_code", "DEFINE FIELD resolution_code ON incident TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "promoted_to", "DEFINE FIELD promoted_to ON incident TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "domain_revision", "DEFINE FIELD domain_revision ON incident TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value > 0 PERMISSIONS FULL"},
    {:fields, "incident", "impact_level", "DEFINE FIELD impact_level ON incident TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['individual', 'team', 'department', 'organization', 'business_critical'] PERMISSIONS FULL"},
    {:fields, "incident", "urgency_level", "DEFINE FIELD urgency_level ON incident TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['immediate', 'high', 'medium', 'low'] PERMISSIONS FULL"},
    {:fields, "incident", "severity_level", "DEFINE FIELD severity_level ON incident TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['critical', 'major', 'minor', 'indeterminate'] PERMISSIONS FULL"},
    {:fields, "incident", "classification", "DEFINE FIELD classification ON incident TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['major', 'minor'] PERMISSIONS FULL"},
    {:fields, "incident", "priority_justification", "DEFINE FIELD priority_justification ON incident TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "priority_policy_version", "DEFINE FIELD priority_policy_version ON incident TYPE record<incident_policy_version> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "priority_override_evidence", "DEFINE FIELD priority_override_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "domain_provenance", "DEFINE FIELD domain_provenance ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "track_plan", "DEFINE FIELD track_plan ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "restoration_evidence", "DEFINE FIELD restoration_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "hold_reason", "DEFINE FIELD hold_reason ON incident TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "hold_owner", "DEFINE FIELD hold_owner ON incident TYPE record<user> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "expected_resume_at", "DEFINE FIELD expected_resume_at ON incident TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "resume_evidence", "DEFINE FIELD resume_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "problem", "DEFINE FIELD problem ON incident TYPE record<ticket> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "notification_evidence", "DEFINE FIELD notification_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "confirmation_evidence", "DEFINE FIELD confirmation_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "response_evidence", "DEFINE FIELD response_evidence ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "closure_approval", "DEFINE FIELD closure_approval ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "cancellation_reason", "DEFINE FIELD cancellation_reason ON incident TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident", "workaround", "DEFINE FIELD workaround ON incident TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "sequence", "DEFINE FIELD `sequence` ON audit_event TYPE int | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "from_state", "DEFINE FIELD from_state ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "to_state", "DEFINE FIELD to_state ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "actor_type", "DEFINE FIELD actor_type ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "actor_id", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "reason", "DEFINE FIELD reason ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "correlation_id", "DEFINE FIELD correlation_id ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "prev_hash", "DEFINE FIELD prev_hash ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "audit_event", "diff", "DEFINE FIELD `diff` ON audit_event TYPE none | object FLEXIBLE PERMISSIONS FULL"},
    {:fields, "event_outbox", "payload", "DEFINE FIELD payload ON event_outbox TYPE none | object FLEXIBLE PERMISSIONS FULL"},
    {:fields, "event_outbox", "published_at", "DEFINE FIELD published_at ON event_outbox TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "relation_kind", "inverse", "DEFINE FIELD inverse ON relation_kind TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "relation_kind", "description", "DEFINE FIELD description ON relation_kind TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "relation_kind", "attributes", "DEFINE FIELD attributes ON relation_kind TYPE none | object FLEXIBLE PERMISSIONS FULL"},
    {:fields, "provider", "base_url", "DEFINE FIELD base_url ON provider TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "provider", "model", "DEFINE FIELD model ON provider TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "provider", "credential_env", "DEFINE FIELD credential_env ON provider TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "provider", "capability_floor_acknowledged_by", "DEFINE FIELD capability_floor_acknowledged_by ON provider TYPE none | object FLEXIBLE PERMISSIONS FULL"},
    {:fields, "provider", "capability_floor_acknowledged_at", "DEFINE FIELD capability_floor_acknowledged_at ON provider TYPE none | datetime PERMISSIONS FULL"},
    {:fields, "search_chunk", "embedding", "DEFINE FIELD embedding ON search_chunk TYPE none | array<float> PERMISSIONS FULL"},
    {:fields, "search_chunk", "model", "DEFINE FIELD model ON search_chunk TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "search_chunk", "version", "DEFINE FIELD version ON search_chunk TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:indexes, "search_chunk", "search_chunk_fts", "DEFINE INDEX search_chunk_fts ON search_chunk FIELDS content FULLTEXT ANALYZER like BM25(1.2,0.75)"},
    {:fields, "sla_clock", "kind", "DEFINE FIELD kind ON sla_clock TYPE string ASSERT $value INSIDE ['response', 'resolution'] PERMISSIONS FULL"},
    {:fields, "sla_clock", "priority", "DEFINE FIELD priority ON sla_clock TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['P1', 'P2', 'P3', 'P4'] PERMISSIONS FULL"},
    {:fields, "sla_clock", "cycle", "DEFINE FIELD cycle ON sla_clock TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "sla_clock", "carried_elapsed_us", "DEFINE FIELD carried_elapsed_us ON sla_clock TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 0 PERMISSIONS FULL"},
    {:fields, "sla_clock", "previous_cycle", "DEFINE FIELD previous_cycle ON sla_clock TYPE record<sla_clock> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "sla_clock", "reopen_mode", "DEFINE FIELD reopen_mode ON sla_clock TYPE string | none DEFAULT NONE ASSERT $value = NONE OR $value INSIDE ['cumulative', 'new_cycle'] PERMISSIONS FULL"},
    {:fields, "sla_clock", "domain_revision", "DEFINE FIELD domain_revision ON sla_clock TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "sla_clock", "started_at", "DEFINE FIELD started_at ON sla_clock TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "sla_clock", "stopped_at", "DEFINE FIELD stopped_at ON sla_clock TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "sla_clock", "qualified_pause_us", "DEFINE FIELD qualified_pause_us ON sla_clock TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 0 PERMISSIONS FULL"},
    {:fields, "sla_clock", "current_hold", "DEFINE FIELD current_hold ON sla_clock TYPE record<incident_hold_episode> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "sla_clock", "policy_version", "DEFINE FIELD policy_version ON sla_clock TYPE record<incident_policy_version> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "sla_clock", "calendar_version", "DEFINE FIELD calendar_version ON sla_clock TYPE record<incident_calendar_version> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "episode", "DEFINE FIELD episode ON incident_hold_episode TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "domain_revision", "DEFINE FIELD domain_revision ON incident_hold_episode TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "reason", "DEFINE FIELD reason ON incident_hold_episode TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "started_at", "DEFINE FIELD started_at ON incident_hold_episode TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "ended_at", "DEFINE FIELD ended_at ON incident_hold_episode TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "expected_resume_at", "DEFINE FIELD expected_resume_at ON incident_hold_episode TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "pause_cap_at", "DEFINE FIELD pause_cap_at ON incident_hold_episode TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "qualified_pause_us", "DEFINE FIELD qualified_pause_us ON incident_hold_episode TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 0 PERMISSIONS FULL"},
    {:fields, "incident_hold_episode", "evidence", "DEFINE FIELD evidence ON incident_hold_episode TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "version", "DEFINE FIELD version ON incident_policy_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "schema_version", "DEFINE FIELD schema_version ON incident_policy_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "revision", "DEFINE FIELD revision ON incident_policy_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "status", "DEFINE FIELD status ON incident_policy_version TYPE string ASSERT $value INSIDE ['draft', 'published'] PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "published_at", "DEFINE FIELD published_at ON incident_policy_version TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "published_by", "DEFINE FIELD published_by ON incident_policy_version TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_policy_version", "calendar_version", "DEFINE FIELD calendar_version ON incident_policy_version TYPE record<incident_calendar_version> | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "version", "DEFINE FIELD version ON incident_calendar_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "schema_version", "DEFINE FIELD schema_version ON incident_calendar_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "revision", "DEFINE FIELD revision ON incident_calendar_version TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "status", "DEFINE FIELD status ON incident_calendar_version TYPE string ASSERT $value INSIDE ['draft', 'published'] PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "timezone", "DEFINE FIELD timezone ON incident_calendar_version TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "timezone_rules_version", "DEFINE FIELD timezone_rules_version ON incident_calendar_version TYPE string | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "published_at", "DEFINE FIELD published_at ON incident_calendar_version TYPE datetime | none DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_calendar_version", "published_by", "DEFINE FIELD published_by ON incident_calendar_version TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_configuration", "workspace", "DEFINE FIELD workspace ON incident_configuration TYPE record<workspace> ASSERT $this.id = type::record('incident_configuration', 'current') PERMISSIONS FULL"},
    {:fields, "incident_configuration", "revision", "DEFINE FIELD revision ON incident_configuration TYPE int ASSERT $value > 0 PERMISSIONS FULL"},
    {:fields, "incident_configuration", "draft", "DEFINE FIELD draft ON incident_configuration TYPE object | none FLEXIBLE DEFAULT NONE PERMISSIONS FULL"},
    {:fields, "incident_configuration", "active_policy_version", "DEFINE FIELD active_policy_version ON incident_configuration TYPE record<incident_policy_version> | none DEFAULT NONE PERMISSIONS FULL"}
  ]

  test "accepts every captured optional, asserted and fulltext declaration" do
    definitions = Schema.definitions()
    for {kind, table, name, actual} <- @captured_definitions do
      expected = definitions[table][kind][name]
      assert is_binary(expected), "missing expected #{table}.#{name}"
      assert IncidentMigration.equivalent?(expected, actual), "#{table}.#{name}"
      assert IncidentMigration.equivalent?(actual, expected), "reverse #{table}.#{name}"
    end
  end

  for {label, expected, changed} <- [
    {"field type", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE int | none DEFAULT NONE PERMISSIONS FULL"},
    {"optionality", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string DEFAULT NONE PERMISSIONS FULL"},
    {"null default", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT NULL PERMISSIONS FULL"},
    {"string default", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT 'none' PERMISSIONS FULL"},
    {"permissions", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT NONE PERMISSIONS NONE"},
    {"readonly", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT NONE READONLY PERMISSIONS FULL"},
    {"value expression", "DEFINE FIELD OVERWRITE actor_id ON audit_event TYPE string | NONE DEFAULT NONE;", "DEFINE FIELD actor_id ON audit_event TYPE string | none DEFAULT NONE VALUE 'changed' PERMISSIONS FULL"},
    {"flexible modifier", "DEFINE FIELD OVERWRITE diff ON audit_event TYPE option<object> FLEXIBLE;", "DEFINE FIELD `diff` ON audit_event TYPE none | object PERMISSIONS FULL"},
    {"default literal case", "DEFINE FIELD OVERWRITE criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value IN ['low','medium','high','tier1'];", "DEFINE FIELD criticality ON ci TYPE string DEFAULT 'Medium' ASSERT $value INSIDE ['low', 'medium', 'high', 'tier1'] PERMISSIONS FULL"},
    {"enum literal case", "DEFINE FIELD OVERWRITE criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value IN ['low','medium','high','tier1'];", "DEFINE FIELD criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value INSIDE ['LOW', 'medium', 'high', 'tier1'] PERMISSIONS FULL"},
    {"removed enum member", "DEFINE FIELD OVERWRITE criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value IN ['low','medium','high','tier1'];", "DEFINE FIELD criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value INSIDE ['medium', 'high', 'tier1'] PERMISSIONS FULL"},
    {"added enum member", "DEFINE FIELD OVERWRITE criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value IN ['low','medium','high','tier1'];", "DEFINE FIELD criticality ON ci TYPE string DEFAULT 'medium' ASSERT $value INSIDE ['other', 'low', 'medium', 'high', 'tier1'] PERMISSIONS FULL"},
    {"range lower operator", "DEFINE FIELD OVERWRITE impact ON ticket TYPE int | NONE DEFAULT NONE ASSERT $value IS NONE OR ($value >= 1 AND $value <= 5);", "DEFINE FIELD impact ON ticket TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value > 1 AND $value <= 5 PERMISSIONS FULL"},
    {"range upper bound", "DEFINE FIELD OVERWRITE urgency ON ticket TYPE int | NONE DEFAULT NONE ASSERT $value IS NONE OR ($value >= 1 AND $value <= 5);", "DEFINE FIELD urgency ON ticket TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 1 AND $value <= 6 PERMISSIONS FULL"},
    {"range conjunction", "DEFINE FIELD OVERWRITE impact ON ticket TYPE int | NONE DEFAULT NONE ASSERT $value IS NONE OR ($value >= 1 AND $value <= 5);", "DEFINE FIELD impact ON ticket TYPE int | none DEFAULT NONE ASSERT $value = NONE OR $value >= 1 OR $value <= 5 PERMISSIONS FULL"},
    {"nullable disjunction", "DEFINE FIELD OVERWRITE severity ON ticket TYPE string | NONE DEFAULT NONE ASSERT $value IS NONE OR $value IN ['sev1','sev2','sev3','sev4','sev5'];", "DEFINE FIELD severity ON ticket TYPE string | none DEFAULT NONE ASSERT $value = NONE AND $value INSIDE ['sev1', 'sev2', 'sev3', 'sev4', 'sev5'] PERMISSIONS FULL"},
    {"priority default condition", "DEFINE FIELD OVERWRITE priority ON ticket TYPE string | NONE DEFAULT IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' } ASSERT ($this.ticket_type = 'incident' AND $value IS NONE) OR $value IN ['low','medium','high','urgent'];", "DEFINE FIELD priority ON ticket TYPE string | none DEFAULT (IF $this.ticket_type = 'change' { NONE } ELSE { 'medium' }) ASSERT $this.ticket_type = 'incident' AND $value = NONE OR $value INSIDE ['low', 'medium', 'high', 'urgent'] PERMISSIONS FULL"},
    {"priority default branch", "DEFINE FIELD OVERWRITE priority ON ticket TYPE string | NONE DEFAULT IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' } ASSERT ($this.ticket_type = 'incident' AND $value IS NONE) OR $value IN ['low','medium','high','urgent'];", "DEFINE FIELD priority ON ticket TYPE string | none DEFAULT (IF $this.ticket_type = 'incident' { NONE } ELSE { 'low' }) ASSERT $this.ticket_type = 'incident' AND $value = NONE OR $value INSIDE ['low', 'medium', 'high', 'urgent'] PERMISSIONS FULL"},
    {"priority assertion conjunction", "DEFINE FIELD OVERWRITE priority ON ticket TYPE string | NONE DEFAULT IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' } ASSERT ($this.ticket_type = 'incident' AND $value IS NONE) OR $value IN ['low','medium','high','urgent'];", "DEFINE FIELD priority ON ticket TYPE string | none DEFAULT (IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' }) ASSERT $this.ticket_type = 'incident' OR $value = NONE OR $value INSIDE ['low', 'medium', 'high', 'urgent'] PERMISSIONS FULL"},
    {"meaningful grouping", "DEFINE FIELD OVERWRITE priority ON ticket TYPE string | NONE DEFAULT IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' } ASSERT ($this.ticket_type = 'incident' AND $value IS NONE) OR $value IN ['low','medium','high','urgent'];", "DEFINE FIELD priority ON ticket TYPE string | none DEFAULT (IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' }) ASSERT $this.ticket_type = 'incident' AND ($value = NONE OR $value INSIDE ['low', 'medium', 'high', 'urgent']) PERMISSIONS FULL"},
    {"fulltext analyzer", "DEFINE INDEX OVERWRITE search_chunk_fts ON search_chunk FIELDS content FULLTEXT;", "DEFINE INDEX search_chunk_fts ON search_chunk FIELDS content FULLTEXT ANALYZER other BM25(1.2,0.75)"},
    {"fulltext scoring k1", "DEFINE INDEX OVERWRITE search_chunk_fts ON search_chunk FIELDS content FULLTEXT;", "DEFINE INDEX search_chunk_fts ON search_chunk FIELDS content FULLTEXT ANALYZER like BM25(1.3,0.75)"},
    {"fulltext scoring b", "DEFINE INDEX OVERWRITE search_chunk_fts ON search_chunk FIELDS content FULLTEXT;", "DEFINE INDEX search_chunk_fts ON search_chunk FIELDS content FULLTEXT ANALYZER like BM25(1.2,0.8)"},
    {"fulltext uniqueness", "DEFINE INDEX OVERWRITE search_chunk_fts ON search_chunk FIELDS content FULLTEXT;", "DEFINE INDEX search_chunk_fts ON search_chunk FIELDS content UNIQUE FULLTEXT ANALYZER like BM25(1.2,0.75)"},
    {"literal NONE case", "DEFINE FIELD label ON sample TYPE string DEFAULT 'none';", "DEFINE FIELD label ON sample TYPE string DEFAULT 'NONE';"},
    {"record identifier case", "DEFINE FIELD owner ON sample TYPE record<none> | NONE;", "DEFINE FIELD owner ON sample TYPE record<NONE> | none;"},
    {"unknown assertion operands", "DEFINE FIELD label ON sample TYPE string ASSERT $value CONTAINS 'one';", "DEFINE FIELD label ON sample TYPE string ASSERT $value CONTAINS 'two';"},
    {"unknown assertion grouping", "DEFINE FIELD size ON sample TYPE int ASSERT ($value + 1) * 2 > 5;", "DEFINE FIELD size ON sample TYPE int ASSERT $value + 1 * 2 > 5;"},
    {"value expression operands", "DEFINE FIELD size ON sample TYPE int VALUE $value + 1;", "DEFINE FIELD size ON sample TYPE int VALUE $value + 2;"}
  ] do
    @tag expected_definition: expected, changed_definition: changed
    test "schema equivalence refuses #{label}", ctx do
      refute IncidentMigration.equivalent?(ctx.expected_definition, ctx.changed_definition)
      refute IncidentMigration.equivalent?(ctx.changed_definition, ctx.expected_definition)
    end
  end

  test "captured metadata reaches audit before bootstrap marker advancement" do
    {query, events} = captured_fixture()
    assert :ok = IncidentMigration.run(query, [], fn :verify -> record(events, :audited); :ok end)
    assert [{:write, marker}, :audited | _] = Process.get(events)
    assert marker =~ "UPSERT schema_version:current"
    assert Enum.count(Process.get(events), &match?({:write, _}, &1)) == 1
  end

  test "changed captured field refuses before audit and bootstrap marker writes" do
    {query, events} = captured_fixture()
    changed = fn sql ->
      case {sql, query.(sql)} do
        {"INFO FOR TABLE audit_event;", {:ok, [info]}} ->
          fields = Map.update!(info["fields"], "actor_id", &String.replace(&1, "TYPE string", "TYPE int"))
          {:ok, [Map.put(info, "fields", fields)]}
        {_sql, result} -> result
      end
    end
    assert {:error, %Error{details: %{migration_reason: :schema_mismatch, table: "audit_event", member: "actor_id", kind: :fields}}} =
             IncidentMigration.run(changed, [], fn _ -> flunk("audit after changed schema") end)
    refute Enum.any?(Process.get(events), &match?({:write, _}, &1))
  end

  defp captured_fixture do
    {query, events} = fixture(:bootstrap)
    observed = fn sql ->
      result = query.(sql)
      if String.starts_with?(sql, "INFO FOR TABLE ") do
        table = sql |> String.replace_prefix("INFO FOR TABLE ", "") |> String.trim_trailing(";")
        {:ok, [info]} = result
        info = Enum.reduce(@captured_definitions, info, fn
          {kind, ^table, name, definition}, acc ->
            Map.update!(acc, Atom.to_string(kind), &Map.put(&1, name, definition))
          _, acc -> acc
        end)
        {:ok, [info]}
      else
        result
      end
    end
    {observed, events}
  end

  defp seeds, do: Schema.seed_statements("migration_fixture")

  defp fixture(phase, marker_result \\ {:ok, []}) do
    state = make_ref()
    events = make_ref()
    Process.put(state, phase)
    Process.put(events, [])
    definitions = Schema.definitions()

    query = fn sql ->
      cond do
        sql == "INFO FOR DB;" ->
          tables = if Process.get(state) == :empty, do: %{}, else: Map.new(definitions, fn {name, d} -> {name, d.table} end)
          {:ok, [%{"tables" => tables}]}

        String.starts_with?(sql, "INFO FOR TABLE ") ->
          name = sql |> String.replace_prefix("INFO FOR TABLE ", "") |> String.trim_trailing(";")
          definition = Map.fetch!(definitions, name)
          record(events, {:metadata, name})
          {:ok, [%{"fields" => definition.fields, "indexes" => definition.indexes, "events" => %{}}]}

        sql == "SELECT * FROM schema_version LIMIT 3;" ->
          {id, version} = case Process.get(state) do
            :bootstrap -> {"schema_version:incident_v6_bootstrap", "6-bootstrap"}
            :v5 -> {"schema_version:current", "5"}
            :v6 -> {"schema_version:current", "6"}
          end
          {:ok, [%{"id" => id, "version" => version, "applied_at" => "2026-11-08T00:00:00Z"}]}

        String.starts_with?(sql, "SELECT * FROM ") ->
          {:ok, []}

        String.starts_with?(sql, "BEGIN TRANSACTION;") ->
          record(events, {:write, sql})
          if String.contains?(sql, "CREATE schema_version:incident_v6_bootstrap") do
            Process.put(state, :bootstrap)
            {:ok, []}
          else
            marker_result
          end

        true -> flunk("unexpected migration query")
      end
    end

    {query, events}
  end

  defp record(key, event), do: Process.put(key, [event | Process.get(key)])
end
