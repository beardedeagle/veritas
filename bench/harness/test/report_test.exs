defmodule Veritas.Core.Bench.ReportTest do
  @moduledoc """
  The report reads the budget; it does not hold a second copy of it.

  The defect this covers was a report that printed a literal `500_000` for
  the depth-5 budget while the gate read the same budget from the budget
  table. The two agreed that day, and would have disagreed the first time
  the budget changed — with the report still printing the old number and
  nobody noticing, because the gate was the one being enforced.

  These tests are the guard: the printed number is the budget's number, and
  the report's source holds no literal to drift.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Veritas.Core.Bench.Budget
  alias Veritas.Core.Bench.Report
  alias Veritas.Core.Bench.Stats

  @report_source "bench/harness/report.ex"
  @per_request_us 10_000

  test "the depth-5 budget is the budget row's p95, converted once" do
    row = Budget.row("db_depth5_5000")

    assert row, "the depth-5 budget row is not in the budget"
    assert Budget.depth5_budget_us() == trunc(row.p95 * 1_000)
    assert Budget.depth5_row_id() == "db_depth5_5000"
  end

  test "the report prints the budget the gate uses" do
    output = capture_io(fn -> Report.print(run()) end)

    budget_us = Budget.depth5_budget_us()

    assert output =~ "The depth-5 traversal is budgeted at #{Stats.format_us(budget_us)}"
  end

  test "the ceiling the report prints is derived from that budget" do
    output = capture_io(fn -> Report.print(run()) end)

    budget_us = Budget.depth5_budget_us()
    ceiling = trunc(budget_us / @per_request_us)

    assert output =~ "allows #{ceiling} round trips"
  end

  test "the report holds no hard-coded depth-5 budget" do
    source = File.read!(Path.join(repo_root(), @report_source))

    refute source =~ "500_000",
           "the report holds a literal depth-5 budget again; it must read " <>
             "Budget.depth5_budget_us/0 so there is one number"
  end

  defp run do
    %{
      mode: "report",
      environment: "smoke",
      dataset: %{
        workspace: "bench_test",
        depth: 5,
        fan_out: 12,
        fan_in: 12,
        node_count: 250,
        edge_count: 253,
        fingerprint: "test"
      },
      store: %{
        url: "http://127.0.0.1:0",
        request_us_basic: 10_000,
        request_us_bearer: @per_request_us,
        error: nil
      },
      results: [
        %{
          scenario: %{id: "cmdb_index", label: "CMDB index", budgets: ["page_load"]},
          stats: %{samples: 30, p50: 10_000, p95: 20_000, p99: 30_000},
          round_trips: 1,
          errors: 0,
          error: nil
        }
      ],
      explain: [],
      findings: [],
      passing?: true
    }
  end

  defp repo_root do
    Path.expand(Path.join(__DIR__, "../../.."))
  end
end
