defmodule Veritas.Core.Bench.Fixture do
  @moduledoc """
  The graph the budget assumes, at a size a laptop can hold.

  `docs/13` says the harness "reproduces volume and shape, not counts", and
  the shape it names is the one from the W3 workload row: a CI graph deep
  enough to reach the traversal's depth cap and wide enough to reach its node
  budget. A 500,000-CI corpus is not needed for that, and a benchmark that
  needs one is a benchmark that only runs on one machine.

  ## The shape

  A **spine** of `depth` CIs, each depending on the next. A **counter-spine**
  of `depth` CIs hanging off the spine's head, so the *other* direction is
  deep too — a fixture that is deep in one direction only would leave half
  the traversal paths untested. At every spine node, `fan_out` CIs it depends
  on and `fan_in` CIs that depend on it, so both directions are wide as well
  as deep.

  The defaults — depth 5, fan-out 12 — are the W3 shape and the depth cap
  from `docs/13`. The default fixture is 250 CIs and 249 edges.

  ## The breadth cap

  The budget caps **nodes**, not just depth: "every traversal carries a node
  budget and returns a partial result with a truncation marker". A fixture
  that never exceeds the node budget cannot prove the cap holds, so the
  `:wide` shape exists: its fan-out is large enough that the reachable set
  from the spine head passes 5,000 nodes, and a traversal that returns more
  than 5,000 nodes — or that returns 5,000 without saying it truncated — is a
  defect the harness reports.

  ## How it is seeded

  Through the product's own write path — `Veritas.Store.put/3` and
  `Veritas.Store.relate/5` — inside **one** transaction, which the Adapter
  sends as one request. The rows are shaped exactly as
  `Veritas.Core.CI.create/2` shapes them, so the fixture is data the product
  could have written itself, and seeding 250 CIs costs one round trip rather
  than 250.

  The fixture writes no Audit Log rows. It writes to a scratch Workspace of
  its own, which the harness removes afterwards; the Audit Log's integrity is
  proved by the test suite, not by a benchmark fixture.
  """

  alias Veritas.Core.CI
  alias Veritas.Store

  @default_depth 5
  @default_fan_out 12
  @default_fan_in 12
  @wide_fan_out 1_000

  @type shape :: %{
          workspace: String.t(),
          root_id: String.t(),
          spine_ids: [String.t()],
          counter_spine_ids: [String.t()],
          depth: pos_integer(),
          fan_out: non_neg_integer(),
          fan_in: non_neg_integer(),
          node_count: non_neg_integer(),
          edge_count: non_neg_integer(),
          reachable_out: non_neg_integer(),
          reachable_in: non_neg_integer(),
          ci_type: String.t()
        }

  @doc """
  The default shape: depth 5, fan-out 12, fan-in 12.
  """
  @spec default_shape() :: keyword()
  def default_shape, do: [depth: @default_depth, fan_out: @default_fan_out, fan_in: @default_fan_in]

  @doc """
  The shape that reaches the node budget: deep and wide enough that the
  reachable set from the spine head passes 5,000 nodes.
  """
  @spec wide_shape() :: keyword()
  def wide_shape, do: [depth: @default_depth, fan_out: @wide_fan_out, fan_in: 0]

  @doc """
  The shape catalogue, read from `bench/fixtures/shapes.json`.

  The shapes are data, and they live in the corpus's `fixtures/` slot rather
  than in the instrument, so that adding a shape is a data change and not a
  code change.
  """
  @spec shapes() :: map()
  def shapes do
    path = Path.join([Path.dirname(__DIR__), "fixtures", "shapes.json"])

    with {:ok, body} <- File.read(path),
         {:ok, %{"shapes" => shapes}} <- Jason.decode(body) do
      shapes
    else
      _ -> %{}
    end
  end

  @doc """
  The named shape, as the options `build/2` takes.
  """
  @spec shape(String.t()) :: keyword()
  def shape(name) do
    case Map.get(shapes(), name) do
      nil ->
        raise ArgumentError, "no fixture shape named #{inspect(name)}"

      shape ->
        [
          depth: shape["depth"],
          fan_out: shape["fan_out"],
          fan_in: shape["fan_in"]
        ]
    end
  end

  @doc """
  Builds the fixture in `workspace` and returns its shape.

  The Workspace is migrated first if it has not been, because the fixture
  needs the relation kinds and the CI types the schema seeds.
  """
  @spec build(String.t(), keyword()) :: {:ok, shape()} | {:error, term()}
  def build(workspace, opts \\ []) do
    depth = Keyword.get(opts, :depth, @default_depth)
    fan_out = Keyword.get(opts, :fan_out, @default_fan_out)
    fan_in = Keyword.get(opts, :fan_in, @default_fan_in)

    with {:ok, ci_type} <- ci_type(workspace),
         {:ok, plan} <- plan(depth, fan_out, fan_in) do
      case seed(workspace, ci_type, plan) do
        :ok ->
          {:ok,
           %{
             workspace: workspace,
             root_id: hd(plan.spine),
             spine_ids: plan.spine,
             counter_spine_ids: plan.counter_spine,
             depth: depth,
             fan_out: fan_out,
             fan_in: fan_in,
             node_count: length(plan.nodes),
             edge_count: length(plan.edges),
             reachable_out: plan.reachable_out,
             reachable_in: plan.reachable_in,
             ci_type: ci_type
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes the fixture's Workspace from the store.

  A benchmark that leaves its data behind is a benchmark that changes the
  thing it measures on the next run.
  """
  @spec cleanup(String.t(), keyword()) :: :ok
  def cleanup(workspace, opts \\ []) do
    url = Keyword.get(opts, :url) || "http://127.0.0.1:8010"
    credentials = Keyword.get(opts, :credentials, [])

    Veritas.Core.Test.SurrealServer.remove_workspace(url, workspace, credentials)
  end

  # ── the plan ──────────────────────────────────────────────────────────────

  # The plan is the set of nodes and edges, worked out before anything is
  # written, so the fixture knows what shape it built and can report it.
  defp plan(depth, fan_out, fan_in) do
    spine = for i <- 0..(depth - 1), do: "bench_spine_#{i}"
    counter_spine = for j <- 0..(depth - 1), do: "bench_counter_#{j}"

    # The spine: each CI depends on the next, so the dependency chain runs
    # spine[0] -> spine[1] -> ... -> spine[depth - 1].
    spine_edges =
      spine
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> {a, b} end)

    # The counter-spine hangs off the spine's head: the last counter node
    # depends on spine[0], so the *dependents* of spine[0] are a chain too.
    counter_edges = Enum.map(counter_spine, &{&1, hd(spine)}) ++ counter_spine_chain(counter_spine)

    # Fan-out: CIs each spine node depends on. Fan-in: CIs that depend on it.
    #
    # A fan of zero is no fan, and `0..-1` is not an empty range — it is
    # `[0, -1]`, which would name a CI `bench_in_0_-1` and be refused by the
    # store as an invalid record id. The wide shape has no fan-in, so the
    # empty case has to be empty.
    {fan_nodes, fan_edges} =
      Enum.reduce(Enum.with_index(spine ++ counter_spine), {[], []}, fn {node, index}, {nodes, edges} ->
        outs = if fan_out > 0, do: for(j <- 0..(fan_out - 1), do: "bench_out_#{index}_#{j}"), else: []
        ins = if fan_in > 0, do: for(j <- 0..(fan_in - 1), do: "bench_in_#{index}_#{j}"), else: []

        new_nodes = outs ++ ins
        new_edges =
          Enum.map(outs, &{node, &1}) ++ Enum.map(ins, &{&1, node})

        {nodes ++ new_nodes, edges ++ new_edges}
      end)

    nodes = spine ++ counter_spine ++ fan_nodes
    edges = spine_edges ++ counter_edges ++ fan_edges

    {:ok,
     %{
       nodes: nodes,
       edges: edges,
       spine: spine,
       counter_spine: counter_spine,
       # What a depth-capped traversal of the spine head can reach in each
       # direction. These are the counts the harness compares the traversal's
       # result against.
       reachable_out: reach(spine, fan_out, depth),
       reachable_in: reach(counter_spine, fan_in, depth)
     }}
  end

  defp counter_spine_chain(counter_spine) do
    counter_spine
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  # The reachable count of a chain of `depth` nodes with `fan` extra nodes at
  # each level: the chain itself plus the fan at each level the traversal
  # reaches.
  defp reach(_chain, 0, _depth), do: 0

  defp reach(_chain, fan, depth) do
    depth + depth * fan
  end

  # ── the seed ──────────────────────────────────────────────────────────────

  # How many rows go in one transaction. The wide shape is five thousand CIs
  # and their edges, and the store refuses a request whose body is longer
  # than it will take — "length limit exceeded", HTTP 413 — so the seed is
  # batched rather than one enormous request.
  @seed_batch 400

  defp seed(workspace, ci_type, plan) do
    now = DateTime.utc_now()

    with :ok <- seed_rows(workspace, ci_type, plan.nodes, now),
         :ok <- seed_edges(workspace, plan.edges) do
      :ok
    end
  end

  # The CIs are written first, in batches, because an edge needs both of its
  # ends to exist before it can be written.
  defp seed_rows(workspace, ci_type, ids, now) do
    ids
    |> Enum.with_index()
    |> Enum.chunk_every(@seed_batch)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      result =
        Store.transaction(workspace, fn tx ->
          Enum.each(chunk, fn {id, index} ->
            {:ok, _ci} =
              Store.put(tx, :ci, %{
                "id" => id,
                "workspace" => workspace,
                "ci_type" => ci_type,
                "name" => name_for(id),
                "lifecycle_state" => "active",
                "criticality" => "medium",
                "attributes" => %{},
                "baseline_version" => 0,
                "actual_version" => 0,
                "owner" => nil,
                "sequence" => index + 1,
                "created_at" => now,
                "updated_at" => now,
                "deleted_at" => nil
              })
          end)

          :ok
        end)

      case result do
        {:error, reason} -> {:halt, {:error, reason}}
        _other -> {:cont, :ok}
      end
    end)
  end

  defp seed_edges(workspace, edges) do
    edges
    |> Enum.chunk_every(@seed_batch)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      result =
        Store.transaction(workspace, fn tx ->
          Enum.each(chunk, fn {from, to} ->
            {:ok, _edge} = Store.relate(tx, "depends_on", from, to, %{})
          end)

          :ok
        end)

      case result do
        {:error, reason} -> {:halt, {:error, reason}}
        _other -> {:cont, :ok}
      end
    end)
  end

  defp name_for(id) do
    id |> String.replace("_", " ") |> String.capitalize()
  end

  # The CI type the fixture's rows carry. The schema requires one, and the
  # Adapter supplies the seeded default when the caller names none; the
  # fixture asks the store what it has rather than assuming, so a Workspace
  # whose seed has changed fails loudly instead of writing rows the schema
  # refuses.
  defp ci_type(workspace) do
    case CI.types(workspace) do
      {:ok, [%{"id" => id} | _]} ->
        {:ok, id}

      {:ok, []} ->
        {:error, :no_ci_type}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
