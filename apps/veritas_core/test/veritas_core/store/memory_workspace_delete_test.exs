defmodule Veritas.Core.Store.MemoryWorkspaceDeleteTest do
  @moduledoc """
  Public-boundary Workspace deletion, outbox isolation and rollback regressions.

  All fixtures are created through Store transactions. Raw state is inspected
  only to compare rollback effects, and restored only by teardown. These serial
  tests belong in a disposable test VM, never a running owner application.
  """
  use ExUnit.Case, async: false

  alias Veritas.Store
  alias Veritas.Store.{Config, Error, Memory}
  alias Veritas.Store.Memory.Server

  setup do
    server = Process.whereis(Server) || start_supervised!(Server)
    baseline = Server.raw_state()
    previous_store = Application.get_env(:veritas_core, :store)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    workspace = "delete_a_" <> suffix
    other = "delete_b_" <> suffix
    id = "shared_" <> suffix
    keep = "keep_" <> suffix
    scopes = [workspace, other, "default"]

    on_exit(fn ->
      try do
        if Process.alive?(server), do: :sys.replace_state(server, fn _ -> baseline end)
      after
        if is_nil(previous_store),
          do: Application.delete_env(:veritas_core, :store),
          else: Application.put_env(:veritas_core, :store, previous_store)
      end
    end)

    Config.configure({Memory, []})

    rows = Map.new(scopes, fn scope ->
      assert {:ok, nil} = fetch(scope, :ci, id)
      assert {:ok, nil} = fetch(scope, :ticket, id)
      ci = put!(scope, :ci, id, "ci in " <> scope)
      ticket = put!(scope, :ticket, id, "ticket in " <> scope)
      retained = put!(scope, :ci, keep, "untouched in " <> scope)
      {scope, %{ci: ci, ticket: ticket, retained: retained}}
    end)

    {:ok, workspace: workspace, other: other, scopes: scopes, id: id, keep: keep, rows: rows}
  end

  test "commit deletes only the selected Workspace row, not same-ID neighbours or another table", ctx do
    assert :ok = Store.transaction(ctx.workspace, fn tx ->
      assert :ok = Store.delete(tx, :ci, ctx.id)
      assert {:ok, nil} = Store.fetch(tx, :ci, ctx.id)
      assert {:ok, rows} = Store.list(tx, :ci, %{where: []})
      refute Enum.any?(rows, &(&1["id"] == ctx.id))
      :ok
    end)

    assert_neighbours(ctx)
    assert {:ok, nil} = fetch(ctx.workspace, :ci, ctx.id)
    assert {:ok, rows} = Store.transaction(ctx.workspace, &Store.list(&1, :ci, %{where: []}))
    refute Enum.any?(rows, &(&1["id"] == ctx.id))
    assert {:ok, row} = fetch(ctx.workspace, :ci, ctx.keep)
    assert row === ctx.rows[ctx.workspace].retained
    assert {:ok, ticket} = fetch(ctx.workspace, :ticket, ctx.id)
    assert ticket === ctx.rows[ctx.workspace].ticket
  end

  test "delete emits exactly one correctly scoped outbox row and advances only that stream", ctx do
    before = Map.new(ctx.scopes, &{&1, outbox(&1)})
    cursor = last_sequence(before[ctx.workspace])
    assert :ok = Store.transaction(ctx.workspace, &Store.delete(&1, :ci, ctx.id))

    assert {:ok, [event]} = Store.transaction(ctx.workspace, &Store.changes(&1, cursor, limit: 100))
    assert Map.take(event, ["workspace", "record_id", "table", "op", "sequence"]) == %{
      "workspace" => ctx.workspace, "record_id" => ctx.id, "table" => "ci",
      "op" => "delete", "sequence" => cursor + 1
    }
    assert %DateTime{} = event["at"]
    assert outbox(ctx.workspace) === before[ctx.workspace] ++ [event]
    assert outbox(ctx.other) === before[ctx.other]
    assert outbox("default") === before["default"]
  end

  test "an explicit default-Workspace deletion still works without touching other Workspaces", ctx do
    before = Map.new(ctx.scopes, &{&1, outbox(&1)})
    assert :ok = Store.transaction("default", &Store.delete(&1, :ci, ctx.id))
    assert {:ok, nil} = fetch("default", :ci, ctx.id)
    for scope <- [ctx.workspace, ctx.other] do
      assert {:ok, row} = fetch(scope, :ci, ctx.id)
      assert row === ctx.rows[scope].ci
      assert outbox(scope) === before[scope]
    end
    assert {:ok, [event]} = Store.transaction("default", &Store.changes(&1, last_sequence(before["default"]), limit: 100))
    assert event["workspace"] == "default"
    assert event["op"] == "delete"
    assert event["record_id"] == ctx.id
    assert {:ok, ticket} = fetch("default", :ticket, ctx.id)
    assert ticket === ctx.rows["default"].ticket
  end

  for failure <- [:returned_error, :raised_error] do
    @tag failure: failure
    test "#{failure} rolls back deletion, companion write, outbox and its counter", ctx do
      before = data_state()
      refusal = Error.new(:conflict, "injected rollback")
      result = Store.transaction(ctx.workspace, fn tx ->
        assert :ok = Store.delete(tx, :ci, ctx.id)
        assert {:ok, nil} = Store.fetch(tx, :ci, ctx.id)
        assert {:ok, _} = Store.put(tx, :ci, %{"id" => ctx.keep, "name" => "must roll back"})
        case ctx.failure do
          :returned_error -> {:error, refusal}
          :raised_error -> raise "injected deletion rollback"
        end
      end)

      case ctx.failure do
        :returned_error -> assert result === {:error, refusal}
        :raised_error ->
          assert {:error, %Error{code: :internal, details: %{exception: %RuntimeError{message: "injected deletion rollback"}}}} = result
      end
      assert data_state() === before
      for scope <- ctx.scopes do
        assert {:ok, row} = fetch(scope, :ci, ctx.id)
        assert row === ctx.rows[scope].ci
        assert {:ok, retained} = fetch(scope, :ci, ctx.keep)
        assert retained === ctx.rows[scope].retained
      end
      assert data_state() === before
    end
  end

  for order <- [:put_then_delete, :delete_then_put] do
    @tag order: order
    test "#{order} preserves buffered operation order and read-your-writes", ctx do
      before = Map.new(ctx.scopes, &{&1, outbox(&1)})
      replacement = %{"id" => ctx.id, "name" => "replacement", "workspace" => ctx.workspace}
      expected = if ctx.order == :put_then_delete, do: nil, else: replacement
      assert :ok = Store.transaction(ctx.workspace, fn tx ->
        case ctx.order do
          :put_then_delete ->
            assert {:ok, ^replacement} = Store.put(tx, :ci, replacement)
            assert :ok = Store.delete(tx, :ci, ctx.id)
          :delete_then_put ->
            assert :ok = Store.delete(tx, :ci, ctx.id)
            assert {:ok, ^replacement} = Store.put(tx, :ci, replacement)
        end
        assert {:ok, ^expected} = Store.fetch(tx, :ci, ctx.id)
        :ok
      end)
      assert_neighbours(ctx)
      assert {:ok, ^expected} = fetch(ctx.workspace, :ci, ctx.id)
      cursor = last_sequence(before[ctx.workspace])
      assert {:ok, events} = Store.transaction(ctx.workspace, &Store.changes(&1, cursor, limit: 100))
      operations = if ctx.order == :put_then_delete, do: ["put", "delete"], else: ["delete", "put"]
      assert Enum.map(events, & &1["op"]) == operations
      assert Enum.map(events, & &1["sequence"]) == [cursor + 1, cursor + 2]
      assert Enum.all?(events, &(&1["workspace"] == ctx.workspace and &1["record_id"] == ctx.id))
      assert outbox(ctx.other) === before[ctx.other]
      assert outbox("default") === before["default"]
    end
  end

  test "public CI deletion creates a real dangling endpoint without removing its historical relation", ctx do
    assert {:ok, edge} = Store.transaction(ctx.workspace, fn tx ->
      Store.relate(tx, "affects", ctx.id, ctx.id, %{"note" => "preserve historical link"})
    end)
    assert {:ok, %{edges: [^edge]}} = Store.transaction(ctx.workspace, &Store.outgoing_relations(&1, "affects", ctx.id))
    assert :ok = Store.transaction(ctx.workspace, &Store.delete(&1, :ci, ctx.id))
    assert {:ok, nil} = fetch(ctx.workspace, :ci, ctx.id)
    assert {:ok, %{edges: [^edge]}} = Store.transaction(ctx.workspace, &Store.outgoing_relations(&1, "affects", ctx.id))
    assert {:ok, ticket} = fetch(ctx.workspace, :ticket, ctx.id)
    assert ticket === ctx.rows[ctx.workspace].ticket
    assert_neighbours(ctx)
  end

  test "repeated absent deletion remains scoped and preserves existing no-op outbox semantics", ctx do
    absent = "absent_" <> ctx.id
    default_row = put!("default", :ci, absent, "default-only row")
    before = Map.new(ctx.scopes, &{&1, outbox(&1)})
    assert {:ok, nil} = fetch(ctx.workspace, :ci, absent)
    for _ <- 1..2 do
      assert :ok = Store.transaction(ctx.workspace, &Store.delete(&1, :ci, absent))
      assert {:ok, nil} = fetch(ctx.workspace, :ci, absent)
    end
    assert {:ok, ^default_row} = fetch("default", :ci, absent)
    cursor = last_sequence(before[ctx.workspace])
    assert {:ok, events} = Store.transaction(ctx.workspace, &Store.changes(&1, cursor, limit: 100))
    assert Enum.map(events, & &1["sequence"]) == [cursor + 1, cursor + 2]
    assert Enum.all?(events, &(&1["workspace"] == ctx.workspace and &1["op"] == "delete" and &1["record_id"] == absent))
    assert outbox(ctx.other) === before[ctx.other]
    assert outbox("default") === before["default"]
    assert_neighbours(ctx)
  end

  defp put!(workspace, table, id, name) do
    assert {:ok, row} = Store.transaction(workspace, &Store.put(&1, table, %{"id" => id, "name" => name}))
    row
  end

  defp fetch(workspace, table, id), do: Store.transaction(workspace, &Store.fetch(&1, table, id))

  defp assert_neighbours(ctx) do
    for scope <- [ctx.other, "default"] do
      assert {:ok, row} = fetch(scope, :ci, ctx.id)
      assert row === ctx.rows[scope].ci
      assert {:ok, ticket} = fetch(scope, :ticket, ctx.id)
      assert ticket === ctx.rows[scope].ticket
    end
  end

  defp outbox(workspace) do
    assert {:ok, rows} = Store.transaction(workspace, &Store.list(&1, :event_outbox, %{where: [], order_by: [{:sequence, :asc}]}))
    rows
  end

  defp last_sequence([]), do: 0
  defp last_sequence(rows), do: rows |> List.last() |> Map.fetch!("sequence")

  # Read-call telemetry is deliberately excluded; every stored Workspace,
  # sequence, outbox row and transition remains part of the rollback proof.
  defp data_state, do: Map.take(Server.raw_state(), [:workspaces, :outbox, :transitions])
end
