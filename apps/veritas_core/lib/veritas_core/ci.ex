defmodule Veritas.Core.CI do
  @moduledoc """
  The CMDB: Configuration Items, the types they are, and the relationships
  between them.

  `docs/00` calls the CMDB "the spine": Incident, Change, Problem,
  Vulnerability, SLA and Knowledge are queries and workflows over
  configuration data. This module is that data, and it is the only place that
  decides what a Configuration Item may be.

  A CI is a document with a type, and the type is *data* (ADR-009): the
  `ci_type` registry carries a JSON Schema for the type's attributes and the
  names the type requires. A CI written with attributes its type does not
  allow is a defect, not a shrug, so the attributes are checked against the
  type before the row is written.

  The module talks to the store only through the `Veritas.Store` port: no
  SurrealQL, no Adapter types, no store types in a domain context (INV-1).
  Every surface — the CLI, GraphQL, the LiveViews — comes through here, so
  there is one implementation of the CMDB and many ways to reach it (INV-8).
  """

  alias Veritas.Core.{Audit, WorkspaceLock}
  alias Veritas.Store

  @lifecycle_states ~w(proposed active in_maintenance retired disposed)
  @criticalities ~w(low medium high tier1)
  @default_limit 50
  @max_limit 500

  @typedoc "A Workspace name."
  @type workspace :: String.t()

  @typedoc "The outcome of an operation that can be refused."
  @type error :: {:error, String.t()}

  # ── reading ────────────────────────────────────────────────────────────────

  @doc """
  The CIs of a Workspace.

  ## Options

    * `:ci_type` — the type of CI to list (`"server"`, `"service"`, …)
    * `:lifecycle_state` — `"proposed" | "active" | "in_maintenance" | "retired" | "disposed"`
    * `:criticality` — `"low" | "medium" | "high" | "tier1"`
    * `:limit` — how many CIs to return (default #{@default_limit}, maximum #{@max_limit})

  Filters apply before the name-ordered limit. Type identifiers stay logical
  ids at the Store port; each Adapter owns their physical representation.
  Only `nil` means an unset filter; other values are compared as strings.
  """
  @spec list(workspace(), keyword()) :: {:ok, [map()]} | error()
  def list(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    where =
      for field <- [:ci_type, :lifecycle_state, :criticality],
          value = opts[field],
          not is_nil(value),
          do: {field, to_string(value)}

    filter = %{where: where, order_by: [{:name, :asc}], limit: limit(opts)}
    Store.transaction(workspace, fn tx -> Store.list(tx, :ci, filter) end)
  end

  @doc """
  One CI, by id.

  Answers `{:ok, nil}` when the Workspace holds no CI with that id: a CI
  that does not exist is an answer, not a failure.
  """
  @spec get(workspace(), String.t()) :: {:ok, map() | nil} | error()
  def get(workspace, ci_id) when is_binary(workspace) and is_binary(ci_id) do
    case Store.transaction(workspace, fn tx -> Store.fetch(tx, :ci, ci_id) end) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The registered CI types of a Workspace.

  The registry is data: a type is registered at runtime, not by a code
  change (ADR-009). Each type carries the JSON Schema its attributes are
  checked against and the names it requires.
  """
  @spec types(workspace()) :: {:ok, [map()]} | error()
  def types(workspace) when is_binary(workspace) do
    case Store.transaction(workspace, fn tx -> Store.ci_types(tx) end) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── writing ────────────────────────────────────────────────────────────────

  @doc """
  Creates a Configuration Item.

  The CI's type must be registered, and the attributes must satisfy that
  type's schema: every name the type requires must be present, and the
  attributes must not carry anything the schema forbids. A CI that fails
  either check is refused, and nothing is written.

  ## Attributes

    * `:ci_type` — the registered type (required)
    * `:name` — the CI's name (required)
    * `:lifecycle_state` — default `"active"`
    * `:criticality` — default `"medium"`
    * `:owner` — the id of the user that owns the CI
    * `:attributes` — the type's own attributes
  """
  @spec create(workspace(), map()) :: {:ok, map()} | error()
  def create(workspace, attrs) when is_binary(workspace) and is_map(attrs) do
    with {:ok, ci_type} <- fetch_type(workspace, attr(attrs, "ci_type")),
         :ok <- validate_lifecycle(attr(attrs, "lifecycle_state", "active")),
         :ok <- validate_criticality(attr(attrs, "criticality", "medium")),
         :ok <- validate_attributes(ci_type, attributes(attrs)) do
      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          with {:ok, sequence} <- Store.next_sequence(tx, "ci"),
               now = DateTime.utc_now(),
               row = %{
                 "id" => identifier(),
                 "workspace" => workspace,
                 "ci_type" => ci_type["id"],
                 "name" => attr(attrs, "name"),
                 "lifecycle_state" => attr(attrs, "lifecycle_state", "active"),
                 "criticality" => attr(attrs, "criticality", "medium"),
                 "attributes" => attributes(attrs),
                 "baseline_version" => attr(attrs, "baseline_version", 0),
                 "actual_version" => attr(attrs, "actual_version", 0),
                 "owner" => attr(attrs, "owner"),
                 "sequence" => sequence,
                 "created_at" => now,
                 "updated_at" => now,
                 "deleted_at" => nil
               },
               {:ok, ci} <- Store.put(tx, :ci, row),
               {:ok, _audit} <-
                 Audit.append(tx, workspace, %{
                   subject: ci["id"],
                   subject_table: "ci",
                   from_state: nil,
                   to_state: row["lifecycle_state"],
                   actor: actor(attrs),
                   reason: attr(attrs, "reason"),
                   correlation_id: attr(attrs, "correlation_id"),
                   diff:
                     %{"ci_type" => row["ci_type"], "name" => row["name"]}
                     |> without_nils()
                 }) do
            {:ok, ci}
          end
        end)
      end)
    end
  end

  @doc """
  Updates a Configuration Item.

  The same rules as creation apply to the attributes that are written: the CI
  keeps its type, and the attributes must still satisfy that type's schema.
  """
  @spec update(workspace(), String.t(), map()) :: {:ok, map()} | error()
  def update(workspace, ci_id, attrs)
      when is_binary(workspace) and is_binary(ci_id) and is_map(attrs) do
    with {:ok, current} <- get(workspace, ci_id),
         {:ok, ci} <- present(current),
         {:ok, ci_type} <- fetch_type(workspace, ci["ci_type"]),
         :ok <- validate_lifecycle(attr(attrs, "lifecycle_state", ci["lifecycle_state"])),
         :ok <- validate_criticality(attr(attrs, "criticality", ci["criticality"])),
         :ok <- validate_attributes(ci_type, attributes(attrs, ci)) do
      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          row = %{
            "id" => ci_id,
            "workspace" => workspace,
            "ci_type" => ci["ci_type"],
            "name" => attr(attrs, "name", ci["name"]),
            "lifecycle_state" => attr(attrs, "lifecycle_state", ci["lifecycle_state"]),
            "criticality" => attr(attrs, "criticality", ci["criticality"]),
            "attributes" => attributes(attrs, ci),
            "baseline_version" => attr(attrs, "baseline_version", ci["baseline_version"]),
            "actual_version" => attr(attrs, "actual_version", ci["actual_version"]),
            "owner" => attr(attrs, "owner", ci["owner"]),
            "sequence" => ci["sequence"],
            "created_at" => ci["created_at"],
            "updated_at" => DateTime.utc_now(),
            "deleted_at" => attr(attrs, "deleted_at", ci["deleted_at"])
          }

          with {:ok, updated} <- Store.put(tx, :ci, row),
               {:ok, _audit} <-
                 Audit.append(tx, workspace, %{
                   subject: ci_id,
                   subject_table: "ci",
                   from_state: ci["lifecycle_state"],
                   to_state: row["lifecycle_state"],
                   actor: actor(attrs),
                   reason: attr(attrs, "reason"),
                   correlation_id: attr(attrs, "correlation_id"),
                   diff:
                     %{"name" => row["name"], "criticality" => row["criticality"]}
                     |> without_nils()
                 }) do
            {:ok, updated}
          end
        end)
      end)
    end
  end

  @doc """
  Relates two CIs.

  The kind must be registered in the Workspace's relation registry: the
  vocabulary is data (ADR-009), and an unregistered kind has no edge table
  and no inverse.
  """
  @spec relate(workspace(), String.t(), String.t(), String.t(), map()) :: {:ok, map()} | error()
  def relate(workspace, from_id, kind, to_id, attrs \\ %{})
      when is_binary(workspace) and is_binary(from_id) and is_binary(kind) and is_binary(to_id) and
             is_map(attrs) do
    with {:ok, from} <- get(workspace, from_id),
         {:ok, from} <- present(from),
         {:ok, to} <- get(workspace, to_id),
         {:ok, to} <- present(to) do
      # The reason belongs to the Audit Log, not to the edge: the relation
      # table declares the fields the relation has, and nothing else.
      attrs = Map.delete(attrs, "reason")

      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          with {:ok, edge} <- Store.relate(tx, kind, from["id"], to["id"], attrs),
               {:ok, _audit} <-
                 Audit.append(tx, workspace, %{
                   subject: from["id"],
                   subject_table: "ci",
                   from_state: nil,
                   to_state: nil,
                   actor: actor(attrs),
                   reason: attr(attrs, "reason", "related #{from["id"]} #{kind} #{to["id"]}"),
                   correlation_id: attr(attrs, "correlation_id"),
                   diff:
                     %{"kind" => kind, "from" => from["id"], "to" => to["id"]}
                     |> without_nils()
                 }) do
            {:ok, edge}
          end
        end)
      end)
    end
  end

  @doc """
  The relations of a CI, at a bounded depth.

  `:direction` is `:in` for the CIs that depend on it and `:out` for the ones
  it depends on. The depth is the traversal's bound, five by default, as the
  contract has it.
  """
  @spec relations(workspace(), String.t(), :in | :out, pos_integer()) ::
          {:ok, %{nodes: [map()], edges: [map()]}} | error()
  def relations(workspace, ci_id, direction \\ :in, depth \\ 5)
      when is_binary(workspace) and is_binary(ci_id) and direction in [:in, :out] and
             is_integer(depth) and depth > 0 do
    case Store.transaction(workspace, fn tx ->
           Store.traverse(tx, ci_id, direction, depth, [])
         end) do
      {:ok, %{nodes: _nodes, edges: _edges} = result} ->
        # The Adapter says whether the graph was truncated at the node budget.
        # The marker travels with the result: a partial graph that does not
        # say it is partial is a lie.
        {:ok, result}

      {:ok, other} ->
        {:ok, %{nodes: [], edges: [], result: other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  How many relations each of the CIs has.

  One pass over the Workspace, because the question is asked of many CIs at
  once: the CMDB's list page asks it of every row, and asking it per row is
  the N+1 the performance corpus names.

  The count is the number of distinct CIs related to each one, in both
  directions.
  """
  @spec relation_counts(workspace(), [String.t()]) ::
          {:ok, %{String.t() => non_neg_integer()}} | error()
  def relation_counts(workspace, ci_ids) when is_binary(workspace) and is_list(ci_ids) do
    case Store.transaction(workspace, fn tx -> Store.relation_counts(tx, ci_ids) end) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The blast radius of a CI: the CIs that depend on it, the services among
  them, and the open tickets that touch them.

  This is the question the CMDB exists to answer: what breaks if this CI
  breaks?
  """
  @spec impact(workspace(), String.t(), pos_integer()) :: {:ok, map()} | error()
  def impact(workspace, ci_id, depth \\ 2)
      when is_binary(workspace) and is_binary(ci_id) and is_integer(depth) and depth > 0 do
    with {:ok, %{ci: ci, tickets: tickets} = impact} <-
           Store.transaction(workspace, fn tx -> Store.impact(tx, ci_id, depth) end),
         {:ok, dependents} <- dependents(workspace, ci_id, depth) do
      # The services in the blast radius are the services among the CIs that
      # depend on this one, however they depend on it. The store's own answer
      # follows one relation kind only, and the CMDB's question is the wider
      # one: if the database goes down, the service that runs on it is in the
      # blast radius too.
      services = Enum.filter(dependents, &(&1["ci_type"] == "service"))

      {:ok,
       Map.merge(impact, %{
         ci: ci,
         services: services,
         tickets: tickets,
         dependents: dependents
       })}
    else
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  end

  @doc """
  Registers a CI type, or updates one.

  Additive: existing CIs are unaffected (the port's contract).
  """
  @spec register_type(workspace(), map()) :: {:ok, map()} | error()
  def register_type(workspace, spec) when is_binary(workspace) and is_map(spec) do
    case Store.transaction(workspace, fn tx -> Store.put_ci_type(tx, spec) end) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Registers a relation kind, or updates one.
  """
  @spec register_relation_kind(workspace(), map()) :: {:ok, map()} | error()
  def register_relation_kind(workspace, spec) when is_binary(workspace) and is_map(spec) do
    case Store.transaction(workspace, fn tx -> Store.put_relation_kind(tx, spec) end) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # The CIs that depend on the given CI. The store's impact answers with the
  # services among them; the traversal answers with all of them.
  defp dependents(workspace, ci_id, depth) do
    case Store.transaction(workspace, fn tx ->
           Store.traverse(tx, ci_id, :in, depth, [])
         end) do
      {:ok, %{nodes: nodes}} -> {:ok, nodes}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_type(workspace, type) when is_binary(type) do
    case types(workspace) do
      {:ok, types} ->
        case Enum.find(types, &(&1["id"] == type)) do
          nil -> {:error, "the CI type \"#{type}\" is not registered in this workspace"}
          type -> {:ok, type}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_type(_workspace, nil), do: {:error, "a CI needs a type"}

  defp fetch_type(_workspace, other),
    do: {:error, "the CI type must be a name, got #{inspect(other)}"}

  defp validate_lifecycle(state) when state in @lifecycle_states, do: :ok

  defp validate_lifecycle(state),
    do:
      {:error,
       "the lifecycle state #{inspect(state)} is not one of #{inspect(@lifecycle_states)}"}

  defp validate_criticality(criticality) when criticality in @criticalities, do: :ok

  defp validate_criticality(criticality),
    do:
      {:error, "the criticality #{inspect(criticality)} is not one of #{inspect(@criticalities)}"}

  # The attributes of a CI are typed by its type: the type carries a JSON
  # Schema for them and the names it requires. Both are checked here, in the
  # domain, because the type is data and the rule is the product's.
  defp validate_attributes(type, attributes) do
    with :ok <- validate_required(type, attributes) do
      validate_schema(type["schema"] || %{}, attributes, "")
    end
  end

  defp validate_required(type, attributes) do
    required = type["required"] || []

    case Enum.find(required, &(not Map.has_key?(attributes, &1))) do
      nil ->
        :ok

      missing ->
        {:error, "the CI type \"#{type["id"]}\" requires the attribute #{inspect(missing)}"}
    end
  end

  # A focused JSON Schema validator: the keywords a CI type's schema uses.
  #
  # The corpus makes a type's schema "a JSON Schema for attributes", and the
  # product ships no schema library, so the subset a CI type needs is checked
  # here — and checked exactly, because a CI written with attributes its type
  # does not allow is a defect, not a shrug.
  defp validate_schema(schema, value, path) when is_map(schema) and is_map(value) do
    with :ok <- validate_type(schema, value, path),
         :ok <- validate_enum(schema, value, path) do
      validate_properties(schema, value, path)
    end
  end

  defp validate_schema(schema, value, path) when is_map(schema) do
    with :ok <- validate_type(schema, value, path),
         :ok <- validate_enum(schema, value, path),
         :ok <- validate_items(schema, value, path),
         :ok <- validate_length(schema, value, path),
         :ok <- validate_pattern(schema, value, path) do
      validate_range(schema, value, path)
    end
  end

  defp validate_schema(_schema, _value, _path), do: :ok

  # The item rule of an array.
  defp validate_items(schema, value, path) when is_list(value) do
    case Map.get(schema, "items") do
      nil ->
        :ok

      item ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {element, index}, _acc ->
          case validate_schema(item, element, "#{path}[#{index}]") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp validate_items(_schema, _value, _path), do: :ok

  defp validate_type(schema, value, path) do
    case Map.get(schema, "type") do
      nil ->
        :ok

      types ->
        types = List.wrap(types)

        if Enum.any?(types, &type_matches?(&1, value)) do
          :ok
        else
          {:error, type_error(path, "must be #{describe_types(types)}")}
        end
    end
  end

  defp validate_enum(schema, value, path) do
    case Map.get(schema, "enum") do
      nil ->
        :ok

      enum ->
        if Enum.member?(enum, value) do
          :ok
        else
          {:error, type_error(path, "must be one of #{inspect(enum)}")}
        end
    end
  end

  defp validate_length(schema, value, path) when is_binary(value) do
    min = Map.get(schema, "minLength")
    max = Map.get(schema, "maxLength")

    cond do
      is_integer(min) and String.length(value) < min ->
        {:error, type_error(path, "must be at least #{min} characters")}

      is_integer(max) and String.length(value) > max ->
        {:error, type_error(path, "must be at most #{max} characters")}

      true ->
        :ok
    end
  end

  defp validate_length(schema, value, path) when is_list(value) do
    min = Map.get(schema, "minItems")
    max = Map.get(schema, "maxItems")

    cond do
      is_integer(min) and length(value) < min ->
        {:error, type_error(path, "must hold at least #{min} items")}

      is_integer(max) and length(value) > max ->
        {:error, type_error(path, "must hold at most #{max} items")}

      true ->
        :ok
    end
  end

  defp validate_length(_schema, _value, _path), do: :ok

  defp validate_pattern(schema, value, path) when is_binary(value) do
    case Map.get(schema, "pattern") do
      nil ->
        :ok

      pattern ->
        if Regex.match?(Regex.compile!(pattern), value) do
          :ok
        else
          {:error, type_error(path, "must match #{inspect(pattern)}")}
        end
    end
  end

  defp validate_pattern(_schema, _value, _path), do: :ok

  defp validate_range(schema, value, path) when is_number(value) do
    min = Map.get(schema, "minimum")
    max = Map.get(schema, "maximum")

    cond do
      is_number(min) and value < min ->
        {:error, type_error(path, "must be at least #{min}")}

      is_number(max) and value > max ->
        {:error, type_error(path, "must be at most #{max}")}

      true ->
        :ok
    end
  end

  defp validate_range(_schema, _value, _path), do: :ok

  defp validate_properties(schema, value, path) do
    properties = Map.get(schema, "properties") || %{}

    with :ok <- validate_schema_properties(properties, value, path) do
      validate_additional_properties(schema, properties, value, path)
    end
  end

  defp validate_schema_properties(properties, value, path) do
    Enum.reduce_while(properties, :ok, fn {name, sub_schema}, _acc ->
      case Map.fetch(value, name) do
        :error ->
          {:cont, :ok}

        {:ok, sub_value} ->
          case validate_schema(sub_schema, sub_value, join(path, name)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_additional_properties(schema, properties, value, path) do
    case Map.get(schema, "additionalProperties", true) do
      false ->
        case Enum.find(Map.keys(value), &(not Map.has_key?(properties, &1))) do
          nil ->
            :ok

          extra ->
            {:error, type_error(join(path, extra), "is not allowed by the type")}
        end

      _other ->
        :ok
    end
  end

  defp type_matches?("object", value), do: is_map(value)
  defp type_matches?("array", value), do: is_list(value)
  defp type_matches?("string", value), do: is_binary(value)
  defp type_matches?("boolean", value), do: is_boolean(value)
  defp type_matches?("null", value), do: is_nil(value)
  defp type_matches?("integer", value), do: is_integer(value)
  defp type_matches?("number", value), do: is_number(value)

  defp type_matches?(other, value), do: matches_inferred?(other, value)

  defp matches_inferred?("object", _value), do: false
  defp matches_inferred?("array", _value), do: false
  defp matches_inferred?("string", _value), do: false
  defp matches_inferred?("boolean", _value), do: false
  defp matches_inferred?("null", _value), do: false
  defp matches_inferred?("integer", _value), do: false
  defp matches_inferred?("number", _value), do: false
  defp matches_inferred?(_other, _value), do: true

  defp describe_types(types), do: Enum.map_join(types, " or ", &inspect/1)

  defp type_error("", message), do: "the attribute #{message}"
  defp type_error(path, message), do: "the attribute #{inspect(path)} #{message}"

  defp join("", name), do: name
  defp join(path, name), do: "#{path}.#{name}"

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 -> min(limit, @max_limit)
      _other -> @default_limit
    end
  end

  defp attributes(attrs), do: attrs["attributes"] || attrs[:attributes] || %{}

  defp attributes(attrs, current) do
    case attrs["attributes"] || attrs[:attributes] do
      nil -> current["attributes"] || %{}
      attributes when is_map(attributes) -> attributes
    end
  end

  defp attr(attrs, key, default \\ nil) do
    case Map.get(attrs, key, Map.get(attrs, String.to_atom(key))) do
      nil -> default
      value -> value
    end
  end

  # A diff with a `nil` in it does not verify: the store drops a null field
  # from the flexible object it writes, and the canonical encoding tells an
  # absent key from a key whose value is null. A value that is not set is not
  # written.
  defp without_nils(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp actor(attrs) do
    case attr(attrs, "actor") do
      nil -> %{type: "system", id: "cmdb"}
      %{} = actor -> actor
      id -> %{type: "user", id: id}
    end
  end

  defp present(nil), do: {:error, "no such configuration item"}
  defp present(ci), do: {:ok, ci}

  defp identifier, do: :crypto.strong_rand_bytes(9) |> Base.encode16(case: :lower)
end
