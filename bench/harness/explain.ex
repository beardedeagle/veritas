defmodule Veritas.Core.Bench.Explain do
  @moduledoc """
  The `EXPLAIN` gate.

  `docs/13` §The Database Budget says it plainly: "Every hot query carries an
  `EXPLAIN` check in CI: a `TableScan` where an `IndexScan` was expected
  fails the build."

  This module is that check. It defines the hot queries **from the budget**
  — the paths the latency budget names and the store paths the database
  budget prices — runs `EXPLAIN` on each, and reports the plan the store
  actually chose.

  ## The statements are the Adapter's statements

  Each hot query below is the statement the Adapter issues, transcribed from
  `apps/veritas_core/lib/veritas/store/surreal.ex`. A gate that checked a
  different statement would be checking something the product does not run.
  A test in `apps/veritas_core/test/veritas_core/bench/` asserts that these
  statements still appear in the Adapter, so a change to the Adapter's SQL
  cannot silently make the gate check a query that no longer exists.

  ## What counts as a pass

  A query passes when the plan uses the access method it needs:

    * a **relation hop** must be an `IndexScan` or the engine's own
      `GraphEdgeScan`. A `TableScan` on an edge table means every hop reads
      every edge in the Workspace.
    * a **point read** must be a `RecordIdScan`.
    * the **CMDB list** must be an `IndexScan`. It is a `SELECT ... ORDER BY
      name LIMIT` over the whole Workspace, and at the W3 shape — 500,000
      CIs — a table scan plus a sort is the difference between a page and a
      stall.
    * the **CI type registry** is allowed to scan. It is a small, seeded
      table, and demanding an index there would be a gate against a cost the
      budget does not carry.

  ## The plan is read, not guessed at

  SurrealDB returns a plan as text. The operators are read out of it, and
  the verdict is made from the operators — not from a substring that happens
  to appear in a table name.
  """

  alias Veritas.Core.Bench.Raw

  @type verdict :: :pass | :fail | :warn

  @doc """
  The hot queries, and what each one must get.
  """
  @spec hot_queries(String.t(), String.t()) :: [map()]
  def hot_queries(sample_id \\ "bench_spine_0", workspace \\ "default") do
    [
      %{
        id: "edge_hop_in",
        label: "Relation hop, :in direction",
        statement:
          "SELECT id, in, out, kind FROM ci_depends_on WHERE out = type::record('ci', '#{sample_id}')",
        expect: ["IndexScan", "GraphEdgeScan"],
        why: "every hop of a traversal reads an edge table; a TableScan reads every edge in the Workspace",
        budget_ref: "db_one_hop"
      },
      %{
        id: "edge_hop_out",
        label: "Relation hop, :out direction",
        statement:
          "SELECT id, in, out, kind FROM ci_depends_on WHERE in = type::record('ci', '#{sample_id}')",
        expect: ["IndexScan", "GraphEdgeScan"],
        why: "the mirror of the :in hop, and the one the impact traversal takes",
        budget_ref: "db_one_hop"
      },
      %{
        id: "ci_list",
        label: "CMDB list",
        statement:
          "SELECT * FROM ci WHERE workspace = type::record('workspace', '#{workspace}') ORDER BY name ASC LIMIT 1000",
        expect: ["IndexScan"],
        why:
          "the CMDB index page reads the Workspace's CIs in name order, and the Workspace predicate is what lets the composite index serve it",
        budget_ref: "db_point_read"
      },
      %{
        id: "ci_point_read",
        label: "CI point read",
        statement: "SELECT * FROM ci:#{sample_id}",
        expect: ["RecordIdScan"],
        why: "a point read that scans is a point read that is not one",
        budget_ref: "db_point_read"
      },
      %{
        id: "ticket_scan",
        label: "Ticket hop inside the impact path",
        statement:
          "SELECT id, in, out, kind FROM ticket_affects WHERE out IN [type::record('ci', '#{sample_id}')]",
        expect: ["IndexScan", "GraphEdgeScan"],
        why:
          "the impact path finds a ticket through the ticket-to-CI edge tables; a scan reads every edge in the Workspace",
        budget_ref: "db_impact_depth3"
      },
      %{
        id: "ticket_point_read",
        label: "Ticket point read inside the impact path",
        statement: "SELECT * FROM ticket WHERE id = ticket:#{sample_id}",
        expect: ["RecordIdScan"],
        why:
          "the impact path reads the ticket rows it found by their record id; a scan reads every ticket in the Workspace",
        budget_ref: "db_point_read"
      },
      %{
        id: "relation_kind_read",
        label: "Relation kind registry read",
        statement: "SELECT * FROM relation_kind:depends_on",
        expect: ["RecordIdScan"],
        why: "the traversal reads the registry on every hop; it is a point read",
        budget_ref: "db_one_hop"
      },
      %{
        id: "ci_type_registry",
        label: "CI type registry",
        statement: "SELECT * FROM ci_type ORDER BY id ASC",
        expect: ["TableScan", "IndexScan"],
        why: "a small seeded registry; a scan here is the right plan and is not worth an index",
        budget_ref: nil
      }
    ]
  end

  @doc """
  Runs `EXPLAIN` on every hot query and returns a verdict for each.
  """
  @spec check(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def check(workspace, opts \\ []) do
    sample_id = Keyword.get(opts, :sample_id, "bench_spine_0")

    results =
      Enum.map(hot_queries(sample_id, workspace), fn query ->
        case explain(query.statement, workspace) do
          {:ok, plan} ->
            evaluate(query, plan)

          {:error, reason} ->
            Map.merge(query, %{
              verdict: :fail,
              plan: nil,
              operators: [],
              reason: "EXPLAIN failed: #{inspect(reason)}"
            })
        end
      end)

    {:ok, results}
  end

  @doc """
  The `EXPLAIN` of one statement, as the plan text.
  """
  @spec explain(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def explain(statement, workspace) do
    case Raw.statement("EXPLAIN #{statement};", workspace) do
      {:ok, [first | _]} ->
        case first do
          %{"result" => plan} when is_binary(plan) -> {:ok, plan}
          %{"status" => status, "result" => plan} when status != "OK" -> {:error, plan}
          other -> {:error, {:unexpected_explain, other}}
        end

      {:ok, other} ->
        {:error, {:unexpected_explain, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The access operators a plan uses.

    * `"IndexScan"` — the index was used.
    * `"TableScan"` — the table was read in full.
    * `"RecordIdScan"` — a record id was addressed directly.
    * `"GraphEdgeScan"` — the engine's own edge traversal.

  The plan is a tree, and more than one operator can appear in it: a
  `GraphEdgeScan` over a `RecordIdScan` is the engine reading one record and
  walking its edges, which is a pass.
  """
  @spec operators(String.t()) :: [String.t()]
  def operators(plan) when is_binary(plan) do
    plan
    |> String.split(~r/\s+/)
    |> Enum.map(&String.split(&1, "[") |> hd())
    |> Enum.filter(&(&1 =~ ~r/Scan\z/))
    |> Enum.uniq()
  end

  @doc """
  Whether the plan pushed its predicate into the index.

  SurrealDB reports `pre_decode_filter: no (unsupported predicate)` when it
  cannot decode the predicate before the scan. An index that is present but
  whose predicate is not pushed down still reads more rows than it needs, so
  the gate reports it as a warning even when the access method is right.
  """
  @spec predicate_pushed_down?(String.t()) :: boolean()
  def predicate_pushed_down?(plan) when is_binary(plan) do
    not String.contains?(plan, "pre_decode_filter: no")
  end

  @doc """
  The verdict for one query and the plan the store chose for it.

  The plan is read for its access operators, and the verdict is made from
  them. A plan that uses the expected access method but could not push its
  predicate into the index is a **warning**: the index is there, and it
  still reads more rows than it needs.
  """
  @spec evaluate(map(), String.t()) :: map()
  def evaluate(query, plan) do
    operators = operators(plan)
    expected = query.expect

    cond do
      Enum.any?(operators, &(&1 in expected)) and not predicate_pushed_down?(plan) ->
        Map.merge(query, %{
          verdict: :warn,
          plan: plan,
          operators: operators,
          reason: "the expected access method was used, but the predicate was not pushed into the index"
        })

      Enum.any?(operators, &(&1 in expected)) ->
        Map.merge(query, %{verdict: :pass, plan: plan, operators: operators, reason: nil})

      "TableScan" in operators ->
        Map.merge(query, %{
          verdict: :fail,
          plan: plan,
          operators: operators,
          reason:
            "TableScan where #{Enum.join(expected, " or ")} was expected — #{query.why}"
        })

      true ->
        Map.merge(query, %{
          verdict: :fail,
          plan: plan,
          operators: operators,
          reason:
            "the plan used #{Enum.join(operators, ", ")}, none of which is #{Enum.join(expected, " or ")}"
        })
    end
  end
end
