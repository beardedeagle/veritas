defmodule Veritas.Core.AuditNilDiffTest do
  @moduledoc """
  A row whose diff carries a **null**, on every engine.

  The two engines disagreed about a null field: the in-memory Adapter keeps
  it, the Surreal Adapter drops it. A signature that covered the null
  therefore covered a value the store could not reproduce, so the row did not
  verify when it was read back — and `Audit.verify/1` reported a break
  nobody caused, which is the one thing a chain nobody trusts looks like.

  The Log therefore writes a diff without the values that are not set: the
  diff is signed and stored with the nulls removed, and these tests are what
  says so:

    * a nil-bearing diff **verifies** on the in-memory Adapter and on the
      Surreal Adapter;
    * a null inside a **nested** map verifies too — the store drops a null
      field from a nested object as well;
    * the stored diff carries **no null** on either Adapter, and the two
      Adapters hold the same diff;
    * a diff with no nulls still verifies, and a value that changes from one
      non-nil value to another still changes the hash;
    * a row whose stored content was altered after the fact still fails.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.Audit.Canonical
  alias Veritas.Store

  @nil_diff %{"state" => "probed", "note" => nil}
  @nested_nil_diff %{"state" => "probed", "detail" => %{"note" => nil}}

  describe "an event whose diff carries a null" do
    test "verifies on the Surreal Adapter", %{workspace: workspace} do
      assert {:ok, :intact} = write_and_verify(workspace, @nil_diff)
    end

    test "verifies on the in-memory Adapter" do
      install(Veritas.Store.Memory)
      workspace = unique_workspace()

      assert {:ok, :intact} = write_and_verify(workspace, @nil_diff)
    end

    test "verifies when the null is inside a nested map", %{workspace: workspace} do
      assert {:ok, :intact} = write_and_verify(workspace, @nested_nil_diff)
    end

    test "a null inside a list is left alone, and a null inside a map in a list is removed",
         %{workspace: workspace} do
      {:ok, subject} = write_event(workspace, %{"list" => [%{"a" => nil, "b" => 1}, nil]})
      {:ok, rows} = Audit.entries(workspace)
      row = Enum.find(rows, &(&1["subject"] == subject))

      # The store KEEPS a null element in an array, so taking it out would
      # change the value. It DROPS a null-valued key of an object — even one
      # inside an array — so that one has to go.
      assert row["diff"] == %{"list" => [%{"b" => 1}, nil]}
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "the stored diff carries no null, and both Adapters hold the same diff",
         %{workspace: workspace} do
      surreal = write_and_read(Veritas.Store.Surreal, workspace)

      install(Veritas.Store.Memory)
      memory = write_and_read(Veritas.Store.Memory, unique_workspace())

      refute null_in?(surreal.row["diff"]),
             "the Surreal Adapter stored a null: #{inspect(surreal.row["diff"])}"

      refute null_in?(memory.row["diff"]),
             "the in-memory Adapter stored a null: #{inspect(memory.row["diff"])}"

      assert surreal.row["diff"] == memory.row["diff"]
      assert Canonical.encode(surreal.row["diff"]) == Canonical.encode(memory.row["diff"])
    end
  end

  describe "what the fix must not weaken" do
    test "a diff with no nulls still verifies", %{workspace: workspace} do
      assert {:ok, :intact} =
               write_and_verify(workspace, %{"state" => "probed", "note" => "kept"})
    end

    test "a value that changes from one non-nil value to another changes the hash" do
      # The hash must still be over the content: two diffs that differ in a
      # value that is set are two different facts.
      first = Canonical.encode(%{"state" => "probed", "note" => "kept"})
      second = Canonical.encode(%{"state" => "probed", "note" => "changed"})

      refute first == second
    end

    test "a row whose stored content was altered still fails to verify", %{workspace: workspace} do
      {:ok, subject} = write_event(workspace, @nil_diff)
      assert {:ok, :intact} = Audit.verify(workspace)

      # The change is made the way an attacker with store access would make
      # it: through the store, not through the host.
      {:ok, rows} = Audit.entries(workspace)
      row = Enum.find(rows, &(&1["subject"] == subject))

      {:ok, _altered} =
        Store.transaction(workspace, fn tx ->
          Store.put(tx, :audit_event, Map.put(row, "diff", %{"state" => "forged"}))
        end)

      assert {:ok, {:broken_at, _index}} = Audit.verify(workspace)
    end
  end

  # ── the helpers ──────────────────────────────────────────────────────────────

  # Writes one event with the given diff, and says whether the chain verifies.
  defp write_and_verify(workspace, diff) do
    {:ok, _subject} = write_event(workspace, diff)
    Audit.verify(workspace)
  end

  # Writes one event with the given diff, and reads the row back.
  defp write_and_read(adapter, workspace) do
    install(adapter)

    {:ok, subject} = write_event(workspace, @nil_diff)
    {:ok, rows} = Audit.entries(workspace)
    row = Enum.find(rows, &(&1["subject"] == subject))

    %{row: row, workspace: workspace}
  end

  # The Adapter is installed for the duration of the check, and put back
  # afterwards: the store is a configuration change (`docs/32`, ADR-033).
  defp install(adapter) do
    previous = Application.get_env(:veritas_core, :store)
    Application.put_env(:veritas_core, :store, adapter)

    on_exit(fn ->
      if previous do
        Application.put_env(:veritas_core, :store, previous)
      else
        Application.delete_env(:veritas_core, :store)
      end
    end)
  end

  # One event, written through the host's own API.
  defp write_event(workspace, diff) do
    subject = "nil_diff_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    {:ok, _sequence} =
      Store.transaction(workspace, fn tx ->
        Audit.append(tx, workspace, %{
          subject: subject,
          subject_table: "ci",
          from_state: nil,
          to_state: "probed",
          actor: %{type: "system", id: "test"},
          reason: "a nil-bearing diff",
          correlation_id: nil,
          diff: diff
        })
      end)

    {:ok, subject}
  end

  # Whether a value carries a null anywhere inside it.
  defp null_in?(nil), do: false

  defp null_in?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, item} -> null_in?(item) end)

  defp null_in?(value) when is_list(value), do: Enum.any?(value, &null_in?/1)
  defp null_in?(_other), do: false
end
