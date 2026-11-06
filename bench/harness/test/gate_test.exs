defmodule Veritas.Core.Bench.GateTest do
  @moduledoc """
  The gate: what a measurement has to do to fail the build.

  Each rule from `docs/13` §Performance Engineering Process is tested
  against the measurement that trips it and against the measurement that
  must not trip it. A gate that only has the failing case tested is a gate
  that fails on everything.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Bench.Gate

  describe "the budget breach" do
    test "a p95 above the budget is a breach" do
      findings = Gate.evaluate([result(p95: 400_000)], baseline: nil)

      assert Enum.any?(findings, &(&1.severity == :breach and &1.kind == :budget))
      assert Gate.failing?(findings)
    end

    test "a p95 inside the budget is not a finding" do
      findings = Gate.evaluate([result(p95: 200_000)], baseline: nil)

      refute Enum.any?(findings, &(&1.kind == :budget))
      refute Gate.failing?(findings)
    end

    test "two p95 breaches in consecutive runs open a defect" do
      baseline = %{"breaches" => %{"cmdb_index" => ["page_load"]}}

      findings = Gate.evaluate([result(p95: 400_000)], baseline: baseline)

      defect = Enum.find(findings, &(&1.kind == :budget))
      assert defect.severity == :defect
      assert defect.detail =~ "opens a defect"
    end

    test "a p99 more than twice the budget opens a defect" do
      findings = Gate.evaluate([result(p95: 200_000, p99: 1_200_001)], baseline: nil)

      defect = Enum.find(findings, &(&1.kind == :p99))
      assert defect.severity == :defect
      assert defect.detail =~ Gate.rule_text()
    end

    test "a p99 inside twice the budget is not a finding" do
      findings = Gate.evaluate([result(p95: 200_000, p99: 1_100_000)], baseline: nil)

      refute Enum.any?(findings, &(&1.kind == :p99))
    end
  end

  describe "the regression against the baseline" do
    test "more than 5% and more than 2 ms on a p95 above 100 ms is a regression" do
      baseline = baseline(p95: 200_000, words: 1_000)

      findings = Gate.evaluate([result(p95: 220_000, words: 1_000)], baseline: baseline)

      assert Enum.any?(findings, &(&1.kind == :regression))
    end

    test "5% on its own is not a regression" do
      baseline = baseline(p95: 200_000, words: 1_000)

      findings = Gate.evaluate([result(p95: 210_000, words: 1_000)], baseline: baseline)

      refute Enum.any?(findings, &(&1.kind == :regression))
    end

    test "more than 2 ms on its own is not a regression" do
      baseline = baseline(p95: 200_000, words: 1_000)

      findings = Gate.evaluate([result(p95: 201_000, words: 1_000)], baseline: baseline)

      refute Enum.any?(findings, &(&1.kind == :regression))
    end

    test "a bench whose p95 is under 100 ms does not gate on regression" do
      baseline = baseline(p95: 50_000, words: 1_000)

      findings = Gate.evaluate([result(p95: 90_000, words: 1_000)], baseline: baseline)

      refute Enum.any?(findings, &(&1.kind == :regression))
    end

    test "an allocation regression over 10% is a regression" do
      baseline = baseline(p95: 200_000, words: 1_000)

      findings = Gate.evaluate([result(p95: 200_000, words: 1_200)], baseline: baseline)

      assert Enum.any?(findings, &(&1.kind == :allocation))
    end
  end

  describe "the round-trip ceiling" do
    test "more round trips than the budget's milliseconds allow is a breach" do
      # 500 ms of budget at 10 ms per request allows 50 round trips.
      findings =
        Gate.evaluate(
          [result(p95: 1_000, round_trips: 51, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil,
          per_request_us: 10_000
        )

      breach = Enum.find(findings, &(&1.kind == :round_trips))
      assert breach.severity == :breach
      assert breach.detail =~ "N+1"
    end

    test "a traversal inside the ceiling is not a finding" do
      findings =
        Gate.evaluate(
          [result(p95: 1_000, round_trips: 10, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil,
          per_request_us: 10_000
        )

      refute Enum.any?(findings, &(&1.kind == :round_trips))
    end

    test "the ceiling moves with the cost of a request" do
      slow =
        Gate.evaluate(
          [result(p95: 1_000, round_trips: 40, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil,
          per_request_us: 12_800
        )

      fast =
        Gate.evaluate(
          [result(p95: 1_000, round_trips: 40, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil,
          per_request_us: 230
        )

      assert Enum.any?(slow, &(&1.kind == :round_trips))
      refute Enum.any?(fast, &(&1.kind == :round_trips))
    end
  end

  describe "the node cap" do
    test "a traversal that visits more nodes than the cap allows is a breach" do
      findings =
        Gate.evaluate(
          [result(p95: 1_000, nodes_visited: 5_001, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil
        )

      breach = Enum.find(findings, &(&1.kind == :node_cap))
      assert breach.severity == :breach
      assert breach.detail =~ "5,000"
    end

    test "a traversal inside the cap is not a finding" do
      findings =
        Gate.evaluate(
          [result(p95: 1_000, nodes_visited: 4_999, kind: :store, id: "graph_traversal_depth5")],
          baseline: nil
        )

      refute Enum.any?(findings, &(&1.kind == :node_cap))
    end
  end

  describe "a budget row that is not in the budget" do
    test "the gate fails rather than passing a path it cannot measure" do
      findings =
        Gate.evaluate(
          [result(budgets: ["no_such_budget_row"], p95: 100_000)],
          baseline: nil
        )

      finding = Enum.find(findings, &(&1.kind == :missing_budget))

      assert finding, "the gate produced no finding for a missing budget row"
      assert finding.severity == :breach
      assert finding.row == "no_such_budget_row"
      assert finding.detail =~ "cannot assert a budget"

      # The finding is one that fails the build, not one that is merely
      # reported.
      assert Gate.failing?(findings)
    end

    test "the other rows of the same scenario are still checked" do
      findings =
        Gate.evaluate(
          [result(budgets: ["no_such_budget_row", "page_load"], p95: 400_000)],
          baseline: nil
        )

      assert Enum.any?(findings, &(&1.kind == :missing_budget and &1.row == "no_such_budget_row"))

      # The p95 of 400 ms is above the page-load budget of 300 ms, and that
      # breach is still reported: one missing row does not stop the gate.
      assert Enum.any?(findings, &(&1.kind == :budget and &1.row == "page_load"))
    end

    test "a scenario with no budget row at all is not a finding" do
      findings = Gate.evaluate([result(budgets: [], p95: 100_000)], baseline: nil)

      refute Enum.any?(findings, &(&1.kind == :missing_budget))
    end
  end

  test "the corpus's own wording for the breach rule is quoted, not paraphrased" do
    assert Gate.rule_text() ==
             "Two p95 breaches in consecutive runs open a defect; a p99 breach by 2x does the same."
  end

  defp result(opts) do
    p50 = Keyword.get(opts, :p50, Keyword.get(opts, :p95, 100))
    p95 = Keyword.get(opts, :p95, 100)
    p99 = Keyword.get(opts, :p99, p95)

    %{
      scenario: %{
        id: Keyword.get(opts, :id, "cmdb_index"),
        label: "CMDB index",
        budgets: Keyword.get(opts, :budgets, ["page_load"]),
        kind: Keyword.get(opts, :kind, :web)
      },
      stats: %{
        samples: 30,
        p50: p50,
        p95: p95,
        p99: p99,
        min: p50,
        max: p99,
        mean: p95,
        stddev: 0,
        words: Keyword.get(opts, :words, 1_000)
      },
      round_trips: Keyword.get(opts, :round_trips, 1),
      nodes_visited: Keyword.get(opts, :nodes_visited, 10)
    }
  end

  defp baseline(opts) do
    p95 = Keyword.fetch!(opts, :p95)
    words = Keyword.fetch!(opts, :words)

    %{
      "scenarios" => %{
        "cmdb_index" => %{"p50_us" => p95, "p95_us" => p95, "p99_us" => p95, "words" => words}
      }
    }
  end
end
