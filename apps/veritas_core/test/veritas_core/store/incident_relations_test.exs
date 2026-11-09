defmodule Veritas.Core.Store.IncidentRelationsFixtures do
  @moduledoc false

  import ExUnit.Assertions
  alias Veritas.Core.Store.Conformance
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.{Config, Memory, Surreal}

  # These are adapter tests, not Incident input handlers. No helper implements
  # desired-set validation, authorization, revision checks or presence markers.
  def prepare(adapter) do
    previous = Application.get_env(:veritas_core, :store)
    previous_surreal = Application.get_env(:veritas_core, :surreal)
    workspaces = [Conformance.scratch_workspace(), Conformance.scratch_workspace()]
    [workspace, other_workspace] = workspaces

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Config.configure({adapter, []})

        case adapter do
          Memory -> cleanup_memory(workspaces)
          Surreal -> Enum.each(workspaces, &StoreCase.remove_workspace/1)
        end
      after
        restore(:store, previous)
        restore(:surreal, previous_surreal)
      end
    end)

    if adapter == Surreal, do: StoreCase.pin_store_configuration()
    Config.configure({adapter, []})

    Enum.each(workspaces, fn ws ->
      if adapter == Surreal, do: assert(:ok = Surreal.migrate(ws))
      seed(ws)
    end)

    %{
      adapter: adapter,
      workspace: workspace,
      other_workspace: other_workspace,
      source: workspace <> "_incident"
    }
  end

  def seed(ws) do
    assert :ok =
             Store.transaction(ws, fn tx ->
               for kind <- ["affects", "implements"] do
                 assert {:ok, _} =
                          Store.put_relation_kind(tx, %{
                            "id" => kind,
                            "from_table" => "ticket",
                            "to_table" => "ci",
                            "inverse" => kind <> "_inverse"
                          })
               end

               for id <- ["ci_a", "ci_b", "ci_c"] do
                 assert {:ok, _} =
                          Store.put(tx, :ci, %{
                            "id" => id,
                            "name" => id,
                            "ci_type" => "unclassified"
                          })
               end

               assert {:ok, _} = Store.put(tx, :ticket, ticket(ws <> "_incident"))
               :ok
             end)
  end

  def ticket(id) do
    %{
      "id" => id,
      "ticket_type" => "incident",
      "state" => "new",
      "title" => "Relation regression fixture",
      "requester" => "fixture_requester",
      "opened_at" => ~U[2026-11-06 12:00:00Z],
      "sequence" => 1
    }
  end

  def edge(id, from, to, attributes \\ %{}) do
    %{"id" => id, "kind" => "affects", "from" => from, "to" => to, "attributes" => attributes}
  end

  def outgoing(ws, source, kind \\ "affects") do
    Store.transaction(ws, &Store.outgoing_relations(&1, kind, source))
  end

  def edges!({:ok, %{edges: edges} = result}) do
    assert Map.keys(result) == [:edges]

    Enum.each(edges, fn edge ->
      assert Enum.sort(Map.keys(edge)) == ["attributes", "from", "id", "kind", "to"]
      assert is_map(edge["attributes"])
    end)

    Enum.sort_by(edges, & &1["id"])
  end

  # Bypass normal creation only to reproduce persisted historical identities and
  # attributes. Reads/removals/transactions under test still use the real port.
  def historical(%{adapter: Memory} = ctx, edges) do
    ops = Enum.map(edges, &{:relate, "affects", Map.put(&1, "workspace", ctx.workspace)})
    assert {:ok, _} = Memory.Server.commit(Memory.Server, ops)
  end

  def historical(%{adapter: Surreal} = ctx, edges) do
    sql!(ctx.workspace, "DEFINE FIELD OVERWRITE note ON ticket_affects TYPE option<string>;")

    statements =
      Enum.map_join(edges, "\n", fn edge ->
        note = Jason.encode!(edge["attributes"]["note"])

        "RELATE ticket:#{edge["from"]}->ticket_affects:#{edge["id"]}->ci:#{edge["to"]} " <>
          "SET kind = 'affects', note = #{note};"
      end)

    sql!(ctx.workspace, statements)
  end

  # Only this test-owned namespace is loosened to model old/corrupt physical
  # rows that today's ENFORCED relation declaration would reject on insertion.
  # This is fixture construction, never a proposed migration or schema repair.
  def damaged_rows!(ctx, statements) do
    sql!(ctx.workspace, """
    REMOVE TABLE ticket_affects;
    DEFINE TABLE ticket_affects SCHEMALESS;
    #{statements}
    """)
  end

  def sql!(workspace, statements) do
    settings = Application.fetch_env!(:veritas_core, :surreal)
    url = Keyword.fetch!(settings, :url)
    user = Keyword.fetch!(settings, :user)
    pass = Keyword.fetch!(settings, :pass)

    request =
      Finch.build(:post, url <> "/sql", [
        {"accept", "application/json"},
        {"content-type", "text/plain"},
        {"surreal-ns", workspace},
        {"surreal-db", workspace},
        {"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}
      ], statements)

    # Never include the request or authorization headers in assertion output.
    case Finch.request(request, :veritas_store_pool, []) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        assert {:ok, results} = Jason.decode(body)
        assert is_list(results) and results != []
        assert Enum.all?(results, &(&1["status"] == "OK")), "historical fixture SQL failed"

      _ ->
        flunk("historical fixture SQL transport failed")
    end
  end

  defp cleanup_memory(workspaces) do
    # Do not stop/reset the application's supervised server. Remove only our
    # namespaces and our uniquely prefixed edges leaked by a broken adapter.
    :sys.replace_state(Memory.Server, fn state ->
      default = Map.get(state.workspaces, "default", %{})

      relations =
        Enum.reject(Map.get(default, :relations, []), fn edge ->
          Enum.any?(workspaces, &String.starts_with?(edge["from"] || "", &1 <> "_"))
        end)

      remaining = Map.drop(state.workspaces, workspaces)

      remaining =
        if Map.has_key?(remaining, "default"),
          do: Map.put(remaining, "default", Map.put(default, :relations, relations)),
          else: remaining

      outbox =
        state.outbox
        |> Map.drop(workspaces)
        |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] in workspaces))
        end)

      %{state | workspaces: remaining, outbox: outbox}
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:veritas_core, key)
  defp restore(key, value), do: Application.put_env(:veritas_core, key, value)
end

defmodule Veritas.Core.Store.IncidentRelationsTest do
  @moduledoc """
  Unrun candidates for VERITAS-INCIDENT-DOMAIN-20261106.

  The exact optional outgoing port returns only `%{edges: [...]}` and never
  performs endpoint lookups. A missing port is an expected pre-implementation
  failure, not observed behavioral RED. These tests do not qualify domain
  omission/null handling, presence markers, authority or revision semantics.
  """
  use ExUnit.Case, async: false

  import Veritas.Core.Store.IncidentRelationsFixtures
  alias Veritas.Store
  alias Veritas.Store.{Error, Memory, Surreal}

  setup %{adapter: adapter} do
    {:ok, ctx: prepare(adapter)}
  end

  for {adapter, label, needs_store} <- [
        {Memory, "Memory", false},
        {Surreal, "Surreal", true}
      ] do
    describe label do
      @describetag adapter: adapter, needs_store: needs_store

      test "no relation mutation preserves existing edges; explicit removals clear only affects", %{ctx: ctx} do
        assert :ok =
                 Store.transaction(ctx.workspace, fn tx ->
                   assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_a", %{})
                   assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_b", %{})
                   assert {:ok, _} = Store.relate(tx, "implements", ctx.source, "ci_a", %{})
                   :ok
                 end)

        before = edges!(outgoing(ctx.workspace, ctx.source))
        assert Enum.sort(Enum.map(before, & &1["to"])) == ["ci_a", "ci_b"]
        unrelated = edges!(outgoing(ctx.workspace, ctx.source, "implements"))
        assert length(unrelated) == 1

        # Storage counterpart of omitted membership: update another field and
        # issue no relation writes. This is not an implementation of omission.
        assert {:ok, _} =
                 Store.transaction(ctx.workspace, fn tx ->
                   {:ok, row} = Store.fetch(tx, :ticket, ctx.source)
                   Store.put(tx, :ticket, Map.put(row, "title", "Content only"))
                 end)

        assert edges!(outgoing(ctx.workspace, ctx.source)) == before

        assert {:ok, %{edges: []}} =
                 Store.transaction(ctx.workspace, fn tx ->
                   assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_a")
                   assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_b")
                   Store.outgoing_relations(tx, "affects", ctx.source)
                 end)

        assert outgoing(ctx.workspace, ctx.source) == {:ok, %{edges: []}}
        assert edges!(outgoing(ctx.workspace, ctx.source, "implements")) == unrelated
      end

      test "endpoint-pair removal deletes historical duplicate IDs without rewriting retained attributes", %{ctx: ctx} do
        keep = edge("historical_keep", ctx.source, "ci_a", %{"note" => "original evidence"})
        remove = edge("historical_random", ctx.source, "ci_b", %{"note" => "old evidence"})
        duplicate = edge("another_random", ctx.source, "ci_b", %{"note" => "second edge"})
        historical(ctx, [keep, remove, duplicate])
        assert edges!(outgoing(ctx.workspace, ctx.source)) == Enum.sort_by([keep, remove, duplicate], & &1["id"])

        assert :ok =
                 Store.transaction(ctx.workspace, fn tx ->
                   assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_b")
                   assert edges!(Store.outgoing_relations(tx, "affects", ctx.source)) == [keep]
                   :ok
                 end)

        assert edges!(outgoing(ctx.workspace, ctx.source)) == [keep]
      end

      test "outgoing reads return every physical edge beyond the ordinary list page size", %{ctx: ctx} do
        # Same endpoints, distinct historical edges: enumeration must neither
        # deduplicate physical identities nor inherit list/traversal truncation.
        expected = for n <- 1..1001, do: edge("history_#{n}", ctx.source, "ci_a", %{"note" => "#{n}"})
        historical(ctx, expected)
        assert edges!(outgoing(ctx.workspace, ctx.source)) == Enum.sort_by(expected, & &1["id"])
      end

      test "buffered additions and removals agree with independent committed readback", %{ctx: ctx} do
        assert {:ok, _} =
                 Store.transaction(ctx.workspace, &Store.relate(&1, "affects", ctx.source, "ci_a", %{}))

        result =
          Store.transaction(ctx.workspace, fn tx ->
            assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_a")
            assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_b", %{})
            assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_b")
            assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_c", %{})
            Store.outgoing_relations(tx, "affects", ctx.source)
          end)

        assert [%{"from" => source, "to" => "ci_c", "kind" => "affects", "attributes" => %{}}] = edges!(result)
        assert source == ctx.source
        assert edges!(outgoing(ctx.workspace, ctx.source)) == edges!(result)
      end

      test "edge and kind-registry scope follows the nondefault transaction Workspace", %{ctx: ctx} do
        for {ws, target} <- [{ctx.workspace, "ci_a"}, {ctx.other_workspace, "ci_b"}] do
          assert :ok =
                   Store.transaction(ws, fn tx ->
                     assert {:ok, _} = Store.put(tx, :ticket, ticket(ctx.source))
                     assert {:ok, _} = Store.relate(tx, "affects", ctx.source, target, %{})
                     :ok
                   end)
        end

        assert [%{"to" => "ci_a"}] = edges!(outgoing(ctx.workspace, ctx.source))
        other = edges!(outgoing(ctx.other_workspace, ctx.source))
        assert [%{"to" => "ci_b"}] = other

        assert :ok = Store.transaction(ctx.workspace, &Store.unrelate(&1, "affects", ctx.source, "ci_a"))
        assert outgoing(ctx.workspace, ctx.source) == {:ok, %{edges: []}}
        assert edges!(outgoing(ctx.other_workspace, ctx.source)) == other

        assert {:ok, %{edges: []}} =
                 Store.transaction(ctx.workspace, fn tx ->
                   assert {:ok, _} = Store.put_relation_kind(tx, %{
                     "id" => "local_only", "from_table" => "ticket", "to_table" => "ci",
                     "inverse" => "local_inverse"
                   })
                   Store.outgoing_relations(tx, "local_only", ctx.source)
                 end)

        assert {:error, %Error{code: :invalid_request, details: %{reason: :unknown_relation_kind}}} =
                 outgoing(ctx.other_workspace, ctx.source, "local_only")
      end

      test "rollback leaves committed edges intact after a visible buffered replacement", %{ctx: ctx} do
        assert {:ok, _} = Store.transaction(ctx.workspace, &Store.relate(&1, "affects", ctx.source, "ci_a", %{}))
        before = edges!(outgoing(ctx.workspace, ctx.source))

        assert {:error, :deliberate_abort} =
                 Store.transaction(ctx.workspace, fn tx ->
                   assert :ok = Store.unrelate(tx, "affects", ctx.source, "ci_a")
                   assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_b", %{})
                   assert [%{"to" => "ci_b"}] = edges!(Store.outgoing_relations(tx, "affects", ctx.source))
                   {:error, :deliberate_abort}
                 end)

        assert edges!(outgoing(ctx.workspace, ctx.source)) == before
      end

      test "known empty kinds do not require a source, but unknown kinds and bad identifiers refuse", %{ctx: ctx} do
        assert outgoing(ctx.workspace, "missing_source") == {:ok, %{edges: []}}
        assert {:error, %Error{code: :invalid_request, details: %{reason: :unknown_relation_kind}}} =
                 outgoing(ctx.workspace, ctx.source, "unknown_kind")

        invalid = "private_identifier'; DELETE ticket; --"

        for {kind, source} <- [{"affects", invalid}, {invalid, ctx.source}, {"affects", nil}, {"affects", %{}}] do
          assert {:error, %Error{code: :invalid_request} = error} = outgoing(ctx.workspace, source, kind)
          refute String.contains?(inspect(error), invalid)
        end
      end

      test "surviving dangling edges remain visible and removable even without their source", %{ctx: ctx} do
        missing_source = ctx.workspace <> "_missing"
        dangling = edge("dangling_history", missing_source, "missing_ci")

        case ctx.adapter do
          Memory -> historical(ctx, [dangling])
          Surreal -> damaged_rows!(ctx, "CREATE ticket_affects:dangling_history SET in = ticket:#{missing_source}, out = ci:missing_ci, kind = 'affects';")
        end

        assert edges!(outgoing(ctx.workspace, missing_source)) == [dangling]
        assert :ok = Store.transaction(ctx.workspace, &Store.unrelate(&1, "affects", missing_source, "missing_ci"))
        assert outgoing(ctx.workspace, missing_source) == {:ok, %{edges: []}}
      end

      test "impact unions legacy ticket.ci and relation matches without duplicates or backfill", %{ctx: ctx} do
        legacy_id = ctx.workspace <> "_legacy"
        both_id = ctx.workspace <> "_both"
        unrelated_id = ctx.workspace <> "_unrelated"

        if ctx.adapter == Surreal do
          # Model a historical column, not a new production membership field.
          sql!(ctx.workspace, "DEFINE FIELD OVERWRITE ci ON ticket TYPE option<record<ci>>;")
        end

        assert :ok =
                 Store.transaction(ctx.workspace, fn tx ->
                   for id <- [legacy_id, both_id, unrelated_id] do
                     assert {:ok, _} = Store.put(tx, :ticket, ticket(id))
                   end
                   assert {:ok, _} = Store.relate(tx, "affects", ctx.source, "ci_a", %{})
                   assert {:ok, _} = Store.relate(tx, "affects", both_id, "ci_a", %{})
                   assert {:ok, _} = Store.relate(tx, "affects", unrelated_id, "ci_b", %{})
                   :ok
                 end)

        case ctx.adapter do
          Memory ->
            assert :ok = Store.transaction(ctx.workspace, fn tx ->
              for id <- [legacy_id, both_id] do
                assert {:ok, _} = Store.put(tx, :ticket, Map.put(ticket(id), "ci", "ci_a"))
              end
              :ok
            end)

          Surreal ->
            sql!(ctx.workspace, "UPDATE ticket:#{legacy_id}, ticket:#{both_id} SET ci = ci:ci_a;")
        end

        assert {:ok, %{tickets: tickets}} = Store.transaction(ctx.workspace, &Store.impact(&1, "ci_a", 1))
        assert Enum.sort(Enum.map(tickets, & &1["id"])) == Enum.sort([ctx.source, legacy_id, both_id])
        assert outgoing(ctx.workspace, legacy_id) == {:ok, %{edges: []}}
      end
    end
  end

  describe "Surreal physical reference failures" do
    @describetag adapter: Surreal, needs_store: true

    for {label, out} <- [{"wrong endpoint table", "problem:ci_b"}, {"malformed endpoint", "'not a record reference'"}] do
      @tag physical_out: out
      test "#{label} refuses the whole read instead of omitting or reinterpreting one edge", %{ctx: ctx, physical_out: out} do
        damaged_rows!(ctx, """
        CREATE ticket_affects:a_valid SET in = ticket:#{ctx.source}, out = ci:ci_a, kind = 'affects';
        CREATE ticket_affects:z_invalid SET in = ticket:#{ctx.source}, out = #{out}, kind = 'affects';
        """)

        assert {:error, %Error{code: :protocol}} = outgoing(ctx.workspace, ctx.source)
      end
    end
  end
end

defmodule Veritas.Core.Store.IncidentRelationsLegacyAdapter do
  @moduledoc false

  # Deliberately implements the existing required port, without the new
  # optional callback. All actual persistence remains Memory's implementation.
  for {name, arity} <- [
        transaction: 3, fetch: 3, put: 3, delete: 3, list: 3,
        next_sequence: 2, relate: 5, unrelate: 4, traverse: 5, impact: 3,
        put_ci_type: 2, put_relation_kind: 2, ci_types: 1, relation_kinds: 1,
        upsert_chunks: 3, vector_search: 3, fulltext_search: 3,
        append_samples: 2, range_samples: 5, append_audit: 2, changes: 3, describe: 0
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: apply(Veritas.Store.Memory, unquote(name), [unquote_splicing(args)])
  end
end

defmodule Veritas.Core.Store.IncidentRelationsFaultAdapter do
  @moduledoc false

  for {name, arity} <- Veritas.Core.Store.IncidentRelationsLegacyAdapter.__info__(:functions) do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: apply(Veritas.Store.Memory, unquote(name), [unquote_splicing(args)])
  end

  def outgoing_relations(_tx, "affects", _source) do
    %Veritas.Store.Error{} = error = Process.get({__MODULE__, :error})
    {:error, error}
  end
end

defmodule Veritas.Core.Store.IncidentRelationsBoundaryTest do
  @moduledoc """
  Tests the real Store facade/Memory transaction boundary under optional-port
  refusal and injected read errors. These do NOT prove Surreal pagination or
  transport fault detection; that lower-level injection seam is not present.
  """
  use ExUnit.Case, async: false

  import Veritas.Core.Store.IncidentRelationsFixtures
  alias Veritas.Store
  alias Veritas.Store.{Config, Error, Memory}
  alias Veritas.Core.Store.{IncidentRelationsFaultAdapter, IncidentRelationsLegacyAdapter}

  setup do
    {:ok, ctx: prepare(Memory)}
  end

  test "missing optional callback refuses and rolls back instead of succeeding with no edges", %{ctx: ctx} do
    Config.configure({IncidentRelationsLegacyAdapter, []})

    assert {:error, %Error{code: :unsupported}} =
             Store.transaction(ctx.workspace, fn tx ->
               assert {:ok, _} = Store.put(tx, :ci, %{"id" => "must_rollback", "name" => "probe"})
               Store.outgoing_relations(tx, "affects", ctx.source)
             end)

    Config.configure({Memory, []})
    assert {:ok, nil} = Store.transaction(ctx.workspace, &Store.fetch(&1, :ci, "must_rollback"))
  end

  for {label, code} <- [{"query unavailable", :unavailable}, {"later page timed out", :timeout}, {"incomplete enumeration", :protocol}] do
    @tag fault_code: code
    test "#{label} is propagated unchanged and aborts buffered writes", %{ctx: ctx, fault_code: code} do
      error = Error.new(code, "injected relation read failure", details: %{stage: :outgoing_read})
      Process.put({IncidentRelationsFaultAdapter, :error}, error)
      Config.configure({IncidentRelationsFaultAdapter, []})

      assert {:error, ^error} =
               Store.transaction(ctx.workspace, fn tx ->
                 assert {:ok, _} = Store.put(tx, :ci, %{"id" => "must_rollback", "name" => "probe"})
                 Store.outgoing_relations(tx, "affects", ctx.source)
               end)

      Config.configure({Memory, []})
      assert {:ok, nil} = Store.transaction(ctx.workspace, &Store.fetch(&1, :ci, "must_rollback"))
    end
  end
end
