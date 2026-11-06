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
  alias Veritas.Store

  @type ticket_type :: String.t()
  @type state :: String.t()
  @type error ::
          {:error, :unknown_ticket_type | :illegal_transition | :not_found | term()}

  @ticket_types ~w(service_request incident change problem vulnerability)

  # The content an update owns: the free text a person reads. Every other
  # field on a ticket belongs to the workflow, to the host, or to another
  # operation.
  @content_fields ~w(title description)

  @doc "The five canonical ticket types."
  def ticket_types, do: @ticket_types

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
    else
      {:error, :unknown_ticket_type}
    end
  end

  @doc false
  def open_in_transaction(tx, workspace, ticket_type, attrs, actor, correlation_id \\ nil) do
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

          {:ok, ticket} ->
            edit(tx, workspace, ticket, attrs, actor, opts)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
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

          {:ok, ticket} ->
            hand_to(tx, workspace, ticket, assignee, actor, opts)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
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
