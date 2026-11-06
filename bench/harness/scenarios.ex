defmodule Veritas.Core.Bench.Scenarios do
  @moduledoc """
  The operations the budget names, and the code path each one exercises.

  Every scenario says which budget rows it answers to. A scenario that
  answers to no row is reported and **not gated**: the corpus has not
  budgeted it, and a threshold the harness invented would be a threshold
  nobody agreed to.

  ## The scenarios

    * `page_load` — `GET /`, the shell.
    * `cmdb_index` — `GET /cmdb/cis`, the CMDB index. It answers to the
      **page load** row: `docs/13` has no separate row for the CMDB index,
      and a page load is a page load.
    * `ci_detail` — `GET /cmdb/cis/<id>`, the CI detail page with its impact
      graph.
    * `graph_traversal_depth5` — the traversal at the depth cap, in both
      directions. Both are measured because they take different paths
      through the Adapter.
    * `store_impact_depth3` — the impact analysis at the depth the budget
      prices.
    * `store_point_read` — the point read.
    * `store_relation_hop` — one hop, which is the unit the traversal is
      made of.
    * `graphql_complex_list` — the list of 100 CIs with a depth-5 impact
      traversal, which is what the budget's "10 relations, 100 rows" names.

  ## Sample counts

  The sample count is per scenario and it is **printed beside every
  percentile**, because a p95 over five samples is the maximum of five
  samples and the reader has to know that.

  The traversals are sampled five times, not thirty. With the Adapter as it
  stands, one depth-5 traversal of the W3 shape costs hundreds of store
  round trips, and thirty samples of that is a coffee break nobody asked
  for. When the traversal gets faster, the sample count is a flag away.
  """

  alias Veritas.Core.Bench.Web
  alias Veritas.Core.CI

  @default_samples 30
  @traversal_samples 5

  @graphql_complex_list """
  query BenchComplexList($workspace: String!, $ciId: String!) {
    cis(workspace: $workspace, limit: 100) {
      id
      name
      ci_type
      criticality
      lifecycle_state
    }
    impact(workspace: $workspace, ciId: $ciId, depth: 5) {
      ci_id
      dependents { id name }
      services { id name }
    }
  }
  """

  @doc """
  The scenarios, given the run's context.

  The context is a map with the Workspace, the fixture's root CI, and the
  base url of the running endpoint.
  """
  @spec all(map()) :: [map()]
  def all(context) do
    web = Map.get(context, :base_url)
    workspace = context.workspace
    root = context.root_id

    [
      %{
        id: "page_load",
        label: "Page load — GET /",
        budgets: ["page_load"],
        samples: @default_samples,
        kind: :web,
        run: fn -> page(web, "/") end
      },
      %{
        id: "cmdb_index",
        label: "CMDB index — GET /cmdb/cis",
        budgets: ["page_load"],
        samples: @default_samples,
        kind: :web,
        run: fn -> page(web, "/cmdb/cis?workspace=#{workspace}") end
      },
      %{
        id: "ci_detail",
        label: "CI detail + impact graph — GET /cmdb/cis/:id",
        budgets: ["ci_detail_impact"],
        samples: @default_samples,
        kind: :web,
        run: fn -> page(web, "/cmdb/cis/#{root}?workspace=#{workspace}") end
      },
      %{
        id: "graphql_complex_list",
        label: "GraphQL complex list — 100 CIs + depth-5 impact",
        budgets: ["graphql_complex_list"],
        samples: @default_samples,
        kind: :graphql,
        run: fn ->
          Web.graphql(@graphql_complex_list, %{"workspace" => workspace, "ciId" => root})
        end
      },
      %{
        id: "store_point_read",
        label: "Point read by record id",
        budgets: ["db_point_read"],
        samples: @default_samples,
        kind: :store,
        run: fn -> CI.get(workspace, root) end
      },
      %{
        id: "store_relation_hop",
        label: "One-hop relation expansion",
        budgets: ["db_one_hop"],
        samples: @default_samples,
        kind: :store,
        run: fn -> CI.relations(workspace, root, :out, 1) end
      },
      %{
        id: "store_impact_depth3",
        label: "Impact traversal, depth 3",
        budgets: ["db_impact_depth3"],
        samples: @traversal_samples,
        kind: :store,
        run: fn -> CI.impact(workspace, root, 3) end
      },
      %{
        id: "graph_traversal_depth5",
        label: "Graph traversal at the depth cap, :out direction",
        budgets: ["graph_traversal_depth5", "db_depth5_5000"],
        samples: @traversal_samples,
        kind: :store,
        run: fn -> CI.relations(workspace, root, :out, 5) end
      },
      %{
        id: "graph_traversal_depth5_in",
        label: "Graph traversal at the depth cap, :in direction",
        budgets: ["graph_traversal_depth5", "db_depth5_5000"],
        samples: @traversal_samples,
        kind: :store,
        run: fn -> CI.relations(workspace, root, :in, 5) end
      }
    ]
  end

  @doc """
  The GraphQL document the complex-list scenario sends.
  """
  @spec graphql_complex_list() :: String.t()
  def graphql_complex_list, do: @graphql_complex_list

  defp page(nil, _path), do: {:error, :no_endpoint}
  defp page(base_url, path) do
    case Web.get(base_url, path) do
      {:ok, status, body} when status in 200..299 -> {:ok, %{status: status, bytes: byte_size(body)}}
      {:ok, status, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
