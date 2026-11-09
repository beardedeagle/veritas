defmodule Veritas.Core.AuditMigrationVerifierTest do
  @moduledoc """
  Host row verification and real-Surreal migration audit dispatch.

  Engine cases are explicitly tagged and require the suite's disposable store.
  No Incident intake fixture, owner database or external credentials are used.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.Audit.ChainKey
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.{Chain, Config, Error, Surreal}

  setup ctx do
    workspace = StoreCase.unique_workspace()
    env_names = ["VERITAS_CHAIN_KEY", "VERITAS_CHAIN_KEY_FILE", "VERITAS_CHAIN_ANCHOR_DIR"]
    old_env = Map.new(env_names, &{&1, System.get_env(&1)})
    old_store = Application.get_env(:veritas_core, :store)
    old_surreal = Application.get_env(:veritas_core, :surreal)
    keys = [{Chain, :reconciler}, {Chain, :verifier}]
    old_callbacks = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
    anchor_dir = Path.expand("../../../../_build/incident-domain-20261106/verifier-fixtures/#{workspace}", __DIR__)

    on_exit(fn ->
      try do
        if ctx[:needs_store] do
          StoreCase.pin_store_configuration()
          Config.configure({Surreal, []})
          StoreCase.remove_workspace(workspace)
        end
      after
        Enum.each(old_env, fn {key, value} -> restore_env(key, value) end)
        Enum.each(old_callbacks, fn
          {key, :absent} -> :persistent_term.erase(key)
          {key, value} -> :persistent_term.put(key, value)
        end)
        restore_app(:store, old_store)
        restore_app(:surreal, old_surreal)
        ChainKey.reset()
      end
    end)

    File.mkdir_p!(anchor_dir)
    System.put_env("VERITAS_CHAIN_KEY", String.duplicate("a1", 32))
    System.delete_env("VERITAS_CHAIN_KEY_FILE")
    System.put_env("VERITAS_CHAIN_ANCHOR_DIR", anchor_dir)
    ChainKey.reset()

    if ctx[:needs_store] do
      StoreCase.pin_store_configuration()
      Config.configure({Surreal, []})
    end

    {:ok, workspace: workspace, anchor_dir: anchor_dir}
  end

  test "verifies supplied ordered rows without consulting the configured adapter", ctx do
    rows = signed_rows(ctx.workspace)
    Application.put_env(:veritas_core, :store, {__MODULE__.NotAnAdapter, []})
    assert {:ok, :intact} = Audit.verify_rows(ctx.workspace, rows)
    assert {:ok, {:broken_at, 0}} = Audit.verify_rows(ctx.workspace, Enum.reverse(rows))
    [first, second] = rows
    assert {:ok, {:broken_at, 1}} = Audit.verify_rows(ctx.workspace, [first, Map.put(second, "reason", "tampered")])
  end

  test "unverifiable history is an error, not an intact or tampered verdict", ctx do
    [first | _] = signed_rows(ctx.workspace)
    assert {:error, %Error{code: :invalid_request}} =
             Audit.verify_rows(ctx.workspace, [Map.put(first, "hash", nil)])
  end

  test "row verification retains anchor truncation checks", ctx do
    rows = signed_rows(ctx.workspace)
    last = List.last(rows)
    path = Path.join(ctx.anchor_dir, ctx.workspace <> ".anchor.json")
    File.write!(path, Jason.encode!(%{"head" => last["hash"], "sequence" => 2}), [:exclusive])
    assert {:ok, :intact} = Audit.verify_rows(ctx.workspace, rows)
    assert {:ok, {:broken_at, 1}} = Audit.verify_rows(ctx.workspace, Enum.take(rows, 1))
    assert {:ok, {:broken_at, 0}} = Audit.verify_rows(ctx.workspace, [])
  end

  test "unreadable and missing checkpoint evidence remain errors", ctx do
    path = Path.join(ctx.anchor_dir, ctx.workspace <> ".anchor.json")
    File.write!(path, "not json", [:exclusive])
    assert {:error, %Error{code: :internal}} = Audit.verify_rows(ctx.workspace, [])
    missing = ctx.workspace <> "_missing"
    File.write!(Path.join(ctx.anchor_dir, missing <> ".anchored"), "{}", [:exclusive])
    assert {:error, %Error{code: :internal}} = Audit.verify_rows(missing, [])
  end

  test "registered verification receives the exact workspace and rows without reconciliation", ctx do
    rows = signed_rows(ctx.workspace)
    Chain.register(fn _ -> flunk("ordinary verification reconciled") end)
    Chain.register_verifier(fn workspace, actual ->
      assert workspace == ctx.workspace
      assert actual === rows
      {:ok, :intact}
    end)
    assert {:ok, :intact} = Chain.verify(ctx.workspace, rows)
    :persistent_term.erase({Chain, :verifier})
    assert {:error, _} = Chain.verify(ctx.workspace, rows)
  end

  @tag needs_store: true
  test "fresh bootstrap and repeat preserve actual seeds, marker and audit rows", ctx do
    assert :ok = Surreal.migrate(ctx.workspace)
    assert {:ok, kinds} = Store.transaction(ctx.workspace, &Store.relation_kinds/1)
    assert Enum.sort(Enum.map(kinds, & &1["id"])) ==
             Enum.sort(Enum.map(Veritas.Store.Surreal.Schema.relation_kinds(), & &1["id"]))
    before = raw_snapshot(ctx.workspace)
    assert length(Map.fetch!(before, "ticket_transition")) == length(Veritas.Store.Surreal.Schema.transitions())
    assert length(Map.fetch!(before, "ci_type")) == length(Veritas.Store.Surreal.Schema.ci_types())
    assert [%{"version" => "6"}] = Map.fetch!(before, "schema_version")
    assert :ok = Surreal.migrate(ctx.workspace)
    assert raw_snapshot(ctx.workspace) === before
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  @tag needs_store: true
  test "ordinary migration verifies its own normalized rows without global Store routing", ctx do
    assert :ok = Surreal.migrate(ctx.workspace)
    append_event!(ctx.workspace)
    before = raw_snapshot(ctx.workspace)
    assert {:ok, rows} = Audit.entries(ctx.workspace)
    Chain.register(fn _ -> flunk("ordinary migration rewrote history") end)
    Chain.register_verifier(fn workspace, actual ->
      assert workspace == ctx.workspace
      assert actual === rows
      Audit.verify_rows(workspace, actual)
    end)
    # Config.options still accepts a tuple; no Store operation may resolve this module.
    Application.put_env(:veritas_core, :store, {__MODULE__.NotAnAdapter, []})
    assert :ok = Surreal.migrate(ctx.workspace)
    assert raw_snapshot(ctx.workspace) === before
  end

  @tag needs_store: true
  test "a broken audit verdict refuses repeat without mutations", ctx do
    assert :ok = Surreal.migrate(ctx.workspace)
    append_event!(ctx.workspace)
    before = raw_snapshot(ctx.workspace)
    Chain.register_verifier(fn _, _ -> {:ok, {:broken_at, 0}} end)
    assert {:error, %Error{details: %{index: 0}}} = Surreal.migrate(ctx.workspace)
    assert raw_snapshot(ctx.workspace) === before
  end

  for outcome <- [:refused, :empty, :partial, :duplicate] do
    @tag needs_store: true, outcome: outcome
    test "explicit re-sign rejects #{outcome} without adoption or history writes", ctx do
      assert :ok = Surreal.migrate(ctx.workspace)
      append_event!(ctx.workspace)
      append_event!(ctx.workspace)
      before = raw_snapshot(ctx.workspace)
      Chain.register(fn rows ->
        case ctx.outcome do
          :refused -> {:error, "injected refusal"}
          :empty -> {:ok, []}
          :partial -> {:ok, [assignment(hd(rows))]}
          :duplicate -> {:ok, [assignment(hd(rows)), assignment(hd(rows))]}
        end
      end)
      assert {:error, _} = Audit.resign_chain(ctx.workspace)
      assert Process.get(:veritas_chain_resign) == nil
      assert raw_snapshot(ctx.workspace) === before
    end
  end

  @tag needs_store: true
  test "explicit v6 re-sign invokes the host and appends one verified adoption event", ctx do
    ring_path = Path.join(ctx.anchor_dir, "synthetic-ring.json")
    keys = [%{"id" => "old", "secret" => String.duplicate("a1", 32), "created_at" => "2026-11-08"},
            %{"id" => "new", "secret" => String.duplicate("b2", 32), "created_at" => "2026-11-08"}]
    File.write!(ring_path, Jason.encode!(%{"current" => "old", "keys" => keys}), [:exclusive])
    File.chmod!(ring_path, 0o600)
    System.delete_env("VERITAS_CHAIN_KEY")
    System.put_env("VERITAS_CHAIN_KEY_FILE", ring_path)
    ChainKey.reset()
    assert :ok = Surreal.migrate(ctx.workspace)
    append_event!(ctx.workspace)
    assert {:ok, [original]} = Audit.entries(ctx.workspace)
    assert {:keyed, "old"} = ChainKey.key_id(original["hash"])
    File.write!(ring_path, Jason.encode!(%{"current" => "new", "keys" => keys}))
    ChainKey.reset()
    marker = sql!(ctx.workspace, "SELECT * FROM schema_version;")
    Chain.register(fn rows ->
      send(self(), :reconciled)
      Audit.reconcile_chain(rows)
    end)
    assert {:ok, _} = Audit.resign_chain(ctx.workspace)
    assert_received :reconciled
    assert Process.get(:veritas_chain_resign) == nil
    assert {:ok, rows} = Audit.entries(ctx.workspace)
    assert length(rows) == 2
    assert Enum.all?(rows, &(ChainKey.key_id(&1["hash"]) == {:keyed, "new"}))
    assert hd(rows)["id"] == original["id"]
    assert Audit.event(hd(rows)) === Audit.event(original)
    assert List.last(rows)["subject_table"] == "audit_chain"
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
    assert sql!(ctx.workspace, "SELECT * FROM schema_version;") === marker
  end

  @tag needs_store: true
  test "later chain-write failure rolls back earlier writes and suppresses adoption", ctx do
    assert :ok = Surreal.migrate(ctx.workspace)
    append_event!(ctx.workspace)
    append_event!(ctx.workspace)
    before = raw_snapshot(ctx.workspace)
    Chain.register(fn [first, second] ->
      # A linked, complete assignment set passes coverage checks. The first
      # update is valid; a fixture-only engine event refuses the second.
      {:ok, [%{assignment(first) | hash: "replacement_one"},
             %{assignment(second) | prev_hash: "replacement_one", hash: "replacement_two"}]}
    end)
    sql!(ctx.workspace, "DEFINE EVENT reject_second ON TABLE audit_event WHEN $event = 'UPDATE' AND $after.sequence = 2 THEN { THROW 'injected later write refusal'; };")
    assert {:error, _} = Audit.resign_chain(ctx.workspace)
    assert Process.get(:veritas_chain_resign) == nil
    assert raw_snapshot(ctx.workspace) === before
  end

  @tag needs_store: true
  test "adoption event failure is returned and clears explicit intent", ctx do
    assert :ok = Surreal.migrate(ctx.workspace)
    append_event!(ctx.workspace)
    sql!(ctx.workspace, "DEFINE EVENT reject_adoption ON TABLE audit_event WHEN $event = 'CREATE' AND $after.subject_table = 'audit_chain' THEN { THROW 'injected adoption refusal'; };")
    assert {:error, _} = Audit.resign_chain(ctx.workspace)
    assert Process.get(:veritas_chain_resign) == nil
    assert {:ok, rows} = Audit.entries(ctx.workspace)
    assert length(rows) == 1
    refute Enum.any?(rows, &(&1["subject_table"] == "audit_chain"))
  end

  defp append_event!(workspace) do
    assert {:ok, _} = Store.transaction(workspace, fn tx -> Audit.append(tx, workspace, event()) end)
  end

  defp event do
    %{subject: "fixture", subject_table: "fixture", from_state: nil, to_state: "ready",
      actor: %{type: "system", id: "migration_test"}, reason: "fixture",
      correlation_id: nil, diff: %{"nested" => [1, nil, "Ω"]}, timestamp: ~U[2026-11-08 00:00:00Z]}
  end

  defp signed_rows(workspace) do
    {rows, _} = Enum.map_reduce(1..2, %{hash: nil, sequence: nil}, fn sequence, previous ->
      event = event()
      assert {:ok, hash} = Audit.sign(previous, event)
      row = %{"id" => "event_#{sequence}", "workspace" => workspace,
        "sequence" => sequence, "prev_hash" => previous.hash, "hash" => hash,
        "subject" => event.subject, "subject_table" => event.subject_table,
        "from_state" => event.from_state, "to_state" => event.to_state,
        "actor_type" => event.actor.type, "actor_id" => event.actor.id,
        "reason" => event.reason, "correlation_id" => event.correlation_id,
        "diff" => event.diff, "timestamp" => event.timestamp}
      {row, %{hash: hash, sequence: sequence}}
    end)
    rows
  end

  defp assignment(row), do: %{id: row["id"], hash: row["hash"], prev_hash: row["prev_hash"]}

  defp raw_snapshot(workspace) do
    for table <- ["audit_event", "workspace_sequence", "schema_version", "ci_type", "relation_kind", "ticket_transition"], into: %{} do
      {table, sql!(workspace, "SELECT * FROM #{table} ORDER BY id;")}
    end
  end

  defp sql!(workspace, statement) do
    settings = Application.fetch_env!(:veritas_core, :surreal)
    headers = [{"accept", "application/json"}, {"content-type", "text/plain"},
      {"surreal-ns", workspace}, {"surreal-db", workspace},
      {"authorization", "Basic " <> Base.encode64(settings[:user] <> ":" <> settings[:pass])}]
    request = Finch.build(:post, settings[:url] <> "/sql", headers, statement)
    case Finch.request(request, :veritas_store_pool, []) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        assert {:ok, results} = Jason.decode(body)
        assert results != [] and Enum.all?(results, &(&1["status"] == "OK")), "fixture SQL failed"
        Enum.flat_map(results, &List.wrap(&1["result"]))
      _ -> flunk("fixture SQL transport failed")
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app(key, nil), do: Application.delete_env(:veritas_core, key)
  defp restore_app(key, value), do: Application.put_env(:veritas_core, key, value)
end
