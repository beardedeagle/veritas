defmodule Veritas.Core.Tickets do
  @moduledoc """
  The ticket context: Service Request, Incident, Change, Problem, Vulnerability.

  One context, five ticket types. A ticket is a `ticket` record plus a
  per-type detail record, so the shared lifecycle lives in one place and the
  type-specific fields live in their own table (`docs/07`).

  ## Where the rules live

  The state machine is **not** a `case` in this module. It is the
  `ticket_transition` lookup table, and this context enforces it (ADR-003).
  That keeps one enforcement point, and it lets a plugin extend the legal
  transitions without forking the host.

  ## What this context does not do

  Transitions enforce `Veritas.Core.Policy` inside the write transaction.
  Agent approval belongs to the approval machinery.
  The context is the only place that writes a ticket, which is what makes the
  Audit Log complete.

  ## How it reaches the datastore

  Through the `Veritas.Store` port and nothing else. There is no SurrealQL in
  this module, and no record shape that belongs to a particular engine
  (`docs/32`, ADR-033). The datastore is a **Default**: the shipped Adapter
  is one implementation of the port, and a substitution is a configuration
  change.
  """

  alias Veritas.Core.{Audit, Policy, Principal, WorkspaceLock}
  alias Veritas.Core.Tickets.{Incident, IncidentClock, IncidentPolicy}
  alias Veritas.Store

  @type ticket_type :: String.t()
  @type state :: String.t()
  @type error ::
          {:error, :unknown_ticket_type | :illegal_transition | :not_found | term()}

  @ticket_types ~w(service_request incident change problem vulnerability)
  @ticket_prefixes %{"service_request" => "REQ", "incident" => "INC", "change" => "CHG",
    "problem" => "PRB", "vulnerability" => "VUL"}

  # The content an update owns: the free text a person reads. Every other
  # field on a ticket belongs to the workflow, to the host, or to another
  # operation.
  @content_fields ~w(title description)
  @communication_fields ~w(notification_evidence confirmation_evidence response_evidence)

  @doc "The five canonical ticket types."
  def ticket_types, do: @ticket_types

  @doc "A shareable, typed reference; the stored record ID remains unchanged."
  @spec reference(map()) :: String.t()
  def reference(%{"id" => id, "ticket_type" => type}),
    do: Map.get(@ticket_prefixes, type, "") <> id

  @doc "Parses a complete typed reference while preserving the record ID's case."
  @spec parse_reference(term()) :: {:ok, String.t(), String.t()} | :error
  def parse_reference(reference) when is_binary(reference) do
    with [_, prefix, id] <- Regex.run(~r/\A([A-Za-z]{3})([A-Za-z0-9_]+)\z/, reference),
         {type, _} <- Enum.find(@ticket_prefixes, fn {_, value} -> value == String.upcase(prefix) end) do
      {:ok, type, id}
    else
      _ -> :error
    end
  end
  def parse_reference(_), do: :error

  @doc """
  The fields an update owns.

  The vocabulary belongs here and not to the callers: what a ticket's content
  is is the domain's to say, and a caller that had to know it would be a
  caller that could get it wrong.
  """
  @spec content_fields() :: [String.t()]
  def content_fields, do: @content_fields

  @doc """
  Opens a ticket.

  The ticket row, its type detail row and its first Audit Log entry are
  written in one transaction, so a ticket never exists without a record of
  having been opened.
  """
  @spec open(Store.workspace(), ticket_type(), map(), Audit.actor(), String.t() | nil) ::
          {:ok, map()} | error()
  def open(workspace, ticket_type, attrs, actor, correlation_id \\ nil)
      when is_binary(workspace) and is_binary(ticket_type) and is_map(attrs) do
    if ticket_type in @ticket_types do
      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          open_in_transaction(tx, workspace, ticket_type, attrs, actor, correlation_id)
        end)
      end)
      |> unwrap_incident_denial()
    else
      {:error, :unknown_ticket_type}
    end
  end

  @doc false
  def open_in_transaction(tx, workspace, ticket_type, attrs, actor, correlation_id \\ nil) do
    if ticket_type == "incident" do
      case Policy.authorize_incident(nil, "ticket:write", %{workspace: workspace, operation: :create, correlation_id: correlation_id}, tx) do
        {:deny, reason} -> {:ok, {:denied, reason}}
        {:error, _} = error -> error
      end
    else
      legacy_open_in_transaction(tx, workspace, ticket_type, attrs, actor, correlation_id)
    end
  end

  defp legacy_open_in_transaction(tx, workspace, ticket_type, attrs, actor, correlation_id) do
    if ticket_type in @ticket_types do
      ticket_id = identifier()
      initial_state = initial_state(ticket_type)
      now = DateTime.utc_now()

      with {:ok, sequence} <- Store.next_sequence(tx, "ticket") do
        ticket = %{
          "id" => ticket_id,
          "workspace" => workspace,
          "ticket_type" => ticket_type,
          "state" => initial_state,
          "title" => attr(attrs, "title", "(untitled)"),
          "description" => attr(attrs, "description", ""),
          "requester" => attr(attrs, "requester", "unknown"),
          "priority" => attr(attrs, "priority", "medium"),
          "opened_at" => now,
          "sequence" => sequence
        }

        detail = detail_row(ticket_type, ticket_id)

        audit = %{
          subject: ticket_id,
          subject_table: "ticket",
          from_state: nil,
          to_state: initial_state,
          actor: actor,
          reason: attr(attrs, "reason", nil),
          correlation_id: correlation_id,
          diff: %{"ticket_type" => ticket_type, "state" => initial_state}
        }

        with {:ok, _ticket} <- Store.put(tx, :ticket, ticket),
             {:ok, _detail} <- Store.put(tx, detail_table(ticket_type), detail),
             {:ok, _audit} <- Audit.append(tx, workspace, audit) do
          {:ok, ticket}
        end
      end
    else
      {:error, :unknown_ticket_type}
    end
  end

  @doc """
  Moves a ticket to a new state.

  The transition is checked against the workflow table, then Policy authorizes
  the Principal using persisted relationship facts. The state and audit event
  commit together; a policy denial records only the refusal.
  """
  @spec transition(Store.workspace(), String.t(), state(), Principal.t() | nil, keyword()) ::
          {:ok, map()} | error()
  def transition(workspace, ticket_id, to_state, principal, opts \\ [])
      when is_binary(workspace) and is_binary(ticket_id) and is_binary(to_state) do
    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with :ok <- unmanaged_transition(tx, ticket_id) do
          transition_in_transaction(tx, workspace, ticket_id, to_state, principal, opts)
        end
      end)
    end)
    |> case do
      {:ok, {:denied, reason}} -> {:error, reason}
      result -> result
    end
  end

  defp unmanaged_transition(tx, ticket_id) do
    case Store.fetch(tx, :workflow_run, ticket_id) do
      {:ok, %{"status" => "active"}} -> {:error, :workflow_step_required}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def transition_in_transaction(tx, workspace, ticket_id, to_state, principal, opts \\ []) do
    case Store.fetch(tx, :ticket, ticket_id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %{"ticket_type" => "incident"}} ->
        transition_in_transaction(tx, workspace, ticket_id, to_state, principal,
          audit_actor(principal), Keyword.put(opts, :operation, :transition))

      {:ok, ticket} ->
        authorize_move(tx, workspace, ticket, to_state, principal, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_move(tx, workspace, ticket, to_state, principal, opts) do
    with :ok <- check_transition(tx, ticket["ticket_type"], ticket["state"], to_state),
         {:ok, events} <-
           Store.list(tx, :audit_event, %{
             where: [subject: ticket["id"], subject_table: "ticket"],
             order_by: [sequence: :asc],
             limit: 1
           }) do
      context = %{
        workspace: workspace,
        ticket_type: ticket["ticket_type"],
        to_state: to_state,
        requester: ticket["requester"],
        requester_id: ticket["requester"],
        author_id:
          case events do
            [event] -> event["actor_id"]
            [] -> nil
          end,
        correlation_id: opts[:correlation_id]
      }

      case Policy.authorize(principal, "ticket:transition", context, tx) do
        :allow ->
          opts = Keyword.put(opts, :note, Policy.authorisation_note(principal, context))
          move(tx, workspace, ticket, to_state, Principal.audit_actor(principal), opts)

        {:deny, reason} ->
          # Commit the denial audit event, but leave the ticket untouched.
          {:ok, {:denied, reason}}
      end
    end
  end

  defp move(tx, workspace, ticket, to_state, actor, opts) do
    from_state = ticket["state"]
    now = DateTime.utc_now()

    moved =
      ticket
      |> Map.put("state", to_state)
      |> put_closed_at(to_state, now)

    audit = %{
      subject: ticket["id"],
      subject_table: "ticket",
      from_state: from_state,
      to_state: to_state,
      actor: actor,
      reason: opts[:reason],
      correlation_id: opts[:correlation_id],
      diff: diff(ticket, to_state, opts)
    }

    with {:ok, _ticket} <- Store.put(tx, :ticket, moved),
         {:ok, _audit} <- Audit.append(tx, workspace, audit) do
      {:ok, moved}
    end
  end

  # Policy facts come from the domain, never from caller-supplied notes.
  defp diff(ticket, to_state, opts) do
    %{"state" => to_state}
    |> Map.merge(Policy.profile_fact(ticket["ticket_type"], to_state) || %{})
    |> Map.merge(opts[:note] || %{})
  end

  @doc """
  Updates a ticket's content.

  A ticket's **content** is the free text a person reads: its title and its
  description. This is the only thing an update changes. The state belongs to
  the workflow and moves through `transition/5`; the ticket's type, its
  requester and its identity belong to the host. A field this operation does
  not own is **refused by name** rather than ignored, because a caller that
  sent `state` to an update is not asking for an update, and dropping the
  field would leave it believing the ticket moved.

  The update and its Audit Log entry are written in one transaction, so a
  ticket never carries content the Audit Log does not record. The entry says
  the ticket did not move: `from_state` and `to_state` are the state it
  already held.

  An update that changes nothing is refused with `{:error, :no_change}` and
  writes nothing: an operation that changed nothing must not append an entry
  claiming that it did.

  ## Arguments

    * `workspace` — the Workspace the ticket belongs to.
    * `ticket_id` — the ticket's identifier.
    * `attrs` — a map holding `"title"` and/or `"description"`, and nothing
      else. A field name may be a string or an atom, as elsewhere in this
      module.
    * `actor` — the Principal the change is recorded against.
    * `opts` — `:reason` and `:correlation_id`, as `transition/5` takes them.

  ## Returns

    `{:ok, ticket}` with the updated row, or `{:error, reason}`:

    * `:not_found` — there is no such ticket.
    * `{:not_updatable, field}` — `field` is not content.
    * `:no_change` — the content already holds the requested values.

  ## Raises

    Nothing. A refusal is a return value and not an exception: a caller that
    sent a field this operation does not own is answered, not crashed.
  """
  @spec update(Store.workspace(), String.t(), map(), Audit.actor(), keyword()) ::
          {:ok, map()} | error()
  def update(workspace, ticket_id, attrs, actor, opts \\ [])
      when is_binary(workspace) and is_binary(ticket_id) and is_map(attrs) do
    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        case Store.fetch(tx, :ticket, ticket_id) do
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, %{"ticket_type" => "incident"} = ticket} ->
            incident_denial(tx, workspace, ticket, nil, {:principal_required, %{operation: :content}})

          {:ok, ticket} ->
            edit(tx, workspace, ticket, attrs, actor, opts)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
    |> unwrap_incident_denial()
  end

  defp edit(tx, workspace, ticket, attrs, actor, opts) do
    case content_changes(ticket, attrs) do
      {:error, reason} ->
        {:error, reason}

      {:ok, changes} ->
        updated = Map.merge(ticket, changes)

        audit = %{
          subject: ticket["id"],
          subject_table: "ticket",
          from_state: ticket["state"],
          to_state: ticket["state"],
          actor: actor,
          reason: opts[:reason],
          correlation_id: opts[:correlation_id],
          diff: changes
        }

        with {:ok, _ticket} <- Store.put(tx, :ticket, updated),
             {:ok, _audit} <- Audit.append(tx, workspace, audit) do
          {:ok, updated}
        end
    end
  end

  # The content this operation owns, and the changes it would make.
  #
  # A field that is not content is refused **by name**: silently dropping it
  # would leave the caller believing the ticket changed. A value that is not
  # set is not a change, and a value that equals what the ticket already holds
  # is not a change either.
  #
  # The fields are taken in name order, so a write that names more than one
  # field it does not own is always refused for the same one.
  defp content_changes(ticket, attrs) do
    attrs
    |> Enum.map(fn {field, value} -> {field_name(field), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, changes} ->
      cond do
        field not in @content_fields ->
          {:halt, {:error, {:not_updatable, field}}}

        is_nil(value) ->
          {:cont, {:ok, changes}}

        ticket[field] == value ->
          {:cont, {:ok, changes}}

        true ->
          {:cont, {:ok, Map.put(changes, field, value)}}
      end
    end)
    |> case do
      {:ok, changes} when map_size(changes) == 0 -> {:error, :no_change}
      other -> other
    end
  end

  # The field's name, as the corpus writes it: a string. An atom is accepted
  # because the module accepts atom keys everywhere else, and a name that is
  # neither is refused under the name it arrived with.
  defp field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(field), do: inspect(field)

  @doc """
  Assigns a ticket to a user.

  An assignment is **not** a transition: the ticket does not move, and the
  Audit Log entry says so — `from_state` and `to_state` are the state the
  ticket already held. The row and its entry are written in one transaction,
  so a ticket never carries an assignee the Audit Log does not record.

  The assignee is a **user id**, as the requester's is: the domain holds the
  logical id, and the Adapter makes it the record the schema types
  (`docs/07`).

  An assignment that changes nothing is refused with `{:error, :no_change}`
  and writes nothing: an operation that changed nothing must not append an
  entry claiming that it did.

  ## Arguments

    * `workspace` — the Workspace the ticket belongs to.
    * `ticket_id` — the ticket's identifier.
    * `assignee` — the id of the user the ticket is assigned to.
    * `actor` — the Principal the change is recorded against.
    * `opts` — `:reason` and `:correlation_id`, as `transition/5` takes them.

  ## Returns

    `{:ok, ticket}` with the assigned row, or `{:error, reason}`:

    * `:not_found` — there is no such ticket.
    * `:no_change` — the ticket already holds that assignee.

  ## Raises

    Nothing. A refusal is a return value and not an exception: a ticket that
    does not exist, and a ticket that already holds the assignee, are both
    answered.
  """
  @spec assign(Store.workspace(), String.t(), String.t(), Audit.actor(), keyword()) ::
          {:ok, map()} | error()
  def assign(workspace, ticket_id, assignee, actor, opts \\ [])
      when is_binary(workspace) and is_binary(ticket_id) and is_binary(assignee) do
    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        case Store.fetch(tx, :ticket, ticket_id) do
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, %{"ticket_type" => "incident"} = ticket} ->
            incident_denial(tx, workspace, ticket, nil, {:principal_required, %{operation: :assign}})

          {:ok, ticket} ->
            hand_to(tx, workspace, ticket, assignee, actor, opts)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
    |> unwrap_incident_denial()
  end

  # The ticket is handed to the assignee, and the handover is recorded.
  #
  # A ticket that already holds the assignee is not handed to it again: the
  # operation changed nothing, and an entry saying that it did would be a
  # false record of the ticket's ownership.
  defp hand_to(tx, workspace, ticket, assignee, actor, opts) do
    if ticket["assignee"] == assignee do
      {:error, :no_change}
    else
      assigned = Map.put(ticket, "assignee", assignee)

      audit = %{
        subject: ticket["id"],
        subject_table: "ticket",
        from_state: ticket["state"],
        to_state: ticket["state"],
        actor: actor,
        reason: opts[:reason],
        correlation_id: opts[:correlation_id],
        diff: %{"assignee" => assignee}
      }

      with {:ok, _ticket} <- Store.put(tx, :ticket, assigned),
           {:ok, _audit} <- Audit.append(tx, workspace, audit) do
        {:ok, assigned}
      end
    end
  end

  @doc "Reads a ticket by identifier."
  @spec read(Store.workspace(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(workspace, ticket_id) do
    Store.transaction(workspace, fn tx -> Store.fetch(tx, :ticket, ticket_id) end)
  end

  @doc """
  Lists tickets in a workspace, optionally filtered by type and state.
  """
  @spec list(Store.workspace(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(workspace, opts \\ []) do
    where =
      []
      |> put_where(:ticket_type, opts[:ticket_type])
      |> put_where(:state, opts[:state])

    filter = %{
      where: where,
      order_by: [{:opened_at, :desc}],
      limit: Keyword.get(opts, :limit, 50)
    }

    Store.transaction(workspace, fn tx -> Store.list(tx, :ticket, filter) end)
  end

  @doc """
  The CIs that depend on the given CI, and the services they belong to.

  This is the question the CMDB exists to answer, so it is a first-class
  operation rather than a query the caller assembles.
  """
  @spec impact(Store.workspace(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def impact(workspace, ci_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 2)

    Store.transaction(workspace, fn tx -> Store.impact(tx, ci_id, depth) end)
  end

  @doc """
  Whether a transition is legal for the given ticket type and state.
  """
  @spec legal_transition?(Store.workspace(), ticket_type(), state(), state()) :: boolean()
  def legal_transition?(workspace, ticket_type, from_state, to_state) do
    case Store.transaction(workspace, fn tx ->
           case transition_rows(tx, ticket_type, from_state) do
             {:ok, rows} -> {:ok, Enum.any?(rows, &(&1["to_state"] == to_state))}
             {:error, _reason} -> {:ok, false}
           end
         end) do
      {:ok, legal?} -> legal?
      _ -> false
    end
  end

  @doc """
  The states a ticket may move to from its current state.

  Read from the `ticket_transition` lookup table, so the UI and the CLI offer
  exactly what the service layer will accept.
  """
  @spec available_transitions(Store.workspace(), ticket_type(), state()) :: [state()]
  def available_transitions(workspace, ticket_type, from_state) do
    case Store.transaction(workspace, fn tx ->
           case transition_rows(tx, ticket_type, from_state) do
             {:ok, rows} -> {:ok, Enum.map(rows, & &1["to_state"])}
             {:error, _reason} -> {:ok, []}
           end
         end) do
      {:ok, transitions} -> transitions
      _ -> []
    end
  end

  @doc "Creates a ticket with trusted authority and separate host audit attribution."
  @spec open(Store.workspace(), ticket_type(), map(), Principal.t() | nil, Audit.actor(), keyword()) :: {:ok, map()} | error()
  def open(workspace, type, attrs, principal, actor, opts) do
    incident_write(workspace, fn tx -> open_in_transaction(tx, workspace, type, attrs, principal, actor, opts) end)
  end

  @doc false
  def open_in_transaction(tx, workspace, "incident", attrs, principal, actor, opts) do
    now = DateTime.utc_now()
    ticket = %{"id" => identifier(), "workspace" => workspace, "ticket_type" => "incident",
      "state" => "new", "title" => attr(attrs, "title", "(untitled)"),
      "description" => attr(attrs, "description", ""),
      "requester" => attr(attrs, "requester", principal_id(principal)),
      "priority" => nil, "opened_at" => now}
    detail = detail_row("incident", ticket["id"])
    base = Map.take(attrs, ~w(title description priority))

    with {:ok, fields} <- Incident.merge_fields(base, attr(attrs, "domain_fields", %{})) do
      apply_incident(tx, workspace, ticket, detail, fields, principal, actor,
        opts |> Keyword.put(:operation, :create) |> Keyword.put(:transaction_time, now))
    end
  end

  def open_in_transaction(tx, workspace, type, attrs, _principal, actor, opts),
    do: legacy_open_in_transaction(tx, workspace, type, attrs, actor, opts[:correlation_id])

  @doc "Updates content with explicit Incident authority; non-Incident semantics are unchanged."
  @spec update(Store.workspace(), String.t(), map(), Principal.t() | nil, Audit.actor(), keyword()) :: {:ok, map()} | error()
  def update(workspace, id, fields, principal, actor, opts) do
    coordinated_incident_write(workspace, id, fields, principal, actor, opts, :content)
  end

  @doc false
  def update_in_transaction(tx, workspace, id, fields, principal, actor, opts) do
    with {:ok, ticket} <- incident_ticket(tx, id) do
      if ticket["ticket_type"] == "incident" do
        with {:ok, changes} <- content_changes(ticket, fields),
             {:ok, detail} <- incident_detail(tx, id) do
          apply_incident(tx, workspace, ticket, detail, changes, principal, actor, Keyword.put(opts, :operation, :content))
        end
      else
        edit(tx, workspace, ticket, fields, actor, opts)
      end
    end
  end

  @doc "Assigns with explicit Incident authority and optimistic domain revision."
  @spec assign(Store.workspace(), String.t(), String.t(), Principal.t() | nil, Audit.actor(), keyword()) :: {:ok, map()} | error()
  def assign(workspace, id, assignee, principal, actor, opts) do
    coordinated_incident_write(workspace, id, %{"assignee" => assignee}, principal, actor, opts, :assign)
  end

  @doc false
  def assign_in_transaction(tx, workspace, id, assignee, principal, actor, opts) do
    with {:ok, ticket} <- incident_ticket(tx, id) do
      if ticket["ticket_type"] == "incident" do
        with {:ok, detail} <- incident_detail(tx, id) do
          apply_incident(tx, workspace, ticket, detail, %{"assignee" => assignee}, principal, actor, Keyword.put(opts, :operation, :assign))
        end
      else
        hand_to(tx, workspace, ticket, assignee, actor, opts)
      end
    end
  end

  @doc "Transitions with host-derived attribution; active runs still require Workflows."
  @spec transition(Store.workspace(), String.t(), state(), Principal.t() | nil, Audit.actor(), keyword()) :: {:ok, map()} | error()
  def transition(workspace, id, state, principal, actor, opts) do
    incident_write(workspace, fn tx ->
      with :ok <- unmanaged_transition(tx, id) do
        transition_in_transaction(tx, workspace, id, state, principal, actor, Keyword.put(opts, :operation, :transition))
      end
    end)
  end

  @doc false
  def transition_in_transaction(tx, workspace, id, state, principal, actor, opts) do
    with {:ok, ticket} <- incident_ticket(tx, id) do
      if ticket["ticket_type"] == "incident" do
        with {:ok, detail} <- incident_detail(tx, id),
             :ok <- incident_edge(tx, ticket, state, opts) do
          apply_incident(tx, workspace, ticket, detail, Keyword.get(opts, :domain_fields, %{}), principal, actor,
            Keyword.put(opts, :to_state, state))
        end
      else
        authorize_move(tx, workspace, ticket, state, principal, opts)
      end
    end
  end

  @doc """
  Reads authorized canonical Incident facts without changing historical data.

  Returns `{:ok, %{ticket: envelope, domain: string_key_facts,
  domain_revision: integer | nil, workflow_revision: integer | nil,
  raw_legacy: known_field_projection, provenance: map, readiness: map,
  clocks: [clock_view], policy: %{active_version: id | nil}}}`. Clock views
  contain recorded rows/holds and a derived evaluation or safe evaluation code.
  Arbitrary preserved unknown fields and policy drafts are never projected.
  """
  @spec read_domain(Store.workspace(), String.t(), Principal.t() | nil) :: {:ok, map()} | error()
  def read_domain(workspace, id, principal), do: read_domain(workspace, id, principal, [])

  @doc "Internal live-grant read bridge; options/functions are never transport input."
  @spec read_domain(Store.workspace(), String.t(), Principal.t() | nil, keyword()) :: {:ok, map()} | error()
  def read_domain(workspace, id, principal, opts) do
    incident_write(workspace, fn tx ->
      context = %{workspace: workspace, ticket_id: id, operation: :read,
        audit_actor: audit_actor(principal), verify_machine_grant: opts[:verify_machine_grant]}
      case Policy.authorize_incident(principal, "ticket:read", context, tx) do
        :allow ->
          with {:ok, ticket} <- incident_ticket(tx, id),
               true <- ticket["ticket_type"] == "incident" || {:error, :not_found},
               {:ok, detail} <- incident_detail(tx, id),
               :ok <- Incident.validate_provenance(detail),
               {:ok, active} <- IncidentPolicy.active(tx),
               {:ok, run} <- Store.fetch(tx, :workflow_run, id),
               {:ok, clocks} <- incident_rows(tx, :sla_clock, [ticket: id]),
               {:ok, holds} <- incident_holds(tx, clocks),
               {:ok, clock_views} <- clock_views(tx, clocks, holds, opts) do
            facts = Incident.facts(ticket, detail)
            {:ok, %{ticket: incident_envelope(ticket), domain: facts, domain_revision: detail["domain_revision"],
              workflow_revision: run && run["revision"],
              raw_legacy: incident_legacy_view(ticket, detail),
              provenance: incident_provenance_view(detail),
              readiness: incident_readiness(facts, active), clocks: clock_views,
              policy: %{active_version: active && active["id"]}}}
          end
        {:deny, reason} -> {:ok, {:denied, reason}}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Corrects Incident facts without advancing an active workflow or accepting AI output."
  @spec update_domain(Store.workspace(), String.t(), map(), Principal.t() | nil, keyword()) :: {:ok, map()} | error()
  def update_domain(workspace, id, fields, principal, opts) do
    coordinated_incident_write(workspace, id, fields, principal, audit_actor(principal), opts, :amend)
  end

  @doc false
  def update_domain_in_transaction(tx, workspace, id, fields, principal, opts) do
    with {:ok, ticket} <- incident_ticket(tx, id),
         true <- ticket["ticket_type"] == "incident" || {:error, :not_found},
         {:ok, detail} <- incident_detail(tx, id) do
      operation = opts[:operation] || :amend
      operation = if operation == :amend and is_map(fields) and
        Map.keys(fields) -- ~w(title description) == [], do: :content, else: operation
      apply_incident(tx, workspace, ticket, detail, fields, principal,
        opts[:audit_actor] || audit_actor(principal), Keyword.put(opts, :operation, operation))
    end
  end

  @doc "Returns active Incident configuration/readiness and an administrator-only draft."
  @spec incident_policy(Store.workspace(), Principal.t() | nil) :: {:ok, map()} | error()
  def incident_policy(workspace, principal), do: IncidentPolicy.read(workspace, principal)

  @doc "Validates supplied policy content; missing components are readiness, not errors."
  @spec validate_incident_policy(Store.workspace(), map(), Principal.t() | nil) :: {:ok, map()} | error()
  def validate_incident_policy(workspace, document, principal), do: IncidentPolicy.validate_for(workspace, document, principal)

  @doc "Saves a valid partial policy draft with its explicit policy CAS revision."
  @spec save_incident_policy(Store.workspace(), map(), Principal.t() | nil, integer() | nil) :: {:ok, map()} | error()
  def save_incident_policy(workspace, document, principal, revision), do: IncidentPolicy.save(workspace, document, principal, revision)

  @doc "Publishes/consumes the exact approved draft; never rewrites existing clock bindings."
  @spec publish_incident_policy(Store.workspace(), Principal.t() | nil, integer(), keyword()) :: {:ok, map()} | error()
  def publish_incident_policy(workspace, principal, revision, opts), do: IncidentPolicy.publish(workspace, principal, revision, opts)

  defp coordinated_incident_write(workspace, id, fields, principal, actor, opts, operation) do
    with {:ok, managed?} <- Store.transaction(workspace, fn tx ->
           with {:ok, ticket} <- incident_ticket(tx, id), {:ok, run} <- Store.fetch(tx, :workflow_run, id) do
             {:ok, ticket["ticket_type"] == "incident" and is_map(run) and run["status"] == "active"}
           end
         end) do
      if managed? do
        case Veritas.Core.Workflows.update_domain(workspace, id, fields, principal,
               opts |> Keyword.put(:audit_actor, actor) |> Keyword.put(:operation, operation)) do
          {:ok, run} -> {:ok, Map.put(run["domain_ticket"], "workflow_revision", run["revision"])}
          error -> error
        end
      else
        incident_write(workspace, fn tx ->
          with :ok <- unmanaged_transition(tx, id) do
            case operation do
              :content -> update_in_transaction(tx, workspace, id, fields, principal, actor, opts)
              :assign -> assign_in_transaction(tx, workspace, id, fields["assignee"], principal, actor, opts)
              :amend -> update_domain_in_transaction(tx, workspace, id, fields, principal,
                opts |> Keyword.put(:operation, :amend) |> Keyword.put(:audit_actor, actor))
            end
          end
        end)
      end
    end
  end

  defp apply_incident(tx, workspace, ticket, detail, input, principal, actor, opts) do
    operation = opts[:operation]
    state = opts[:to_state] || ticket["state"]
    now = opts[:transaction_time] || DateTime.utc_now()

    with :ok <- Incident.validate_provenance(detail),
         old = Incident.facts(ticket, detail),
         {:ok, patch} <- Incident.normalize(input),
         :ok <- incident_actor(principal, actor),
         {:ok, author} <- incident_author(tx, ticket, operation),
         :ok <- incident_authorize(tx, workspace, ticket, old, patch, state, principal, actor, author, opts),
         :ok <- incident_revision(detail, operation, opts),
         :ok <- Incident.preserve(old, patch),
         {:ok, active} <- IncidentPolicy.active(tx),
         :ok <- IncidentPolicy.version(active, opts),
         {:ok, facts, priority_changed?} <- incident_priority(Map.merge(old, patch), patch, detail, active, principal, opts),
         :ok <- Incident.guard(facts, state, operation, now),
         :ok <- incident_resume(ticket, facts, state),
         :ok <- Incident.references(tx, if(operation in [:transition, :advance], do: facts, else: patch), principal, workspace),
         :ok <- incident_affected_storage(patch),
         :ok <- incident_changed(old, facts, operation),
         {:ok, clocks} <- incident_rows(tx, :sla_clock, [ticket: ticket["id"]]),
         {:ok, holds} <- incident_holds(tx, clocks),
         {:ok, clock_opts} <- incident_clock_options(tx, clocks, active, opts) do
      facts = Map.merge(facts, Incident.attest(patch, principal, now))
      revision = if operation == :create, do: 1, else: (detail["domain_revision"] || 0) + 1
      clock_opts = clock_opts |> Keyword.put(:operation, if(operation in [:content, :assign], do: :amend, else: operation))
        |> Keyword.put(:to_state, state) |> Keyword.put(:domain_revision, revision)
        |> Keyword.put(:resume_evidence, facts["resume_evidence"])

      with {:ok, plan} <- IncidentClock.plan(ticket, facts, clocks, holds, active, now, clock_opts),
           {:ok, ticket} <- incident_sequence(tx, ticket, operation) do
        header = Map.merge(ticket, Map.take(facts, ~w(title description assignee))) |> Map.put("state", state)
        header = if priority_changed? or operation == :create, do: Map.put(header, "priority", IncidentPolicy.storage_priority(facts["priority"])), else: header
        header = if state == "closed" and ticket["state"] != "closed", do: Map.put(header, "closed_at", now), else: header
        provenance = incident_provenance(ticket, detail, patch, facts, principal, now, revision)
        updated = Map.merge(detail, Incident.detail_patch(facts))
          |> Map.put("domain_revision", revision) |> Map.put("domain_provenance", provenance)
        updated = if priority_changed?, do: Map.put(updated, "priority_policy_version", active && active["id"]), else: updated
        updated = if patch["priority_override"], do: Map.put(updated, "priority_override_evidence", %{
          "reason" => patch["priority_override"]["reason"], "expires_at" => patch["priority_override"]["expires_at"],
          "approved_by" => principal.id, "approved_at" => DateTime.to_iso8601(now), "domain_revision" => revision
        }), else: updated
        approval = if state == "closed" and facts["root_cause_track"] != "complete", do: %{
          "actor" => %{"type" => "user", "id" => principal.id}, "approved_at" => DateTime.to_iso8601(now),
          "domain_revision" => revision, "problem_id" => facts["problem_id"],
          "workflow_visit" => opts[:workflow_visit], "workflow_revision" => opts[:expected_revision]
        }
        updated = if approval, do: Map.put(updated, "closure_approval", approval), else: updated

        with {:ok, _} <- Store.put(tx, :ticket, header),
             {:ok, _} <- Store.put(tx, :incident, updated),
             :ok <- incident_store_plan(tx, :sla_clock, plan.clocks, clocks),
             :ok <- incident_store_plan(tx, :incident_hold_episode, plan.holds, holds),
             {:ok, _} <- Audit.append(tx, workspace, %{
               subject: ticket["id"], subject_table: "ticket", actor: actor,
               from_state: if(operation == :create, do: nil, else: ticket["state"]), to_state: state,
               reason: opts[:reason] || "Incident domain operation", correlation_id: opts[:correlation_id],
               diff: %{"operation" => to_string(operation), "domain_revision" => revision,
                 "before" => old, "after" => facts, "effective_at" => DateTime.to_iso8601(now),
                 "policy_version" => active && active["id"], "profile" => Policy.profile_name(),
                 "approval" => approval, "clocks" => incident_audit_rows(plan.clocks),
                 "holds" => incident_audit_rows(plan.holds)}
             }) do
          {:ok, Map.put(incident_envelope(header), "domain_revision", revision)}
        end
      end
    else
      {:ok, {:denied, _}} = denial -> denial
      {:incident_priority_denied, :approval_required} -> incident_priority_denial(tx, workspace, ticket, actor, opts)
      {:error, {:principal_required, _} = reason} -> incident_denial(tx, workspace, ticket, principal, reason)
      {:error, {:invalid_domain_fields, %{"audit_actor" => _}} = reason} -> incident_denial(tx, workspace, ticket, principal, reason)
      {:error, _} = error -> error
    end
  end

  defp incident_actor(%Principal{id: id, kind: :human}, %{id: id, type: type}) when type in ["user", :user], do: :ok
  defp incident_actor(%Principal{id: id, kind: :service}, %{id: id, type: type}) when type in ["plugin", :plugin, "adapter", :adapter, "service", :service], do: :ok
  defp incident_actor(%Principal{}, _), do: {:error, {:invalid_domain_fields, %{"audit_actor" => :forbidden}}}
  defp incident_actor(_, _), do: {:error, {:principal_required, %{operation: :incident_write}}}

  defp incident_authorize(tx, workspace, ticket, old, patch, state, principal, actor, author, opts) do
    facts = Map.merge(old, patch)
    context = %{workspace: workspace, ticket_type: "incident", ticket_id: ticket["id"],
      operation: opts[:operation], fields: Map.keys(patch), from_state: ticket["state"], to_state: state,
      requester_id: ticket["requester"], author_id: author, assignee: facts["assignee"],
      hold_owner: facts["hold_owner_id"], audit_actor: actor, approved: opts[:approve] == true,
      conditional_approval: state == "closed" and facts["root_cause_track"] != "complete",
      verify_machine_grant: opts[:verify_machine_grant], correlation_id: opts[:correlation_id]}
    case Policy.authorize_incident(principal, "ticket:write", context, tx) do
      :allow -> :ok
      {:deny, reason} -> {:ok, {:denied, reason}}
      {:error, _} = error -> error
    end
  end

  defp incident_revision(_detail, :create, _opts), do: :ok
  defp incident_revision(detail, _operation, opts), do: Incident.revision(detail, opts)
  defp incident_author(_tx, _ticket, :create), do: {:ok, nil}
  defp incident_author(tx, ticket, _operation) do
    with {:ok, events} <- Store.list(tx, :audit_event, %{where: [subject: ticket["id"], subject_table: "ticket"], order_by: [sequence: :asc], limit: 1}) do
      {:ok, case events do [event] -> event["actor_id"]; [] -> nil end}
    end
  end

  defp incident_priority(facts, patch, detail, active, principal, opts) do
    changed? = Enum.any?(~w(impact urgency priority priority_justification priority_override), &Map.has_key?(patch, &1)) or
      (is_nil(facts["priority"]) and not is_nil(facts["impact"]) and not is_nil(facts["urgency"]))
    if changed? and facts["impact"] && facts["urgency"] do
      case IncidentPolicy.derive(active && active["definition"], facts["impact"], facts["urgency"]) do
        {:ok, derived} ->
          chosen = patch["priority"] || derived
          cond do
            chosen != derived and (not is_map(patch["priority_override"]) or opts[:approve] != true) -> {:incident_priority_denied, :approval_required}
            chosen != derived and not (:service_desk_manager in principal.roles or (:platform_admin in principal.roles and Policy.profile() == :home_lab)) ->
              {:error, {:invalid_domain_fields, %{"priority_override" => :not_authorised}}}
            not is_binary(facts["priority_justification"]) or String.trim(facts["priority_justification"]) == "" ->
              {:error, {:invalid_domain_fields, %{"priority_justification" => :required}}}
            true -> {:ok, Map.put(facts, "priority", chosen), true}
          end
        {:error, {:policy_unconfigured, _}} = error ->
          if opts[:operation] in [:create, :amend, :content, :assign] and is_nil(facts["priority"]) and not Map.has_key?(patch, "priority"),
            do: {:ok, facts, false}, else: error
        {:error, _} = error -> error
      end
    else
      if Map.has_key?(patch, "priority") and not is_nil(patch["priority"]) and is_nil(detail["priority_policy_version"]),
        do: {:error, {:policy_unconfigured, %{missing: ["priority_rules", "impact", "urgency"], operation: :derive_priority}}},
        else: {:ok, facts, false}
    end
  end

  defp incident_resume(%{"state" => "on_hold"}, facts, "in_progress") do
    if is_map(facts["resume_evidence"]), do: :ok,
      else: {:error, {:invalid_domain_fields, %{"resume_evidence" => :required}}}
  end
  defp incident_resume(_, _, _), do: :ok

  # The affected-CI authority handoff is held by root/Architect. Do not persist
  # an unsynchronized array or disguise canonical associations as provenance.
  defp incident_affected_storage(patch) do
    if Map.has_key?(patch, "affected_ci_ids"),
      do: {:error, Store.Error.new(:unsupported, "Affected-CI storage integration is pending.")}, else: :ok
  end

  defp incident_changed(old, facts, operation) when operation in [:amend, :content, :assign] do
    if old == facts, do: {:error, :no_change}, else: :ok
  end
  defp incident_changed(_, _, _), do: :ok
  defp incident_sequence(tx, ticket, :create) do
    with {:ok, sequence} <- Store.next_sequence(tx, "ticket"), do: {:ok, Map.put(ticket, "sequence", sequence)}
  end
  defp incident_sequence(_tx, ticket, _), do: {:ok, ticket}

  # Nested audit timestamps are JSON strings when read from the real store.
  defp incident_audit_rows(rows) do
    Enum.map(rows, fn row ->
      Map.new(row, fn
        {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
        pair -> pair
      end)
    end)
  end

  defp incident_provenance(ticket, detail, patch, facts, principal, now, revision) do
    provenance = detail["domain_provenance"] || %{}
    legacy = Map.new(Incident.raw_legacy(ticket, detail), fn {key, value} -> {to_string(key), value} end)
    mark = %{"actor" => %{"type" => if(principal.kind == :human, do: "user", else: "service"), "id" => principal.id},
      "recorded_at" => DateTime.to_iso8601(now)}
    fields = Enum.reduce(Map.keys(patch), provenance["fields"] || %{}, &Map.put(&2, &1, mark))
    communications = for field <- @communication_fields,
      Map.has_key?(patch, field) and is_map(facts[field]),
      do: %{"field" => field, "marker" => facts[field], "domain_revision" => revision}
    provenance |> Map.put_new("legacy", legacy) |> Map.put("fields", fields)
      |> Map.put("communications", (provenance["communications"] || []) ++ communications)
  end

  defp incident_priority_denial(tx, workspace, ticket, actor, opts) do
    with {:ok, _} <- Audit.append(tx, workspace, %{subject: ticket["id"], subject_table: "ticket",
           actor: actor, from_state: ticket["state"], to_state: "refused",
           reason: "Incident priority override requires approval", correlation_id: opts[:correlation_id],
           diff: %{"refusal" => "approval_required", "operation" => to_string(opts[:operation]),
             "ticket_type" => "incident", "capability" => "ticket:write"}}) do
      {:ok, {:denied, :approval_required}}
    end
  end

  defp incident_denial(tx, workspace, ticket, principal, reason) do
    with {:ok, _} <- Audit.append(tx, workspace, %{subject: ticket["id"], subject_table: "ticket",
           actor: audit_actor(principal), from_state: ticket["state"], to_state: "refused",
           reason: "Incident operation refused", correlation_id: nil,
           diff: %{"refusal" => "principal_or_attribution_required"}}) do
      {:ok, {:denied, reason}}
    end
  end

  defp incident_ticket(tx, id) do
    case Store.fetch(tx, :ticket, id) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end
  defp incident_detail(tx, id) do
    case Store.list(tx, :incident, %{where: [ticket_id: id], limit: 2}) do
      {:ok, [detail]} -> {:ok, detail}
      {:ok, _} -> {:error, Store.Error.new(:internal, "Incident detail is unavailable.")}
      {:error, _} = error -> error
    end
  end
  defp incident_edge(tx, ticket, state, opts) do
    if ticket["state"] == state and opts[:operation] == :advance,
      do: :ok, else: check_transition(tx, "incident", ticket["state"], state)
  end
  defp incident_rows(tx, table, where, offset \\ 0, accumulated \\ []) do
    with {:ok, rows} <- Store.list(tx, table, %{where: where, order_by: [id: :asc], offset: offset, limit: 200}) do
      if length(rows) == 200, do: incident_rows(tx, table, where, offset + 200, accumulated ++ rows),
        else: {:ok, accumulated ++ rows}
    end
  end
  defp incident_holds(tx, clocks) do
    Enum.reduce_while(clocks, {:ok, []}, fn clock, {:ok, result} ->
      case incident_rows(tx, :incident_hold_episode, [clock: clock["id"]]) do
        {:ok, holds} -> {:cont, {:ok, result ++ holds}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
  defp incident_clock_options(tx, clocks, active, opts) do
    ids = Enum.uniq(Enum.reject(Enum.map(clocks, & &1["policy_version"]) ++ [active && active["id"]], &is_nil/1))
    with {:ok, policies} <- incident_versions(tx, :incident_policy_version, ids) do
      calendars = Enum.map(clocks, & &1["calendar_version"]) ++
        Enum.flat_map(Map.values(policies), &Map.values(&1["definition"]["calendar_versions"] || %{}))
      with {:ok, calendars} <- incident_versions(tx, :incident_calendar_version, Enum.uniq(Enum.reject(calendars, &is_nil/1))) do
        {:ok, opts |> Keyword.put(:policies, policies) |> Keyword.put(:calendars, calendars)
          |> Keyword.put(:clocks, Map.new(clocks, &{&1["id"], &1}))}
      end
    end
  end
  defp incident_versions(tx, table, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, result} ->
      case Store.fetch(tx, table, id) do
        {:ok, %{} = row} -> {:cont, {:ok, Map.put(result, id, row)}}
        {:ok, nil} -> {:halt, {:error, :clock_evidence_required}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
  defp incident_store_plan(tx, table, rows, original) do
    original = Map.new(original, &{&1["id"], &1})
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      if original[row["id"]] == row do
        {:cont, :ok}
      else
        case Store.put(tx, table, row) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end
  defp clock_views(tx, clocks, holds, opts) do
    case incident_clock_options(tx, clocks, nil, opts) do
      {:ok, context} -> {:ok, Enum.map(clocks, fn clock ->
        evaluation = case IncidentClock.evaluate(clock, holds, DateTime.utc_now(), context) do
          {:ok, value} -> value
          {:error, reason} -> %{unavailable: clock_error(reason)}
        end
        Map.merge(clock, %{"evaluation" => evaluation, "holds" => Enum.filter(holds, &(&1["clock"] == clock["id"]))})
      end)}
      {:error, %Store.Error{}} = error -> error
      {:error, _} -> {:ok, Enum.map(clocks, &Map.put(&1, "evaluation", %{unavailable: :clock_evidence_required}))}
    end
  end
  defp clock_error({code, _}) when is_atom(code), do: code
  defp clock_error(code) when is_atom(code), do: code
  defp clock_error(_), do: :clock_evidence_required
  defp incident_envelope(ticket), do: Map.take(ticket,
    ~w(id workspace ticket_type state title description requester assignee priority opened_at closed_at sequence))

  defp incident_legacy_view(ticket, detail) do
    current = Incident.raw_legacy(ticket, detail)
    case get_in(detail, ["domain_provenance", "legacy"]) do
      stored when is_map(stored) ->
        %{ticket: Map.take(stored["ticket"] || stored[:ticket] || %{}, Map.keys(current.ticket)),
          incident: Map.take(stored["incident"] || stored[:incident] || %{}, Map.keys(current.incident))}
      _ -> current
    end
  end

  defp incident_provenance_view(detail) do
    provenance = detail["domain_provenance"] || %{}
    fields = provenance["fields"] || %{}
    fields = if is_map(fields), do: Map.take(fields, Incident.fields()), else: %{}
    %{"fields" => fields, "communications" => provenance["communications"] || [],
      "priority_policy_version" => detail["priority_policy_version"],
      "priority_override_evidence" => detail["priority_override_evidence"],
      "closure_approval" => detail["closure_approval"]}
  end

  defp incident_readiness(facts, active) do
    needed = ~w(impact urgency severity incident_class priority priority_justification assignee notification_evidence)
    missing = Enum.filter(needed, &is_nil(facts[&1]))
    policy = IncidentPolicy.readiness(active && active["definition"])
    %{missing: missing, operations: %{acknowledge: missing ++ policy.operations.acknowledge}, policy: policy}
  end
  defp audit_actor(%Principal{} = principal), do: Principal.audit_actor(principal)
  defp audit_actor(_), do: %{type: "unknown", id: "unknown"}
  defp principal_id(%Principal{id: id}), do: id
  defp principal_id(_), do: "unknown"
  defp unwrap_incident_denial({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_incident_denial(result), do: result

  defp incident_write(workspace, fun) do
    WorkspaceLock.with_lock(workspace, fn -> Store.transaction(workspace, fun) end)
    |> case do {:ok, {:denied, reason}} -> {:error, reason}; result -> result end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp transition_rows(tx, ticket_type, from_state) do
    filter = %{
      where: [ticket_type: ticket_type, from_state: from_state],
      order_by: [{:to_state, :asc}]
    }

    Store.list(tx, :ticket_transition, filter)
  end

  defp check_transition(tx, ticket_type, from_state, to_state) do
    case transition_rows(tx, ticket_type, from_state) do
      {:ok, rows} ->
        if Enum.any?(rows, &(&1["to_state"] == to_state)),
          do: :ok,
          else: {:error, :illegal_transition}

      {:error, _reason} ->
        {:error, :illegal_transition}
    end
  end

  defp put_closed_at(ticket, "closed", now), do: Map.put(ticket, "closed_at", now)
  defp put_closed_at(ticket, _state, _now), do: ticket

  @doc "The canonical starting state of a ticket type."
  def initial_state("change"), do: "draft"
  def initial_state("problem"), do: "new"
  def initial_state("vulnerability"), do: "new"
  def initial_state("service_request"), do: "submitted"
  def initial_state(_), do: "new"

  defp detail_table("incident"), do: :incident
  defp detail_table(_other_type), do: :ticket_detail

  defp detail_row("incident", ticket_id) do
    %{
      "id" => identifier(),
      "ticket_id" => ticket_id,
      "incident_class" => "service_degradation",
      "restore_track" => "open",
      "root_cause_track" => "not_started",
      "major" => false
    }
  end

  defp detail_row(ticket_type, ticket_id) do
    %{
      "id" => identifier(),
      "ticket_id" => ticket_id,
      "ticket_type" => ticket_type
    }
  end

  defp attr(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, String.to_atom(key), default))
  end

  defp put_where(where, _key, nil), do: where
  defp put_where(where, key, value), do: where ++ [{key, value}]

  # Record ids must be alphanumeric and underscore only: a '-' is lexed by
  # SurrealQL as a duration suffix and fails to parse (`ticket:abc-1`).
  defp identifier, do: :crypto.strong_rand_bytes(9) |> Base.encode16(case: :lower)
end
