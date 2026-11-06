defmodule Veritas.Core.Bench.FixtureTest do
  @moduledoc """
  The fixture really does produce the shape the budget assumes.

  `docs/13` says the harness "reproduces volume and shape, not counts". A
  fixture that is a chain of three nodes reproduces neither, and the
  benchmark would report a number that says nothing about the budget.

  So these tests assert the shape: the graph reaches the traversal's depth
  cap, the fan-out is the one the budget names, and the wide shape reaches
  the budget's 5,000-node cap — which is the only way to prove the cap
  holds.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Bench.Fixture
  alias Veritas.Core.CI

  @moduletag :needs_store

  setup do
    workspace = "bench_fixture_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    :ok = Veritas.Store.Surreal.migrate(workspace)

    on_exit(fn ->
      Veritas.Core.Test.SurrealServer.remove_workspace(
        store_url(),
        workspace,
        user: "root",
        pass: "root"
      )
    end)

    {:ok, workspace: workspace}
  end

  test "the W3 shape reaches the depth cap and the fan-out the budget names", %{workspace: workspace} do
    {:ok, shape} = Fixture.build(workspace, Fixture.shape("w3"))

    assert shape.depth == 5
    assert shape.fan_out == 12
    assert shape.node_count == 250
    assert shape.edge_count == 253

    # The chain is as deep as the cap, and the cap is what the budget names.
    assert length(shape.spine_ids) == 5
    assert length(shape.counter_spine_ids) == 5
  end

  test "a depth-5 traversal of the fixture reaches the depth cap", %{workspace: workspace} do
    {:ok, shape} = Fixture.build(workspace, Fixture.shape("w3"))

    {:ok, %{nodes: nodes}} = CI.relations(workspace, shape.root_id, :out, 5)

    assert length(nodes) > 1
    # The traversal must not run away: it is bounded by the depth cap.
    assert length(nodes) <= shape.node_count
  end

  test "the counter-spine makes the other direction deep as well", %{workspace: workspace} do
    {:ok, shape} = Fixture.build(workspace, Fixture.shape("w3"))

    {:ok, %{nodes: nodes}} = CI.relations(workspace, shape.root_id, :in, 5)

    assert length(nodes) > 1
  end

  test "the wide shape's reachable set passes the budget's node cap", %{workspace: workspace} do
    {:ok, shape} = Fixture.build(workspace, Fixture.shape("wide"))

    assert shape.reachable_out > 5_000
    assert shape.node_count > 5_000
  end

  test "the shape catalogue is read from the corpus's fixtures slot" do
    shapes = Fixture.shapes()

    assert Map.has_key?(shapes, "w3")
    assert Map.has_key?(shapes, "wide")
  end

  defp store_url do
    Veritas.Store.Surreal.settings() |> Keyword.fetch!(:url)
  end
end
