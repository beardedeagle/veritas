defmodule Veritas.Core.Parity.Contract do
  @moduledoc """
  Validates the fixed MVP parity inventory before any coverage is counted.

  The baseline is transcribed from docs/04:479-481. It is deliberately not
  supplied by the document being checked: deleting two matching declarations
  cannot delete a requirement. Counts remain declarations, not executed proof.
  """

  @surfaces ~w(cli graphql ui)
  @types ~w(incident change service_request problem vulnerability)
  @ticket_ids ~w(ticket.create ticket.update ticket.transition ticket.comment ticket.assign)
  @other_ids ~w(ci.create ci.update ci.retire relationship.create relationship.delete ci.query search.global bulk.transition bulk.assign audit.query audit.export dashboard.report agent_run.start agent_run.status agent_run.approve agent_run.reject agent_run.transcript discovery.trigger adapter.list ci.observation_fetch)
  @ids @ticket_ids ++ @other_ids
  @binding_states ~w(missing implemented-unverified behaviorally-verified)
  @aspect_states @binding_states ++ ~w(open not-examined)
  @modes ~w(by_attribute by_type by_relationship)
  @formats ~w(csv jsonl)
  @grammar_operations ~w(ci.query search.global)
  @source "docs/04-information-architecture-and-dashboards.md"
  @rank ~w(missing open not-examined implemented-unverified behaviorally-verified)

  @doc """
  Validates a decoded manifest without starting applications or reading docs.

  ## Arguments
    * `manifest` — the decoded JSON value, including malformed shapes.

  ## Returns
    * `:ok` for a structurally complete inventory.
    * `{:error, messages}` for invalid or contradictory declarations.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(%{"meta" => meta, "operations" => operations})
      when is_map(meta) and is_list(operations) do
    errors = validate_meta(meta) ++ validate_operations(operations)
    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate(_manifest),
    do: {:error, ["R0: require a JSON object with meta object and nonempty operations array"]}

  @doc "Returns the fixed operation identifiers from the reviewed parity clause."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "Returns the fixed required surfaces."
  @spec surfaces() :: [String.t()]
  def surfaces, do: @surfaces

  @doc """
  Enumerates independently required proof cells for a validated manifest.

  ## Arguments
    * `manifest` — a manifest for which `validate/1` returned `:ok`.

  ## Returns
    * A list of operation/surface/aspect cells and their declared states.
  """
  @spec obligations(map()) :: [map()]
  def obligations(manifest) do
    Enum.flat_map(manifest["operations"], fn operation ->
      ordinary_obligations(operation) ++ grammar_obligations(operation, manifest)
    end)
  end

  @doc """
  Counts the fixed 45 operations and 135 bindings conservatively.

  ## Arguments
    * `manifest` — a validated manifest.

  ## Returns
    * Counts whose state for each binding includes its required aspects.
  """
  @spec counts(map()) :: map()
  def counts(manifest) do
    cells = Enum.flat_map(manifest["operations"], &binding_cells(&1, manifest))
    states = Enum.frequencies_by(cells, & &1.status)
    %{operations: 45, required: 135, states: states, cells: cells}
  end

  @doc "Returns the least-proved state; an unresolved part cannot certify a whole."
  @spec conservative([String.t()]) :: String.t()
  def conservative(states), do: Enum.find(@rank, &(&1 in states))

  defp validate_meta(meta) do
    validate_contract(meta["contract"]) ++
      vocabulary(meta["coverage_states"], @binding_states, "meta.coverage_states") ++
      vocabulary(meta["aspect_states"], @aspect_states, "meta.aspect_states") ++
      enumeration(meta["enumeration"]) ++ validate_grammar(meta["filter_grammar"])
  end

  defp validate_contract(%{"source" => @source, "clause_line" => 479, "scope_line" => 481}),
    do: []

  defp validate_contract(_contract),
    do: ["R0: meta.contract must name the reviewed docs/04:479-481 baseline"]

  defp vocabulary(value, names, label) when is_map(value) do
    require_set(Map.keys(value), names, label) ++
      require_true(Enum.all?(Map.values(value), &text?/1), "#{label} needs nonempty descriptions")
  end

  defp vocabulary(_value, _names, label), do: ["R3: #{label} must be an object"]

  defp enumeration(value) when is_map(value) do
    require_set(Map.keys(value), @ids, "meta.enumeration") ++
      Enum.flat_map(value, fn {id, surfaces} ->
        require_set(surfaces, @surfaces, "enumeration #{id} surfaces")
      end)
  end

  defp enumeration(_value), do: ["R2: meta.enumeration must carry the fixed nonempty baseline"]

  defp validate_grammar(%{"applies_to" => operations, "states" => states} = grammar) do
    require_true(text?(grammar["source"]), "shared filter grammar needs its source") ++
      require_set(operations, @grammar_operations, "shared filter grammar operations") ++
      state_map(states, "shared filter grammar")
  end

  defp validate_grammar(_grammar),
    do: ["R5: shared filter grammar needs complete per-surface states and applies_to"]

  defp validate_operations(operations) do
    ids = Enum.map(operations, fn operation -> if is_map(operation), do: operation["id"] end)

    require_set(ids, @ids, "operations (unique fixed IDs)") ++
      Enum.flat_map(operations, &validate_operation/1)
  end

  defp validate_operation(%{"id" => id} = operation) when id in @ids do
    {kind, names} = aspect_definition(id)

    require_true(text?(operation["name"]), "#{id} needs a name") ++
      require_set(operation["surfaces"], @surfaces, "#{id} surfaces") ++
      require_set(operation["ticket_types"], ticket_types(id), "#{id} ticket_types") ++
      validate_bindings(operation["bindings"], id) ++
      validate_aspects(operation["aspects"], kind, names, id) ++
      named_obligations(operation, id) ++ contradictions(operation)
  end

  defp validate_operation(_operation),
    do: ["R2: each operation must be an object with a fixed ID"]

  defp validate_bindings(bindings, id) when is_map(bindings) do
    require_set(Map.keys(bindings), @surfaces, "#{id} binding keys") ++
      Enum.flat_map(bindings, fn {surface, binding} -> validate_binding(binding, id, surface) end)
  end

  defp validate_bindings(_bindings, id), do: ["R4: #{id} needs a bindings object"]

  defp validate_binding(binding, id, surface) when is_map(binding) do
    label = "#{id}/#{surface}"

    require_true(binding["kind"] == surface, "#{label} binding kind must match its surface") ++
      require_true(binding["status"] in @binding_states, "#{label} has an invalid binding status") ++
      validate_identity(binding, label) ++
      optional_strings(binding, "evidence", label) ++
      optional_strings(binding, "proof_ids", label)
  end

  defp validate_binding(_binding, id, surface),
    do: ["R3: #{id}/#{surface} needs a binding object"]

  defp validate_identity(%{"status" => "missing"} = binding, label) do
    require_true(
      is_nil(binding["identifier"]),
      "#{label}: a missing binding cannot name an identifier"
    ) ++
      require_true(
        is_nil(binding["location"]),
        "#{label}: a missing binding cannot name a location"
      ) ++
      require_true(
        binding["evidence"] in [nil, []],
        "#{label}: a missing binding cannot claim evidence"
      ) ++
      require_true(
        binding["proof_ids"] in [nil, []],
        "#{label}: a missing binding cannot claim proof"
      )
  end

  defp validate_identity(binding, label) do
    require_true(
      text?(binding["identifier"]),
      "#{label}: an existing binding needs an identifier"
    ) ++
      require_true(
        is_nil(binding["location"]) or text?(binding["location"]),
        "#{label}: invalid location"
      )
  end

  defp optional_strings(binding, key, label) do
    case Map.fetch(binding, key) do
      :error ->
        []

      {:ok, values} ->
        require_true(string_list?(values), "#{label}: #{key} needs unique nonempty strings")
    end
  end

  defp validate_aspects(nil, nil, [nil], _id), do: []

  defp validate_aspects(%{"kind" => kind, "states" => states}, kind, names, id)
       when not is_nil(kind) and is_map(states) do
    require_set(Map.keys(states), names, "#{id} aspect names") ++
      Enum.flat_map(states, fn {name, per_surface} -> state_map(per_surface, "#{id}/#{name}") end)
  end

  defp validate_aspects(_aspects, _kind, _names, id),
    do: ["R5: #{id} needs exactly its required aspect kind, names and per-surface states"]

  defp state_map(states, label) when is_map(states) do
    require_set(Map.keys(states), @surfaces, "#{label} aspect surfaces") ++
      require_true(
        Enum.all?(Map.values(states), &(&1 in @aspect_states)),
        "#{label} has an invalid aspect status"
      )
  end

  defp state_map(_states, label), do: ["R5: #{label} needs a per-surface state object"]

  defp named_obligations(operation, "ci.query"),
    do: require_set(operation["query_modes"], @modes, "ci.query query_modes")

  defp named_obligations(operation, "audit.export"),
    do: require_set(operation["formats"], @formats, "audit.export formats")

  defp named_obligations(_operation, _id), do: []

  defp contradictions(%{"bindings" => bindings, "aspects" => %{"states" => states}} = operation)
       when is_map(bindings) and is_map(states) do
    Enum.flat_map(@surfaces, &contradictory_surface(bindings[&1], states, &1, operation["id"]))
  end

  defp contradictions(_operation), do: []

  defp contradictory_surface(%{"status" => "missing"}, states, surface, id) do
    values = Enum.map(Map.values(states), fn value -> if is_map(value), do: value[surface] end)

    require_true(
      not Enum.any?(values, &(&1 in ~w(implemented-unverified behaviorally-verified))),
      "#{id}/#{surface}: a missing parent cannot offer or prove an aspect"
    )
  end

  defp contradictory_surface(%{"status" => "behaviorally-verified"}, states, surface, id) do
    values = Enum.map(Map.values(states), fn value -> if is_map(value), do: value[surface] end)

    require_true(
      Enum.all?(values, &(&1 == "behaviorally-verified")),
      "#{id}/#{surface}: a verified parent cannot conceal unproved required aspects"
    )
  end

  defp contradictory_surface(_binding, _states, _surface, _id), do: []

  defp require_set(value, expected, label) do
    valid =
      is_list(value) and length(value) == length(expected) and
        Enum.sort(value) == Enum.sort(expected)

    require_true(
      valid,
      "#{label} must be exactly #{Enum.join(expected, ", ")} without duplicates"
    )
  end

  defp require_true(true, _message), do: []
  defp require_true(false, message), do: ["R0: " <> message]
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_list?(values),
    do: is_list(values) and Enum.all?(values, &text?/1) and Enum.uniq(values) == values

  defp ticket_types(id) when id in @ticket_ids, do: @types
  defp ticket_types(_id), do: []
  defp aspect_definition(id) when id in @ticket_ids, do: {"ticket_type", @types}
  defp aspect_definition("ci.query"), do: {"query_mode", @modes}
  defp aspect_definition("audit.export"), do: {"format", @formats}
  defp aspect_definition(_id), do: {nil, [nil]}

  defp ordinary_obligations(operation) do
    {kind, names} = aspect_definition(operation["id"])

    for surface <- @surfaces, name <- names do
      parent = operation["bindings"][surface]["status"]
      declared = if is_nil(kind), do: parent, else: operation["aspects"]["states"][name][surface]
      cell(operation["id"], surface, kind, name, conservative([parent, declared]))
    end
  end

  defp grammar_obligations(%{"id" => id}, manifest) when id in @grammar_operations do
    for surface <- @surfaces do
      cell(
        id,
        surface,
        "filter_grammar",
        "shared",
        manifest["meta"]["filter_grammar"]["states"][surface]
      )
    end
  end

  defp grammar_obligations(_operation, _manifest), do: []

  defp binding_cells(operation, manifest) do
    for surface <- @surfaces, type <- expanded_types(operation) do
      base = operation["bindings"][surface]["status"]

      states =
        required_states(operation, surface, type) ++ grammar_states(operation, manifest, surface)

      cell(
        operation["id"],
        surface,
        if(type, do: "ticket_type"),
        type,
        conservative([base | states])
      )
    end
  end

  defp expanded_types(%{"id" => id}) when id in @ticket_ids, do: @types
  defp expanded_types(_operation), do: [nil]

  defp required_states(operation, surface, type) when not is_nil(type),
    do: [operation["aspects"]["states"][type][surface]]

  defp required_states(%{"aspects" => aspects}, surface, _type),
    do: Enum.map(aspects["states"], fn {_name, states} -> states[surface] end)

  defp required_states(_operation, _surface, _type), do: []

  defp grammar_states(%{"id" => id}, manifest, surface) when id in @grammar_operations,
    do: [manifest["meta"]["filter_grammar"]["states"][surface]]

  defp grammar_states(_operation, _manifest, _surface), do: []

  defp cell(id, surface, kind, name, status),
    do: %{operation: id, surface: surface, aspect_kind: kind, aspect: name, status: status}
end
