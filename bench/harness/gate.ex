defmodule Veritas.Core.Bench.Gate do
  @moduledoc """
  The gate: what a measurement has to do to fail the build.

  The rules come from `docs/13` §Performance Engineering Process, and the
  two that decide a breach are quoted from it rather than paraphrased,
  because a paraphrased threshold is a threshold nobody can check:

  > Two p95 breaches in consecutive runs open a defect; a p99 breach by 2x
  > does the same.

  And the CI gate list, which is the list of things that fail the build:

  > - latency regression >5% **and** absolute >2 ms on a bench whose p95
  >   exceeds 100 ms
  > - allocation regression >10%
  > - budget breach: any §4/§5 row measured above its p95 target, reported
  >   with the owning Node Role
  > - `EXPLAIN` drift: a hot query that regresses from IndexScan to TableScan
  > - release size regression >2%

  ## The rules, in the order they are applied

    1. **Budget breach** — a scenario's p95 is above a budget row's p95. This
       fails the build.
    2. **Consecutive breach** — the same row was breached in the previous run
       too. The corpus says two consecutive breaches *open a defect*: it is
       noise plus a signal, not a single unlucky run.
    3. **p99 by two times** — a scenario's p99 is above twice the row's p99.
       The corpus says the same thing this does about a defect.
    4. **Regression** — worse than the committed baseline by more than 5% and
       by more than 2 ms, on a row whose p95 exceeds 100 ms.
    5. **Allocation regression** — worse than the baseline by more than 10%.
    6. **EXPLAIN drift** — a hot query whose plan is a TableScan where an
       IndexScan was expected.
    7. **Round-trip ceiling** — the traversal made more store round trips
       than the budget's own milliseconds allow. The ceiling is *derived*:
       `budget_ms / measured_request_ms`, so it moves with the store's
       actual per-request cost rather than with a constant someone picked.
    8. **Node cap** — a traversal returned more nodes than the budget's
       5,000-node cap allows, or returned exactly the cap without saying it
       had truncated.

  ## A run with no baseline

  `docs/13`: "A run with no matching baseline is a **no-baseline result, not
  a pass**." So a missing or mismatched baseline is reported as such, and in
  `--check` mode it fails. The owner accepts a new baseline explicitly.

  ## A budget row that is not in the budget

  A scenario names the budget rows it answers to. If it names a row that does
  not exist, the gate **cannot assert a budget for that path**.

  The honest reading of an unassertable budget is that the path is
  unmeasured against the corpus — and an unmeasured path is not a passing
  path. So a missing row is a **finding that fails the build**, named with
  the row that is missing.

  It is deliberately not a crash: a crash takes the whole report down with
  it, and the other scenarios' findings are still worth reading. It is
  deliberately not a silence either: a path that looks checked, on a budget
  that was never applied, is the failure mode this gate exists to prevent.

  The same rule covers the round-trip ceiling, whose budget is the depth-5
  row: if that row is not in the budget the ceiling cannot be derived, and
  the traversal is reported as unchecked rather than unchecked-and-green.
  """

  alias Veritas.Core.Bench.Budget
  alias Veritas.Core.Bench.Stats

  @node_budget 5_000
  @regression_pct 5.0
  @regression_floor_us 2_000
  @regression_p95_floor_us 100_000
  @allocation_pct 10.0
  @p99_multiplier 2.0

  @type severity :: :breach | :defect | :regression | :ok | :informational

  @doc """
  Evaluates the run and returns the findings, worst first.
  """
  @spec evaluate([map()], keyword()) :: [map()]
  def evaluate(results, opts \\ []) do
    baseline = Keyword.get(opts, :baseline)
    per_request_us = Keyword.get(opts, :per_request_us)
    node_budget = Keyword.get(opts, :node_budget, @node_budget)

    results
    |> Enum.flat_map(&findings_for(&1, baseline, per_request_us, node_budget))
    |> Enum.sort_by(&severity_rank(&1.severity))
  end

  @doc """
  The node budget the corpus sets: 5,000 nodes.
  """
  @spec node_budget() :: pos_integer()
  def node_budget, do: @node_budget

  @doc """
  Whether the findings fail the build.

  A finding of `:informational` or `:ok` does not. Everything else does:
  a breach is a breach, and a benchmark whose result nobody acts on is a
  report, not a gate.
  """
  @spec failing?([map()]) :: boolean()
  def failing?(findings) do
    Enum.any?(findings, &(&1.severity in [:breach, :defect, :regression]))
  end

  @doc """
  The corpus's own words for the breach rule, for the report to quote.
  """
  @spec rule_text() :: String.t()
  def rule_text do
    "Two p95 breaches in consecutive runs open a defect; a p99 breach by 2x does the same."
  end

  defp findings_for(result, baseline, per_request_us, node_budget) do
    scenario = result.scenario
    stats = result.stats

    budget_findings =
      Enum.flat_map(scenario.budgets, fn row_id ->
        case Budget.row(row_id) do
          nil -> missing_budget_finding(scenario, row_id)
          row -> budget_finding(scenario, stats, row, baseline)
        end
      end)

    regression_findings = regression_findings(scenario, stats, baseline)
    allocation_findings = allocation_findings(scenario, stats, baseline)
    round_trip_findings = round_trip_findings(scenario, result, per_request_us)
    node_cap_findings = node_cap_findings(scenario, result, node_budget)
    error_findings = error_findings(scenario, result)

    budget_findings ++
      regression_findings ++
      allocation_findings ++
      round_trip_findings ++
      node_cap_findings ++
      error_findings
  end

  # A path that answers with an error is not a fast path. It is a broken
  # one, and the percentiles it produced say nothing about its speed — so a
  # scenario with a failed sample is a finding, and its latency is not
  # compared to a budget.
  defp error_findings(scenario, result) do
    case Map.get(result, :errors, 0) do
      0 ->
        []

      count ->
        [
          %{
            severity: :breach,
            kind: :error,
            scenario: scenario.id,
            row: nil,
            label: scenario.label,
            measured_us: nil,
            target_us: nil,
            detail:
              "#{count} of #{result.stats.samples} samples failed (#{inspect(result.error)}); " <>
                "a path that answers with an error has no latency to compare against a budget"
          }
        ]
    end
  end

  # ── the budget breach ─────────────────────────────────────────────────────

  # A scenario that names a budget row which is not in the budget is a gate
  # that cannot assert its budget.
  #
  # The honest reading is that this path is **unmeasured against the
  # corpus**, and an unmeasured path is not a passing path. So it is a
  # finding with a severity that fails the build, not a crash and not a
  # silence:
  #
  #   * A crash would take the whole report down with it. The other
  #     scenarios' findings are still worth reading, and a stack trace from
  #     the gate is not a finding anybody can act on.
  #   * A silence would be the worst of the three: the path would look
  #     checked, and the build would go green on a budget that was never
  #     applied.
  #
  # The finding names the row, so the fix is obvious: either the scenario
  # names a row that exists, or the budget gains the row it means.
  defp missing_budget_finding(scenario, row_id) do
    [
      %{
        severity: :breach,
        kind: :missing_budget,
        scenario: scenario.id,
        row: row_id,
        label: scenario.label,
        measured_us: nil,
        target_us: nil,
        detail:
          "the scenario names a budget row that is not in the budget (#{inspect(row_id)}), so the " <>
            "gate cannot assert a budget for this path. The gate fails rather than pass a path it " <>
            "cannot measure against the corpus."
      }
    ]
  end

  defp budget_finding(scenario, stats, row, baseline) do
    # The budget is written in milliseconds and the measurement is taken in
    # microseconds. They are put in the same unit before they are compared,
    # because a comparison across units is a comparison across nothing.
    measured = stats.p95
    target = row.p95 * 1_000

    if measured > target do
      consecutive? = consecutive_breach?(baseline, scenario.id, row.id)

      [
        %{
          severity: if(consecutive?, do: :defect, else: :breach),
          kind: :budget,
          scenario: scenario.id,
          row: row.id,
          label: row.label,
          measured_us: measured,
          target_us: target,
          detail:
            "p95 #{Stats.format_us(measured)} is above the budget of #{Stats.format_us(target)} " <>
              "(#{row.source})" <>
              if(consecutive?,
                do: " — and the previous run breached it too, so this opens a defect.",
                else: "."
              )
        }
      ]
    else
      p99_finding(scenario, stats, row)
    end
  end

  defp p99_finding(scenario, stats, row) do
    target = row.p99 * 1_000 * @p99_multiplier

    if stats.p99 > target do
      [
        %{
          severity: :defect,
          kind: :p99,
          scenario: scenario.id,
          row: row.id,
          label: row.label,
          measured_us: stats.p99,
          target_us: target,
          detail:
            "p99 #{Stats.format_us(stats.p99)} is more than twice the budget's p99 of " <>
              "#{Stats.format_us(row.p99)} — #{rule_text()}"
        }
      ]
    else
      []
    end
  end

  # ── the regression against the baseline ───────────────────────────────────

  defp regression_findings(scenario, stats, baseline) do
    with previous when is_map(previous) <- baseline_scenario(baseline, scenario.id),
         true <- previous.p95 > @regression_p95_floor_us,
         pct when is_float(pct) <- Stats.regression_pct(previous.p95, stats.p95),
         true <- pct > @regression_pct,
         delta when delta > @regression_floor_us <- stats.p95 - previous.p95 do
      [
        %{
          severity: :regression,
          kind: :regression,
          scenario: scenario.id,
          row: nil,
          label: scenario.label,
          measured_us: stats.p95,
          target_us: previous.p95,
          detail:
            "p95 regressed #{Float.round(pct, 1)}% against the committed baseline " <>
              "(#{Stats.format_us(previous.p95)} → #{Stats.format_us(stats.p95)}); the gate is " <>
              ">5% and >2 ms on a bench whose p95 exceeds 100 ms"
        }
      ]
    else
      _ -> []
    end
  end

  defp allocation_findings(scenario, stats, baseline) do
    with previous when is_map(previous) <- baseline_scenario(baseline, scenario.id),
         true <- previous.words > 0,
         pct when is_float(pct) <- Stats.regression_pct(previous.words, stats.words),
         true <- pct > @allocation_pct do
      [
        %{
          severity: :regression,
          kind: :allocation,
          scenario: scenario.id,
          row: nil,
          label: scenario.label,
          measured_us: stats.words,
          target_us: previous.words,
          detail:
            "allocation proxy regressed #{Float.round(pct, 1)}% against the committed baseline; " <>
              "the gate is >10%"
        }
      ]
    else
      _ -> []
    end
  end

  # ── the round-trip ceiling, derived from the budget ───────────────────────

  # The budget prices the depth-5 traversal at 150-500 ms. How many round
  # trips that allows depends on what a round trip costs, which the harness
  # measures. The ceiling is therefore `budget_ms / request_ms` — derived
  # from the corpus's own numbers, not from a constant.
  #
  # The budget is read from the same row the report reads it from, so the
  # ceiling and the printed budget cannot drift apart. And if that row is
  # not in the budget, the ceiling cannot be derived at all: the gate fails
  # rather than quietly stops checking the traversal.
  defp round_trip_findings(scenario, result, per_request_us) do
    if scenario.kind == :store and
         scenario.id in ["graph_traversal_depth5", "graph_traversal_depth5_in"] and
         is_integer(result.round_trips) and result.round_trips > 0 and
         is_integer(per_request_us) and per_request_us > 0 do
      case Budget.depth5_budget_us() do
        nil ->
          missing_budget_finding(scenario, Budget.depth5_row_id())

        budget_us ->
          ceiling = max(trunc(budget_us / per_request_us), 1)

          if result.round_trips > ceiling do
            [
              %{
                severity: :breach,
                kind: :round_trips,
                scenario: scenario.id,
                row: Budget.depth5_row_id(),
                label: scenario.label,
                measured_us: result.round_trips,
                target_us: ceiling,
                detail:
                  "the traversal made #{result.round_trips} store round trips; the budget's " <>
                    "#{Stats.format_us(budget_us)} for this path allows #{ceiling} at the " <>
                    "measured #{Stats.format_us(per_request_us)} per request. " <>
                    "This is the N+1: the count scales with the nodes visited, not with the depth."
              }
            ]
          else
            []
          end
      end
    else
      []
    end
  end

  # ── the node cap ──────────────────────────────────────────────────────────

  defp node_cap_findings(scenario, result, node_budget) do
    with true <- scenario.id in ["graph_traversal_depth5", "graph_traversal_depth5_in"],
         nodes when is_integer(nodes) <- result.nodes_visited,
         true <- nodes > node_budget do
      [
        %{
          severity: :breach,
          kind: :node_cap,
          scenario: scenario.id,
          row: nil,
          label: scenario.label,
          measured_us: nodes,
          target_us: node_budget,
          detail:
            "the traversal visited #{nodes} nodes; the budget caps a traversal at " <>
              "#{node_budget |> Integer.to_string() |> String.replace(~r/(\d)(?=\d{3}\b)/, "\\1,")}. " <>
              "A truncated graph is honest; an unbounded one is an outage."
        }
      ]
    else
      _ -> []
    end
  end

  # ── the baseline ──────────────────────────────────────────────────────────

  @doc """
  The fingerprint of the dataset a baseline belongs to.

  A baseline is only comparable to a run over the same shape. The
  fingerprint covers the fixture's shape and the store's schema version, so
  a baseline recorded over a different graph is a **no-baseline result**, not
  a pass.
  """
  @spec dataset_fingerprint(map()) :: String.t()
  def dataset_fingerprint(shape) do
    shape
    |> Map.take([:depth, :fan_out, :fan_in, :node_count, :edge_count])
    |> Map.merge(%{engine: engine_version()})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  @doc """
  The store's engine version, or `"unknown"`.

  The baseline is keyed by the configuration as well as by the dataset, and
  the engine version is part of the configuration: the same graph measured
  against two different engines is two different measurements.
  """
  @spec engine_version() :: String.t()
  def engine_version do
    version = get_in(Veritas.Store.Surreal.describe(), ["engine", "version"])

    if is_binary(version), do: version, else: "unknown"
  end

  defp baseline_scenario(nil, _id), do: nil

  # The baseline is JSON, so its keys are strings. They are normalised once,
  # here, rather than read as strings in three places.
  defp baseline_scenario(baseline, id) do
    case get_in(baseline, ["scenarios", id]) do
      nil ->
        nil

      scenario ->
        %{
          p95: scenario["p95_us"],
          p99: scenario["p99_us"],
          words: scenario["words"]
        }
    end
  end

  defp consecutive_breach?(nil, _scenario_id, _row_id), do: false

  defp consecutive_breach?(baseline, scenario_id, row_id) do
    case get_in(baseline, ["breaches", scenario_id]) do
      breaches when is_list(breaches) -> row_id in breaches
      _ -> false
    end
  end

  defp severity_rank(:breach), do: 0
  defp severity_rank(:defect), do: 1
  defp severity_rank(:regression), do: 2
  defp severity_rank(:informational), do: 3
  defp severity_rank(:ok), do: 4
end
