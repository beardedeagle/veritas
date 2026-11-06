defmodule Veritas.Core.Bench.AdapterStatementsTest do
  @moduledoc """
  The gate checks the queries the product actually runs.

  The EXPLAIN gate's statements are transcribed from the Adapter. If the
  Adapter's SQL changes and the gate is not changed with it, the gate is
  checking a query the product no longer issues — and it would report a
  clean bill of health for a query nobody runs.

  So this test reads the Adapter's source and asserts that the statements
  the gate checks are still the statements the Adapter writes. When the
  Adapter's SQL changes, this fails and says what to update.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Bench.Explain

  @adapter "apps/veritas_core/lib/veritas/store/surreal.ex"

  setup do
    path = Path.expand(Path.join([repo_root(), @adapter]))

    unless File.exists?(path) do
      flunk("the Adapter is not at #{path}")
    end

    {:ok, source: File.read!(path)}
  end

  test "the relation hop is still written the way the gate checks it", %{source: source} do
    assert source =~ "SELECT id, in, out, kind FROM"
    assert source =~ "WHERE out = "
    assert source =~ "WHERE in = "
  end

  test "the list is still written the way the gate checks it", %{source: source} do
    assert source =~ "SELECT * FROM \#{table_name(table)}"
    assert source =~ "order_clause"
    assert source =~ "limit_clause"
  end

  test "the list is still scoped to the Workspace, so the composite index can serve it", %{
    source: source
  } do
    assert source =~ "workspace_clause"
    assert source =~ ~s|record_ref("workspace", workspace)|
  end

  test "the point read is still written the way the gate checks it", %{source: source} do
    assert source =~ "SELECT * FROM \#{table_name(table)}:\#{id}"
  end

  test "the impact path finds tickets through the edge tables, not by reading them all", %{
    source: source
  } do
    assert source =~ ~s(row["from_table"] == "ticket")
    refute source =~ "SELECT * FROM ticket"
  end

  test "the gate's hot queries are the ones the Adapter's fragments describe" do
    ids = Enum.map(Explain.hot_queries(), & &1.id)

    for required <- [
          "edge_hop_in",
          "edge_hop_out",
          "ci_list",
          "ci_point_read",
          "ticket_scan",
          "ticket_point_read",
          "relation_kind_read",
          "ci_type_registry"
        ] do
      assert required in ids, "the gate no longer checks #{required}"
    end
  end

  defp repo_root do
    Path.expand(Path.join(__DIR__, "../../.."))
  end
end
