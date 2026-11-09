defmodule Veritas.Core.Tickets.IncidentPolicy do
  @moduledoc """
  Revisioned Incident configuration, with no operational defaults.

  Documents have JSON string keys. `priority_rules` is a list of
  `%{"impact" => name, "urgency" => name, "priority" => "P1"}` cells.
  `sla_targets` maps P1..P4 to `response`/`resolution` targets, each containing
  a positive integer `amount`, `unit` (seconds/minutes/hours/days), `basis`
  (elapsed/business), and an optional named `calendar`. Business targets and
  qualified holds require a calendar. `calendars` maps identifier-safe names
  to timezone, weekly intervals (mon..sun), nonworking_dates and exceptions.
  Intervals are [HH:MM, HH:MM] pairs; exceptions are date/intervals objects.

  Missing sections are valid drafts, not default configuration. Published
  versions are immutable. Publication consumes the draft and its revision.
  The timezone database and its rules version are injected by trusted host
  options/configuration; neither is accepted from an operator document.
  """

  alias Veritas.Core.{Audit, Policy, Principal, WorkspaceLock}
  alias Veritas.Core.Tickets.IncidentClock
  alias Veritas.Store

  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @severities ~w(critical major minor indeterminate)
  @priorities ~w(P1 P2 P3 P4)
  @days ~w(mon tue wed thu fri sat sun)
  @sections ~w(priority_rules sla_targets calendars reopen_resolution)
  @aliases %{"p1" => "P1", "urgent" => "P1", "p2" => "P2", "high" => "P2",
             "p3" => "P3", "medium" => "P3", "p4" => "P4", "low" => "P4"}

  @doc "The named, nonnumeric classification vocabulary."
  @spec vocabulary() :: map()
  def vocabulary, do: %{impact: @impacts, urgency: @urgencies, severity: @severities}

  @doc "Normalizes a priority representation, without selecting or deriving one."
  @spec priority(term()) :: {:ok, String.t()} | {:error, :invalid_priority}
  def priority(value) when is_binary(value) do
    case Map.fetch(@aliases, value |> String.trim() |> String.downcase()) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_priority}
    end
  end

  def priority(_), do: {:error, :invalid_priority}

  @doc "The existing sole ticket column retains its descriptive storage representation."
  @spec storage_priority(String.t() | nil) :: String.t() | nil
  def storage_priority(nil), do: nil
  def storage_priority("P1"), do: "urgent"
  def storage_priority("P2"), do: "high"
  def storage_priority("P3"), do: "medium"
  def storage_priority("P4"), do: "low"

  @doc """
  Validates supplied content and returns missing-component readiness separately.

  Returns `{:ok, %{document: map, errors: path_code_map, readiness: map}}`.
  Missing sections/cells are not errors. A non-object is `:policy_invalid`.
  No configuration is activated and no provider/process is started.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(document) when is_map(document) do
    with {:ok, document} <- string_keys(document) do
      errors = unknown(document, @sections, "")
      {rules, errors} = rules(document["priority_rules"], errors)
      {targets, errors} = targets(document["sla_targets"], errors)
      errors = calendars(document["calendars"], errors)
      errors = reopen(document["reopen_resolution"], errors)

      normalized =
        document
        |> maybe_put("priority_rules", rules)
        |> maybe_put("sla_targets", targets)

      {:ok, %{document: normalized, errors: errors, readiness: readiness(normalized)}}
    end
  end

  def validate(_), do: {:error, {:policy_invalid, %{"document" => :object_required}}}

  @doc "Returns per-component and per-operation missing paths without inventing values."
  @spec readiness(map() | nil) :: map()
  def readiness(document) do
    document = document || %{}
    cells = if is_list(document["priority_rules"]),
      do: Enum.filter(document["priority_rules"], &is_map/1), else: []

    priority_missing =
      for impact <- @impacts, urgency <- @urgencies,
          not Enum.any?(cells, &(&1["impact"] == impact and &1["urgency"] == urgency)),
          do: "priority_rules.#{impact}.#{urgency}"

    response = target_missing(document, "response")
    resolution = target_missing(document, "resolution")
    reopen_missing = if document["reopen_resolution"] in ~w(cumulative new_cycle), do: [],
      else: ["reopen_resolution"]

    operations = %{
      derive_priority: priority_missing,
      acknowledge: Enum.uniq(priority_missing ++ response ++ resolution),
      response: response,
      resolution: resolution,
      reopen: Enum.uniq(resolution ++ reopen_missing)
    }

    %{missing: operations |> Map.values() |> List.flatten() |> Enum.uniq(), operations: operations}
  end

  @doc "Selects a configured cell; severity is deliberately not an input."
  @spec derive(map() | nil, term(), term()) :: {:ok, String.t()} | {:error, term()}
  def derive(document, impact, urgency) do
    missing = readiness(document).operations.derive_priority

    if missing == [] do
      case Enum.find(document["priority_rules"], &(&1["impact"] == impact and &1["urgency"] == urgency)) do
        %{"priority" => priority} -> {:ok, priority}
        _ -> {:error, {:invalid_domain_fields, %{"impact" => :invalid, "urgency" => :invalid}}}
      end
    else
      {:error, {:policy_unconfigured, %{missing: missing, operation: :derive_priority}}}
    end
  end

  @doc "Loads the active immutable version inside the caller's transaction."
  @spec active(Store.tx()) :: {:ok, map() | nil} | {:error, term()}
  def active(tx) do
    with {:ok, config} <- Store.fetch(tx, :incident_configuration, "current") do
      case config && config["active_policy_version"] do
        nil -> {:ok, nil}
        id ->
          with {:ok, row} <- Store.fetch(tx, :incident_policy_version, id) do
            if is_map(row) and row["status"] == "published",
              do: {:ok, row},
              else: {:error, Store.Error.new(:internal, "The active Incident policy is unavailable.")}
          end
      end
    end
  end

  @doc "Checks an optional active-version precondition, never selects a historic version."
  @spec version(map() | nil, keyword()) :: :ok | {:error, term()}
  def version(active, opts) do
    current = active && active["id"]
    if Keyword.has_key?(opts, :expected_policy_version) and opts[:expected_policy_version] != current,
      do: {:error, {:policy_version_conflict, current}}, else: :ok
  end

  @doc """
  Returns authorized active configuration and an administrator-only draft.

  The atom-key envelope is `%{policy_revision: integer | nil, active_version:
  id | nil, active: document | nil, draft: %{revision: integer, document: map}
  | nil, readiness: map, errors: map}`. Draft contents are never returned to a
  non-administrator. Reads authorize before exposing any revision or content.
  """
  @spec read(Store.workspace(), Principal.t() | nil) :: {:ok, map()} | {:error, term()}
  def read(workspace, principal) do
    write(workspace, fn tx ->
      case Policy.authorize_incident(principal, "ticket:read", %{workspace: workspace}, tx) do
        :allow -> response(tx, principal)
        {:deny, reason} -> {:ok, {:denied, reason}}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Validates a policy for an authorized human Platform Admin, without saving it."
  @spec validate_for(Store.workspace(), term(), Principal.t() | nil) :: {:ok, map()} | {:error, term()}
  def validate_for(workspace, document, principal) do
    write(workspace, fn tx -> admin(tx, workspace, principal, fn -> validate(document) end) end)
  end

  @doc "Saves a valid partial draft using an explicit nil-or-integer policy revision."
  @spec save(Store.workspace(), map(), Principal.t() | nil, integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def save(workspace, document, principal, expected) do
    write(workspace, fn tx ->
      admin(tx, workspace, principal, fn ->
        with {:ok, validation} <- validate(document),
             :ok <- valid(validation),
             {:ok, config} <- Store.fetch(tx, :incident_configuration, "current"),
             :ok <- revision(config, expected) do
          now = DateTime.utc_now()
          row = %{"id" => "current", "workspace" => workspace,
            "revision" => (config && config["revision"] || 0) + 1,
            "draft" => validation.document, "updated_at" => now,
            "updated_by" => actor_document(principal),
            "active_policy_version" => config && config["active_policy_version"]}

          with {:ok, _} <- Store.put(tx, :incident_configuration, row),
               {:ok, _} <- audit(tx, workspace, principal, "Incident policy draft saved", %{
                 "revision" => row["revision"], "document" => validation.document
               }) do
            response(tx, principal)
          end
        end
      end)
    end)
  end

  @doc "Publishes and consumes the exact draft and human approval in one transaction."
  @spec publish(Store.workspace(), Principal.t() | nil, integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def publish(workspace, principal, expected, opts) do
    write(workspace, fn tx ->
      admin(tx, workspace, principal, fn ->
        with :ok <- approval(tx, workspace, principal, opts),
             {:ok, config} <- Store.fetch(tx, :incident_configuration, "current"),
             :ok <- revision(config, expected),
             {:ok, draft} <- draft(config),
             {:ok, validation} <- validate(draft),
             :ok <- valid(validation),
             {:ok, calendars} <- publication_calendars(workspace, validation.document, principal, config, opts) do
          now = DateTime.utc_now()
          id = identifier()
          definition = Map.put(validation.document, "calendar_versions", Map.new(calendars, &{&1["calendar_key"], &1["id"]}))
          row = %{"id" => id, "workspace" => workspace, "policy_key" => "incident",
            "version" => config["revision"], "schema_version" => 1,
            "revision" => config["revision"], "status" => "published",
            "definition" => definition, "created_at" => now,
            "created_by" => actor_document(principal), "published_at" => now,
            "published_by" => actor_document(principal)}
          updated = Map.merge(config, %{"draft" => nil, "active_policy_version" => id,
            "revision" => config["revision"] + 1, "updated_at" => now,
            "updated_by" => actor_document(principal)})

          with :ok <- store_calendars(tx, calendars),
               {:ok, _} <- Store.put(tx, :incident_policy_version, row),
               {:ok, _} <- Store.put(tx, :incident_configuration, updated),
               {:ok, _} <- audit(tx, workspace, principal, "Human published Incident policy", %{
                 "version" => id, "revision" => updated["revision"],
                 "calendar_versions" => definition["calendar_versions"],
                 "approval" => actor_document(principal)
               }) do
            response(tx, principal)
          end
        end
      end)
    end)
  end

  defp response(tx, principal) do
    with {:ok, config} <- Store.fetch(tx, :incident_configuration, "current"),
         {:ok, active} <- active(tx) do
      document = active && Map.delete(active["definition"], "calendar_versions")
      draft = if administer?(principal) and config && is_map(config["draft"]),
        do: %{revision: config["revision"], document: config["draft"]}, else: nil
      {:ok, %{policy_revision: config && config["revision"], active_version: active && active["id"],
        active: document, draft: draft, readiness: readiness(document), errors: %{}}}
    end
  end

  defp admin(tx, workspace, principal, fun) do
    case Policy.authorize_incident(principal, :incident_policy_admin, %{workspace: workspace}, tx) do
      :allow -> fun.()
      {:deny, reason} -> {:ok, {:denied, reason}}
      {:error, _} = error -> error
    end
  end

  defp approval(tx, workspace, principal, opts) do
    if opts[:approve] == true do
      :ok
    else
      case Policy.authorize_incident(principal, :incident_policy_admin,
             %{workspace: workspace, approval_required: true, approved: false}, tx) do
        {:deny, reason} -> {:ok, {:denied, reason}}
        {:error, _} = error -> error
      end
    end
  end

  defp administer?(%Principal{kind: :human, roles: roles}), do: :platform_admin in roles
  defp administer?(_), do: false
  defp draft(%{"draft" => draft}) when is_map(draft), do: {:ok, draft}
  defp draft(_), do: {:error, {:policy_unconfigured, %{missing: ["draft"], operation: :publish}}}
  defp revision(row, expected) do
    current = row && row["revision"]
    if current == expected, do: :ok, else: {:error, {:policy_revision_conflict, current}}
  end

  defp valid(%{errors: errors}) when map_size(errors) == 0, do: :ok
  defp valid(%{errors: errors}), do: {:error, {:policy_invalid, errors}}

  defp write(workspace, fun) do
    WorkspaceLock.with_lock(workspace, fn -> Store.transaction(workspace, fun) end)
    |> case do
      {:ok, {:denied, reason}} -> {:error, reason}
      result -> result
    end
  end

  defp audit(tx, workspace, principal, reason, diff) do
    Audit.append(tx, workspace, %{subject: "current", subject_table: "incident_configuration",
      actor: Principal.audit_actor(principal), from_state: nil, to_state: "configured",
      reason: reason, correlation_id: nil, diff: diff})
  end

  defp publication_calendars(workspace, document, principal, config, opts) do
    Enum.reduce_while(document["calendars"] || %{}, {:ok, []}, fn {name, calendar}, {:ok, rows} ->
      with :ok <- complete_calendar(name, calendar),
           :ok <- IncidentClock.validate_calendar(calendar, opts),
           version when is_binary(version) and byte_size(version) > 0 <- IncidentClock.rules_version(opts) do
        now = DateTime.utc_now()
        row = %{"id" => identifier(), "workspace" => workspace, "calendar_key" => name,
          "version" => config["revision"], "schema_version" => 1, "revision" => config["revision"],
          "status" => "published", "timezone" => calendar["timezone"],
          "timezone_rules_version" => version, "definition" => calendar,
          "created_at" => now, "created_by" => actor_document(principal),
          "published_at" => now, "published_by" => actor_document(principal)}
        {:cont, {:ok, rows ++ [row]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :timezone_provider_unavailable}}
      end
    end)
  end

  defp store_calendars(tx, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Store.put(tx, :incident_calendar_version, row) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp actor_document(principal), do: %{"type" => "user", "id" => principal.id}
  defp identifier, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp rules(nil, errors), do: {nil, errors}
  defp rules(cells, errors) when is_list(cells) do
    {cells, errors, _seen} = Enum.with_index(cells) |> Enum.reduce({[], errors, MapSet.new()}, fn {cell, index}, {rows, errors, seen} ->
      path = "priority_rules.#{index}"
      if is_map(cell) do
        errors = unknown(cell, ~w(impact urgency priority), path)
          |> Map.merge(errors)
          |> check(cell["impact"] in @impacts, path <> ".impact", :invalid)
          |> check(cell["urgency"] in @urgencies, path <> ".urgency", :invalid)
        key = {cell["impact"], cell["urgency"]}
        errors = check(errors, not MapSet.member?(seen, key), path, :duplicate)
        {canonical, errors} = case priority(cell["priority"]) do
          {:ok, value} -> {value, errors}
          _ -> {cell["priority"], Map.put(errors, path <> ".priority", :invalid)}
        end
        {rows ++ [Map.put(cell, "priority", canonical)], errors, MapSet.put(seen, key)}
      else
        {rows, Map.put(errors, path, :object_required), seen}
      end
    end)
    {cells, errors}
  end
  defp rules(_, errors), do: {nil, Map.put(errors, "priority_rules", :array_required)}

  defp targets(nil, errors), do: {nil, errors}
  defp targets(targets, errors) when is_map(targets) do
    Enum.reduce(targets, {%{}, errors}, fn {name, kinds}, {result, errors} ->
      case priority(name) do
        {:ok, canonical} when is_map(kinds) ->
          path = "sla_targets.#{canonical}"
          errors = Map.merge(errors, unknown(kinds, ~w(response resolution), path))
          errors = check(errors, not Map.has_key?(result, canonical), path, :duplicate)
          errors = Enum.reduce(kinds, errors, fn {kind, target}, errors -> target_errors(target, path <> "." <> kind, errors) end)
          {Map.put(result, canonical, kinds), errors}
        _ -> {result, Map.put(errors, "sla_targets", :invalid)}
      end
    end)
  end
  defp targets(_, errors), do: {nil, Map.put(errors, "sla_targets", :object_required)}

  defp target_errors(target, path, errors) when is_map(target) do
    errors |> Map.merge(unknown(target, ~w(amount unit basis calendar), path))
    |> check(is_nil(target["amount"]) or (is_integer(target["amount"]) and target["amount"] > 0), path <> ".amount", :positive_integer_required)
    |> check(is_nil(target["unit"]) or target["unit"] in ~w(seconds minutes hours days), path <> ".unit", :invalid)
    |> check(is_nil(target["basis"]) or target["basis"] in ~w(elapsed business), path <> ".basis", :invalid)
    |> check(is_nil(target["calendar"]) or identifier?(target["calendar"]), path <> ".calendar", :invalid)
  end
  defp target_errors(_, path, errors), do: Map.put(errors, path, :object_required)

  defp calendars(nil, errors), do: errors
  defp calendars(values, errors) when is_map(values) do
    Enum.reduce(values, errors, fn {name, calendar}, errors ->
      path = "calendars.#{name}"
      errors = check(errors, identifier?(name), path, :invalid_identifier)
      if is_map(calendar) do
        errors = Map.merge(errors, unknown(calendar, ~w(timezone weekly nonworking_dates exceptions), path))
        errors = check(errors, is_nil(calendar["timezone"]) or text?(calendar["timezone"]), path <> ".timezone", :invalid)
        errors = weekly(calendar["weekly"], path <> ".weekly", errors)
        errors = dates(calendar["nonworking_dates"], path <> ".nonworking_dates", errors)
        exceptions(calendar["exceptions"], path <> ".exceptions", errors)
      else
        Map.put(errors, path, :object_required)
      end
    end)
  end
  defp calendars(_, errors), do: Map.put(errors, "calendars", :object_required)

  defp weekly(nil, _path, errors), do: errors
  defp weekly(values, path, errors) when is_map(values) do
    Enum.reduce(values, Map.merge(errors, unknown(values, @days, path)), fn {day, intervals}, errors ->
      interval_errors(intervals, path <> "." <> day, errors)
    end)
  end
  defp weekly(_, path, errors), do: Map.put(errors, path, :object_required)

  defp interval_errors(values, path, errors) when is_list(values) do
    {errors, _} = Enum.reduce(values, {errors, nil}, fn pair, {errors, previous} ->
      case pair do
        [a, b] ->
          with {:ok, from, until, next_day} <- interval(a, b),
               {from_seconds, _} <- Time.to_seconds_after_midnight(from),
               {until_seconds, _} <- Time.to_seconds_after_midnight(until),
               finish <- until_seconds + next_day * 86_400,
               true <- from_seconds < finish and (is_nil(previous) or previous <= from_seconds) do
            {errors, finish}
          else
            _ -> {Map.put(errors, path, :invalid_intervals), previous}
          end
        _ -> {Map.put(errors, path, :invalid_intervals), previous}
      end
    end)
    errors
  end
  defp interval_errors(_, path, errors), do: Map.put(errors, path, :array_required)

  defp dates(nil, _path, errors), do: errors
  defp dates(values, path, errors) when is_list(values) do
    check(errors, Enum.all?(values, &date?/1) and length(values) == length(Enum.uniq(values)), path, :invalid_dates)
  end
  defp dates(_, path, errors), do: Map.put(errors, path, :array_required)

  defp exceptions(nil, _path, errors), do: errors
  defp exceptions(values, path, errors) when is_list(values) do
    {errors, _} = Enum.reduce(values, {errors, MapSet.new()}, fn value, {errors, seen} ->
      if is_map(value) do
        date = value["date"]
        errors = errors |> Map.merge(unknown(value, ~w(date intervals), path))
          |> check(date?(date) and not MapSet.member?(seen, date), path, :invalid_dates)
        {interval_errors(value["intervals"], path, errors), MapSet.put(seen, date)}
      else
        {Map.put(errors, path, :object_required), seen}
      end
    end)
    errors
  end
  defp exceptions(_, path, errors), do: Map.put(errors, path, :array_required)

  defp reopen(nil, errors), do: errors
  defp reopen(mode, errors), do: check(errors, mode in ~w(cumulative new_cycle), "reopen_resolution", :invalid)

  defp target_missing(document, kind) do
    Enum.flat_map(@priorities, fn priority ->
      target = nested(document, ["sla_targets", priority, kind])
      path = "sla_targets.#{priority}.#{kind}"
      if is_map(target) do
        missing = for key <- ~w(amount unit basis), is_nil(target[key]), do: path <> "." <> key
        if target["basis"] == "business" do
          missing ++ calendar_missing(document, target["calendar"], path)
        else
          missing
        end
      else
        [path]
      end
    end)
  end

  defp calendar_missing(_document, nil, path), do: [path <> ".calendar"]
  defp calendar_missing(document, name, path) do
    if identifier?(name) do
      calendar = nested(document, ["calendars", name])
      if is_map(calendar), do: calendar_missing(name, calendar), else: ["calendars.#{name}"]
    else
      [path <> ".calendar"]
    end
  end

  defp calendar_missing(name, calendar) do
    base = "calendars.#{name}"
    for {path, missing?} <- [{base <> ".timezone", not text?(calendar["timezone"])},
        {base <> ".nonworking_dates", not is_list(calendar["nonworking_dates"])},
        {base <> ".exceptions", not is_list(calendar["exceptions"])}] ++
        Enum.map(@days, &{base <> ".weekly." <> &1, not is_list(nested(calendar, ["weekly", &1]))}),
        missing?, do: path
  end

  defp complete_calendar(name, calendar) do
    missing = calendar_missing(name, calendar)
    if missing == [], do: :ok,
      else: {:error, {:policy_unconfigured, %{missing: missing, operation: :publish}}}
  end

  defp nested(value, []), do: value
  defp nested(value, [key | rest]) when is_map(value), do: nested(value[key], rest)
  defp nested(_, _), do: nil

  @doc "Parses an explicitly declared interval; 24:00 is an end on the following date."
  @spec interval(term(), term()) :: {:ok, Time.t(), Time.t(), 0 | 1} | {:error, term()}
  def interval(from, until) do
    with {:ok, from} <- time(from) do
      if until in ["24:00", "24:00:00"] do
        {:ok, from, ~T[00:00:00], 1}
      else
        with {:ok, until} <- time(until), do: {:ok, from, until, 0}
      end
    end
  end

  @doc false
  def time(value) when is_binary(value) do
    value = if byte_size(value) == 5, do: value <> ":00", else: value
    Time.from_iso8601(value)
  end
  def time(_), do: {:error, :invalid_format}
  defp date?(value) when is_binary(value), do: match?({:ok, _}, Date.from_iso8601(value))
  defp date?(_), do: false
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/, value)
  defp check(errors, true, _path, _code), do: errors
  defp check(errors, false, path, code), do: Map.put(errors, path, code)
  defp unknown(map, allowed, prefix), do: Map.new(Map.keys(map) -- allowed, fn key -> {if(prefix == "", do: key, else: prefix <> "." <> key), :unknown_field} end)

  defp string_keys(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      if is_binary(key) or is_atom(key) do
        key = to_string(key)
        with false <- Map.has_key?(result, key), {:ok, value} <- string_keys(value) do
          {:cont, {:ok, Map.put(result, key, value)}}
        else
          _ -> {:halt, {:error, {:policy_invalid, %{"document" => :duplicate_field}}}}
        end
      else
        {:halt, {:error, {:policy_invalid, %{"document" => :invalid_key}}}}
      end
    end)
  end
  defp string_keys(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, values} ->
      case string_keys(value) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end
  defp string_keys(value), do: {:ok, value}
end
