defmodule Veritas.Core.Delivery do
  @moduledoc """
  Delivery: Programs, Milestones and Work Items.

  A Program is a body of work bigger than a ticket; a Milestone groups the
  Work Items that move it; a Work Item is the unit of work, and it is linked
  to the Configuration Items it touches and to the Changes that implement it
  (`docs/04` §Navigation Model: *"Programs, milestones, work items linked to
  CIs and Changes"*).

  ## What the corpus says, and what it does not

  The corpus specifies **the section**: its panels, its widgets and the
  tables they read — `program`, `milestone`, `work_item` and `benefit`
  (`docs/04` §6). It does **not** specify the domain: `docs/02` has no
  Delivery section, so there is no lifecycle to inherit, and `docs/07` has
  no tables for these records.

  So this module carries the smallest model the corpus's own widgets need,
  and nothing more:

    * a Program has a **status** — `docs/04` counts Programs by status
      for the RAG tile;
    * a Milestone has a **planned** and an **actual** date — the burn-up is
      planned against actual, and `docs/04` forbids false precision where a
      planned date was back-filled;
    * a Work Item has a **state**, and a moment it was **blocked** — the
      blocked-items widget counts them and ages them;
    * a Benefit has a **type** — the benefits widget counts them by type.

  The lifecycles themselves are this module's decision and are reported
  as such: the states are the delivery states, and a record moves between
  them by an explicit write, not by a seeded transition table. The corpus
  reserves the seeded state machine for ticket types, and a Work Item is
  not a ticket.

  ## Every write is audited

  A Delivery record is a record somebody changed, so its change is written
  to the Audit Log the way every other change is — the same
  `Veritas.Core.Audit` call, in the same transaction as the row.
  """

  alias Veritas.Core.{Audit, Principal, WorkspaceLock}
  alias Veritas.Store

  @program_statuses ~w(red amber green)
  @delivery_states ~w(planned in_progress blocked done)

  @typedoc "A Delivery record."
  @type row :: map()

  @typedoc "The attributes a write accepts."
  @type attrs :: map()

  # ── Programs ─────────────────────────────────────────────────────────────

  @doc """
  The Workspace's Programs, newest first.
  """
  @spec list_programs(Store.workspace(), keyword()) :: {:ok, [row()]} | {:error, Store.Error.t()}
  def list_programs(workspace, opts \\ []) when is_binary(workspace) do
    limit = Keyword.get(opts, :limit, 100)

    case all(workspace, :program) do
      {:ok, rows} -> {:ok, rows |> Enum.reverse() |> Enum.take(limit)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One Program, by its id.
  """
  @spec get_program(Store.workspace(), String.t()) ::
          {:ok, row() | nil} | {:error, Store.Error.t()}
  def get_program(workspace, id) when is_binary(workspace) and is_binary(id) do
    fetch(workspace, :program, id)
  end

  @doc """
  Creates a Program.
  """
  @spec create_program(Store.workspace(), attrs()) :: {:ok, row()} | {:error, Store.Error.t()}
  def create_program(workspace, attrs) when is_binary(workspace) and is_map(attrs) do
    with {:ok, name} <- required(attrs, "name") do
      row = %{
        "id" => identifier(),
        "workspace" => workspace,
        "name" => name,
        "description" => attr(attrs, "description", ""),
        "status" => attr(attrs, "status", "amber"),
        "owner" => attr(attrs, "owner"),
        "target_date" => datetime(attr(attrs, "target_date")),
        "started_at" => DateTime.utc_now(),
        "created_at" => DateTime.utc_now(),
        "updated_at" => DateTime.utc_now(),
        "sequence" => 0
      }

      write(workspace, :program, row, attrs, "program", nil, "created")
    end
  end

  @doc """
  Changes a Program.
  """
  @spec update_program(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def update_program(workspace, id, attrs) when is_binary(workspace) and is_binary(id) do
    change(workspace, :program, id, attrs, &program_changes/2)
  end

  # ── Milestones ─────────────────────────────────────────────────────────────

  @doc """
  The Milestones of a Program.
  """
  @spec list_milestones(Store.workspace(), String.t()) ::
          {:ok, [row()]} | {:error, Store.Error.t()}
  def list_milestones(workspace, program_id) when is_binary(workspace) do
    # The rows are filtered here, not in the store: a reference field holds
    # a record id, and a statement that compares a plain id with it matches
    # nothing. `Veritas.Core.CI.list/2` filters the same way.
    case all(workspace, :milestone) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1["program"] == program_id))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One Milestone, by its id.
  """
  @spec get_milestone(Store.workspace(), String.t()) ::
          {:ok, row() | nil} | {:error, Store.Error.t()}
  def get_milestone(workspace, id) when is_binary(workspace) and is_binary(id) do
    fetch(workspace, :milestone, id)
  end

  @doc """
  Creates a Milestone under a Program.
  """
  @spec create_milestone(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def create_milestone(workspace, program_id, attrs)
      when is_binary(workspace) and is_binary(program_id) and is_map(attrs) do
    with {:ok, name} <- required(attrs, "name") do
      row = %{
        "id" => identifier(),
        "workspace" => workspace,
        "program" => program_id,
        "name" => name,
        "description" => attr(attrs, "description", ""),
        "status" => attr(attrs, "status", "planned"),
        "planned_date" => datetime(attr(attrs, "planned_date")),
        "actual_date" => datetime(attr(attrs, "actual_date")),
        "owner" => attr(attrs, "owner"),
        "sequence" => 0
      }

      write(workspace, :milestone, row, attrs, "milestone", program_id, "created")
    end
  end

  @doc """
  Changes a Milestone.
  """
  @spec update_milestone(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def update_milestone(workspace, id, attrs) when is_binary(workspace) and is_binary(id) do
    change(workspace, :milestone, id, attrs, &milestone_changes/2)
  end

  # ── Work Items ─────────────────────────────────────────────────────────────

  @doc """
  The Work Items of a Milestone.
  """
  @spec list_work_items(Store.workspace(), String.t()) ::
          {:ok, [row()]} | {:error, Store.Error.t()}
  def list_work_items(workspace, milestone_id) when is_binary(workspace) do
    case all(workspace, :work_item) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1["milestone"] == milestone_id))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One Work Item, by its id.
  """
  @spec get_work_item(Store.workspace(), String.t()) ::
          {:ok, row() | nil} | {:error, Store.Error.t()}
  def get_work_item(workspace, id) when is_binary(workspace) and is_binary(id) do
    fetch(workspace, :work_item, id)
  end

  @doc """
  Creates a Work Item under a Milestone.
  """
  @spec create_work_item(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def create_work_item(workspace, milestone_id, attrs)
      when is_binary(workspace) and is_binary(milestone_id) and is_map(attrs) do
    with {:ok, title} <- required(attrs, "title") do
      state = attr(attrs, "state", "planned")

      row = %{
        "id" => identifier(),
        "workspace" => workspace,
        "milestone" => milestone_id,
        "title" => title,
        "description" => attr(attrs, "description", ""),
        "state" => state,
        "blocked_at" => if(state == "blocked", do: DateTime.utc_now(), else: nil),
        "ci_refs" => attr(attrs, "ci_refs", []),
        "change_refs" => attr(attrs, "change_refs", []),
        "owner" => attr(attrs, "owner"),
        "due_date" => datetime(attr(attrs, "due_date")),
        "sequence" => 0
      }

      write(workspace, :work_item, row, attrs, "work_item", milestone_id, "created")
    end
  end

  @doc """
  Changes a Work Item.
  """
  @spec update_work_item(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def update_work_item(workspace, id, attrs) when is_binary(workspace) and is_binary(id) do
    change(workspace, :work_item, id, attrs, &work_item_changes/2)
  end

  # ── Benefits ───────────────────────────────────────────────────────────────

  @doc """
  The Benefits a Work Item carries.
  """
  @spec list_benefits(Store.workspace(), String.t()) :: {:ok, [row()]} | {:error, Store.Error.t()}
  def list_benefits(workspace, work_item_id) when is_binary(workspace) do
    case all(workspace, :benefit) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1["work_item"] == work_item_id))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records a Benefit against a Work Item.
  """
  @spec create_benefit(Store.workspace(), String.t(), attrs()) ::
          {:ok, row()} | {:error, Store.Error.t()}
  def create_benefit(workspace, work_item_id, attrs)
      when is_binary(workspace) and is_binary(work_item_id) and is_map(attrs) do
    with {:ok, kind} <- required(attrs, "kind") do
      row = %{
        "id" => identifier(),
        "workspace" => workspace,
        "work_item" => work_item_id,
        "kind" => kind,
        "description" => attr(attrs, "description", ""),
        "realised_at" => datetime(attr(attrs, "realised_at")),
        "sequence" => 0
      }

      write(workspace, :benefit, row, attrs, "benefit", work_item_id, "created")
    end
  end

  # ── the vocabulary ─────────────────────────────────────────────────────────

  @doc """
  The statuses a Program may hold.
  """
  @spec program_statuses() :: [String.t()]
  def program_statuses, do: @program_statuses

  @doc """
  The states a Milestone or a Work Item may hold.
  """
  @spec delivery_states() :: [String.t()]
  def delivery_states, do: @delivery_states

  # ── the writing ────────────────────────────────────────────────────────────

  # The write path every record shares: the row and its Audit Log entry are
  # written in one transaction, so a change and the record of the change
  # commit together.
  defp write(workspace, table, row, attrs, subject_table, parent, to_state) do
    result =
      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          with {:ok, sequence} <- Store.next_sequence(tx, table),
               stored = Map.put(row, "sequence", sequence),
               {:ok, _stored} <- Store.put(tx, table, stored),
               {:ok, _audit} <-
                 Audit.append(tx, workspace, %{
                   subject: stored["id"],
                   subject_table: subject_table,
                   from_state: nil,
                   to_state: to_state,
                   actor: actor(attrs),
                   reason: attr(attrs, "reason", "a delivery record was written"),
                   correlation_id: attr(attrs, "correlation_id"),
                   diff: diff(stored, parent)
                 }) do
            {:ok, stored}
          end
        end)
      end)

    result
  end

  # A change to a record that already exists: the same transaction, the same
  # Audit Log, and the before and after in the entry.
  defp change(workspace, table, id, attrs, changes) do
    with {:ok, current} <- fetch(workspace, table, id) do
      case current do
        nil ->
          {:error, :not_found}

        current ->
          updated = changes.(current, attrs)

          result =
            WorkspaceLock.with_lock(workspace, fn ->
              Store.transaction(workspace, fn tx ->
                with {:ok, _stored} <- Store.put(tx, table, updated),
                     {:ok, _audit} <-
                       Audit.append(tx, workspace, %{
                         subject: id,
                         subject_table: Atom.to_string(table),
                         from_state: current["status"] || current["state"],
                         to_state: updated["status"] || updated["state"],
                         actor: actor(attrs),
                         reason: attr(attrs, "reason", "a delivery record was changed"),
                         correlation_id: attr(attrs, "correlation_id"),
                         diff: diff(updated, nil)
                       }) do
                  {:ok, updated}
                end
              end)
            end)

          result
      end
    end
  end

  defp program_changes(current, attrs) do
    current
    |> maybe_put("name", attr(attrs, "name"))
    |> maybe_put("description", attr(attrs, "description"))
    |> maybe_put("status", attr(attrs, "status"))
    |> maybe_put("owner", attr(attrs, "owner"))
    |> maybe_put("target_date", attr(attrs, "target_date"))
    |> touch()
  end

  defp milestone_changes(current, attrs) do
    current
    |> maybe_put("name", attr(attrs, "name"))
    |> maybe_put("description", attr(attrs, "description"))
    |> maybe_put("status", attr(attrs, "status"))
    |> maybe_put("planned_date", attr(attrs, "planned_date"))
    |> maybe_put("actual_date", attr(attrs, "actual_date"))
    |> maybe_put("owner", attr(attrs, "owner"))
    |> touch()
  end

  defp work_item_changes(current, attrs) do
    updated =
      current
      |> maybe_put("title", attr(attrs, "title"))
      |> maybe_put("description", attr(attrs, "description"))
      |> maybe_put("state", attr(attrs, "state"))
      |> maybe_put("ci_refs", attr(attrs, "ci_refs"))
      |> maybe_put("change_refs", attr(attrs, "change_refs"))
      |> maybe_put("owner", attr(attrs, "owner"))
      |> maybe_put("due_date", attr(attrs, "due_date"))

    # The moment an item was blocked is the moment it became blocked, so it
    # is set when the state says blocked and cleared when it does not.
    case attr(attrs, "state") do
      nil -> updated
      "blocked" -> Map.put(updated, "blocked_at", current["blocked_at"] || DateTime.utc_now())
      _state -> Map.put(updated, "blocked_at", nil)
    end
  end

  # Every row of a table in the Workspace, oldest first. The Workspace is
  # the store's own scope, so the statement needs no filter.
  defp all(workspace, table) do
    case Store.transaction(workspace, fn tx ->
           Store.list(tx, table, %{where: [], order_by: [{:sequence, :asc}]})
         end) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(workspace, table, id) do
    case Store.transaction(workspace, fn tx -> Store.fetch(tx, table, id) end) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(row, _key, nil), do: row
  defp maybe_put(row, key, value), do: Map.put(row, key, value)

  defp touch(row), do: Map.put(row, "updated_at", DateTime.utc_now())

  # An empty field is not a value. A form sends an empty string for a field
  # the operator left blank, and the store refuses an empty record id — so a
  # blank owner would take the whole record down with it.
  defp attr(attrs, key, default \\ nil) do
    case Map.get(attrs, key, Map.get(attrs, String.to_atom(key), default)) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  # A date arrives as a DateTime from the domain and as a string from a
  # form. The store holds a datetime, so a string is parsed here rather than
  # written as one.
  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = at), do: at
  defp datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp datetime(_value), do: nil

  defp required(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_attributes, "the #{key} is required"}}
    end
  end

  defp actor(attrs) do
    case attr(attrs, "actor") do
      %{} = actor -> actor
      nil -> %{type: "user", id: "local"}
      id -> %{type: "user", id: id}
    end
  end

  defp diff(row, parent) do
    %{
      "name" => row["name"] || row["title"],
      "status" => row["status"] || row["state"],
      "parent" => parent
    }
    |> without_nils()
  end

  # A diff with a `nil` in it does not verify.
  #
  # The store drops a null field from the flexible object it writes, and the
  # canonical encoding tells an absent key from a key whose value is null. So
  # a value that is not set is **not written**: the diff says the same thing
  # either way, and the row still verifies when it is read back.
  defp without_nils(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp identifier do
    "p_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  The Audit Log actor for a Principal.
  """
  @spec actor_for(Principal.t() | nil) :: Audit.actor()
  def actor_for(nil), do: %{type: "user", id: "local"}
  def actor_for(principal), do: Principal.audit_actor(principal)
end
