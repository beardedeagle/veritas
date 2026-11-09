defmodule Veritas.Core.Store.IncidentRelationAttributesTest do
  @moduledoc """
  Real-Surreal relation attribute round trips and schema-refresh preservation.

  Public-write cases use only the production schema. A separate historical
  fixture declares one old field solely to preserve an already committed row.
  Reopened reads below mean new Store transactions, not an engine restart.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.{Config, Surreal}

  @moduletag needs_store: true
  @kinds [{"affects", :ticket_affects}, {"implements", :ticket_implements}, {"remediates", :ticket_remediates}]

  setup do
    previous_store = Application.get_env(:veritas_core, :store)
    previous_surreal = Application.get_env(:veritas_core, :surreal)
    workspace = StoreCase.unique_workspace()

    on_exit(fn ->
      try do
        StoreCase.pin_store_configuration()
        Config.configure({Surreal, []})
        StoreCase.remove_workspace(workspace)
      after
        restore(:store, previous_store)
        restore(:surreal, previous_surreal)
      end
    end)

    StoreCase.pin_store_configuration()
    Config.configure({Surreal, []})
    assert :ok = Surreal.migrate(workspace)

    assert :ok =
             Store.transaction(workspace, fn tx ->
               for id <- ["ci_a", "ci_b"] do
                 assert {:ok, _} =
                          Store.put(tx, :ci, %{
                            "id" => id,
                            "name" => id,
                            "ci_type" => "unclassified"
                          })
               end

               assert {:ok, _} =
                        Store.put(tx, :ticket, %{
                          "id" => "attribute_ticket",
                          "ticket_type" => "incident",
                          "state" => "new",
                          "title" => "Attribute persistence fixture",
                          "requester" => "fixture_requester",
                          "opened_at" => ~U[2026-11-06 12:00:00Z],
                          "sequence" => 1
                        })

               :ok
             end)

    {:ok, workspace: workspace}
  end

  for {kind, table} <- @kinds do
    @tag relation_kind: kind, edge_table: table
    test "#{kind} preserves nonempty attributes in returned, buffered and reopened reads", %{
      workspace: workspace,
      relation_kind: kind,
      edge_table: table
    } do
      attributes = attributes(kind)
      first = put_edge(workspace, kind, "ci_a", attributes)
      assert first == expected_edge(kind, "ci_a", attributes)

      # This independent committed read deliberately precedes the optional
      # outgoing reader: the original failure must expose attribute loss,
      # not merely the already-known missing callback.
      stored = fetch_edge(workspace, table, first["id"])
      assert_attributes_persisted(stored, attributes)
      assert outgoing(workspace, kind) == [first]

      second_attributes = Map.put(attributes, "revision", 2)
      second = expected_edge(kind, "ci_b", second_attributes)

      assert {:ok, ^second} =
               Store.transaction(workspace, fn tx ->
                 assert {:ok, returned} =
                          Store.relate(tx, kind, "attribute_ticket", "ci_b", second_attributes)

                 assert returned == second
                 assert {:ok, %{edges: buffered}} =
                          Store.outgoing_relations(tx, kind, "attribute_ticket")

                 assert sort_edges(buffered) == sort_edges([first, second])
                 {:ok, returned}
               end)

      assert_attributes_persisted(fetch_edge(workspace, table, second["id"]), second_attributes)
      assert outgoing(workspace, kind) == sort_edges([first, second])
      assert outgoing(workspace, kind) == sort_edges([first, second])
      assert fetch_edge(workspace, table, first["id"]) == stored
    end
  end

  test "refreshing one kind preserves all committed attributes, identities and unrelated kinds", %{
    workspace: workspace
  } do
    before =
      for {kind, table} <- @kinds do
        attrs = attributes(kind)
        edge = put_edge(workspace, kind, "ci_a", attrs)
        raw = fetch_edge(workspace, table, edge["id"])
        assert_attributes_persisted(raw, attrs)
        {kind, table, edge, raw}
      end

    refresh_kind(workspace, "affects")

    for {kind, table, edge, raw} <- before do
      assert fetch_edge(workspace, table, edge["id"]) === raw
      assert outgoing(workspace, kind) == [edge]
    end

    # Reapplying the same necessary definition is non-destructive too.
    refresh_kind(workspace, "affects")

    for {kind, table, edge, raw} <- before do
      assert fetch_edge(workspace, table, edge["id"]) === raw
      assert outgoing(workspace, kind) == [edge]
    end
  end

  test "schema refresh preserves a legacy flat attribute and historical identity", %{
    workspace: workspace
  } do
    # Historical fixture only, isolated from every public-write case above.
    # The new public edge below uses attributes this DDL does not declare.
    sql!(workspace, """
    DEFINE FIELD OVERWRITE legacy_note ON ticket_affects TYPE option<string>;
    RELATE ticket:attribute_ticket->ticket_affects:historical_attribute_edge->ci:ci_a
      SET kind = 'affects', legacy_note = 'retain original evidence';
    """)

    unrelated = put_edge(workspace, "implements", "ci_b", %{})
    unrelated_raw = fetch_edge(workspace, :ticket_implements, unrelated["id"])
    historical = fetch_edge(workspace, :ticket_affects, "historical_attribute_edge")
    assert historical["legacy_note"] == "retain original evidence"

    refresh_kind(workspace, "affects")
    assert fetch_edge(workspace, :ticket_affects, "historical_attribute_edge") === historical
    assert fetch_edge(workspace, :ticket_implements, unrelated["id"]) === unrelated_raw

    expected = %{
      "id" => "historical_attribute_edge",
      "kind" => "affects",
      "from" => "attribute_ticket",
      "to" => "ci_a",
      "attributes" => %{"legacy_note" => "retain original evidence"}
    }

    assert outgoing(workspace, "affects") == [expected]
    attrs = attributes("after_refresh")
    added = put_edge(workspace, "affects", "ci_b", attrs)
    assert_attributes_persisted(fetch_edge(workspace, :ticket_affects, added["id"]), attrs)
    assert outgoing(workspace, "affects") == sort_edges([expected, added])
    assert outgoing(workspace, "implements") == [unrelated]
    assert fetch_edge(workspace, :ticket_affects, "historical_attribute_edge") === historical
  end

  defp attributes(marker) do
    %{
      "evidence" => %{
        "marker" => marker,
        "steps" => ["observed", %{"count" => 2, "confirmed" => true}],
        "text" => "quoted ' evidence — preserved",
        "optional" => nil
      },
      "enabled" => false,
      "weight" => 1.25,
      "empty" => %{},
      "kind" => "payload kind, not edge metadata",
      "id" => "payload_id",
      "in" => "payload input",
      "out" => "payload output",
      "attributes" => %{"nested" => "ordinary caller data"}
    }
  end

  defp expected_edge(kind, target, attrs) do
    %{
      "id" => kind <> "_attribute_ticket_" <> target,
      "kind" => kind,
      "from" => "attribute_ticket",
      "to" => target,
      "attributes" => attrs
    }
  end

  defp put_edge(workspace, kind, target, attrs) do
    assert {:ok, edge} =
             Store.transaction(workspace, fn tx ->
               Store.relate(tx, kind, "attribute_ticket", target, attrs)
             end)

    edge
  end

  defp fetch_edge(workspace, table, id) do
    assert {:ok, row} = Store.transaction(workspace, &Store.fetch(&1, table, id))
    assert is_map(row)
    assert row["id"] == id
    row
  end

  # A storage-only loss detector, not a choice of physical representation.
  # The exact public attribute map is asserted through outgoing_relations next.
  defp assert_attributes_persisted(row, attrs) do
    flat = Map.take(row, Map.keys(attrs)) === attrs
    nested = Enum.any?(Map.values(row), &(&1 === attrs))
    assert flat or nested, "committed relation lost or changed the supplied nonempty attributes"
  end

  defp outgoing(workspace, kind) do
    assert {:ok, %{edges: edges} = result} =
             Store.transaction(workspace, &Store.outgoing_relations(&1, kind, "attribute_ticket"))

    assert Map.keys(result) == [:edges]
    Enum.each(edges, &assert(Enum.sort(Map.keys(&1)) == ["attributes", "from", "id", "kind", "to"]))
    sort_edges(edges)
  end

  defp sort_edges(edges), do: Enum.sort_by(edges, & &1["id"])

  defp refresh_kind(workspace, kind) do
    assert {:ok, _} =
             Store.transaction(workspace, fn tx ->
               Store.put_relation_kind(tx, %{
                 "id" => kind,
                 "from_table" => "ticket",
                 "to_table" => "ci",
                 "inverse" => "affected_by"
               })
             end)
  end

  defp sql!(workspace, statement) do
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
      ], statement)

    case Finch.request(request, :veritas_store_pool, []) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        assert {:ok, results} = Jason.decode(body)
        assert is_list(results) and results != []
        assert Enum.all?(results, &(&1["status"] == "OK")), "historical fixture SQL failed"

      _ ->
        flunk("historical fixture SQL transport failed")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:veritas_core, key)
  defp restore(key, value), do: Application.put_env(:veritas_core, key, value)
end
