defmodule Veritas.Core.Store.OverlayTest do
  @moduledoc """
  The transaction's own writes, and the rows it has deleted.

  A transaction reads its own writes. The row it has written is the row that
  exists, for the rest of the transaction, whatever the engine holds — and the
  row it has deleted does not exist at all: not as the marker the delete
  leaves behind, and not as the committed row the delete removed.

  The two Adapters are held to the same answers, because the port is one
  contract. A store that answered `fetch/3` with the transaction's version of a
  row and `list/3` with the committed one would be two stores wearing one
  name, and the difference between them is invisible until a transaction reads
  a row it has already written.

  ## Why this is not an obligation of `docs/32`

  The numbered obligations live in `Veritas.Store.Spec` — the normative
  implementation of `docs/32` — and a rule about a transaction's own writes is
  not one of the fifteen the corpus numbers. A new obligation is the corpus's
  to number, not this file's to invent.

  What is checked here is the **overlay**: the rows a transaction has written,
  and the rows it has deleted. It is checked against both Adapters, because
  that is what makes the port substitutable — a rule one Adapter answers and
  the other does not is not a rule.

  ## The in-memory Adapter is installed here, not by the harness

  The conformance harness starts an Adapter's process if the Adapter has one,
  and stops it in the cleanup. The in-memory Adapter's process is a **child of
  the application's supervisor** — the application starts it at boot — so
  stopping it is a restart, and a supervisor allows three in five seconds: the
  fourth takes the application down, and every store request with it.

  So the in-memory Adapter is installed here, its Workspace is named here, and
  nothing that belongs to the application is stopped.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Store.Conformance
  alias Veritas.Store

  # The probes carry fixed ids and names, so the two Adapters' answers can be
  # compared with `==`: what is compared is the answer, not a pair of random
  # ids. Each Adapter works in its own scratch Workspace, so the fixed ids
  # cannot collide.
  @changed_id "overlay_probe_changed"
  @changed_name "overlay probe changed"
  @deleted_id "overlay_probe_deleted"
  @deleted_name "overlay probe deleted"
  @committed_deleted_id "overlay_probe_committed_deleted"
  @committed_deleted_name "overlay probe committed deleted"

  describe "the in-memory Adapter" do
    setup do
      {:ok, ctx: install_memory()}
    end

    test "a row the transaction has written is the row that exists", %{ctx: ctx} do
      answers = scenario(ctx)

      # The list must carry the transaction's version of the row, and not the
      # committed one it has changed.
      assert answers["changed row through list"] == [{@changed_id, "retired"}]
      assert answers["changed row through fetch"] == {:present, "retired", nil}
    end

    test "a row the transaction has deleted does not exist", %{ctx: ctx} do
      answers = scenario(ctx)

      # Not as the marker the delete leaves behind, and not as a row with no
      # fields.
      assert answers["deleted row through list"] == []
      assert answers["deleted row through fetch"] == :missing
    end

    test "a committed row the transaction has deleted does not come back", %{ctx: ctx} do
      answers = scenario(ctx)

      # The engine still holds the row when the transaction reads it: the
      # delete is buffered and has not run. The transaction's own delete is
      # what decides, and the committed row must not come back through it.
      assert answers["committed row deleted through list"] == []
      assert answers["committed row deleted through fetch"] == :missing
    end
  end

  describe "the SurrealDB Adapter" do
    setup do
      {:ok, ctx} = Conformance.prepare(Veritas.Store.Surreal)
      on_exit(fn -> Conformance.cleanup(ctx) end)

      {:ok, ctx: ctx}
    end

    @tag :needs_store

    test "a row the transaction has written is the row that exists", %{ctx: ctx} do
      answers = scenario(ctx)

      assert answers["changed row through list"] == [{@changed_id, "retired"}]
      assert answers["changed row through fetch"] == {:present, "retired", nil}
    end

    @tag :needs_store

    test "a row the transaction has deleted does not exist", %{ctx: ctx} do
      answers = scenario(ctx)

      assert answers["deleted row through list"] == []
      assert answers["deleted row through fetch"] == :missing
    end

    @tag :needs_store

    test "a committed row the transaction has deleted does not come back", %{ctx: ctx} do
      answers = scenario(ctx)

      assert answers["committed row deleted through list"] == []
      assert answers["committed row deleted through fetch"] == :missing
    end
  end

  @tag :needs_store

  test "the two Adapters answer the same question the same way" do
    memory = answers_for(Veritas.Store.Memory)
    surreal = answers_for(Veritas.Store.Surreal)

    assert memory == surreal
  end

  # The scenario both Adapters are held to.
  #
  # It answers six questions and returns the answers, so the two Adapters can
  # be compared with `==` — the comparison is of answers, not of ids.
  defp scenario(ctx) do
    workspace = ctx.workspace

    # A committed row, changed by a later transaction. The engine holds the
    # row, with the old value, when the second transaction reads it.
    {:ok, _} =
      Store.transaction(workspace, fn tx ->
        Store.put(tx, :ci, probe(@changed_id, @changed_name, "proposed"))
      end)

    {:ok, changed_list, changed_fetch} =
      Store.transaction(workspace, fn tx ->
        {:ok, _} = Store.put(tx, :ci, probe(@changed_id, @changed_name, "retired"))

        {:ok, listed} = Store.list(tx, :ci, %{where: [{"name", @changed_name}]})
        answer = Store.fetch(tx, :ci, @changed_id)

        {:ok, listed, answer}
      end)

    # A row put and deleted in the same transaction. The engine never held it.
    {:ok, deleted_list, deleted_fetch} =
      Store.transaction(workspace, fn tx ->
        {:ok, _} = Store.put(tx, :ci, probe(@deleted_id, @deleted_name, "active"))
        :ok = Store.delete(tx, :ci, @deleted_id)

        {:ok, listed} = Store.list(tx, :ci, %{where: [{"name", @deleted_name}]})
        answer = Store.fetch(tx, :ci, @deleted_id)

        {:ok, listed, answer}
      end)

    # A committed row, deleted by a later transaction.
    {:ok, _} =
      Store.transaction(workspace, fn tx ->
        Store.put(tx, :ci, probe(@committed_deleted_id, @committed_deleted_name, "active"))
      end)

    {:ok, stale_list, stale_fetch} =
      Store.transaction(workspace, fn tx ->
        :ok = Store.delete(tx, :ci, @committed_deleted_id)

        {:ok, listed} = Store.list(tx, :ci, %{where: [{"name", @committed_deleted_name}]})
        answer = Store.fetch(tx, :ci, @committed_deleted_id)

        {:ok, listed, answer}
      end)

    %{
      "changed row through list" => states(changed_list),
      "changed row through fetch" => fetched(changed_fetch),
      "deleted row through list" => states(deleted_list),
      "deleted row through fetch" => fetched(deleted_fetch),
      "committed row deleted through list" => states(stale_list),
      "committed row deleted through fetch" => fetched(stale_fetch)
    }
  end

  # The answers of one Adapter, in a Workspace of its own.
  defp answers_for(Veritas.Store.Memory) do
    scenario(install_memory())
  end

  defp answers_for(Veritas.Store.Surreal) do
    {:ok, ctx} = Conformance.prepare(Veritas.Store.Surreal)
    on_exit(fn -> Conformance.cleanup(ctx) end)

    scenario(ctx)
  end

  # Installs the in-memory Adapter and names a Workspace for it, without
  # touching the process the application owns.
  defp install_memory do
    previous = Application.get_env(:veritas_core, :store)

    Veritas.Store.Config.configure({Veritas.Store.Memory, []})

    on_exit(fn -> restore(previous) end)

    %{adapter: Veritas.Store.Memory, workspace: Conformance.scratch_workspace()}
  end

  defp restore(nil), do: Application.delete_env(:veritas_core, :store)
  defp restore(previous), do: Application.put_env(:veritas_core, :store, previous)

  # A row on the `ci` table, carrying the fields the schema declares so the
  # engine accepts it. `name` is the field the list is filtered by, and
  # `lifecycle_state` is the field the transaction changes.
  defp probe(id, name, state) do
    %{
      "id" => id,
      "ci_type" => "overlay_probe",
      "name" => name,
      "lifecycle_state" => state
    }
  end

  # A row as the list states it: its id, and the field the transaction
  # changed. A row that is not there is not in the answer at all, so a marker
  # — which carries an id and no fields — shows up as an id and a nil.
  defp states(rows), do: Enum.map(rows, &{&1["id"], &1["lifecycle_state"]})

  # What a fetch answered: the row's changed field, and whether the row it
  # returned is the marker a delete leaves behind. The Workspace is left out —
  # each Adapter works in its own, and the Workspace is not what the two
  # Adapters have to agree about.
  defp fetched({:ok, nil}), do: :missing
  defp fetched({:ok, row}), do: {:present, row["lifecycle_state"], row["deleted"]}
  defp fetched(other), do: other
end
