defmodule Veritas.Store.Surreal.Schema do
  @moduledoc """
  The schema of record, expressed as SurrealQL.

  The field lists follow `docs/07` §Core tables, narrowed to what the current
  slice writes. Only the tables the v0.1 slice needs are here; `docs/07` is
  the authority for the rest.

  Two rules run through it:

    * Every table carries a `workspace` field, because Workspace is the
      isolation unit (ADR-018) and a row that cannot be attributed to one
      Workspace is a row that can be read across Workspaces. The Adapter also
      scopes every statement to the Workspace's database, so the field is the
      *record* of the scope, not the only enforcement of it.
    * Relations are **typed edge tables**, one per relation kind, and the
      kinds are held in the `relation_kind` registry as data. A kind
      registered at runtime gets its edge table with it.

  ## The schema is data

  Tables are data so migrations can inspect the required declarations. The
  v6 Incident migration adds only its owned declarations; it never reconciles,
  prunes or reseeds existing rows. The complete statements and seeds are for
  an explicitly empty Workspace, not an upgrade shortcut.
  """

  @version "6"

  @doc "The schema version this Adapter expects."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The engine version this Adapter was written against."
  @spec engine_version() :: String.t()
  def engine_version, do: "3.3.4"

  # ── the tables ────────────────────────────────────────────────────────────

  # Optional canonical facts never reinterpret the legacy envelope/category.
  # Writers supply revisions, evidence and event times explicitly.
  @incident_fields [
    %{name: "domain_revision", type: "int | NONE", default: "NONE", assert: "$value IS NONE OR $value > 0"},
    %{name: "impact_level", type: "string | NONE", default: "NONE", assert: "$value IS NONE OR $value IN ['individual','team','department','organization','business_critical']"},
    %{name: "urgency_level", type: "string | NONE", default: "NONE", assert: "$value IS NONE OR $value IN ['immediate','high','medium','low']"},
    %{name: "severity_level", type: "string | NONE", default: "NONE", assert: "$value IS NONE OR $value IN ['critical','major','minor','indeterminate']"},
    %{name: "classification", type: "string | NONE", default: "NONE", assert: "$value IS NONE OR $value IN ['major','minor']"},
    %{name: "priority_justification", type: "string | NONE", default: "NONE"},
    %{name: "priority_policy_version", type: "record<incident_policy_version> | NONE", ref: "incident_policy_version", default: "NONE"},
    %{name: "priority_override_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "domain_provenance", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "track_plan", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "restoration_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "hold_reason", type: "string | NONE", default: "NONE"},
    %{name: "hold_owner", type: "record<user> | NONE", ref: "user", default: "NONE"},
    %{name: "expected_resume_at", type: "datetime | NONE", default: "NONE"},
    %{name: "resume_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "problem", type: "record<ticket> | NONE", ref: "ticket", default: "NONE"},
    %{name: "notification_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "confirmation_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "response_evidence", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "closure_approval", type: "object | NONE", flexible: true, default: "NONE"},
    %{name: "cancellation_reason", type: "string | NONE", default: "NONE"},
    %{name: "workaround", type: "object | NONE", flexible: true, default: "NONE"}
  ]

  # A published version is immutable at the domain boundary; drafts are never
  # used as clock bindings. No policy, calendar or counter value is seeded.
  @incident_tables [
    %{
      name: "sla_clock",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "ticket", type: "record<ticket>", ref: "ticket"},
        %{name: "kind", type: "string", assert: "$value IN ['response','resolution']"},
        %{
          name: "priority",
          type: "string | NONE",
          default: "NONE",
          assert: "$value IS NONE OR $value IN ['P1','P2','P3','P4']"
        },
        %{name: "cycle", type: "int", assert: "$value > 0"},
        %{
          name: "carried_elapsed_us",
          type: "int | NONE",
          default: "NONE",
          assert: "$value IS NONE OR $value >= 0"
        },
        %{
          name: "previous_cycle",
          type: "record<sla_clock> | NONE",
          ref: "sla_clock",
          default: "NONE"
        },
        %{
          name: "reopen_mode",
          type: "string | NONE",
          default: "NONE",
          assert: "$value IS NONE OR $value IN ['cumulative','new_cycle']"
        },
        %{name: "domain_revision", type: "int", assert: "$value > 0"},
        %{name: "history_complete", type: "bool"},
        %{name: "started_at", type: "datetime | NONE", default: "NONE"},
        %{name: "stopped_at", type: "datetime | NONE", default: "NONE"},
        %{name: "qualified_pause_us", type: "int | NONE", default: "NONE", assert: "$value IS NONE OR $value >= 0"},
        %{name: "current_hold", type: "record<incident_hold_episode> | NONE", ref: "incident_hold_episode", default: "NONE"},
        %{name: "policy_version", type: "record<incident_policy_version> | NONE", ref: "incident_policy_version", default: "NONE"},
        %{name: "calendar_version", type: "record<incident_calendar_version> | NONE", ref: "incident_calendar_version", default: "NONE"}
      ],
      indexes: [{"sla_clock_cycle", "workspace, ticket, kind, cycle", unique: true}]
    },
    %{
      name: "incident_hold_episode",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "clock", type: "record<sla_clock>", ref: "sla_clock"},
        %{name: "episode", type: "int", assert: "$value > 0"},
        %{name: "domain_revision", type: "int", assert: "$value > 0"},
        %{name: "reason", type: "string | NONE", default: "NONE"},
        %{name: "started_at", type: "datetime | NONE", default: "NONE"},
        %{name: "ended_at", type: "datetime | NONE", default: "NONE"},
        %{name: "expected_resume_at", type: "datetime | NONE", default: "NONE"},
        %{name: "pause_cap_at", type: "datetime | NONE", default: "NONE"},
        %{name: "qualified_pause_us", type: "int | NONE", default: "NONE", assert: "$value IS NONE OR $value >= 0"},
        %{name: "evidence", type: "object | NONE", flexible: true, default: "NONE"}
      ],
      indexes: [{"incident_hold_clock_episode", "workspace, clock, episode", unique: true}]
    },
    %{
      name: "incident_policy_version",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "policy_key", type: "string"},
        %{name: "version", type: "int", assert: "$value > 0"},
        %{name: "schema_version", type: "int", assert: "$value > 0"},
        %{name: "revision", type: "int", assert: "$value > 0"},
        %{name: "status", type: "string", assert: "$value IN ['draft','published']"},
        %{name: "definition", type: "object", flexible: true},
        %{name: "created_at", type: "datetime"},
        %{name: "created_by", type: "object", flexible: true},
        %{name: "published_at", type: "datetime | NONE", default: "NONE"},
        %{name: "published_by", type: "object | NONE", flexible: true, default: "NONE"},
        %{name: "calendar_version", type: "record<incident_calendar_version> | NONE", ref: "incident_calendar_version", default: "NONE"}
      ],
      indexes: [{"incident_policy_key_version", "workspace, policy_key, version", unique: true}]
    },
    %{
      name: "incident_calendar_version",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "calendar_key", type: "string"},
        %{name: "version", type: "int", assert: "$value > 0"},
        %{name: "schema_version", type: "int", assert: "$value > 0"},
        %{name: "revision", type: "int", assert: "$value > 0"},
        %{name: "status", type: "string", assert: "$value IN ['draft','published']"},
        %{name: "timezone", type: "string | NONE", default: "NONE"},
        %{name: "timezone_rules_version", type: "string | NONE", default: "NONE"},
        %{name: "definition", type: "object", flexible: true},
        %{name: "created_at", type: "datetime"},
        %{name: "created_by", type: "object", flexible: true},
        %{name: "published_at", type: "datetime | NONE", default: "NONE"},
        %{name: "published_by", type: "object | NONE", flexible: true, default: "NONE"}
      ],
      indexes: [{"incident_calendar_key_version", "workspace, calendar_key, version", unique: true}]
    },
    %{
      name: "incident_configuration",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace", assert: "$this.id = type::record('incident_configuration', 'current')"},
        %{name: "revision", type: "int", assert: "$value > 0"},
        %{name: "draft", type: "object | NONE", flexible: true, default: "NONE"},
        %{name: "updated_at", type: "datetime"},
        %{name: "updated_by", type: "object", flexible: true},
        %{name: "active_policy_version", type: "record<incident_policy_version> | NONE", ref: "incident_policy_version", default: "NONE"}
      ],
      indexes: [{"incident_configuration_workspace", "workspace", unique: true}]
    }
  ]

  @tables [
    %{
      name: "workflow",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "name", type: "string"},
        %{name: "ticket_type", type: "string"},
        %{name: "definition", type: "object", flexible: true},
        %{name: "published_definition", type: "object | NONE", default: "NONE", flexible: true},
        %{name: "revision", type: "int", default: "1"},
        %{name: "published_revision", type: "int", default: "0"},
        %{name: "updated_at", type: "datetime"}
      ],
      indexes: [{"workflow_workspace_name", "workspace, name", []}]
    },
    %{
      name: "workflow_run",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "ticket", type: "record<ticket>", ref: "ticket"},
        %{name: "workflow", type: "record<workflow>", ref: "workflow"},
        %{name: "workflow_revision", type: "int"},
        %{name: "definition", type: "object", flexible: true},
        %{name: "data", type: "object", flexible: true},
        %{name: "status", type: "string", assert: "$value IN ['active','completed']"},
        %{name: "revision", type: "int", default: "1"},
        %{name: "updated_at", type: "datetime"}
      ],
      indexes: [{"workflow_run_workspace_ticket", "workspace, ticket", ["UNIQUE"]}]
    },
    %{
      name: "workspace",
      fields: [
        %{name: "name", type: "string"},
        %{name: "home_dc", type: "string"},
        %{
          name: "status",
          type: "string",
          default: "'active'",
          assert: "$value IN ['active','suspended','archived']"
        },
        %{name: "sequence", type: "int", default: "0"}
      ]
    },
    %{
      name: "user",
      fields: [
        %{name: "email", type: "string"},
        %{name: "display_name", type: "string"},
        %{name: "disabled", type: "bool", default: "false"},
        %{name: "roles", type: "array<string>", default: "[]"},
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        # The local account's credential. `docs/09` §3: the password is
        # hashed with Argon2id and **only the hash** is stored. An account
        # with no hash is an account that cannot be signed into — it exists
        # for the corpus's other purposes, and it is never a default account
        # with a default password.
        %{name: "password_hash", type: "string | NONE", default: "NONE"},
        %{name: "password_changed_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"user_email", "workspace, email", []}
      ]
    },
    %{
      # A server-side session (`docs/09` §3). The browser holds an opaque
      # 256-bit token; **only its SHA-256 digest is stored**, so the three
      # digest fields are the credentials the store holds. The session lives
      # in the store rather than in the BEAM, which is what makes a Node
      # restart unable to invalidate it.
      name: "session",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "principal_id", type: "string"},
        %{name: "roles", type: "array<string>", default: "[]"},
        %{name: "kind", type: "string", default: "'human'"},
        %{name: "token_digest", type: "string"},
        %{name: "scope_digest", type: "string"},
        %{name: "csrf_digest", type: "string"},
        %{name: "created_at", type: "datetime"},
        %{name: "last_seen_at", type: "datetime"},
        %{name: "absolute_expires_at", type: "datetime"},
        %{name: "idle_expires_at", type: "datetime"},
        %{name: "rotated_at", type: "datetime"}
      ],
      indexes: [
        {"session_token", "token_digest", []},
        {"session_scope", "scope_digest", []},
        {"session_principal", "principal_id", []}
      ]
    },
    %{
      name: "ci",
      fields: [
        # A reference is a plain id in the port and a record reference in the
        # store. The corpus's schema (`docs/07`) types these fields as
        # records, and the Adapter is what maps one onto the other.
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "ci_type", type: "record<ci_type>", ref: "ci_type", required_ref: "unclassified"},
        %{name: "name", type: "string"},
        %{
          name: "lifecycle_state",
          type: "string",
          default: "'active'",
          assert: "$value IN ['proposed','active','in_maintenance','retired','disposed']"
        },
        %{
          name: "criticality",
          type: "string",
          default: "'medium'",
          assert: "$value IN ['low','medium','high','tier1']"
        },
        %{name: "attributes", type: "object", default: "{}", flexible: true},
        %{name: "baseline_version", type: "int", default: "0"},
        %{name: "actual_version", type: "int", default: "0"},
        %{name: "owner", type: "record<user> | NONE", ref: "user", default: "NONE"},
        %{name: "sequence", type: "int", default: "0"},
        %{name: "created_at", type: "datetime | NONE", default: "NONE"},
        %{name: "updated_at", type: "datetime | NONE", default: "NONE"},
        %{name: "deleted_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"ci_workspace_type", "workspace, ci_type", []},
        {"ci_workspace_name", "workspace, name", []},
        {"ci_workspace_crit", "workspace, criticality", []}
      ]
    },
    %{
      name: "program",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "name", type: "string"},
        %{name: "description", type: "string", default: "''"},
        # The RAG status `docs/04` §6 counts by ("Program RAG | Count by
        # status"). It is a delivery status, not a ticket state.
        %{
          name: "status",
          type: "string",
          default: "'amber'",
          assert: "$value IN ['red','amber','green']"
        },
        %{name: "owner", type: "record<user> | NONE", ref: "user", default: "NONE"},
        %{name: "target_date", type: "datetime | NONE", default: "NONE"},
        %{name: "started_at", type: "datetime | NONE", default: "NONE"},
        %{name: "sequence", type: "int", default: "0"},
        %{name: "created_at", type: "datetime | NONE", default: "NONE"},
        %{name: "updated_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"program_workspace_name", "workspace, name", []},
        {"program_workspace_status", "workspace, status", []}
      ]
    },
    %{
      name: "milestone",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "program", type: "record<program> | NONE", ref: "program", default: "NONE"},
        %{name: "name", type: "string"},
        %{name: "description", type: "string", default: "''"},
        %{
          name: "status",
          type: "string",
          default: "'planned'",
          assert: "$value IN ['planned','in_progress','blocked','done']"
        },
        # The burn-up is planned against actual (`docs/04` §6), so both dates
        # are the record's own.
        %{name: "planned_date", type: "datetime | NONE", default: "NONE"},
        %{name: "actual_date", type: "datetime | NONE", default: "NONE"},
        %{name: "owner", type: "record<user> | NONE", ref: "user", default: "NONE"},
        %{name: "sequence", type: "int", default: "0"},
        %{name: "created_at", type: "datetime | NONE", default: "NONE"},
        %{name: "updated_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"milestone_workspace_program", "workspace, program", []},
        {"milestone_workspace_status", "workspace, status", []}
      ]
    },
    %{
      name: "work_item",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "milestone", type: "record<milestone> | NONE", ref: "milestone", default: "NONE"},
        %{name: "title", type: "string"},
        %{name: "description", type: "string", default: "''"},
        %{
          name: "state",
          type: "string",
          default: "'planned'",
          assert: "$value IN ['planned','in_progress','blocked','done']"
        },
        # When the item was blocked: the aging `docs/04` §6 reports is
        # measured from here.
        %{name: "blocked_at", type: "datetime | NONE", default: "NONE"},
        # The links the section names: work items linked to CIs and to
        # Changes. They are plain ids, because a Work Item links to records
        # of two different kinds and the Adapter maps a reference one field
        # at a time.
        %{name: "ci_refs", type: "array<string>", default: "[]"},
        %{name: "change_refs", type: "array<string>", default: "[]"},
        %{name: "owner", type: "record<user> | NONE", ref: "user", default: "NONE"},
        %{name: "due_date", type: "datetime | NONE", default: "NONE"},
        %{name: "sequence", type: "int", default: "0"},
        %{name: "created_at", type: "datetime | NONE", default: "NONE"},
        %{name: "updated_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"work_item_workspace_milestone", "workspace, milestone", []},
        {"work_item_workspace_state", "workspace, state", []}
      ]
    },
    %{
      name: "benefit",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "work_item", type: "record<work_item> | NONE", ref: "work_item", default: "NONE"},
        # `docs/04` §6 counts benefits by type.
        %{name: "kind", type: "string"},
        %{name: "description", type: "string", default: "''"},
        %{name: "realised_at", type: "datetime | NONE", default: "NONE"},
        %{name: "sequence", type: "int", default: "0"},
        %{name: "created_at", type: "datetime | NONE", default: "NONE"},
        %{name: "updated_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"benefit_workspace_work_item", "workspace, work_item", []},
        {"benefit_workspace_kind", "workspace, kind", []}
      ]
    },
    %{
      name: "ticket",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{
          name: "ticket_type",
          type: "string",
          assert: "$value IN ['service_request','incident','change','problem','vulnerability']"
        },
        %{name: "state", type: "string"},
        %{name: "title", type: "string"},
        %{name: "description", type: "string", default: "''"},
        %{name: "requester", type: "record<user>", ref: "user"},
        %{name: "assignee", type: "record<user> | NONE", ref: "user", default: "NONE"},
        %{
          name: "priority",
          type: "string | NONE",
          default: "IF $this.ticket_type = 'incident' { NONE } ELSE { 'medium' }",
          assert:
            "($this.ticket_type = 'incident' AND $value IS NONE) OR $value IN ['low','medium','high','urgent']"
        },
        %{
          name: "impact",
          type: "int | NONE",
          default: "NONE",
          assert: "$value IS NONE OR ($value >= 1 AND $value <= 5)"
        },
        %{
          name: "urgency",
          type: "int | NONE",
          default: "NONE",
          assert: "$value IS NONE OR ($value >= 1 AND $value <= 5)"
        },
        %{
          name: "severity",
          type: "string | NONE",
          default: "NONE",
          assert: "$value IS NONE OR $value IN ['sev1','sev2','sev3','sev4','sev5']"
        },
        %{name: "sla_ref", type: "record<sla_policy> | NONE", ref: "sla_policy", default: "NONE"},
        %{name: "opened_at", type: "datetime"},
        %{name: "acknowledged_at", type: "datetime | NONE", default: "NONE"},
        %{name: "resolved_at", type: "datetime | NONE", default: "NONE"},
        %{name: "closed_at", type: "datetime | NONE", default: "NONE"},
        %{name: "sequence", type: "int"},
        %{name: "deleted_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"ticket_workspace", "workspace", []},
        {"ticket_state", "workspace, ticket_type, state", []}
      ]
    },
    %{
      name: "incident",
      fields: [
        %{name: "ticket_id", type: "string"},
        %{
          name: "incident_class",
          type: "string",
          default: "'service_degradation'",
          assert:
            "$value IN ['service_degradation','service_outage','security_incident','test_incident']"
        },
        %{name: "restore_track", type: "string", default: "'open'"},
        %{name: "root_cause_track", type: "string", default: "'not_started'"},
        %{name: "resolution_code", type: "string | NONE", default: "NONE"},
        %{name: "major", type: "bool", default: "false"},
        %{name: "promoted_to", type: "string | NONE", default: "NONE"}
      ] ++ @incident_fields,
      indexes: [
        {"incident_ticket", "ticket_id", unique: true}
      ]
    },
    %{
      name: "ticket_detail",
      fields: [
        %{name: "ticket_id", type: "string"},
        %{name: "ticket_type", type: "string"}
      ],
      indexes: [
        {"ticket_detail_ticket", "ticket_id", unique: true}
      ]
    },
    %{
      name: "ticket_transition",
      type: "NORMAL",
      fields: [
        %{name: "ticket_type", type: "string"},
        %{name: "from_state", type: "string"},
        %{name: "to_state", type: "string"},
        %{name: "requires_approval", type: "bool", default: "false"},
        %{name: "sla_effect", type: "string", default: "'none'"}
      ],
      indexes: [
        {"ticket_transition_from", "ticket_type, from_state, to_state", unique: true}
      ]
    },
    %{
      name: "audit_event",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "sequence", type: "int | NONE", default: "NONE"},
        %{name: "subject", type: "string"},
        %{name: "subject_table", type: "string"},
        %{name: "from_state", type: "string | NONE", default: "NONE"},
        %{name: "to_state", type: "string | NONE", default: "NONE"},
        %{name: "actor_type", type: "string | NONE", default: "NONE"},
        %{name: "actor_id", type: "string | NONE", default: "NONE"},
        %{name: "timestamp", type: "datetime"},
        %{name: "reason", type: "string | NONE", default: "NONE"},
        %{name: "correlation_id", type: "string | NONE", default: "NONE"},
        %{name: "prev_hash", type: "string | NONE", default: "NONE"},
        %{name: "hash", type: "string"},
        %{name: "diff", type: "option<object>", flexible: true}
      ],
      indexes: [
        {"audit_subject", "workspace, subject", []},
        {"audit_correlation", "correlation_id", []},
        {"audit_chain", "workspace, sequence", unique: true}
      ]
    },
    %{
      name: "event_outbox",
      fields: [
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "sequence", type: "int"},
        %{name: "table", type: "string"},
        %{name: "record_id", type: "string"},
        %{name: "op", type: "string"},
        %{name: "at", type: "datetime"},
        # The corpus's relay columns: the event's type, its payload, and when
        # the relay published it.
        %{name: "event_type", type: "string"},
        %{name: "payload", type: "option<object>", flexible: true},
        %{name: "published_at", type: "datetime | NONE", default: "NONE"}
      ],
      indexes: [
        {"outbox_workspace", "workspace, sequence", unique: true}
      ]
    },
    %{
      name: "ci_type",
      fields: [
        %{name: "name", type: "string"},
        # The JSON Schema of the attributes a CI of this type carries.
        %{name: "schema", type: "object", default: "{}", flexible: true},
        %{name: "required", type: "array<string>", default: "[]"},
        %{name: "plural", type: "string"},
        %{name: "workspace", type: "record<workspace>", ref: "workspace"}
      ]
    },
    %{
      name: "relation_kind",
      fields: [
        %{name: "from_table", type: "string"},
        %{name: "to_table", type: "string"},
        %{name: "inverse", type: "string | NONE", default: "NONE"},
        %{name: "description", type: "string | NONE", default: "NONE"},
        %{name: "attributes", type: "option<object>", flexible: true}
      ]
    },
    %{
      name: "provider",
      fields: [
        # A provider is the Workspace's own configuration: which models it
        # speaks to, where they live, and which credential answers for them.
        # It is scoped by its Workspace, and the Adapter stamps that scope on
        # it — the registry does not decide which Workspace a provider is in.
        %{name: "workspace", type: "record<workspace>", ref: "workspace"},
        %{name: "kind", type: "string"},
        %{name: "adapter", type: "string"},
        %{name: "base_url", type: "string | NONE", default: "NONE"},
        %{name: "model", type: "string | NONE", default: "NONE"},
        # The **name** of the environment the credential is in, never the
        # credential itself: the store holds where to look, not the secret.
        %{name: "credential_env", type: "string | NONE", default: "NONE"},
        # The acceptance of the contractual floor. It is **evidence** that the
        # risk was shown to somebody, not a condition on using the provider,
        # so it is recorded with who accepted it and when — and it is written
        # only when there is an acceptance to record.
        %{name: "capability_floor_acknowledged", type: "bool", default: "false"},
        %{name: "capabilities", type: "array<string>", default: "[]"},
        %{name: "capability_floor_acknowledged_by", type: "option<object>", flexible: true},
        %{name: "capability_floor_acknowledged_at", type: "option<datetime>"}
      ],
      indexes: [
        {"provider_workspace", "workspace", []}
      ]
    },
    %{
      name: "search_chunk",
      fields: [
        %{name: "subject", type: "string"},
        %{name: "chunk_index", type: "int"},
        %{name: "content", type: "string"},
        %{name: "embedding", type: "option<array<float>>"},
        %{name: "model", type: "string | NONE", default: "NONE"},
        %{name: "version", type: "string | NONE", default: "NONE"}
      ],
      indexes: [
        {"search_chunk_fts", "content", fulltext: true}
      ]
    },
    %{
      name: "metric_sample",
      fields: [
        %{name: "target", type: "string"},
        %{name: "metric", type: "string"},
        %{name: "at", type: "datetime"},
        %{name: "value", type: "float"}
      ],
      indexes: [
        {"metric_sample_target", "target, at", []}
      ]
    },
    %{
      name: "workspace_sequence",
      fields: [
        %{name: "next_value", type: "int"}
      ]
    },
    %{
      name: "schema_version",
      fields: [
        %{name: "version", type: "string"},
        %{name: "applied_at", type: "datetime"}
      ]
    }
  ] ++ @incident_tables

  @doc "The tables the schema declares, with their fields."
  @spec tables() :: [map()]
  def tables, do: @tables

  @doc """
  The field names each table should have.

  The migration uses this to remove the fields an earlier version declared and
  this one does not.
  """
  @spec field_names() :: %{String.t() => [String.t()]}
  def field_names do
    Map.new(@tables, fn table ->
      {table.name, Enum.map(table.fields, & &1.name)}
    end)
  end

  @doc """
  Which fields hold a reference to a record of another table.

  A reference is a plain id in the port and a record reference in the store:
  the corpus's schema (`docs/07`) types `workspace`, `ci_type`, `requester`
  and `owner` as records, and the Adapter is what maps one onto the other.
  """
  @spec reference_fields() :: %{String.t() => %{String.t() => String.t()}}
  def reference_fields do
    Map.new(@tables, fn table ->
      refs = for field <- table.fields, ref = field[:ref], do: {field.name, ref}

      {table.name, Map.new(refs)}
    end)
  end

  @doc """
  The declared type of every field.
  """
  @spec field_types() :: %{String.t() => %{String.t() => String.t()}}
  def field_types do
    Map.new(@tables, fn table ->
      {table.name, Map.new(table.fields, &{&1.name, &1.type})}
    end)
  end

  @doc """
  The full specification of every field: its type, whether it is flexible, and
  the default and the assertion it carries.

  The migration needs the modifiers as well as the type. A field that is
  `FLEXIBLE` accepts the free-form keys a JSON payload carries, and a widened
  field that loses its `FLEXIBLE` refuses the very rows the migration is
  trying to move — the row is written, and the store rejects it for carrying a
  key the column does not declare.
  """
  @spec field_specs() :: %{String.t() => %{String.t() => map()}}
  def field_specs do
    Map.new(@tables, fn table ->
      {table.name, Map.new(table.fields, &{&1.name, &1})}
    end)
  end

  @doc """
  The fields each table declares.
  """
  @spec declared_fields() :: %{String.t() => [String.t()]}
  def declared_fields do
    Map.new(@tables, fn table ->
      {table.name, Enum.map(table.fields, & &1.name)}
    end)
  end

  @doc """
  The default value of each field that has one.

  The migration needs them: a field an earlier schema did not have is absent
  from the row, and a row written without it is rejected by the store's
  coercion. The backfill states the default, so the row matches the schema
  it is now under.
  """
  @spec defaults() :: %{String.t() => %{String.t() => String.t()}}
  def defaults do
    Map.new(@tables, fn table ->
      defaults = for field <- table.fields, default = field[:default], do: {field.name, default}

      {table.name, Map.new(defaults)}
    end)
  end

  @doc """
  Which fields hold a reference that a row must carry.

  The corpus makes `ci.ci_type` required, so a CI row that arrives without
  one is given the placeholder type rather than being written with a field
  the schema does not accept.
  """
  @spec required_references() :: %{String.t() => %{String.t() => String.t()}}
  def required_references do
    Map.new(@tables, fn table ->
      refs =
        for field <- table.fields,
            placeholder = field[:required_ref],
            do: {field.name, placeholder}

      {table.name, Map.new(refs)}
    end)
  end

  @doc """
  Which fields hold a datetime.

  The store answers a datetime as an ISO-8601 string. The Adapter turns those
  back into `DateTime` structs on the way out, so the domain never sees a
  datetime as a string — and so a row read from the store can be written back
  without the store rejecting the string it just returned.
  """
  @spec datetime_fields() :: %{String.t() => [String.t()]}
  def datetime_fields do
    Map.new(@tables, fn table ->
      fields =
        for field <- table.fields,
            String.contains?(field.type, "datetime"),
            do: field.name

      {table.name, fields}
    end)
  end

  @doc """
  The statements that bring a Workspace to the current schema.
  """
  @spec statements() :: [String.t()]
  def statements do
    analyzer_statements() ++ Enum.map(@tables, &table_statements/1)
  end

  @doc """
  The table definitions alone, without their fields.

  The migration needs them before the fields. A table the store does not hold
  yet is created as an ordinary table when a field is defined on it, and a
  field that is `FLEXIBLE` may only be used in a `SCHEMAFULL` table — so the
  table is made `SCHEMAFULL` first, and the fields follow.
  """
  @spec table_definitions() :: [String.t()]
  def table_definitions do
    Enum.map(@tables, &table_definition/1)
  end

  @doc """
  The unique indexes the schema declares, with the table and the fields each
  one covers.

  A unique index is built on a field the reconciliation can fill, and the
  reconciliation gives every legacy row the same value for a field it lacks.
  The index would then refuse the second row, so the index has to be out of
  the way while the reconciliation runs — and the rows have to end up
  distinct. This is the list that says which fields are in that class.
  """
  @spec declared_unique_indexes() :: [
          %{table: String.t(), name: String.t(), fields: [String.t()]}
        ]
  def declared_unique_indexes do
    Enum.flat_map(@tables, fn table ->
      table[:indexes]
      |> Kernel.||([])
      |> Enum.filter(fn {_name, _columns, opts} -> Keyword.get(opts, :unique) == true end)
      |> Enum.map(fn {name, columns, _opts} ->
        %{
          table: table.name,
          name: name,
          fields: columns |> String.split(",") |> Enum.map(&String.trim/1)
        }
      end)
    end)
  end

  @doc """
  The fields of a table that a unique index covers.
  """
  @spec unique_indexed_fields(String.t()) :: [String.t()]
  def unique_indexed_fields(table) do
    declared_unique_indexes()
    |> Enum.filter(&(&1.table == table))
    |> Enum.flat_map(& &1.fields)
    |> Enum.uniq()
  end

  @doc """
  The seed rows: the transition table, the CI types and the relation kinds.

  The state machine is data, not code (ADR-003), so it is seeded with the
  schema rather than hard-coded into a `case` in the context.

  The seeds are Workspace-scoped: the CI type registry carries the Workspace
  that owns it (`docs/07`), so the seed needs to know which Workspace it is
  seeding.
  """
  @spec seed_statements(String.t()) :: [String.t()]
  def seed_statements(workspace \\ "default") do
    transition_seeds() ++ ci_type_seeds(workspace) ++ relation_kind_seeds()
  end

  @doc """
  The statement that records the schema version the Workspace is at.

  The doctor reads it, so "is this Workspace at the version the Adapter
  expects?" is a question with an answer rather than a guess.
  """
  @spec version_statement() :: String.t()
  def version_statement do
    """
    UPSERT schema_version:current SET
      id = 'current',
      version = '#{@version}',
      applied_at = d'#{DateTime.utc_now() |> DateTime.to_iso8601()}'
    """
  end

  @doc """
  The ticket transitions the current slice ships.

  The Incident lifecycle from `docs/02` §State machines, complete.

  The corpus's diagram has ten edges, and the table holds all ten. The two an
  earlier slice left out — `acknowledged → on_hold` and `on_hold → resolved` —
  are legal in `docs/02`, and the corpus gives no reason to refuse them: the
  approval machinery it asks for gates *closing* an Incident with an open
  root-cause track (`docs/02` §Approvals), which is a condition on a
  transition rather than a state in this lifecycle, and it lands with the
  rest of that work.

  The lookup table is the data the service layer enforces transitions
  against, so a plugin can extend it and the enforcement point stays in one
  place.
  """
  @spec incident_transitions() :: [{String.t(), String.t(), String.t()}]
  def incident_transitions do
    [
      {"incident", "new", "acknowledged"},
      {"incident", "new", "cancelled"},
      {"incident", "acknowledged", "in_progress"},
      {"incident", "acknowledged", "on_hold"},
      {"incident", "in_progress", "on_hold"},
      {"incident", "in_progress", "resolved"},
      {"incident", "on_hold", "in_progress"},
      {"incident", "on_hold", "resolved"},
      {"incident", "resolved", "closed"},
      {"incident", "resolved", "in_progress"}
    ]
  end

  @doc """
  The transitions of every ticket type, from `docs/02`.

  The authorisation edges are here because the corpus names them **and** the
  Policy's own authorisation states name them: `docs/02` §Change has
  `submitted → authorized` and §Vulnerability has `triaged → accepted_risk`.
  A Change's authorisation is a decision the Policy polices, so without
  those edges the states it calls authorisations could not be reached at all
  and the separation of duty would have had nothing to enforce.
  """
  @spec transitions() :: [{String.t(), String.t(), String.t()}]
  def transitions do
    incident_transitions() ++
      [
        {"service_request", "submitted", "triaged"},
        {"service_request", "submitted", "cancelled"},
        {"service_request", "triaged", "in_progress"},
        {"service_request", "in_progress", "fulfilled"},
        {"service_request", "fulfilled", "closed"},
        {"change", "draft", "submitted"},
        {"change", "draft", "cancelled"},
        {"change", "submitted", "authorized"},
        {"change", "submitted", "rejected"},
        {"change", "submitted", "scheduled"},
        {"change", "authorized", "scheduled"},
        {"change", "scheduled", "implementing"},
        {"change", "implementing", "completed"},
        {"change", "implementing", "rolled_back"},
        {"change", "completed", "closed"},
        {"problem", "new", "under_investigation"},
        {"problem", "under_investigation", "identified"},
        {"problem", "identified", "root_caused"},
        {"problem", "root_caused", "closed"},
        {"vulnerability", "new", "triaged"},
        {"vulnerability", "triaged", "confirmed"},
        {"vulnerability", "triaged", "accepted_risk"},
        {"vulnerability", "confirmed", "mitigated"},
        {"vulnerability", "mitigated", "closed"}
      ]
  end

  @doc "The CI types the CMDB seeds."
  @spec ci_types() :: [String.t()]
  def ci_types, do: ~w(server application service network_device database container unclassified)

  @doc """
  The CI type a row is given when it does not say what it is.

  The corpus makes `ci.ci_type` required (`docs/07`), and a CI without a type
  is not a CI. A row that arrives without one is not silently dropped: it is
  given this type, which the CMDB shows as *Unclassified* — visible, and
  honest, rather than a fabrication hidden in the store.
  """
  @spec unclassified_ci_type() :: String.t()
  def unclassified_ci_type, do: "unclassified"

  @doc "The relation kinds the CMDB seeds."
  @spec relation_kinds() :: [map()]
  def relation_kinds do
    [
      %{
        "id" => "depends_on",
        "from_table" => "ci",
        "to_table" => "ci",
        "inverse" => "required_by"
      },
      %{"id" => "parent_of", "from_table" => "ci", "to_table" => "ci", "inverse" => "child_of"},
      %{
        "id" => "affects",
        "from_table" => "ticket",
        "to_table" => "ci",
        "inverse" => "affected_by"
      },
      %{
        "id" => "implements",
        "from_table" => "ticket",
        "to_table" => "ci",
        "inverse" => "implemented_by"
      },
      %{
        "id" => "remediates",
        "from_table" => "ticket",
        "to_table" => "ci",
        "inverse" => "remediated_by"
      }
    ]
  end

  # ── statement generation ──────────────────────────────────────────────────

  defp analyzer_statements do
    [
      """
      DEFINE ANALYZER OVERWRITE like TOKENIZERS class FILTERS lowercase,ascii,snowball(english);
      DEFINE ANALYZER OVERWRITE veritas_text TOKENIZERS class FILTERS lowercase,ascii,snowball(english);
      """
    ]
  end

  defp table_statements(table) do
    definition = definition(table)

    fields = Enum.map(table.fields, &Map.fetch!(definition.fields, &1.name))
    indexes = Enum.map(table[:indexes] || [], fn {name, _, _} -> Map.fetch!(definition.indexes, name) end)
    Enum.join([definition.table | fields ++ indexes], "\n")
  end

  @doc false
  @spec definitions() :: %{String.t() => map()}
  def definitions, do: Map.new(@tables, &{&1.name, definition(&1)})

  @doc false
  @spec incident_definitions() :: %{String.t() => map()}
  def incident_definitions do
    priority = Enum.find(Enum.find(@tables, &(&1.name == "ticket")).fields, &(&1.name == "priority"))

    Map.new(
      [%{name: "ticket", fields: [priority]}, %{name: "incident", fields: @incident_fields}] ++
        @incident_tables,
      &{&1.name, definition(&1)}
    )
  end

  @doc false
  @spec v5_priority_definition() :: String.t()
  def v5_priority_definition do
    field_definition("ticket", %{
      name: "priority",
      type: "string",
      default: "'medium'",
      assert: "$value IN ['low','medium','high','urgent']"
    })
  end

  defp definition(table) do
    %{
      table: table_definition(table),
      fields: Map.new(table.fields, &{&1.name, field_definition(table.name, &1)}),
      indexes:
        Map.new(table[:indexes] || [], fn {name, columns, opts} ->
          unique = if opts[:unique], do: " UNIQUE", else: ""
          fulltext = if opts[:fulltext], do: " FULLTEXT", else: ""

          {name,
           "DEFINE INDEX OVERWRITE #{name} ON #{table.name} FIELDS #{columns}#{fulltext}#{unique};"}
        end)
    }
  end

  defp field_definition(table, field) do
    definition = "DEFINE FIELD OVERWRITE #{field.name} ON #{table} TYPE #{field.type}"
    definition = if field[:flexible], do: definition <> " FLEXIBLE", else: definition
    definition = if field[:default], do: definition <> " DEFAULT #{field.default}", else: definition
    definition = if field[:assert], do: definition <> " ASSERT #{field.assert}", else: definition
    definition <> ";"
  end

  # `SCHEMAFULL` is a modifier, not a type: an ordinary table is declared
  # without `TYPE`, and a typed table with `TYPE NORMAL SCHEMAFULL`.
  defp table_definition(table) do
    kind = if table[:type], do: "TYPE #{table[:type]} SCHEMAFULL", else: "SCHEMAFULL"

    "DEFINE TABLE OVERWRITE #{table.name} #{kind};"
  end

  defp transition_seeds do
    transitions()
    |> Enum.map(fn {type, from, to} ->
      """
      UPSERT ticket_transition:#{type}__#{from}__#{to} SET
        id = '#{type}__#{from}__#{to}',
        ticket_type = '#{type}',
        from_state = '#{from}',
        to_state = '#{to}',
        requires_approval = false,
        sla_effect = 'none'
      """
    end)
  end

  defp ci_type_seeds(workspace) do
    Enum.map(ci_types(), fn type ->
      """
      UPSERT ci_type:#{type} SET
        id = '#{type}',
        name = '#{type}',
        schema = {},
        required = [],
        plural = '#{type}',
        workspace = type::record('workspace', '#{workspace}')
      """
    end)
  end

  defp relation_kind_seeds do
    Enum.map(relation_kinds(), fn kind ->
      """
      UPSERT relation_kind:#{kind["id"]} SET
        id = '#{kind["id"]}',
        from_table = '#{kind["from_table"]}',
        to_table = '#{kind["to_table"]}',
        inverse = '#{kind["inverse"]}',
        description = NONE,
        attributes = NONE;
      #{edge_table_statements(kind)}
      """
    end)
  end

  @doc """
  The name of the edge table a relation kind lives in.

  The table comes from the kind's `from_table` and the kind's own name: a
  relation kind is data, and the table it lives in follows from it. The
  Adapter asks the Schema for the name, so the migration and the Adapter
  cannot drift apart on it.
  """
  @spec edge_table(map()) :: String.t()
  def edge_table(%{"from_table" => from, "id" => id}) when is_binary(from),
    do: "#{from}_#{bare_id(id)}"

  def edge_table(%{"id" => id}), do: "edge_#{bare_id(id)}"

  @doc """
  The statements that define a relation kind's edge table.

  The two endpoints are **indexed**, and that is not an optimisation: an
  unindexed edge turns a hop into a table scan, and a scan of the edge table
  is a scan of every relation in the Workspace. The corpus's gate is a plan:
  a `TableScan` where an `IndexScan` was expected fails the build.

  The statements are idempotent, so the migration may re-apply them to a
  Workspace whose edge tables already hold their edges: a `DEFINE` is a
  schema statement and leaves the rows alone.
  """
  @spec edge_table_statements(map()) :: String.t()
  def edge_table_statements(spec) do
    edge = edge_table(spec)

    """
    DEFINE TABLE OVERWRITE #{edge} TYPE RELATION IN #{spec["from_table"]} OUT #{spec["to_table"]} ENFORCED SCHEMAFULL;
    DEFINE FIELD OVERWRITE kind ON #{edge} TYPE string DEFAULT '#{bare_id(spec["id"])}';
    DEFINE INDEX OVERWRITE #{edge}_in ON #{edge} FIELDS in;
    DEFINE INDEX OVERWRITE #{edge}_out ON #{edge} FIELDS out;
    """
  end

  # A record id's bare form: the part after the table.
  defp bare_id(id) when is_binary(id), do: id |> to_string() |> String.split(":") |> List.last()
  defp bare_id(id), do: id |> to_string() |> String.split(":") |> List.last()
end
