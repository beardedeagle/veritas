defmodule Veritas.Core.Bench.ExplainTest do
  @moduledoc """
  Reading the plan, and deciding what it means.

  The plans in these tests are the ones SurrealDB 3.3.4 actually returned for
  the statements the Adapter issues — they were measured, not written from
  memory. A plan is read, not guessed at: the verdict is made from the
  access operators in it.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Bench.Explain

  @index_scan """
  SelectProject [ctx: Db] [projections: id, in, out, kind]
      IndexScan [ctx: Db] [index: probe_rel_out, access: = ci:abc, direction: Forward, predicate: out = ci:abc]
  """

  @table_scan """
  SelectProject [ctx: Db] [projections: id, in, out, kind]
      TableScan [ctx: Db] [table: ci_depends_on, direction: Forward, predicate: out = ci:web - 1, pre_decode_filter: no (unsupported predicate)]
  """

  @graph_edge_scan """
  Project [ctx: Db]
    field.lookup: GraphEdgeScan [ctx: Db] [direction: ->, tables: probe_rel, output: TargetVertex]
        CurrentValueSource [ctx: Rt]
      RecordIdScan [ctx: Db] [record_id: ci:abc]
  """

  describe "operators/1" do
    test "finds the access operator in a plan" do
      assert "IndexScan" in Explain.operators(@index_scan)
      assert "TableScan" in Explain.operators(@table_scan)
      assert "GraphEdgeScan" in Explain.operators(@graph_edge_scan)
      assert "RecordIdScan" in Explain.operators(@graph_edge_scan)
    end

    test "does not mistake a table name for an operator" do
      plan = "TableScan [ctx: Db] [table: index_scan_log, direction: Forward]"

      assert Explain.operators(plan) == ["TableScan"]
    end
  end

  describe "predicate_pushed_down?/1" do
    test "is false when the store could not push the predicate into the index" do
      refute Explain.predicate_pushed_down?(@table_scan)
      assert Explain.predicate_pushed_down?(@index_scan)
    end
  end

  describe "evaluate/2" do
    test "a TableScan where an IndexScan was expected fails, and says why" do
      query = real_query("edge_hop_in")

      verdict = Explain.evaluate(query, @table_scan)

      assert verdict.verdict == :fail
      assert verdict.reason =~ "TableScan"
      assert verdict.reason =~ "reads every edge"
    end

    test "an IndexScan passes" do
      verdict = Explain.evaluate(query("edge_hop_in", ["IndexScan", "GraphEdgeScan"]), @index_scan)

      assert verdict.verdict == :pass
      assert verdict.reason == nil
    end

    test "the engine's own edge traversal passes" do
      verdict = Explain.evaluate(query("edge_hop_in", ["IndexScan", "GraphEdgeScan"]), @graph_edge_scan)

      assert verdict.verdict == :pass
    end

    test "an index that cannot push the predicate down is a warning, not a pass" do
      verdict = Explain.evaluate(query("edge_hop_in", ["IndexScan"]), @table_scan)

      assert verdict.verdict == :fail
    end

    test "a point read that scans fails" do
      verdict = Explain.evaluate(query("ci_point_read", ["RecordIdScan"]), @table_scan)

      assert verdict.verdict == :fail
    end
  end

  describe "hot_queries/1" do
    test "every hot query names the budget row it belongs to" do
      for query <- Explain.hot_queries("bench_spine_0") do
        assert query.statement =~ ~r/^SELECT /
        assert query.expect != []
        assert query.why != ""
      end
    end

    test "the CI type registry is allowed to scan — it is a small seeded table" do
      query = Enum.find(Explain.hot_queries(), &(&1.id == "ci_type_registry"))

      assert "TableScan" in query.expect
    end
  end

  defp real_query(id) do
    Enum.find(Explain.hot_queries(), &(&1.id == id))
  end

  defp query(id, expect) do
    %{
      id: id,
      label: id,
      statement: "SELECT ...",
      expect: expect,
      why: "a reason",
      budget_ref: nil
    }
  end
end
