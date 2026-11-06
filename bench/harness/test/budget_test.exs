defmodule Veritas.Core.Bench.BudgetTest do
  @moduledoc """
  The budget, as the harness holds it.

  The harness does not keep a second, private set of thresholds. These
  tests assert that the numbers here are the numbers `docs/13` is written
  in, so that a change to one without the other is a failing test rather
  than a quiet drift.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Bench.Budget
  alias Veritas.Core.Bench.Scenarios

  test "every row names the corpus section it came from" do
    for row <- Budget.rows() do
      assert String.starts_with?(row.source, "docs/13"),
             "#{row.id} does not name its source"
    end
  end

  test "no row has a p99 below its p95, or a p95 below its p50" do
    for row <- Budget.rows() do
      assert row.p50 <= row.p95, "#{row.id} has a p95 below its p50"
      assert row.p95 <= row.p99, "#{row.id} has a p99 below its p95"
    end
  end

  test "the latency rows are the ones docs/13 writes" do
    assert {120, 300, 600} == triple("page_load")
    assert {120, 500, 1_200} == triple("ci_detail_impact")
    assert {300, 900, 2_000} == triple("graph_traversal_depth5")
    assert {150, 400, 1_000} == triple("graphql_complex_list")
    assert {60, 200, 600} == triple("ticket_create")
  end

  test "the database rows keep the range the corpus states" do
    assert [0.5, 2.0] == Budget.row("db_point_read").range
    assert [5.0, 20.0] == Budget.row("db_one_hop").range
    assert [40.0, 150.0] == Budget.row("db_impact_depth3").range
    assert [150.0, 500.0] == Budget.row("db_depth5_5000").range
  end

  test "every scenario names a budget row that exists" do
    scenarios = Scenarios.all(%{workspace: "w", root_id: "r", base_url: nil})

    assert scenarios != []

    for scenario <- scenarios do
      for id <- scenario.budgets do
        assert Budget.row(id), "#{scenario.id} names a budget row that does not exist: #{id}"
      end
    end
  end

  test "the hot paths the task names are all covered by a scenario" do
    ids =
      Scenarios.all(%{workspace: "w", root_id: "r", base_url: nil})
      |> Enum.map(& &1.id)

    for required <- [
          "page_load",
          "cmdb_index",
          "ci_detail",
          "graph_traversal_depth5",
          "graphql_complex_list"
        ] do
      assert required in ids, "no scenario measures #{required}"
    end
  end

  defp triple(id) do
    row = Budget.row(id)
    {row.p50, row.p95, row.p99}
  end
end
