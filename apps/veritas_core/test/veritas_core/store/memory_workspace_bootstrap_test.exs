defmodule Veritas.Core.Store.MemoryWorkspaceBootstrapTest do
  @moduledoc """
  Absent Memory Workspaces start with the existing relation vocabulary.
  Existing Workspace maps are never repaired, merged or backfilled by reads.

  These candidates are unrun. They exercise the real Store boundary; only
  historical Workspace fixtures and scoped cleanup use direct server state.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Store.Conformance
  alias Veritas.Store
  alias Veritas.Store.{Config, Error, Memory}
  alias Veritas.Store.Memory.Server

  # Hand-derived from Schema.relation_kinds/0, not computed by the production
  # constructor under test. Full rows catch wrong endpoints/inverses as well
  # as missing kinds, and Workspace tags catch cross-Workspace defaults.
  @builtins [
    %{"id" => "affects", "from_table" => "ticket", "to_table" => "ci", "inverse" => "affected_by"},
    %{"id" => "depends_on", "from_table" => "ci", "to_table" => "ci", "inverse" => "required_by"},
    %{"id" => "implements", "from_table" => "ticket", "to_table" => "ci", "inverse" => "implemented_by"},
    %{"id" => "parent_of", "from_table" => "ci", "to_table" => "ci", "inverse" => "child_of"},
    %{"id" => "remediates", "from_table" => "ticket", "to_table" => "ci", "inverse" => "remediated_by"}
  ]

  setup do
    previous = Application.get_env(:veritas_core, :store)
    workspace = Conformance.scratch_workspace()
    other_workspace = Conformance.scratch_workspace()
    workspaces = [workspace, other_workspace]

    on_exit(fn ->
      try do
        :sys.replace_state(Server, fn state ->
          outbox =
            state.outbox
            |> Map.drop(workspaces)
            |> Map.update(:__all__, [], fn rows ->
              Enum.reject(rows, &(&1["workspace"] in workspaces))
            end)

          %{state | workspaces: Map.drop(state.workspaces, workspaces), outbox: outbox}
        end)
      after
        if is_nil(previous),
          do: Application.delete_env(:veritas_core, :store),
          else: Application.put_env(:veritas_core, :store, previous)
      end
    end)

    Config.configure({Memory, []})
    {:ok, workspace: workspace, other_workspace: other_workspace}
  end

  test "a fresh first read exposes exactly five scoped kinds and distinguishes unknown from empty", %{
    workspace: workspace,
    other_workspace: other_workspace
  } do
    assert kinds(workspace) == expected_kinds(workspace)
    assert outgoing(workspace, "affects") == {:ok, %{edges: []}}
    assert_unknown_kind(workspace, "unknown_bootstrap_kind")
    assert kinds(other_workspace) == expected_kinds(other_workspace)
    assert kinds(workspace) == expected_kinds(workspace)
  end

  test "an unrelated first write retains the constructor's complete registry", %{workspace: workspace} do
    assert {:ok, row} =
             Store.transaction(workspace, fn tx ->
               Store.put(tx, :ci, %{"id" => "first_ci", "name" => "First write"})
             end)

    assert row["workspace"] == workspace
    assert kinds(workspace) == expected_kinds(workspace)
    assert {:ok, ^row} = Store.transaction(workspace, &Store.fetch(&1, :ci, "first_ci"))
    assert outgoing(workspace, "affects") == {:ok, %{edges: []}}
  end

  test "a custom first registration is visible in the transaction and persists without leaking", %{
    workspace: workspace,
    other_workspace: other_workspace
  } do
    custom = custom_kind(workspace)
    expected = sort_kinds([custom | expected_kinds(workspace)])

    assert :ok =
             Store.transaction(workspace, fn tx ->
               assert {:ok, ^custom} = Store.put_relation_kind(tx, Map.delete(custom, "workspace"))
               assert {:ok, rows} = Store.relation_kinds(tx)
               assert sort_kinds(rows) == expected
               assert Store.outgoing_relations(tx, "local_link", "absent_source") == {:ok, %{edges: []}}
               :ok
             end)

    assert kinds(workspace) == expected
    assert outgoing(workspace, "local_link") == {:ok, %{edges: []}}
    assert_unknown_kind(other_workspace, "local_link")
    assert kinds(other_workspace) == expected_kinds(other_workspace)
  end

  test "an explicit built-in override wins on first write and survives independent reads", %{
    workspace: workspace,
    other_workspace: other_workspace
  } do
    override = %{
      "id" => "affects",
      "from_table" => "ticket",
      "to_table" => "ci",
      "inverse" => "operator_affected_by",
      "workspace" => workspace
    }

    expected =
      expected_kinds(workspace)
      |> Enum.reject(&(&1["id"] == "affects"))
      |> then(&sort_kinds([override | &1]))

    assert :ok =
             Store.transaction(workspace, fn tx ->
               assert {:ok, ^override} = Store.put_relation_kind(tx, Map.delete(override, "workspace"))
               assert {:ok, rows} = Store.relation_kinds(tx)
               assert sort_kinds(rows) == expected
               :ok
             end)

    assert kinds(workspace) == expected
    assert outgoing(workspace, "affects") == {:ok, %{edges: []}}
    assert kinds(other_workspace) == expected_kinds(other_workspace)
    assert kinds(workspace) == expected
  end

  for shape <- [:empty_workspace, :missing_registry, :empty_registry, :custom_only_registry] do
    @tag existing_shape: shape
    test "reads preserve a preexisting #{shape} without adding built-ins", %{
      workspace: workspace,
      existing_shape: shape
    } do
      original = existing_workspace(shape, workspace)

      :sys.replace_state(Server, fn state ->
        %{state | workspaces: Map.put(state.workspaces, workspace, original)}
      end)

      expected = if shape == :custom_only_registry, do: [custom_kind(workspace)], else: []
      assert kinds(workspace) == expected
      assert_unknown_kind(workspace, "affects")

      if shape == :custom_only_registry do
        assert outgoing(workspace, "local_link") == {:ok, %{edges: []}}
      end

      # Both read paths must leave the entire persisted map untouched, including
      # raw records, old dangling edges, audit evidence and absent registry keys.
      assert {:ok, row} = Store.transaction(workspace, &Store.fetch(&1, :ci, "legacy_ci"))
      assert row == get_in(original, [:records, :ci, "legacy_ci"])
      assert kinds(workspace) == expected
      assert Map.fetch!(Server.raw_state().workspaces, workspace) === original
    end
  end

  defp expected_kinds(workspace), do: Enum.map(@builtins, &Map.put(&1, "workspace", workspace))
  defp sort_kinds(rows), do: Enum.sort_by(rows, & &1["id"])

  defp kinds(workspace) do
    assert {:ok, rows} = Store.transaction(workspace, &Store.relation_kinds/1)
    sort_kinds(rows)
  end

  defp outgoing(workspace, kind) do
    Store.transaction(workspace, &Store.outgoing_relations(&1, kind, "absent_source"))
  end

  defp assert_unknown_kind(workspace, kind) do
    assert {:error, %Error{code: :invalid_request} = error} = outgoing(workspace, kind)
    assert error.details == %{reason: :unknown_relation_kind}
    refute String.contains?(inspect(error), kind)
  end

  defp custom_kind(workspace) do
    %{
      "id" => "local_link",
      "from_table" => "ticket",
      "to_table" => "ci",
      "inverse" => "local_inverse",
      "workspace" => workspace
    }
  end

  defp existing_workspace(:empty_workspace, _workspace), do: %{}

  defp existing_workspace(shape, workspace) do
    original = %{
      records: %{
        ci: %{"legacy_ci" => %{"id" => "legacy_ci", "raw_field" => "preserve verbatim"}}
      },
      relations: [
        %{
          "id" => "historical_edge",
          "kind" => "affects",
          "from" => "legacy_ticket",
          "to" => "missing_target",
          "attributes" => %{"note" => "historical evidence"}
        }
      ],
      audit: [%{"id" => "historical_audit", "raw_payload" => "unchanged"}],
      sequences: %{"ticket" => 17}
    }

    case shape do
      :missing_registry -> original
      :empty_registry -> Map.put(original, :relation_kinds, %{})
      :custom_only_registry -> Map.put(original, :relation_kinds, %{"local_link" => custom_kind(workspace)})
    end
  end
end
