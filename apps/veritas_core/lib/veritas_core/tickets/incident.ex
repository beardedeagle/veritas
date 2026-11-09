defmodule Veritas.Core.Tickets.Incident do
  @moduledoc """
  Incident facts, explicit answer bindings and operation-specific guards.

  No workflow key/label or legacy numeric/category value is interpreted as a
  canonical fact. Canonical inputs are JSON string-key maps. Structured bound
  textarea values are explicitly JSON-decoded according to their declared
  binding, never inferred from an unbound answer. Supplemental objects may be
  supplied directly. Server attribution, approval and clock facts are not inputs.

  Evidence objects use `reference` and `text`. Communication markers additionally
  require channel, direction and recipient; their purpose is the chosen bound
  field, and attribution/recording time is added by the host. Workarounds contain
  steps, owner_id, effective_at and expires_at or review_at. A human's marker is
  an attestation about the referenced communication, not an automatic send.
  """

  alias Veritas.Core.{Policy, Principal}
  alias Veritas.Core.Tickets.IncidentPolicy
  alias Veritas.Store

  @states ~w(new acknowledged in_progress on_hold resolved closed cancelled)
  @tracks ~w(not_started open in_progress complete)
  @codes ~w(fixed_permanently workaround_applied no_fault_found not_reproducible duplicate_incident user_error no_action_required transferred_to_problem)
  @objects ~w(priority_override track_plan restoration_evidence resume_evidence notification_evidence confirmation_evidence response_evidence workaround)
  @fields ~w(title description impact urgency severity incident_class priority priority_justification priority_override assignee affected_ci_ids track_plan restore_track restoration_evidence root_cause_track hold_reason hold_owner_id expected_resume_at resume_evidence resolution_code problem_id notification_evidence confirmation_evidence response_evidence cancellation_reason workaround)
  @aliases %{"requester_notification" => "notification_evidence", "requester_confirmation" => "confirmation_evidence"}
  @columns %{"impact" => "impact_level", "urgency" => "urgency_level",
    "severity" => "severity_level", "incident_class" => "classification",
    "priority_justification" => "priority_justification", "track_plan" => "track_plan",
    "restore_track" => "restore_track", "restoration_evidence" => "restoration_evidence",
    "root_cause_track" => "root_cause_track", "hold_reason" => "hold_reason",
    "hold_owner_id" => "hold_owner", "expected_resume_at" => "expected_resume_at",
    "resume_evidence" => "resume_evidence", "resolution_code" => "resolution_code",
    "problem_id" => "problem", "notification_evidence" => "notification_evidence",
    "confirmation_evidence" => "confirmation_evidence", "response_evidence" => "response_evidence",
    "cancellation_reason" => "cancellation_reason", "workaround" => "workaround"}

  @doc "The supported semantic fields; these are not database paths."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "The canonical form/editor vocabularies, without initial selections."
  @spec vocabulary() :: map()
  def vocabulary do
    Map.merge(IncidentPolicy.vocabulary(), %{incident_class: ~w(major minor),
      track: @tracks, resolution_code: @codes, state: @states})
  end

  @doc "Returns the input type for an explicit known binding."
  @spec binding_type(term()) :: :string | :object | :array | nil
  def binding_type(binding) do
    binding = canonical_key(binding)
    cond do
      binding in @objects -> :object
      binding == "affected_ci_ids" -> :array
      binding in @fields -> :string
      true -> nil
    end
  end

  @doc "Validates field binding targets, type compatibility and within-step uniqueness."
  @spec validate_bindings([map()]) :: :ok | {:error, term()}
  def validate_bindings(fields) do
    Enum.with_index(fields)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {field, index}, {:ok, seen} ->
      binding = field["binding"]
      if is_nil(binding) do
        {:cont, {:ok, seen}}
      else
        type = binding_type(binding)
        key = canonical_key(binding)
        path = "fields.#{index}.binding"
        allowed = if type in [:object, :array], do: ["textarea"], else: ~w(text textarea select)
        cond do
          is_nil(type) -> {:halt, invalid(path, :unknown_binding)}
          field["type"] not in allowed -> {:halt, invalid(path, :incompatible_binding)}
          MapSet.member?(seen, key) -> {:halt, invalid(path, :duplicate_binding)}
          true -> {:cont, {:ok, MapSet.put(seen, key)}}
        end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Extracts only declared bindings and rejects conflicting supplemental facts."
  @spec bound_fields(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def bound_fields(step, answers, supplemental) when is_map(answers) and is_map(supplemental) do
    with :ok <- validate_bindings(step["fields"] || []),
         {:ok, supplied} <- normalize(supplemental),
         {:ok, bound} <- Enum.reduce_while(step["fields"] || [], {:ok, %{}}, fn field, {:ok, result} ->
           binding = field["binding"]
           value = answers[field["key"]]
           if is_nil(binding) or is_nil(value) or value == "" do
             {:cont, {:ok, result}}
           else
             case normalize(%{canonical_key(binding) => value}) do
               {:ok, normalized} -> {:cont, {:ok, Map.merge(result, normalized)}}
               error -> {:halt, error}
             end
           end
         end) do
      conflicts = for {key, value} <- bound, Map.has_key?(supplied, key) and supplied[key] != value,
        into: %{}, do: {key, :conflicting_value}
      if map_size(conflicts) == 0, do: {:ok, Map.merge(bound, supplied)},
        else: {:error, {:invalid_domain_fields, conflicts}}
    end
  end
  def bound_fields(_, _, _), do: invalid("domain_fields", :object_required)

  @doc "Combines two explicit sources without silently giving either precedence."
  @spec merge_fields(map(), map()) :: {:ok, map()} | {:error, term()}
  def merge_fields(left, right) do
    with {:ok, left} <- normalize(left), {:ok, right} <- normalize(right) do
      conflicts = for {key, value} <- left, Map.has_key?(right, key) and right[key] != value,
        into: %{}, do: {key, :conflicting_value}
      if map_size(conflicts) == 0, do: {:ok, Map.merge(left, right)},
        else: {:error, {:invalid_domain_fields, conflicts}}
    end
  end

  @doc "Normalizes supplied facts without accepting authority, clocks or approval fields."
  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(fields) when is_map(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {raw, value}, {:ok, values} ->
      key = canonical_key(raw)
      cond do
        key not in @fields -> {:halt, invalid("domain_fields", :unknown_field)}
        Map.has_key?(values, key) -> {:halt, invalid(key, :duplicate_field)}
        true ->
          case normalize_value(key, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
            error -> {:halt, error}
          end
      end
    end)
  end
  def normalize(_), do: invalid("domain_fields", :object_required)

  @doc "Checks explicit nil legacy revisions separately from omitted preconditions."
  @spec revision(map(), keyword()) :: :ok | {:error, term()}
  def revision(detail, opts) do
    current = detail["domain_revision"]
    if Keyword.has_key?(opts, :expected_domain_revision) and opts[:expected_domain_revision] == current,
      do: :ok, else: {:error, {:domain_revision_conflict, current}}
  end

  @doc "Checks stored provenance containers without normalizing or replacing history."
  @spec validate_provenance(map()) :: :ok | {:error, Store.Error.t()}
  def validate_provenance(detail) do
    valid? = case detail["domain_provenance"] do
      nil -> true
      provenance when is_map(provenance) and not is_struct(provenance) ->
        fields = provenance["fields"]
        communications = provenance["communications"]
        (is_nil(fields) or (is_map(fields) and not is_struct(fields))) and
          (is_nil(communications) or is_list(communications))
      _ -> false
    end

    if valid?, do: :ok,
      else: {:error, Store.Error.new(:protocol, "Incident provenance has an invalid stored shape.")}
  end

  @doc "Projects canonical facts separately from the known legacy evidence fields."
  @spec facts(map(), map()) :: map()
  def facts(ticket, detail) do
    provenance = detail["domain_provenance"] || %{}
    recorded = provenance["fields"] || %{}
    values = Enum.reduce(@columns, %{}, fn {field, column}, facts ->
      value = detail[column]
      if not is_nil(value) and (column != field or Map.has_key?(recorded, field)),
        do: Map.put(facts, field, value), else: facts
    end)
    values = values |> Map.put("title", ticket["title"]) |> Map.put("description", ticket["description"])
      |> Map.put("assignee", ticket["assignee"])
    if detail["priority_policy_version"] || detail["priority_override_evidence"] do
      case IncidentPolicy.priority(ticket["priority"]) do
        {:ok, priority} -> Map.put(values, "priority", priority)
        _ -> values
      end
    else
      values
    end
  end

  @doc "Only known authorized legacy fields are exposed, never arbitrary preserved extras."
  @spec raw_legacy(map(), map()) :: map()
  def raw_legacy(ticket, detail) do
    %{ticket: Map.take(ticket, ~w(priority impact urgency severity sla_ref)),
      incident: Map.take(detail, ~w(incident_class major restore_track root_cause_track resolution_code promoted_to))}
  end

  @doc "Maps validated semantic fields to declared scalar detail columns."
  @spec detail_patch(map()) :: map()
  def detail_patch(fields), do: Map.new(for {key, column} <- @columns, Map.has_key?(fields, key), do: {column, fields[key]})

  @doc "Checks supplied facts cannot erase previously valid protected facts."
  @spec preserve(map(), map()) :: :ok | {:error, term()}
  def preserve(old, patch) do
    errors = for {key, value} <- patch, not is_nil(old[key]) and is_nil(value),
      into: %{}, do: {key, :cannot_clear_protected_fact}
    if map_size(errors) == 0, do: :ok, else: {:error, {:invalid_domain_fields, errors}}
  end

  @doc "Checks candidate state invariants only when an operation advances or transitions."
  @spec guard(map(), String.t(), atom(), DateTime.t()) :: :ok | {:error, term()}
  def guard(facts, state, operation, now) do
    cond do
      state not in @states -> invalid("state", :legacy_value_requires_correction)
      operation in [:create, :amend, :content, :assign] -> :ok
      true -> state_guard(facts, state, now)
    end
  end

  defp state_guard(facts, state, now) do
    common = if state in ~w(acknowledged in_progress on_hold resolved closed),
      do: ~w(impact urgency severity incident_class priority priority_justification assignee notification_evidence), else: []
    specific = case state do
      "in_progress" -> ~w(track_plan)
      "on_hold" -> ~w(hold_reason hold_owner_id expected_resume_at)
      "resolved" -> ~w(restore_track restoration_evidence resolution_code)
      "closed" -> ~w(restore_track restoration_evidence resolution_code root_cause_track confirmation_evidence)
      "cancelled" -> ~w(cancellation_reason)
      _ -> []
    end
    errors = for key <- common ++ specific, is_nil(facts[key]) or facts[key] == "", into: %{}, do: {key, :required}
    errors = if state in ~w(resolved closed) and facts["restore_track"] != "complete",
      do: Map.put(errors, "restore_track", :restoration_required), else: errors
    errors = if state == "closed" and facts["root_cause_track"] in @tracks -- ["complete"] and is_nil(facts["problem_id"]),
      do: Map.put(errors, "problem_id", :required), else: errors
    errors = if facts["resolution_code"] == "workaround_applied" and state in ~w(resolved closed) and not is_map(facts["workaround"]),
      do: Map.put(errors, "workaround", :required), else: errors
    errors = if state == "on_hold" and not future?(facts["expected_resume_at"], now),
      do: Map.put(errors, "expected_resume_at", :future_instant_required), else: errors
    if map_size(errors) == 0, do: :ok, else: {:error, {:invalid_domain_fields, errors}}
  end

  @doc "Validates referenced records through the Workspace-scoped port, without foreign reads."
  @spec references(Store.tx(), map(), Principal.t(), String.t()) :: :ok | {:error, term()}
  def references(tx, facts, principal, workspace) do
    refs = for key <- ~w(assignee hold_owner_id), is_binary(facts[key]), do: {key, :user, facts[key], nil}
    refs = refs ++ for id <- facts["affected_ci_ids"] || [], do: {"affected_ci_ids", :ci, id, nil}
    refs = if facts["problem_id"], do: refs ++ [{"problem_id", :ticket, facts["problem_id"], "problem"}], else: refs
    refs = if is_map(facts["workaround"]), do: refs ++ [{"workaround.owner_id", :user, facts["workaround"]["owner_id"], nil}], else: refs
    Enum.reduce_while(refs, :ok, fn {field, table, id, type}, :ok ->
      case Store.fetch(tx, table, id) do
        {:ok, row} when is_map(row) ->
          cond do
            row["workspace"] != workspace -> {:halt, invalid(field, :invalid_reference)}
            table == :user and row["disabled"] == true -> {:halt, invalid(field, :invalid_reference)}
            type && row["ticket_type"] != type -> {:halt, invalid(field, :invalid_reference)}
            true ->
              capability = if table == :ci, do: "ci:read", else: "ticket:read"
              case Policy.authorize_incident(principal, capability, %{workspace: workspace, ticket_type: type || "incident"}, tx) do
                :allow -> {:cont, :ok}
                {:deny, _} -> {:halt, {:ok, {:denied, {:invalid_domain_fields, %{field => :invalid_reference}}}}}
                {:error, _} = error -> {:halt, error}
              end
          end
        {:ok, _} -> {:halt, invalid(field, :invalid_reference)}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Adds only host-owned marker attribution/time after human authorization."
  @spec attest(map(), Principal.t(), DateTime.t()) :: map()
  def attest(fields, principal, now) do
    Enum.reduce(~w(notification_evidence confirmation_evidence response_evidence), fields, fn key, fields ->
      case fields[key] do
        %{} = marker -> Map.put(fields, key, Map.merge(marker, %{"purpose" => key,
          "recorded_by" => principal.id, "recorded_at" => DateTime.to_iso8601(now)}))
        _ -> fields
      end
    end)
  end

  defp canonical_key(value) when is_atom(value), do: canonical_key(Atom.to_string(value))
  defp canonical_key(value) when is_binary(value), do: Map.get(@aliases, value, value)
  defp canonical_key(_), do: nil

  defp normalize_value(_key, nil), do: {:ok, nil}
  defp normalize_value("priority", value) do
    case IncidentPolicy.priority(value) do
      {:ok, value} -> {:ok, value}
      _ -> invalid("priority", :invalid)
    end
  end
  defp normalize_value(key, value) when key in @objects do
    with {:ok, object} <- object(value, key), :ok <- object_shape(key, object) do
      {:ok, object}
    end
  end
  defp normalize_value("affected_ci_ids", value) do
    value = if is_binary(value), do: decode(value), else: value
    if is_list(value) and Enum.all?(value, &text?/1) and length(value) == length(Enum.uniq(value)),
      do: {:ok, value}, else: invalid("affected_ci_ids", :array_of_references_required)
  end
  defp normalize_value("expected_resume_at", value), do: datetime(value, "expected_resume_at")
  defp normalize_value(key, value) do
    vocabulary = IncidentPolicy.vocabulary()
    allowed = case key do
      "impact" -> vocabulary.impact
      "urgency" -> vocabulary.urgency
      "severity" -> vocabulary.severity
      "incident_class" -> ~w(major minor)
      key when key in ~w(restore_track root_cause_track) -> @tracks
      "resolution_code" -> @codes
      _ -> nil
    end
    cond do
      not is_binary(value) -> invalid(key, :text_required)
      key == "description" -> {:ok, value}
      not text?(value) -> invalid(key, :required)
      is_list(allowed) and value not in allowed -> invalid(key, :invalid)
      true -> {:ok, value}
    end
  end

  defp object(value, _key) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &is_binary/1), do: {:ok, value}, else: invalid("domain_fields", :string_keys_required)
  end
  defp object(value, key) when is_binary(value) do
    case decode(value) do
      value when is_map(value) -> object(value, key)
      _ -> invalid(key, :object_required)
    end
  end
  defp object(_, key), do: invalid(key, :object_required)

  defp object_shape(key, value) do
    {allowed, required} = case key do
      "priority_override" -> {~w(reason expires_at), ~w(reason)}
      "workaround" -> {~w(steps owner_id effective_at expires_at review_at reference), ~w(steps owner_id effective_at)}
      key when key in ~w(notification_evidence confirmation_evidence response_evidence) ->
        {~w(reference text channel direction recipient), ~w(reference channel direction recipient)}
      _ -> {~w(reference text steps), []}
    end
    unknown = Map.keys(value) -- allowed
    missing = Enum.filter(required, &(not present?(value[&1])))
    cond do
      unknown != [] -> invalid(key, :unknown_field)
      missing != [] -> invalid(key, :incomplete_evidence)
      key in ~w(notification_evidence response_evidence) and value["direction"] != "outbound" -> invalid(key, :outbound_required)
      key == "confirmation_evidence" and value["direction"] != "inbound" -> invalid(key, :inbound_required)
      key == "workaround" -> workaround_shape(value)
      key == "priority_override" and not is_nil(value["expires_at"]) ->
        case datetime(value["expires_at"], key <> ".expires_at") do
          {:ok, _} -> :ok
          error -> error
        end
      required == [] and not Enum.any?(~w(reference text steps), &present?(value[&1])) -> invalid(key, :evidence_required)
      true -> :ok
    end
  end

  defp workaround_shape(value) do
    with {:ok, effective} <- datetime(value["effective_at"], "workaround.effective_at"),
         true <- text?(value["owner_id"]) and valid_steps?(value["steps"]) || invalid("workaround", :incomplete_evidence),
         date when not is_nil(date) <- value["expires_at"] || value["review_at"] || invalid("workaround", :review_date_required),
         {:ok, review} <- datetime(date, "workaround.review_at"),
         true <- DateTime.compare(parse(review), parse(effective)) != :lt || invalid("workaround.review_at", :invalid_chronology) do
      :ok
    else
      {:error, _} = error -> error
      _ -> invalid("workaround", :incomplete_evidence)
    end
  end

  defp valid_steps?(value), do: text?(value) or (is_list(value) and value != [] and Enum.all?(value, &text?/1))
  defp present?(value), do: text?(value) or (is_list(value) and value != []) or (is_map(value) and map_size(value) > 0)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp decode(value) do
    case Jason.decode(value) do
      {:ok, value} -> value
      _ -> nil
    end
  end
  defp datetime(value, key) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, value, _} -> {:ok, DateTime.to_iso8601(value)}
      _ -> invalid(key, :instant_required)
    end
  end
  defp datetime(_, key), do: invalid(key, :instant_required)
  defp parse(value) do
    {:ok, value, _} = DateTime.from_iso8601(value)
    value
  end
  defp future?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, value, _} -> DateTime.compare(value, now) == :gt
      _ -> false
    end
  end
  defp future?(_, _), do: false
  defp invalid(path, code), do: {:error, {:invalid_domain_fields, %{path => code}}}
end
