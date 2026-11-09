defmodule Veritas.Web.WorkflowLive.Components do
  use Veritas.Web, :html

  @incident_copy %{
    "impact" =>
      {"Impact", "Who or what is affected, from one person to a business-critical service."},
    "urgency" => {"Urgency", "How quickly someone needs to begin work on the issue."},
    "severity" =>
      {"Severity", "How serious the disruption is for the people or services affected."},
    "incident_class" =>
      {"Incident classification",
       "A major incident needs a coordinated response; a minor incident follows the normal response process."},
    "priority" =>
      {"Priority",
       "P1 is highest and P4 is lowest. Your role and the incident policy control whether you can set this."},
    "priority_justification" =>
      {"Reason for priority", "Explain the business impact behind the requested priority."},
    "priority_override" =>
      {"Temporary priority override",
       "Record why a different priority is needed and when the exception expires."},
    "assignee" =>
      {"Assigned to",
       "Identifier of the person responsible for the incident. Leave blank if nobody is assigned yet."},
    "affected_ci_ids" =>
      {"Affected systems",
       "Configuration item identifiers from the CMDB, one per line. These link the incident to affected services or devices."},
    "problem_id" =>
      {"Related problem",
       "Identifier of an existing problem record investigating the underlying cause."},
    "track_plan" =>
      {"Response plan", "Describe the plan to restore service and investigate the cause."},
    "restore_track" =>
      {"Service restoration progress",
       "Track the work to get the affected service running again."},
    "root_cause_track" =>
      {"Root cause investigation progress",
       "Track the investigation into why the incident happened."},
    "restoration_evidence" =>
      {"Restoration record",
       "Record checks or a reference showing that service has been restored. Usually completed later."},
    "workaround" =>
      {"Temporary workaround",
       "Describe temporary recovery steps, who maintains them, and when they take effect and expire or need review."},
    "notification_evidence" =>
      {"Requester notification record",
       "Record a message already sent to the requester, with its channel, direction and recipient. This form does not send it."},
    "response_evidence" =>
      {"Response record",
       "Record a response already sent to the requester, with its channel, direction and recipient. This form does not send it."},
    "confirmation_evidence" =>
      {"Requester confirmation record",
       "Record the requester's reply confirming the outcome. Include the channel, direction and recipient. This form does not request confirmation."},
    "hold_reason" =>
      {"Reason work is on hold",
       "Explain why work cannot continue. Complete this when putting the incident on hold."},
    "hold_owner_id" =>
      {"Person responsible for the hold",
       "Identifier of the person responsible for unblocking work."},
    "expected_resume_at" =>
      {"Expected restart time",
       "When work is expected to resume. Include a time-zone offset, for example 2026-11-08T18:00:00-06:00."},
    "resume_evidence" =>
      {"Work resumption record",
       "Record why work can resume or reference the update that unblocked it."},
    "resolution_code" =>
      {"Resolution outcome",
       "How the incident was resolved. Usually completed once service has recovered."},
    "cancellation_reason" =>
      {"Reason for cancellation",
       "Explain why the incident should be cancelled. Usually completed later."}
  }

  attr :field, :map, required: true
  attr :value, :any, default: nil
  attr :prefix, :string, default: "answers"

  def answer_field(assigns) do
    assigns = assign(assigns, :input_name, "#{assigns.prefix}[#{assigns.field["key"]}]")

    ~H"""
    <fieldset class="block text-sm">
      <legend class="mb-1.5 block font-medium">
        {@field["label"]}<span
          :if={@field["required"]}
          class="ml-1 text-error"
        >*</span>
      </legend>
      <.domain_input
        :if={
          @field["type"] != "select" and
            not is_nil(Veritas.Core.Tickets.Incident.binding_type(@field["binding"]))
        }
        field={@field["binding"]}
        name={@input_name}
        value={@value}
      />
      <textarea
        :if={
          @field["type"] == "textarea" and
            is_nil(Veritas.Core.Tickets.Incident.binding_type(@field["binding"]))
        }
        name={@input_name}
        required={@field["required"]}
        rows="4"
        class="textarea textarea-bordered w-full"
      >{@value}</textarea>
      <select
        :if={@field["type"] == "select"}
        name={@input_name}
        required={@field["required"]}
        class="select select-bordered w-full"
      >
        <option value="">Choose…</option><option
          :for={option <- @field["options"] || []}
          value={option}
          selected={option == @value}
        >
          {option}
        </option>
      </select>
      <input
        :if={
          @field["type"] == "checkbox" and
            is_nil(Veritas.Core.Tickets.Incident.binding_type(@field["binding"]))
        }
        type="checkbox"
        name={@input_name}
        value="true"
        checked={@value in [true, "true"]}
        required={@field["required"]}
        class="checkbox checkbox-sm"
      />
      <input
        :if={
          @field["type"] in ["text", "number"] and
            is_nil(Veritas.Core.Tickets.Incident.binding_type(@field["binding"]))
        }
        type={@field["type"]}
        step={if @field["type"] == "number", do: "any", else: nil}
        name={@input_name}
        value={@value}
        required={@field["required"]}
        class="input input-bordered w-full"
      />
    </fieldset>
    """
  end

  @doc "Transport-only conversion of explicitly included form fields; the domain validates them."
  @spec incident_fields(map()) :: map()
  def incident_fields(params) do
    values = params["domain_fields"] || %{}

    for {field, included} <- params["include_domain"] || %{}, included == "true", into: %{} do
      {field, form_value(field, values[field])}
    end
  end

  @doc "Creation includes populated controls; empty optional controls do not assert a fact."
  @spec incident_creation_fields(map()) :: map()
  def incident_creation_fields(params) do
    for {field, raw} <- params["domain_fields"] || %{},
        value = form_value(field, raw),
        not blank_creation_value?(value),
        into: %{} do
      {field, value}
    end
  end

  defp blank_creation_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_creation_value?(value), do: value in [nil, %{}, []]

  @doc "Diffs a populated record form without reasserting unchanged facts or empty optional fields."
  def incident_record_fields(params, saved) do
    values = Map.merge(Map.take(params, ~w(title description)), params["domain_fields"] || %{})

    Enum.reduce(values, %{}, fn {field, raw}, changes ->
      value = form_value(field, raw)
      previous = editable_record_value(saved[field]) |> then(&form_value(field, &1))

      if value == previous or (blank_creation_value?(value) and blank_creation_value?(previous)),
        do: changes,
        else: Map.put(changes, field, value)
    end)
  end

  defp editable_record_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp editable_record_value(value) when is_map(value) do
    value
    |> Map.drop(~w(purpose recorded_by recorded_at))
    |> Map.new(fn
      {"steps", steps} when is_list(steps) -> {"steps", Enum.join(steps, "\n")}
      {key, %DateTime{} = datetime} -> {key, DateTime.to_iso8601(datetime)}
      pair -> pair
    end)
  end

  defp editable_record_value(value), do: value

  @doc "Converts typed bound controls without inferring bindings from answer names."
  @spec prepare_answers(map(), map()) :: map()
  def prepare_answers(step, values) do
    Enum.reduce(step["fields"] || [], values, fn field, answers ->
      key = field["key"]

      if field["binding"] && Map.has_key?(answers, key) do
        value = form_value(field["binding"], answers[key])

        cond do
          field["binding"] == "affected_ci_ids" and value == [] -> Map.put(answers, key, value)
          value in [nil, "", %{}, []] -> Map.delete(answers, key)
          true -> Map.put(answers, key, value)
        end
      else
        answers
      end
    end)
  end

  defp form_value("affected_ci_ids", value) when is_binary(value),
    do: value |> String.split([",", "\n"], trim: true) |> Enum.map(&String.trim/1)

  defp form_value(_field, value) when is_map(value),
    do: Map.reject(value, fn {_key, value} -> value in [nil, ""] end)

  defp form_value(_field, value), do: value

  attr :field, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil

  def domain_input(assigns) do
    assigns = assign(assigns, :value, editable_record_value(assigns.value))
    vocabulary = Veritas.Core.Tickets.Incident.vocabulary()

    choices =
      case assigns.field do
        "priority" ->
          ~w(P1 P2 P3 P4)

        field when field in ~w(restore_track root_cause_track) ->
          vocabulary.track

        field ->
          Enum.find_value(vocabulary, [], fn {key, values} ->
            if Atom.to_string(key) == field, do: values
          end)
      end

    object =
      case assigns.field do
        "priority_override" ->
          ~w(reason expires_at)

        "workaround" ->
          ~w(steps owner_id effective_at expires_at review_at reference)

        field
        when field in ~w(notification_evidence confirmation_evidence response_evidence requester_notification requester_confirmation) ->
          ~w(reference text channel direction recipient)

        field when field in ~w(track_plan restoration_evidence resume_evidence) ->
          ~w(reference text steps)

        _ ->
          []
      end

    value =
      if is_map(assigns.value),
        do: Map.drop(assigns.value, ~w(purpose recorded_by recorded_at)),
        else: %{}

    assigns = assign(assigns, choices: choices, object: object, object_value: value)

    ~H"""
    <div class="space-y-2">
      <label :for={key <- @object} class="block text-xs">
        {human_label(key)}
        <select
          :if={key == "direction"}
          name={@name <> "[#{key}]"}
          class="select select-bordered w-full"
        >
          <option value="">Choose…</option><option
            :for={v <- ~w(inbound outbound)}
            value={v}
            selected={@object_value[key] == v}
          >
            {human_label(v)}
          </option>
        </select>
        <textarea
          :if={key in ~w(text steps reason)}
          name={@name <> "[#{key}]"}
          class="textarea textarea-bordered w-full"
        >{@object_value[key]}</textarea>
        <input
          :if={key not in ~w(direction text steps reason)}
          name={@name <> "[#{key}]"}
          value={@object_value[key]}
          type="text"
          class="input input-bordered w-full"
          placeholder={if String.ends_with?(key, "_at"), do: "2026-11-08T18:00:00-06:00", else: nil}
        />
        <span :if={String.ends_with?(key, "_at")} class="mt-1 block text-base-content/60">Date and time, including a time-zone offset.</span>
      </label>
      <select
        :if={@object == [] and @choices != []}
        name={@name}
        aria-label={human_label(@field)}
        class="select select-bordered w-full"
      >
        <option value="">Choose…</option><option :for={v <- @choices} value={v} selected={@value == v}>
          {human_label(v)}
        </option>
      </select>
      <textarea
        :if={@field == "affected_ci_ids"}
        name={@name}
        class="textarea textarea-bordered w-full"
        aria-label={human_label(@field)}
        placeholder="One configuration item identifier per line"
      >{if is_list(@value), do: Enum.join(@value, "\n"), else: @value}</textarea>
      <textarea
        :if={@field in ~w(description priority_justification cancellation_reason)}
        name={@name}
        aria-label={human_label(@field)}
        class="textarea textarea-bordered w-full"
      >{@value}</textarea>
      <input
        :if={
          @object == [] and @choices == [] and
            @field not in ~w(affected_ci_ids description priority_justification cancellation_reason)
        }
        name={@name}
        value={@value}
        type="text"
        aria-label={human_label(@field)}
        class="input input-bordered w-full"
        placeholder={if @field == "expected_resume_at", do: "2026-11-08T18:00:00-06:00", else: nil}
      />
    </div>
    """
  end

  @incident_control_sections [
    {"priority", "Impact and priority",
     ~w(impact urgency severity incident_class priority priority_justification priority_override)},
    {"ownership", "Ownership and affected systems", ~w(assignee affected_ci_ids problem_id)},
    {"response", "Response and recovery",
     ~w(track_plan restore_track root_cause_track restoration_evidence workaround)},
    {"communications", "Communication records",
     ~w(notification_evidence response_evidence confirmation_evidence)},
    {"hold", "Work on hold", ~w(hold_reason hold_owner_id expected_resume_at resume_evidence)},
    {"resolution", "Resolution and cancellation", ~w(resolution_code cancellation_reason)}
  ]

  def incident_control_sections, do: @incident_control_sections

  @doc "Returns the shared Incident form sections in navigation order."
  @spec incident_form_sections() :: [{String.t(), String.t(), [String.t()]}]
  def incident_form_sections do
    [
      {"overview", "Overview", ~w(ticket_type requester title description)}
      | incident_control_sections()
    ]
  end

  attr :errors, :map, default: %{}
  attr :values, :map, default: %{}
  attr :mode, :atom, default: :patch, values: [:create, :patch, :record]
  attr :only, :list, default: nil

  def incident_controls(assigns) do
    sections =
      for {_key, heading, fields} <- @incident_control_sections,
          selected = Enum.filter(fields, &(is_nil(assigns.only) or &1 in assigns.only)),
          selected != [],
          do: {heading, selected}

    assigns = assign(assigns, :sections, sections)

    ~H"""
    <div class="space-y-7">
      <p :if={@mode == :patch} class="text-sm text-base-content/65">
        Select the fields you want to change. Other fields stay as they are.
        Applying an empty affected-systems list clears the existing links.
      </p>
      <section :for={{heading, fields} <- @sections} class="space-y-4 border-t border-base-300 pt-5">
        <h3 class="text-base font-semibold">{heading}</h3>
        <div class="grid items-start gap-5 md:grid-cols-2">
          <fieldset :for={field <- fields} class="min-w-0 space-y-2">
            <legend class="mb-1 text-sm font-medium">{human_label(field)}</legend>
            <p class="text-xs leading-5 text-base-content/65">{incident_help(field)}</p>
            <label :if={@mode == :patch} class="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name={"include_domain[#{field}]"}
                value="true"
                class="checkbox checkbox-sm"
              /> Change this field
            </label>
            <.domain_input field={field} name={"domain_fields[#{field}]"} value={@values[field]} />
            <p :if={@errors[field]} class="mt-1 text-xs text-error" role="alert">{@errors[field]}</p>
          </fieldset>
        </div>
      </section>
    </div>
    """
  end

  attr :view, :map, required: true

  def incident_activity(assigns) do
    assigns =
      assign(
        assigns,
        :updates,
        (assigns.view.provenance["fields"] || %{})
        |> Enum.sort_by(fn {_, mark} -> mark["recorded_at"] || "" end, :desc)
      )

    ~H"""
    <div>
      <h3 class="mb-4 text-sm font-semibold">Latest field updates</h3>
      <p :if={@updates == []} class="text-sm text-base-content/60">
        No field updates have been recorded yet.
      </p>
      <ol class="divide-y divide-base-300">
        <li
          :for={{field, mark} <- @updates}
          class="flex flex-wrap items-center justify-between gap-2 py-3 text-sm"
        >
          <span class="font-medium">{human_label(field)}</span>
          <span class="text-xs text-base-content/60">{record_time(mark["recorded_at"])} · {get_in(
            mark,
            ["actor", "id"]
          )}</span>
        </li>
      </ol>
    </div>
    """
  end

  def record_time(%DateTime{} = value), do: Calendar.strftime(value, "%b %d, %Y · %H:%M UTC")

  def record_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> record_time(datetime)
      _ -> value
    end
  end

  def record_time(_), do: "Not recorded"

  attr :view, :map, required: true

  def incident_readback(assigns) do
    ~H"""
    <section class="v-panel space-y-4 rounded-xl p-5">
      <h2 class="font-semibold">Authoritative Incident readback</h2>
      <p class="text-xs">
        Domain revision: {revision_label(@view.domain_revision)} · Workflow revision: {revision_label(
          @view.workflow_revision
        )} · Active policy: {@view.policy.active_version || "unconfigured"}
      </p>
      <dl class="grid gap-3 md:grid-cols-2">
        <div :for={{key, value} <- Enum.sort(@view.domain)}>
          <dt class="text-xs text-base-content/60">{human_label(key)}</dt><dd class="whitespace-pre-wrap text-sm">
            {display_value(value)}
          </dd>
        </div>
      </dl>
      <h3 class="text-sm font-semibold">Readiness · missing requirements</h3>
      <ul class="text-sm">
        <li :for={path <- @view.readiness.missing}>{path}</li>
      </ul>
      <dl class="text-xs">
        <div :for={{operation, missing} <- @view.readiness.operations}>
          <dt class="mt-2 font-semibold">{operation}</dt><dd>{display_value(missing)}</dd>
        </div>
      </dl>
      <details>
        <summary class="cursor-pointer text-sm">Recorded clocks and provenance</summary>
        <pre class="overflow-auto whitespace-pre-wrap text-xs">{display_value(%{clocks: @view.clocks, provenance: @view.provenance, raw_legacy: @view.raw_legacy})}</pre>
      </details>
      <p class="text-xs text-base-content/60">
        Legacy values are shown separately, never automatically mapped. Unknown clock history is not zero elapsed time.
      </p>
    </section>
    """
  end

  defp revision_label(nil), do: "absent (explicit nil precondition)"
  defp revision_label(value), do: to_string(value)
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value), do: Jason.encode!(value, pretty: true)
  defp incident_help(field), do: @incident_copy |> Map.fetch!(field) |> elem(1)

  defp human_label(value) do
    key = to_string(value)

    case Map.get(@incident_copy, key) do
      {label, _help} ->
        label

      nil ->
        Map.get(
          %{
            "reference" => "Reference or link",
            "text" => "Notes",
            "owner_id" => "Responsible person",
            "effective_at" => "Effective from",
            "expires_at" => "Expires at",
            "review_at" => "Review at",
            "channel" => "Communication channel",
            "direction" => "Message direction",
            "inbound" => "Received",
            "outbound" => "Sent",
            "organization" => "Organization-wide",
            "business_critical" => "Business-critical service"
          },
          key,
          key |> String.replace("_", " ") |> String.capitalize()
        )
    end
  end

  attr :error, :map, default: nil

  def public_error(assigns) do
    ~H"""
    <div :if={@error} role="alert" class="alert alert-error my-3 block">
      <p>{@error.message} <span class="font-mono text-xs">({@error.code})</span></p>
      <ul class="mt-2 text-xs">
        <li :for={{path, code} <- Map.get(@error, :fields, %{})}>{path}: {code}</li>
        <li :for={path <- Map.get(@error, :missing, [])}>{path}: missing</li>
      </ul>
      <p :if={Map.has_key?(@error, :current_revision)} class="text-xs">
        Current revision: {revision_label(@error.current_revision)}. Reload explicitly; your submitted form has not been saved.
      </p>
    </div>
    """
  end

  @doc "Builds an editable policy form from authorized saved values, without selecting missing values."
  @spec policy_form(map()) :: map()
  def policy_form(document) do
    cells =
      Enum.reduce(document["priority_rules"] || [], %{}, fn cell, cells ->
        Map.update(
          cells,
          cell["impact"],
          %{cell["urgency"] => cell["priority"]},
          &Map.put(&1, cell["urgency"], cell["priority"])
        )
      end)

    calendars =
      for {key, calendar} <- document["calendars"] || %{} do
        calendar
        |> Map.put("key", key)
        |> Map.put(
          "weekly",
          Map.new(calendar["weekly"] || %{}, fn {day, intervals} ->
            {day, %{"configured" => "true", "intervals" => interval_form(intervals)}}
          end)
        )
        |> Map.put(
          "dates_configured",
          if(Map.has_key?(calendar, "nonworking_dates"), do: "true", else: "false")
        )
        |> Map.put(
          "nonworking_dates",
          indexed(Enum.map(calendar["nonworking_dates"] || [], &%{"date" => &1}))
        )
        |> Map.put(
          "exceptions_configured",
          if(Map.has_key?(calendar, "exceptions"), do: "true", else: "false")
        )
        |> Map.put(
          "exceptions",
          indexed(
            Enum.map(calendar["exceptions"] || [], fn row ->
              Map.put(row, "intervals", interval_form(row["intervals"]))
            end)
          )
        )
      end

    %{
      "priority_rules" => cells,
      "sla_targets" => document["sla_targets"] || %{},
      "calendars" => indexed(calendars),
      "reopen_resolution" => document["reopen_resolution"] || ""
    }
  end

  @doc "Serializes human controls only; policy validation remains in Tickets."
  @spec policy_document(map()) :: {:ok, map()} | {:error, :invalid_request}
  def policy_document(form) do
    rows = Enum.reject(form_rows(form["calendars"]), &(&1["remove"] == "true"))
    names = Enum.map(rows, & &1["key"]) |> Enum.reject(&(&1 in [nil, ""]))

    if length(names) == length(Enum.uniq(names)),
      do: {:ok, encode_policy(form)},
      else: {:error, :invalid_request}
  rescue
    _error in [ArgumentError, BadMapError, FunctionClauseError, Protocol.UndefinedError, KeyError] ->
      {:error, :invalid_request}
  end

  defp encode_policy(form) do
    cells =
      for {impact, urgencies} <- form["priority_rules"] || %{},
          {urgency, priority} <- urgencies,
          priority not in [nil, ""],
          do: %{"impact" => impact, "urgency" => urgency, "priority" => priority}

    targets =
      Map.new(
        for {priority, kinds} <- form["sla_targets"] || %{} do
          {priority,
           Map.new(
             for {kind, target} <- kinds,
                 clean = Map.reject(target, fn {_key, value} -> value in [nil, ""] end),
                 map_size(clean) > 0 do
               {kind,
                Map.update(clean, "amount", nil, &form_integer/1)
                |> Map.reject(fn {_k, v} -> is_nil(v) end)}
             end
           )}
        end
      )
      |> Map.reject(fn {_key, value} -> value == %{} end)

    calendars =
      Map.new(
        for row <- form_rows(form["calendars"]),
            row["remove"] != "true",
            Enum.any?(Map.take(row, ~w(key timezone)), fn {_key, value} ->
              value not in [nil, ""]
            end) do
          weekly =
            Map.new(
              for {day, value} <- row["weekly"] || %{},
                  value["configured"] == "true",
                  do: {day, interval_document(value["intervals"])}
            )

          calendar = %{} |> put_present("timezone", row["timezone"])

          calendar =
            if map_size(weekly) > 0, do: Map.put(calendar, "weekly", weekly), else: calendar

          calendar =
            if row["dates_configured"] == "true" do
              dates =
                for date <- form_rows(row["nonworking_dates"]),
                    date["remove"] != "true",
                    date["date"] not in [nil, ""] do
                  date["date"]
                end

              Map.put(calendar, "nonworking_dates", dates)
            else
              calendar
            end

          calendar =
            if row["exceptions_configured"] == "true" do
              exceptions =
                for exception <- form_rows(row["exceptions"]),
                    exception["remove"] != "true",
                    exception["date"] not in [nil, ""] do
                  %{
                    "date" => exception["date"],
                    "intervals" => interval_document(exception["intervals"])
                  }
                end

              Map.put(calendar, "exceptions", exceptions)
            else
              calendar
            end

          {row["key"] || "", calendar}
        end
      )

    %{}
    |> put_section("priority_rules", cells)
    |> put_section("sla_targets", targets)
    |> put_section("calendars", calendars)
    |> put_present("reopen_resolution", form["reopen_resolution"])
  end

  @doc "Adds an empty, unselected form row without creating a policy value."
  @spec add_policy_row(map(), [String.t()], map()) :: map()
  def add_policy_row(form, [key], row),
    do:
      Map.update(form, key, %{"0" => row}, fn rows ->
        rows = rows || %{}

        key =
          Stream.iterate(map_size(rows), &(&1 + 1))
          |> Enum.find(&(not Map.has_key?(rows, to_string(&1))))

        Map.put(rows, to_string(key), row)
      end)

  def add_policy_row(form, [key | rest], row),
    do:
      Map.update(form, key, add_policy_row(%{}, rest, row), &add_policy_row(&1 || %{}, rest, row))

  defp indexed(values),
    do: values |> Enum.with_index() |> Map.new(fn {v, i} -> {to_string(i), v} end)

  defp interval_form(values),
    do: indexed(Enum.map(values || [], fn [a, b] -> %{"start" => a, "end" => b} end))

  defp form_rows(nil), do: []

  defp form_rows(rows),
    do: rows |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end) |> Enum.map(&elem(&1, 1))

  defp interval_document(rows) do
    for row <- form_rows(rows),
        row["remove"] != "true",
        row["start"] not in [nil, ""] or row["end"] not in [nil, ""] do
      [row["start"] || "", row["end"] || ""]
    end
  end

  defp form_integer(value) when is_integer(value), do: value

  defp form_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
  defp put_section(map, _key, value) when value == %{} or value == [], do: map
  defp put_section(map, key, value), do: Map.put(map, key, value)

  attr :form, :map, required: true
  attr :envelope, :map, required: true
  attr :can_edit, :boolean, required: true
  attr :validation, :map, default: nil

  def policy_editor(assigns) do
    assigns =
      assign(assigns,
        vocabulary: Veritas.Core.Tickets.Incident.vocabulary(),
        days: ~w(mon tue wed thu fri sat sun)
      )

    ~H"""
    <section id="incident-policy" class="v-panel mt-8 space-y-5 rounded-xl p-6">
      <h2 class="text-xl font-semibold">Incident policy</h2>
      <p class="text-xs">
        Configuration revision: {revision_label(@envelope.policy_revision)} · Active immutable version: {@envelope.active_version ||
          "none"}. Saving a draft does not activate it. Publication consumes the approved draft; its configuration revision remains.
      </p>
      <details>
        <summary class="cursor-pointer">Active policy and readiness</summary><pre class="overflow-auto whitespace-pre-wrap text-xs">{display_value(%{active: @envelope.active, readiness: @envelope.readiness})}</pre>
      </details>
      <div :if={@validation} class="text-sm" role="status">
        <p>Validation errors (missing configuration is listed separately):</p>
        <ul>
          <li :for={{path, code} <- @validation.errors}>{path}: {code}</li>
        </ul>
        <p class="mt-2">Missing: {Enum.join(@validation.readiness.missing, ", ")}</p>
      </div>
      <form
        :if={@can_edit}
        id="incident-policy-form"
        phx-change="policy-change"
        phx-submit="policy-action"
        class="space-y-6"
      >
        <h3 class="font-semibold">Priority matrix · all 20 cells must be chosen before derivation</h3>
        <div class="overflow-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Impact / urgency</th><th :for={u <- @vocabulary.urgency}>{u}</th>
              </tr>
            </thead><tbody>
              <tr :for={impact <- @vocabulary.impact}>
                <th>{impact}</th><td :for={urgency <- @vocabulary.urgency}>
                  <select
                    name={"policy[priority_rules][#{impact}][#{urgency}]"}
                    aria-label={impact <> " / " <> urgency}
                    class="select select-bordered select-sm"
                  >
                    <option value="">Unconfigured</option><option
                      :for={p <- ~w(P1 P2 P3 P4)}
                      value={p}
                      selected={get_in(@form, ["priority_rules", impact, urgency]) == p}
                    >
                      {p}
                    </option>
                  </select>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <h3 class="font-semibold">Response and resolution targets</h3>
        <div :for={priority <- ~w(P1 P2 P3 P4)} class="space-y-3">
          <h4>{priority}</h4>
          <fieldset
            :for={kind <- ~w(response resolution)}
            class="grid gap-2 rounded border border-base-300 p-3 md:grid-cols-5"
          >
            <legend>{kind}</legend>
            <label class="text-xs">Amount<input
              type="number"
              min="1"
              step="1"
              name={"policy[sla_targets][#{priority}][#{kind}][amount]"}
              value={get_in(@form, ["sla_targets", priority, kind, "amount"])}
              class="input input-bordered w-full"
            /></label>
            <label
              :for={
                {key, options} <- [
                  {"unit", ~w(seconds minutes hours days)},
                  {"basis", ~w(elapsed business)}
                ]
              }
              class="text-xs"
            >
              {key}
              <select
                name={"policy[sla_targets][#{priority}][#{kind}][#{key}]"}
                class="select select-bordered w-full"
              >
                <option value="">Unconfigured</option>
                <option
                  :for={v <- options}
                  value={v}
                  selected={get_in(@form, ["sla_targets", priority, kind, key]) == v}
                >
                  {v}
                </option>
              </select>
            </label>
            <label class="text-xs">Calendar key<input
              name={"policy[sla_targets][#{priority}][#{kind}][calendar]"}
              value={get_in(@form, ["sla_targets", priority, kind, "calendar"])}
              class="input input-bordered w-full"
            /></label>
          </fieldset>
        </div>
        <label class="block text-sm">Reopened resolution accounting<select
          name="policy[reopen_resolution]"
          class="select select-bordered ml-2"
        ><option value="">Unconfigured</option><option
          :for={v <- ~w(cumulative new_cycle)}
          value={v}
          selected={@form["reopen_resolution"] == v}
        >
          {human_label(v)}
        </option></select></label>
        <h3 class="font-semibold">Versioned calendars</h3>
        <p class="text-xs">
          No timezone or working day is assumed. Check each day to explicitly configure its intervals (none means a nonworking day). End 24:00 is allowed. Publication checks provider availability; this form cannot install one.
        </p>
        <fieldset
          :for={{index, calendar} <- Enum.sort(@form["calendars"] || %{})}
          class="space-y-3 rounded-xl border border-base-300 p-4"
        >
          <label>Calendar key<input
            name={"policy[calendars][#{index}][key]"}
            value={calendar["key"]}
            class="input input-bordered ml-2"
          /></label>
          <label>IANA timezone<input
            name={"policy[calendars][#{index}][timezone]"}
            value={calendar["timezone"]}
            class="input input-bordered ml-2"
          /></label>
          <label class="text-xs"><input
            type="checkbox"
            name={"policy[calendars][#{index}][remove]"}
            value="true"
            checked={calendar["remove"] == "true"}
          /> Remove calendar from draft</label>
          <div :for={day <- @days} class="rounded border border-base-300 p-2">
            <input
              type="hidden"
              name={"policy[calendars][#{index}][weekly][#{day}][configured]"}
              value="false"
            />
            <label class="text-sm"><input
              type="checkbox"
              name={"policy[calendars][#{index}][weekly][#{day}][configured]"}
              value="true"
              checked={get_in(calendar, ["weekly", day, "configured"]) == "true"}
            /> Configure {day}</label>
            <.interval_controls
              rows={get_in(calendar, ["weekly", day, "intervals"]) || %{}}
              name={"policy[calendars][#{index}][weekly][#{day}][intervals]"}
            />
            <button
              type="button"
              phx-click="policy-add"
              phx-value-kind="weekly"
              phx-value-calendar={index}
              phx-value-day={day}
              class="btn btn-ghost btn-xs"
            >Add interval</button>
          </div>
          <input type="hidden" name={"policy[calendars][#{index}][dates_configured]"} value="false" />
          <label class="text-sm"><input
            type="checkbox"
            name={"policy[calendars][#{index}][dates_configured]"}
            value="true"
            checked={calendar["dates_configured"] == "true"}
          /> Explicit nonworking dates (may be empty)</label>
          <div :for={{row, date} <- Enum.sort(calendar["nonworking_dates"] || %{})} class="flex gap-2">
            <input
              type="date"
              name={"policy[calendars][#{index}][nonworking_dates][#{row}][date]"}
              value={date["date"]}
              aria-label="Nonworking date"
              class="input input-bordered"
            />
            <label><input
              type="checkbox"
              name={"policy[calendars][#{index}][nonworking_dates][#{row}][remove]"}
              value="true"
              checked={date["remove"] == "true"}
            />Remove</label>
          </div>
          <button
            type="button"
            phx-click="policy-add"
            phx-value-kind="date"
            phx-value-calendar={index}
            class="btn btn-ghost btn-xs"
          >Add nonworking date</button>
          <input
            type="hidden"
            name={"policy[calendars][#{index}][exceptions_configured]"}
            value="false"
          />
          <label class="text-sm"><input
            type="checkbox"
            name={"policy[calendars][#{index}][exceptions_configured]"}
            value="true"
            checked={calendar["exceptions_configured"] == "true"}
          /> Explicit date exceptions (may be empty)</label>
          <div
            :for={{row, exception} <- Enum.sort(calendar["exceptions"] || %{})}
            class="rounded border border-base-300 p-2"
          >
            <input
              type="date"
              name={"policy[calendars][#{index}][exceptions][#{row}][date]"}
              value={exception["date"]}
              aria-label="Exception date"
              class="input input-bordered"
            />
            <label><input
              type="checkbox"
              name={"policy[calendars][#{index}][exceptions][#{row}][remove]"}
              value="true"
              checked={exception["remove"] == "true"}
            />Remove</label>
            <.interval_controls
              rows={exception["intervals"] || %{}}
              name={"policy[calendars][#{index}][exceptions][#{row}][intervals]"}
            />
            <button
              type="button"
              phx-click="policy-add"
              phx-value-kind="exception-interval"
              phx-value-calendar={index}
              phx-value-row={row}
              class="btn btn-ghost btn-xs"
            >Add exception interval</button>
          </div>
          <button
            type="button"
            phx-click="policy-add"
            phx-value-kind="exception"
            phx-value-calendar={index}
            class="btn btn-ghost btn-xs"
          >Add date exception</button>
        </fieldset>
        <button
          type="button"
          phx-click="policy-add"
          phx-value-kind="calendar"
          class="btn btn-outline btn-sm"
        >Add calendar</button>
        <div class="flex flex-wrap gap-3">
          <button name="action" value="validate" class="btn btn-outline">Validate draft</button><button
            name="action"
            value="save"
            class="btn btn-primary"
          >Save draft only</button>
        </div>
      </form>
      <form
        :if={@can_edit and @envelope.draft}
        id="incident-policy-publish"
        phx-submit="policy-publish"
        class="space-y-3 border-t border-base-300 pt-4"
      >
        <p class="text-sm">
          Publish saved draft revision {@envelope.policy_revision}, not unsaved editor changes.
        </p>
        <label class="flex items-center gap-2"><input
          type="checkbox"
          name="approve"
          value="true"
          required
          class="checkbox checkbox-sm"
        />I reviewed and approve this exact saved draft for publication.</label>
        <button type="submit" class="btn btn-primary">Publish approved saved draft</button>
      </form>
      <button
        type="button"
        phx-click="policy-reload"
        data-confirm="Reload policy and discard unsaved policy edits?"
        class="btn btn-ghost btn-sm"
      >Reload policy</button>
    </section>
    """
  end

  attr :rows, :map, required: true
  attr :name, :string, required: true

  def interval_controls(assigns) do
    ~H"""
    <div
      :for={{index, row} <- Enum.sort(@rows)}
      class="my-2 flex flex-wrap items-center gap-2 text-xs"
    >
      <label>Start<input
        name={@name <> "[#{index}][start]"}
        value={row["start"]}
        placeholder="HH:MM"
        pattern="[0-2][0-9]:[0-5][0-9]"
        class="input input-bordered input-sm w-24"
      /></label>
      <label>End<input
        name={@name <> "[#{index}][end]"}
        value={row["end"]}
        placeholder="HH:MM (24:00 allowed)"
        pattern="[0-2][0-9]:[0-5][0-9]"
        class="input input-bordered input-sm w-24"
      /></label>
      <label><input
        type="checkbox"
        name={@name <> "[#{index}][remove]"}
        value="true"
        checked={row["remove"] == "true"}
      />Remove</label>
    </div>
    """
  end

  attr :steps, :list, required: true
  attr :current, :string, default: ""
  attr :completed, :list, default: []

  def progress(assigns) do
    ~H"""
    <ol class="space-y-2" aria-label="Workflow steps">
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class={[
          "rounded-xl border px-4 py-3",
          if(step["id"] == @current, do: "border-primary bg-primary/5", else: "border-base-300")
        ]}
      >
        <div class="flex items-center gap-3">
          <span class={[
            "flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
            if(step["id"] in @completed, do: "bg-success/15 text-success", else: "bg-base-200")
          ]}>{if step["id"] in @completed, do: "✓", else: index + 1}</span><div>
            <p class="text-sm font-semibold">{step["name"]}</p><p class="text-[11px] uppercase tracking-wide text-base-content/50">
              {String.replace(step["phase"], "_", " ")} · {step["kind"]}
            </p>
          </div>
        </div>
      </li>
    </ol>
    """
  end
end
