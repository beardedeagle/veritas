defmodule Veritas.Core.Tickets.IncidentClock do
  @moduledoc """
  Pure Incident clock and business-calendar planning.

  The caller supplies transaction time, immutable policy/calendar records and
  existing clock/episode facts. Nothing is stored or scheduled here. A provider
  must implement `Calendar.TimeZoneDatabase`; its rules version is supplied
  independently. UTC-only/fixed-offset substitutions and gap/fold guesses are
  not supported. Persisted counters are facts, not a wall-clock timer.

  Calendar intervals are local [HH:MM, HH:MM] pairs. All seven weekdays must
  be explicit, including empty nonworking days. Date exceptions override the
  weekly/nonworking-date schedule. A business day is the scheduled working
  time of that date, not an invented eight-hour constant. Evaluations exceeding
  36,600 calendar dates refuse rather than loop indefinitely.
  """

  alias Veritas.Core.Tickets.IncidentPolicy

  @days ~w(mon tue wed thu fri sat sun)
  @scan_limit 36_600
  @unit_us %{"seconds" => 1_000_000, "minutes" => 60_000_000,
             "hours" => 3_600_000_000, "days" => 86_400_000_000}

  @doc "Returns the explicitly supplied timezone rules identity; there is no default."
  @spec rules_version(keyword()) :: String.t() | nil
  def rules_version(opts) do
    opts[:timezone_rules_version] || Application.get_env(:veritas_core, :incident_timezone_rules_version)
  end

  @doc "Checks provider support without substituting UTC or choosing a gap/fold side."
  @spec validate_calendar(map(), keyword()) :: :ok | {:error, term()}
  def validate_calendar(calendar, opts) do
    with {:ok, provider} <- provider(opts),
         zone when is_binary(zone) <- calendar["timezone"],
         {:ok, _} <- local(~N[2000-01-15 12:00:00], zone, provider) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :timezone_provider_unavailable}
    end
  end

  @doc "Measures elapsed/business microseconds between two known UTC instants."
  @spec duration(DateTime.t(), DateTime.t(), map(), map() | nil, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def duration(from, until, target, calendar, opts) do
    cond do
      DateTime.compare(until, from) == :lt ->
        {:error, :clock_evidence_required}
      target["basis"] == "elapsed" ->
        {:ok, DateTime.diff(until, from, :microsecond)}
      target["basis"] == "business" and is_map(calendar) ->
        business_duration(from, until, calendar, opts)
      true ->
        {:error, {:policy_unconfigured, %{missing: ["calendar"], operation: :clock}}}
    end
  end

  @doc "Adds an explicit target using its declared basis and calendar."
  @spec deadline(DateTime.t(), map(), map() | nil, keyword()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def deadline(from, target, calendar, opts) do
    amount = target["amount"]
    unit = target["unit"]

    cond do
      not is_integer(amount) or amount <= 0 or not Map.has_key?(@unit_us, unit) ->
        {:error, {:policy_invalid, %{"sla_targets" => :invalid_target}}}
      target["basis"] == "elapsed" ->
        add_instant(from, amount * @unit_us[unit])
      target["basis"] == "business" and is_map(calendar) ->
        if unit == "days",
          do: business_days(from, amount, calendar, opts),
          else: business_add(from, amount * @unit_us[unit], calendar, opts)
      true ->
        {:error, {:policy_unconfigured, %{missing: ["calendar"], operation: :clock}}}
    end
  end

  @doc """
  Plans records, preserving stopped cycles and immutable budget bindings.

  Options carry `:operation` (:create/:amend/:advance/:transition),
  `:to_state`, `:domain_revision`, and maps of immutable `:policies` and
  `:calendars`. Returns `{:ok, %{clocks: rows, holds: rows}}`; only the caller
  writes them. All IDs are deterministic from the supplied ticket/cycle.
  """
  @spec plan(map(), map(), [map()], [map()], map() | nil, DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def plan(ticket, facts, clocks, holds, active, now, opts) do
    original_clocks = Map.new(clocks, &{&1["id"], &1})
    operation = opts[:operation]
    to_state = opts[:to_state] || ticket["state"]
    opts = Keyword.put(opts, :clocks, original_clocks)

    with :ok <- chronology(clocks, holds, now),
         {:ok, clocks} <- response_fact(ticket, clocks, now, opts),
         :ok <- chronology(clocks, holds, now),
         {:ok, clocks} <- response_marker(clocks, facts, now, opts) do
      result =
        cond do
          operation == :create -> configured_response(clocks, holds, facts, active, opts)
          operation == :amend -> {:ok, %{clocks: clocks, holds: holds}}
          ticket["state"] == "new" and to_state == "acknowledged" ->
            acknowledge(ticket, facts, clocks, holds, active, now, opts)
          to_state == "cancelled" ->
            stop_response(clocks, holds, now, opts)
          ticket["state"] == "resolved" and to_state == "in_progress" ->
            reopen(ticket, facts, clocks, holds, active, now, opts)
          to_state == "on_hold" and ticket["state"] != "on_hold" ->
            begin_hold(ticket, facts, clocks, holds, now, opts)
          ticket["state"] == "on_hold" and to_state in ~w(in_progress resolved) ->
            with {:ok, result} <- end_hold(clocks, holds, now, opts) do
              maybe_stop_resolution(result, to_state, now, opts)
            end
          to_state == "resolved" and ticket["state"] != "resolved" ->
            maybe_stop_resolution(%{clocks: clocks, holds: holds}, to_state, now, opts)
          ticket["state"] in ~w(acknowledged in_progress on_hold resolved closed) ->
            case latest(clocks, "resolution") do
              nil -> {:error, :clock_evidence_required}
              _ -> {:ok, %{clocks: clocks, holds: holds}}
            end
          true -> {:ok, %{clocks: clocks, holds: holds}}
        end

      with {:ok, result} <- result do
        rows = Enum.map(result.clocks, fn row ->
          if original_clocks[row["id"]] == row, do: row, else: revision(row, opts)
        end)
        {:ok, %{result | clocks: rows}}
      end
    end
  end

  @doc "Returns an evaluation without modifying the recorded clock or its bindings."
  @spec evaluate(map(), [map()], DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(clock, holds, now, opts) do
    with true <- clock["history_complete"] == true || {:error, :clock_evidence_required},
         {:ok, start} <- instant(clock["started_at"]),
         {:ok, finish} <- instant(clock["stopped_at"] || now),
         {:ok, target, calendar} <- binding(clock, opts),
         {:ok, measured} <- duration(start, finish, target, calendar, opts),
         {:ok, paused} <- pause_total(clock, holds, finish, target, calendar, opts),
         {:ok, carried} <- carried(clock),
         {:ok, origin} <- budget_origin(clock, opts, MapSet.new()),
         {:ok, nominal} <- deadline(origin, target, calendar, opts),
         {:ok, budget} <- duration(origin, nominal, target, calendar, opts),
         {:ok, due} <- add_budget(start, max(0, budget - carried) + paused, target, calendar, opts) do
      elapsed = carried + max(0, measured - paused)
      {:ok, %{elapsed_us: elapsed, qualified_pause_us: paused, budget_us: budget,
        remaining_us: max(0, budget - elapsed), deadline: due, evaluated_at: finish,
        target: target, policy_version: clock["policy_version"],
        calendar_version: clock["calendar_version"], priority: clock["priority"]}}
    end
  end

  defp response_fact(ticket, clocks, now, opts) do
    cond do
      not is_nil(latest(clocks, "response")) -> {:ok, clocks}
      opts[:operation] == :create ->
        {:ok, clocks ++ [new_clock(ticket, "response", 1, now, opts)]}
      ticket["state"] == "new" ->
        case instant(ticket["opened_at"]) do
          {:ok, opened} -> {:ok, clocks ++ [new_clock(ticket, "response", 1, opened, opts)]}
          _ -> if opts[:operation] == :amend, do: {:ok, clocks}, else: {:error, :clock_evidence_required}
        end
      opts[:operation] == :amend -> {:ok, clocks}
      true -> {:error, :clock_evidence_required}
    end
  end

  defp response_marker(clocks, facts, now, opts) do
    marker = facts["response_evidence"]
    clock = latest(clocks, "response")
    if is_map(marker) and clock && is_nil(clock["stopped_at"]) do
      with {:ok, at} <- instant(marker["recorded_at"]),
           {:ok, start} <- instant(clock["started_at"]),
           true <- DateTime.compare(at, start) != :lt and DateTime.compare(at, now) != :gt ||
                     {:error, :clock_evidence_required} do
        {:ok, replace(clocks, revision(Map.put(clock, "stopped_at", at), opts))}
      end
    else
      {:ok, clocks}
    end
  end

  defp configured_response(clocks, holds, facts, active, opts) do
    target = if is_map(active) and is_binary(facts["priority"]),
      do: get_in(active, ["definition", "sla_targets", facts["priority"], "response"])

    if is_map(target) do
      with {:ok, clock} <- bind(latest(clocks, "response"), active, facts["priority"], opts) do
        {:ok, %{clocks: replace(clocks, clock), holds: holds}}
      end
    else
      {:ok, %{clocks: clocks, holds: holds}}
    end
  end

  defp acknowledge(ticket, facts, clocks, holds, active, now, opts) do
    with clock when is_map(clock) <- latest(clocks, "response") || {:error, :clock_evidence_required},
         {:ok, response} <- bind(clock, active, facts["priority"], opts),
         {:ok, resolution} <- bind(new_clock(ticket, "resolution", 1, now, opts), active, facts["priority"], opts) do
      response = Map.put(response, "stopped_at", response["stopped_at"] || now)
      {:ok, %{clocks: replace(clocks, response) ++ [resolution], holds: holds}}
    end
  end

  defp stop_response(clocks, holds, now, opts) do
    case latest(clocks, "response") do
      nil -> {:error, :clock_evidence_required}
      clock -> {:ok, %{clocks: replace(clocks, revision(Map.put(clock, "stopped_at", clock["stopped_at"] || now), opts)), holds: holds}}
    end
  end

  defp begin_hold(_ticket, facts, clocks, holds, now, opts) do
    with clock when is_map(clock) <- latest(clocks, "resolution") || {:error, :clock_evidence_required},
         true <- is_nil(clock["current_hold"]) || {:error, :clock_evidence_required},
         {:ok, target, calendar} <- binding(clock, opts),
         {:ok, cap} <- hold_cap(facts["hold_reason"], calendar, now, opts) do
      number = Enum.count(holds, &(&1["clock"] == clock["id"])) + 1
      episode = %{"id" => id(clock["id"], "hold", number), "workspace" => clock["workspace"],
        "clock" => clock["id"], "episode" => number, "domain_revision" => opts[:domain_revision],
        "reason" => facts["hold_reason"], "started_at" => now, "ended_at" => nil,
        "expected_resume_at" => facts["expected_resume_at"], "pause_cap_at" => cap,
        "qualified_pause_us" => 0, "evidence" => nil}
      # Confirm a business target's provider before persisting a hold.
      with {:ok, _} <- duration(now, now, target, calendar, opts) do
        updated = Map.put(clock, "current_hold", episode["id"])
        {:ok, %{clocks: replace(clocks, updated), holds: holds ++ [episode]}}
      end
    end
  end

  defp hold_cap(reason, calendar, now, opts) when reason in ~w(customer_wait third_party_wait) do
    if is_map(calendar), do: business_days(now, 5, calendar, opts),
      else: {:error, {:policy_unconfigured, %{missing: ["sla_targets.resolution.calendar"], operation: :hold}}}
  end
  defp hold_cap(_, _, _, _), do: {:ok, nil}

  defp end_hold(clocks, holds, now, opts) do
    with clock when is_map(clock) <- latest(clocks, "resolution") || {:error, :clock_evidence_required},
         episode when is_map(episode) <- Enum.find(holds, &(&1["id"] == clock["current_hold"])) || {:error, :clock_evidence_required},
         true <- is_nil(episode["ended_at"]) || {:error, :clock_evidence_required},
         {:ok, target, calendar} <- binding(clock, opts),
         true <- is_integer(clock["qualified_pause_us"]) and clock["qualified_pause_us"] >= 0 ||
                   {:error, :clock_evidence_required},
         {:ok, paused} <- episode_pause(episode, now, target, calendar, opts) do
      episode = Map.merge(episode, %{"ended_at" => now, "qualified_pause_us" => paused,
        "domain_revision" => opts[:domain_revision], "evidence" => opts[:resume_evidence]})
      clock = Map.merge(clock, %{"current_hold" => nil,
        "qualified_pause_us" => clock["qualified_pause_us"] + paused})
      {:ok, %{clocks: replace(clocks, clock), holds: replace(holds, episode)}}
    end
  end

  defp maybe_stop_resolution(result, "resolved", now, opts) do
    case latest(result.clocks, "resolution") do
      nil -> {:error, :clock_evidence_required}
      clock -> {:ok, %{result | clocks: replace(result.clocks, revision(Map.put(clock, "stopped_at", now), opts))}}
    end
  end
  defp maybe_stop_resolution(result, _, _, _), do: {:ok, result}

  defp reopen(ticket, facts, clocks, holds, active, now, opts) do
    mode = active && active["definition"]["reopen_resolution"]
    with true <- mode in ~w(cumulative new_cycle) ||
                   {:error, {:policy_unconfigured, %{missing: ["reopen_resolution"], operation: :reopen}}},
         previous when is_map(previous) <- latest(clocks, "resolution") || {:error, :clock_evidence_required},
         {:ok, _} <- instant(previous["stopped_at"]) do
      next = new_clock(ticket, "resolution", previous["cycle"] + 1, now, opts)
      next = Map.merge(next, %{"previous_cycle" => previous["id"], "reopen_mode" => mode})
      if mode == "new_cycle" do
        with {:ok, next} <- bind(next, active, facts["priority"], opts) do
          {:ok, %{clocks: clocks ++ [next], holds: holds}}
        end
      else
        with {:ok, evaluation} <- evaluate(previous, holds, now, opts) do
          next = Map.merge(next, Map.take(previous, ~w(policy_version calendar_version priority)))
          next = Map.put(next, "carried_elapsed_us", evaluation.elapsed_us)
          {:ok, %{clocks: clocks ++ [next], holds: holds}}
        end
      end
    end
  end

  defp bind(%{"policy_version" => version} = clock, _active, _priority, opts) when not is_nil(version) do
    with {:ok, _, _} <- binding(clock, opts), do: {:ok, clock}
  end
  defp bind(clock, active, priority, opts) do
    target = active && get_in(active, ["definition", "sla_targets", priority, clock["kind"]])
    if is_map(target) do
      calendar_name = target["calendar"]
      calendar_id = active["definition"]["calendar_versions"][calendar_name]
      updated = Map.merge(clock, %{"policy_version" => active["id"], "calendar_version" => calendar_id, "priority" => priority})
      opts = Keyword.update(opts, :policies, %{active["id"] => active}, &Map.put(&1, active["id"], active))
      with {:ok, target, calendar} <- binding(updated, opts),
           {:ok, start} <- instant(clock["started_at"]),
           {:ok, _} <- duration(start, start, target, calendar, opts) do
        {:ok, updated}
      end
    else
      {:error, {:policy_unconfigured, %{missing: ["sla_targets.#{priority}.#{clock["kind"]}"], operation: :clock}}}
    end
  end

  defp binding(clock, opts) do
    policy = (opts[:policies] || %{})[clock["policy_version"]]
    target = if is_map(policy) and is_binary(clock["priority"]),
      do: get_in(policy, ["definition", "sla_targets", clock["priority"], clock["kind"]])
    calendar_row = (opts[:calendars] || %{})[clock["calendar_version"]]
    calendar = calendar_row && calendar_row["definition"]
    cond do
      is_nil(clock["priority"]) -> {:error, :clock_evidence_required}
      not is_map(target) -> {:error, :clock_evidence_required}
      is_map(calendar_row) and calendar_row["timezone_rules_version"] != rules_version(opts) ->
        {:error, :timezone_provider_unavailable}
      target["basis"] == "business" and not is_map(calendar) ->
        {:error, :timezone_provider_unavailable}
      true -> {:ok, target, calendar}
    end
  end

  defp pause_total(clock, holds, until, target, calendar, opts) do
    Enum.filter(holds, &(&1["clock"] == clock["id"]))
    |> Enum.reduce_while({:ok, 0}, fn episode, {:ok, sum} ->
      with {:ok, end_at} <- instant(episode["ended_at"] || until),
           {:ok, pause} <- episode_pause(episode, end_at, target, calendar, opts) do
        {:cont, {:ok, sum + pause}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp episode_pause(%{"reason" => reason}, _, _, _, _) when reason not in ~w(customer_wait third_party_wait), do: {:ok, 0}
  defp episode_pause(episode, until, target, calendar, opts) do
    with {:ok, start} <- instant(episode["started_at"]),
         {:ok, cap} <- instant(episode["pause_cap_at"]) do
      duration(start, earlier(until, cap), target, calendar, opts)
    end
  end

  defp add_budget(start, 0, _target, _calendar, _opts), do: {:ok, start}
  defp add_budget(start, amount, %{"basis" => "elapsed"}, _calendar, _opts),
    do: add_instant(start, amount)
  defp add_budget(start, amount, %{"basis" => "business"}, calendar, opts),
    do: business_add(start, amount, calendar, opts)

  defp budget_origin(clock, opts, seen) do
    previous_id = clock["previous_cycle"]
    cond do
      MapSet.member?(seen, clock["id"]) -> {:error, :clock_evidence_required}
      is_nil(previous_id) -> instant(clock["started_at"])
      true ->
        previous = (opts[:clocks] || %{})[previous_id]
        with true <- is_map(previous) || {:error, :clock_evidence_required},
             true <- Enum.all?(~w(workspace ticket kind), &(previous[&1] == clock[&1])) || {:error, :clock_evidence_required},
             true <- previous["cycle"] < clock["cycle"] || {:error, :clock_evidence_required},
             {:ok, stopped} <- instant(previous["stopped_at"]),
             {:ok, started} <- instant(clock["started_at"]),
             true <- DateTime.compare(stopped, started) != :gt || {:error, :clock_evidence_required} do
          if clock["reopen_mode"] == "cumulative" do
            with true <- Enum.all?(~w(policy_version calendar_version priority), &(previous[&1] == clock[&1])) || {:error, :clock_evidence_required} do
              budget_origin(previous, opts, MapSet.put(seen, clock["id"]))
            end
          else
            if clock["reopen_mode"] == "new_cycle", do: {:ok, started}, else: {:error, :clock_evidence_required}
          end
        end
    end
  end

  defp carried(%{"carried_elapsed_us" => value}) when is_integer(value) and value >= 0, do: {:ok, value}
  defp carried(_), do: {:error, :clock_evidence_required}

  defp new_clock(ticket, kind, cycle, start, opts) do
    %{"id" => id(ticket["id"], kind, cycle), "workspace" => ticket["workspace"],
      "ticket" => ticket["id"], "kind" => kind, "cycle" => cycle,
      "domain_revision" => opts[:domain_revision], "history_complete" => true,
      "started_at" => start, "stopped_at" => nil, "qualified_pause_us" => 0,
      "current_hold" => nil, "priority" => nil, "policy_version" => nil,
      "calendar_version" => nil, "carried_elapsed_us" => 0}
  end

  defp revision(clock, opts), do: Map.put(clock, "domain_revision", opts[:domain_revision])
  defp latest(clocks, kind), do: clocks |> Enum.filter(&(&1["kind"] == kind)) |> Enum.max_by(& &1["cycle"], fn -> nil end)
  defp replace(rows, row), do: Enum.map(rows, fn old -> if old["id"] == row["id"], do: row, else: old end)
  defp id(subject, kind, cycle), do: :crypto.hash(:sha256, "#{subject}:#{kind}:#{cycle}") |> Base.encode16(case: :lower) |> binary_part(0, 24)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  @doc false
  @spec instant(term()) :: {:ok, DateTime.t()} | {:error, :clock_evidence_required}
  def instant(%DateTime{} = value), do: {:ok, value}
  def instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :clock_evidence_required}
    end
  end
  def instant(_), do: {:error, :clock_evidence_required}

  defp provider(opts) do
    module = opts[:timezone_database] || Application.get_env(:veritas_core, :incident_timezone_database)
    if is_atom(module) and not is_nil(module) and module != Calendar.UTCOnlyTimeZoneDatabase and
         Code.ensure_loaded?(module) and function_exported?(module, :time_zone_periods_from_wall_datetime, 2) and
         function_exported?(module, :time_zone_period_from_utc_iso_days, 2),
      do: {:ok, module}, else: {:error, :timezone_provider_unavailable}
  end

  defp local(naive, zone, provider) do
    case DateTime.from_naive(naive, zone, provider) do
      {:ok, value} -> {:ok, value}
      {:ambiguous, _, _} -> {:error, {:policy_invalid, %{"calendars.timezone" => :ambiguous_time}}}
      {:gap, _, _} -> {:error, {:policy_invalid, %{"calendars.timezone" => :nonexistent_time}}}
      _ -> {:error, :timezone_provider_unavailable}
    end
  rescue
    _ -> {:error, :timezone_provider_unavailable}
  end

  defp zoned(value, calendar, provider) do
    case DateTime.shift_zone(value, calendar["timezone"], provider) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :timezone_provider_unavailable}
    end
  rescue
    _ -> {:error, :timezone_provider_unavailable}
  end

  defp intervals(date, calendar, provider) do
    weekly = calendar["weekly"]
    day = Enum.at(@days, Date.day_of_week(date) - 1)
    exception = Enum.find(calendar["exceptions"] || [], &(&1["date"] == Date.to_iso8601(date)))
    values = cond do
      is_map(exception) -> exception["intervals"]
      Date.to_iso8601(date) in (calendar["nonworking_dates"] || []) -> []
      is_map(weekly) -> weekly[day]
      true -> nil
    end
    if is_list(values) do
      Enum.reduce_while(values, {:ok, []}, fn pair, {:ok, rows} ->
        with [from, until] <- pair,
             {:ok, from, until, next_day} <- IncidentPolicy.interval(from, until),
             {:ok, a} <- local(NaiveDateTime.new!(date, from), calendar["timezone"], provider),
             {:ok, b} <- local(NaiveDateTime.new!(Date.add(date, next_day), until), calendar["timezone"], provider),
             true <- DateTime.compare(a, b) == :lt do
          {:cont, {:ok, rows ++ [{a, b}]}}
        else
          {:error, :timezone_provider_unavailable} = error -> {:halt, error}
          {:error, {:policy_invalid, _}} = error -> {:halt, error}
          _ -> {:halt, {:error, {:policy_invalid, %{"calendars" => :invalid_intervals}}}}
        end
      end)
    else
      {:error, {:policy_unconfigured, %{missing: ["calendars.weekly.#{day}"], operation: :clock}}}
    end
  end

  defp business_duration(from, until, calendar, opts) do
    with {:ok, provider} <- provider(opts),
         {:ok, first} <- zoned(from, calendar, provider),
         {:ok, last} <- zoned(until, calendar, provider),
         true <- Date.diff(DateTime.to_date(last), DateTime.to_date(first)) <= @scan_limit || evaluation_limit() do
      Date.range(DateTime.to_date(first), DateTime.to_date(last))
      |> Enum.reduce_while({:ok, 0}, fn date, {:ok, total} ->
        case intervals(date, calendar, provider) do
          {:ok, rows} ->
            used = Enum.reduce(rows, 0, fn {a, b}, sum -> sum + max(0, DateTime.diff(earlier(b, until), later(a, from), :microsecond)) end)
            {:cont, {:ok, total + used}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp business_add(from, amount, calendar, opts) do
    with {:ok, provider} <- provider(opts), {:ok, local} <- zoned(from, calendar, provider) do
      walk(DateTime.to_date(local), from, amount, calendar, provider, @scan_limit)
    end
  end

  defp walk(_date, cursor, 0, _calendar, _provider, _left), do: {:ok, cursor}
  defp walk(_date, _cursor, _amount, _calendar, _provider, 0), do: evaluation_limit()
  defp walk(date, cursor, amount, calendar, provider, left) do
    with {:ok, rows} <- intervals(date, calendar, provider) do
      case consume(rows, cursor, amount) do
        {:done, value} -> {:ok, value}
        {:error, _} = error -> error
        {:remaining, cursor, amount} -> walk(Date.add(date, 1), cursor, amount, calendar, provider, left - 1)
      end
    end
  end

  defp consume([], cursor, amount), do: {:remaining, cursor, amount}
  defp consume([{a, b} | rest], cursor, amount) do
    start = later(a, cursor)
    available = max(0, DateTime.diff(b, start, :microsecond))
    if available >= amount do
      case add_instant(start, amount) do
        {:ok, value} -> {:done, value}
        {:error, _} = error -> error
      end
    else
      consume(rest, later(cursor, b), amount - available)
    end
  end

  defp business_days(from, amount, calendar, opts) do
    with {:ok, provider} <- provider(opts), {:ok, local} <- zoned(from, calendar, provider) do
      walk_days(DateTime.to_date(local), from, {amount, 1}, calendar, provider, @scan_limit)
    end
  end

  defp walk_days(_date, cursor, {0, _}, _calendar, _provider, _left), do: {:ok, cursor}
  defp walk_days(_date, _cursor, _remaining, _calendar, _provider, 0), do: evaluation_limit()
  defp walk_days(date, cursor, {n, d}, calendar, provider, left) do
    with {:ok, rows} <- intervals(date, calendar, provider) do
      total = Enum.reduce(rows, 0, fn {a, b}, sum -> sum + DateTime.diff(b, a, :microsecond) end)
      available = Enum.reduce(rows, 0, fn {a, b}, sum -> sum + max(0, DateTime.diff(b, later(a, cursor), :microsecond)) end)
      cond do
        total == 0 or available == 0 -> walk_days(Date.add(date, 1), cursor, {n, d}, calendar, provider, left - 1)
        n * total <= available * d ->
          case consume(rows, cursor, div(n * total + d - 1, d)) do
            {:done, result} -> {:ok, result}
            {:error, _} = error -> error
            _ -> evaluation_limit()
          end
        true ->
          numerator = n * total - available * d
          denominator = d * total
          gcd = Integer.gcd(numerator, denominator)
          next = Enum.reduce(rows, cursor, fn {_, b}, value -> later(value, b) end)
          walk_days(Date.add(date, 1), next, {div(numerator, gcd), div(denominator, gcd)}, calendar, provider, left - 1)
      end
    end
  end

  defp chronology(clocks, holds, now) do
    Enum.reduce_while(clocks ++ holds, :ok, fn row, :ok ->
      with {:ok, start} <- optional_instant(row["started_at"]),
           {:ok, finish} <- optional_instant(row["stopped_at"] || row["ended_at"]),
           true <- (is_nil(start) or DateTime.compare(start, now) != :gt) and
             (is_nil(finish) or DateTime.compare(finish, now) != :gt) and
             (is_nil(start) or is_nil(finish) or DateTime.compare(start, finish) != :gt) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :clock_evidence_required}}
      end
    end)
  end

  defp optional_instant(nil), do: {:ok, nil}
  defp optional_instant(value), do: instant(value)

  # Arithmetic on a known instant is independent of its presentation timezone.
  # Local wall boundaries still go through the explicitly injected provider.
  defp add_instant(value, amount) do
    case DateTime.from_unix(DateTime.to_unix(value, :microsecond) + amount, :microsecond) do
      {:ok, instant} -> {:ok, instant}
      _ -> {:error, {:policy_invalid, %{"calendars" => :instant_out_of_range}}}
    end
  end

  defp evaluation_limit, do: {:error, {:policy_invalid, %{"calendars" => :evaluation_limit}}}
end
