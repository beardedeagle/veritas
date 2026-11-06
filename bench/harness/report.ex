defmodule Veritas.Core.Bench.Report do
  @moduledoc """
  The report: what was measured, what the budget says, and what failed.

  The report prints the percentiles the budget is written in — p50, p95 and
  p99 — and it prints the **sample count** beside them, because a p95 over
  five samples is the slowest of five samples and the reader has to know
  that.

  It prints the round trips beside the latency, because a latency without a
  round-trip count does not say whether the path is slow or whether the path
  is an N+1.

  And it prints the scale the numbers were taken at, next to the scale the
  budget is written for, because a number measured at a tenth of the budget's
  scale is not a budget verification and must not read like one.

  Every budget number it prints is **read from the budget**, through
  `Veritas.Core.Bench.Budget`, which is the same source the gate reads. A
  literal here would be a second budget that happens to agree with the first
  today, and drifts from it the moment either one changes.
  """

  alias Veritas.Core.Bench.Budget
  alias Veritas.Core.Bench.Stats

  @doc """
  Prints the whole run.
  """
  @spec print(map()) :: :ok
  def print(run) do
    print_header(run)
    print_latency(run)
    print_store_cost(run)
    print_explain(run)
    print_findings(run)
    print_footer(run)
  end

  @doc """
  The run as a map, for the JSON artifact.
  """
  @spec to_map(map()) :: map()
  def to_map(run) do
    %{
      "version" => 1,
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "mode" => run.mode,
      "environment" => run.environment,
      "dataset" => run.dataset,
      "store" => run.store,
      "scenarios" =>
        Enum.map(run.results, fn result ->
          %{
            "id" => result.scenario.id,
            "label" => result.scenario.label,
            "budgets" => result.scenario.budgets,
            "samples" => result.stats.samples,
            "p50_us" => result.stats.p50,
            "p95_us" => result.stats.p95,
            "p99_us" => result.stats.p99,
            "min_us" => result.stats.min,
            "max_us" => result.stats.max,
            "mean_us" => result.stats.mean,
            "stddev_us" => result.stats.stddev,
            "words" => result.stats.words,
            "round_trips" => result.round_trips,
            "nodes_visited" => result.nodes_visited,
            "errors" => Map.get(result, :errors, 0),
            "error" => result.error && inspect(result.error)
          }
        end),
      "explain" =>
        Enum.map(run.explain, fn result ->
          %{
            "id" => result.id,
            "label" => result.label,
            "statement" => result.statement,
            "expected" => result.expect,
            "operators" => result.operators,
            "verdict" => to_string(result.verdict),
            "reason" => result.reason,
            "plan" => result.plan
          }
        end),
      "findings" =>
        Enum.map(run.findings, fn finding ->
          %{
            "severity" => to_string(finding.severity),
            "kind" => to_string(finding.kind),
            "scenario" => finding.scenario,
            "row" => finding.row,
            "measured_us" => finding.measured_us,
            "target_us" => finding.target_us,
            "detail" => finding.detail
          }
        end)
    }
  end

  defp print_header(run) do
    IO.puts("""

    Veritas performance benchmark
    =============================

    mode          #{run.mode}
    environment   #{run.environment}
    workspace     #{run.dataset.workspace}
    graph         depth #{run.dataset.depth}, fan-out #{run.dataset.fan_out}, fan-in #{run.dataset.fan_in}
                  #{run.dataset.node_count} CIs, #{run.dataset.edge_count} edges
    fingerprint   #{run.dataset.fingerprint}
    store         #{run.store.url}
    """)
  end

  defp print_latency(run) do
    IO.puts("""

    Latency against the budget
    --------------------------
    """)

    IO.puts(
      String.pad_trailing("scenario", 34) <>
        String.pad_trailing("budget p50/p95/p99", 24) <>
        String.pad_trailing("measured p50/p95/p99", 26) <>
        String.pad_trailing("n", 5) <>
        String.pad_trailing("rt", 5) <> "failed"
    )

    Enum.each(run.results, fn result ->
      row = result.scenario.budgets |> Enum.map(&Budget.row/1) |> Enum.reject(&is_nil/1)

      budget =
        case row do
          [] -> "no budget row"
          [first | _] -> "#{first.p50}/#{first.p95}/#{first.p99} ms"
        end

      measured =
        "#{Stats.format_us(result.stats.p50)} / #{Stats.format_us(result.stats.p95)} / " <>
          "#{Stats.format_us(result.stats.p99)}"

      failed = Map.get(result, :errors, 0)

      IO.puts(
        String.pad_trailing(result.scenario.id, 34) <>
          String.pad_trailing(budget, 24) <>
          String.pad_trailing(measured, 26) <>
          String.pad_trailing(to_string(result.stats.samples), 5) <>
          String.pad_trailing(to_string(result.round_trips || "-"), 5) <>
          to_string(failed)
      )
    end)
  end

  defp print_store_cost(run) do
    IO.puts("""

    The cost of one store request
    -----------------------------
    """)

    basic = run.store.request_us_basic
    bearer = run.store.request_us_bearer

    IO.puts("  Basic credential (a password check on every request)  #{cost(basic)}")
    IO.puts("  Bearer token (what the Adapter sends)                #{cost(bearer)}")

    if run.store[:error] do
      IO.puts("  the store cost was not measured: #{inspect(run.store.error)}")
    end

    if is_integer(basic) and is_integer(bearer) and bearer > 0 do
      IO.puts(
        "  The credential costs #{Stats.format_us(basic - bearer)} of every request — " <>
          "#{Float.round((basic - bearer) / bearer, 1)}x the cost of the request itself."
      )
    end

    # The depth-5 budget is read from the same row the gate reads it from, so
    # the number printed here and the number the gate enforces are the same
    # number — today, and after any change to the budget. A literal here would
    # be a second budget that happens to agree.
    budget_us = Budget.depth5_budget_us()

    ceiling =
      case {budget_us, bearer} do
        {budget, value} when is_integer(budget) and is_integer(value) and value > 0 ->
          max(trunc(budget / value), 1)

        _ ->
          nil
      end

    cond do
      is_nil(budget_us) ->
        IO.puts(
          "  The depth-5 budget row (#{Budget.depth5_row_id()}) is not in the budget; " <>
            "the gate cannot assert a budget for that path."
        )

      ceiling ->
        IO.puts(
          "  The depth-5 traversal is budgeted at #{Stats.format_us(budget_us)}, which allows " <>
            "#{ceiling} round trips at that per-request cost."
        )

      true ->
        IO.puts(
          "  The depth-5 traversal is budgeted at #{Stats.format_us(budget_us)}; " <>
            "the per-request cost was not measurable."
        )
    end
  end

  defp cost(nil), do: "not measurable"
  defp cost(us), do: Stats.format_us(us)

  defp print_explain(run) do
    IO.puts("""

    The EXPLAIN gate
    ----------------
    """)

    Enum.each(run.explain, fn result ->
      mark = if result.verdict == :pass, do: "pass", else: String.upcase(to_string(result.verdict))
      IO.puts("  [#{String.pad_trailing(mark, 4)}] #{result.id} — expects #{Enum.join(result.expect, " or ")}")
      IO.puts("          plan: #{String.replace(result.plan || "-", "\n", "\n                ")}")

      if result.reason do
        IO.puts("          #{result.reason}")
      end
    end)
  end

  defp print_findings(run) do
    IO.puts("""

    Findings
    --------
    """)

    if run.findings == [] do
      IO.puts("  none — every measured path is inside its budget.")
    else
      Enum.each(run.findings, fn finding ->
        IO.puts("  [#{String.upcase(to_string(finding.severity))}] #{finding.kind}: #{finding.detail}")
      end)
    end
  end

  defp print_footer(run) do
    IO.puts("""

    #{if run.passing?, do: "PASS", else: "FAIL"} — #{length(run.findings)} finding(s).
    The breach rule: "#{Veritas.Core.Bench.Gate.rule_text()}"
    """)
  end
end
