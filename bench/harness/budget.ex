defmodule Veritas.Core.Bench.Budget do
  @moduledoc """
  The budget, as data.

  Every row here is transcribed from `docs/13-performance-budget.md`, and every
  row carries the section it came from. The harness does not hold a second,
  private set of thresholds: a number that is not in the corpus is a number
  the corpus has not agreed to, and a gate against an unagreed number is a
  gate against a guess.

  ## The two kinds of row

  `docs/13` states its budget in two shapes.

  The **§Latency Budgets** table gives p50, p95 and p99 per user-visible
  operation. The harness gates on p95, because that is what §Performance
  Engineering Process names: "budget breach: any §4/§5 row measured above its
  p95 target, reported with the owning Node Role".

  The **§The Database Budget** table gives a single range per store path —
  "point read by id 0.5-2ms". It is read here as a **p95** target at the top
  of the range, and the range itself is kept in the row so the report shows
  the corpus's own words rather than only the bound the gate uses. That
  reading is an interpretation and it is labelled as one in the report.

  ## Rows with no budget

  A scenario the corpus has not budgeted is reported and **not gated**. The
  harness says so out loud rather than inventing a threshold, because a gate
  against a threshold nobody wrote down is a gate that fails for a reason
  nobody can act on.
  """

  @latency_source "docs/13 §Latency Budgets"
  @database_source "docs/13 §The Database Budget"

  # The row the depth-5 traversal's budget is read from. The gate derives its
  # round-trip ceiling from it and the report prints it, and both read it
  # through `depth5_budget_us/0`, so there is one number rather than two
  # places that happen to agree today.
  @depth5_row "db_depth5_5000"

  @doc """
  Every budget row, in the order the report prints them.
  """
  @spec rows() :: [map()]
  def rows do
    latency_rows() ++ database_rows()
  end

  @doc """
  The budget row with the given id, or `nil`.
  """
  @spec row(String.t()) :: map() | nil
  def row(id) do
    Enum.find(rows(), &(&1.id == id))
  end

  @doc """
  The depth-5 traversal's budget, in microseconds.

  The budget is written in milliseconds and the measurements are taken in
  microseconds, so the conversion happens **here**, once, rather than in each
  of the two places that use the number.

  The gate derives the round-trip ceiling from it; the report prints it.
  Neither reads a literal, so a change to the budget moves both of them
  together and they cannot drift apart.

  `nil` when the row is not in the budget. That is not a number to guess at:
  the gate treats it as a failure, and the report says so.
  """
  @spec depth5_budget_us() :: pos_integer() | nil
  def depth5_budget_us do
    case row(@depth5_row) do
      nil -> nil
      row -> trunc(row.p95 * 1_000)
    end
  end

  @doc """
  The id of the row the depth-5 budget is read from.
  """
  @spec depth5_row_id() :: String.t()
  def depth5_row_id, do: @depth5_row

  @doc """
  The budget rows with the given ids, in the order the ids are given.

  A scenario names the rows it answers to. A scenario that names no row has
  no budget, and the report says that rather than guessing one.
  """
  @spec rows_for([String.t()]) :: [map()]
  def rows_for(ids) when is_list(ids) do
    Enum.map(ids, fn id ->
      case row(id) do
        nil -> raise ArgumentError, "no budget row named #{inspect(id)}"
        found -> found
      end
    end)
  end

  defp latency_rows do
    [
      row("page_load", "Page load (cold)", "page_load", 120, 300, 600, @latency_source),
      row("liveview_mount", "LiveView mount + first render", "liveview_mount", 180, 400, 900,
        @latency_source),
      row("liveview_push", "LiveView push after a ticket change", "liveview_push", 60, 150, 400,
        @latency_source),
      row("ticket_queue_filter", "Ticket queue filter (50 rows)", "ticket_queue_filter", 30, 50, 120,
        @latency_source),
      row("ci_detail_impact", "CI detail + impact graph (depth 3)", "ci_detail_impact", 120, 500, 1_200,
        @latency_source),
      row("graph_traversal_depth5", "Graph traversal at the depth-5 cap", "graph_traversal_depth5",
        300, 900, 2_000, @latency_source),
      row("dashboard_aggregate", "Dashboard aggregate (5 panels)", "dashboard_aggregate", 80, 200, 600,
        @latency_source),
      row("graphql_simple", "GraphQL simple query", "graphql_simple", 30, 90, 250, @latency_source),
      row("graphql_complex_list", "GraphQL complex list (10 relations, 100 rows)", "graphql_complex_list",
        150, 400, 1_000, @latency_source),
      row("search_keyword", "Search — keyword", "search_keyword", 50, 150, 400, @latency_source),
      row("search_semantic", "Search — semantic top-20", "search_semantic", 120, 300, 900,
        @latency_source),
      row("ticket_create", "Ticket create (one transaction)", "ticket_create", 60, 200, 600,
        @latency_source),
      row("ticket_transition", "Ticket transition", "ticket_transition", 50, 150, 400, @latency_source),
      row("ingest_ack", "Ingest ack (accepted, not persisted)", "ingest_ack", 5, 15, 50, @latency_source),
      row("webhook_delivery", "Webhook delivery (first attempt)", "webhook_delivery", 200, 1_500, 8_000,
        @latency_source),
      row("agent_suggestion", "Agent suggestion (first token streamed)", "agent_suggestion", 800, 3_000,
        9_000, @latency_source),
      row("approval_action", "Approval action (human approve/reject)", "approval_action", 60, 200, 600,
        @latency_source)
    ]
  end

  defp database_rows do
    [
      db_row("db_point_read", "Point read by record id", "store_point_read", 0.5, 2.0, @database_source),
      db_row("db_one_hop", "One-hop relation expansion (100 rows)", "store_relation_hop", 5.0, 20.0,
        @database_source),
      db_row("db_impact_depth3", "Impact traversal depth 3, fan-out 12", "store_impact_depth3", 40.0,
        150.0, @database_source),
      db_row("db_depth5_5000", "Depth 5 over 5,000 nodes", "graph_traversal_depth5_store", 150.0, 500.0,
        @database_source),
      db_row("db_hybrid_search", "Hybrid search top-20", "search_semantic", 20.0, 120.0,
        @database_source),
      db_row("db_time_series_24h", "Time-series range over 24 h", "db_time_series_24h", 1.0, 5.0,
        @database_source)
    ]
  end

  defp row(id, label, scenario, p50, p95, p99, source) do
    %{
      id: id,
      label: label,
      scenario: scenario,
      p50: p50,
      p95: p95,
      p99: p99,
      unit: :ms,
      source: source,
      kind: :latency
    }
  end

  defp db_row(id, label, scenario, low, high, source) do
    %{
      id: id,
      label: label,
      scenario: scenario,
      # The corpus gives a range, not percentiles. The gate reads the top of
      # the range as the p95 target; the range is kept so the report can
      # print the corpus's own words.
      range: [low, high],
      p50: low,
      p95: high,
      p99: high,
      unit: :ms,
      source: source,
      kind: :database
    }
  end
end
