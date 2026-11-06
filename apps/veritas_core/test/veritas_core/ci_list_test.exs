defmodule Veritas.Core.CIListContract do
  @moduledoc """
  CI.list filters before taking its documented page, through either Store
  adapter. Fixtures deliberately put more than 1,000 nonmatches first.
  """
  use ExUnit.CaseTemplate

  alias Veritas.Store

  using options do
    quote do
      @moduletag needs_store: unquote(Keyword.get(options, :needs_store, false))
      alias Veritas.Core.CI
      alias Veritas.Store
      import Veritas.Core.CIListContract

      for {field, excluded, selected} <- [
            {:ci_type, "service", "server"},
            {:lifecycle_state, "retired", "active"},
            {:criticality, "low", "high"}
          ] do
        @field field
        @excluded excluded
        @selected selected
        test "#{field} finds matches after 1,001 earlier nonmatches", %{workspace: workspace} do
          earlier =
            for n <- 1..1_001 do
              row("early_#{n}", "A#{pad(n)}")
              |> Map.put(to_string(@field), @excluded)
            end

          seed(workspace, earlier ++ [row("late_b", "Z-B"), row("late_a", "Z-A")])
          assert {:ok, rows} = CI.list(workspace, [{@field, @selected}, {:limit, 2}])
          assert ids(rows) == ["late_a", "late_b"]
        end
      end

      test "combined filters keep name order, default 50 and maximum 500", %{workspace: workspace} do
        earlier =
          for n <- 1..1_001 do
            nonmatch =
              case rem(n, 3) do
                0 -> %{"ci_type" => "service"}
                1 -> %{"lifecycle_state" => "retired"}
                2 -> %{"criticality" => "low"}
              end

            Map.merge(row("early_#{n}", "A#{pad(n)}"), nonmatch)
          end

        # Insert in reverse name order: insertion order cannot satisfy the check.
        matching = for n <- 503..1//-1, do: row("match_#{pad(n)}", "Z#{pad(n)}")
        seed(workspace, earlier ++ matching)
        filters = [ci_type: "server", lifecycle_state: "active", criticality: "high"]

        assert {:ok, rows} = CI.list(workspace, filters ++ [limit: 2])
        assert ids(rows) == ["match_0001", "match_0002"]

        for options <- [[], [limit: 0], [limit: -1], [limit: nil], [limit: "2"]] do
          assert {:ok, rows} = CI.list(workspace, filters ++ options)
          assert ids(rows) == for(n <- 1..50, do: "match_#{pad(n)}")
        end

        assert {:ok, rows} = CI.list(workspace, filters ++ [limit: 501])
        assert ids(rows) == for(n <- 1..500, do: "match_#{pad(n)}")
      end

      test "nil is unset but empty, whitespace, qualified and unknown filters stay exact", %{
        workspace: workspace
      } do
        seed(workspace, [row("known", "Known")])
        assert {:ok, [%{"id" => "known"}]} = CI.list(workspace)

        assert {:ok, [%{"id" => "known"}]} =
                 CI.list(workspace, ci_type: nil, lifecycle_state: nil, criticality: nil)

        assert {:ok, [%{"id" => "known"}]} =
                 CI.list(workspace,
                   ci_type: :server,
                   lifecycle_state: :active,
                   criticality: :high
                 )

        for field <- [:ci_type, :lifecycle_state, :criticality],
            value <- ["", " ", "unknown", "server ", "d'2000-01-01T00:00:00Z'"] do
          assert {:ok, []} = CI.list(workspace, [{field, value}])
        end

        assert {:ok, []} = CI.list(workspace, ci_type: "ci_type:server")
        assert {:ok, []} = CI.list(workspace, ci_type: "other:server")
      end

      test "matching rows never cross Workspace boundaries", %{workspace: workspace, other: other} do
        seed(workspace, [row("local", "Z-local")])
        seed(other, [row("foreign", "A-foreign")])
        assert {:ok, rows} = CI.list(workspace, ci_type: "server", limit: 1)
        assert ids(rows) == ["local"]
        assert {:ok, rows} = CI.list(other, ci_type: "server", limit: 1)
        assert ids(rows) == ["foreign"]
      end

      test "a Store page includes own inserts and replacements, not deleted or stale rows", %{
        workspace: workspace
      } do
        seed(workspace, [row("a", "A"), row("b", "B"), row("c", "C"), row("d", "D")])

        assert {:ok, answer} =
                 Store.transaction(workspace, fn tx ->
                   :ok = Store.delete(tx, :ci, "a")
                   {:ok, _} = Store.put(tx, :ci, Map.put(row("b", "B"), "ci_type", "service"))
                   {:ok, _} = Store.put(tx, :ci, row("d", "AA"))
                   {:ok, _} = Store.put(tx, :ci, row("new", "AB"))
                   {:ok, _} = Store.put(tx, :ci, row("gone", "A0"))
                   :ok = Store.delete(tx, :ci, "gone")

                   filter = %{where: [ci_type: "server"], order_by: [name: :asc], limit: 3}
                   {:ok, first} = Store.list(tx, :ci, filter)
                   {:ok, next} = Store.list(tx, :ci, %{filter | limit: 2} |> Map.put(:offset, 1))
                   {:ok, {ids(first), ids(next)}}
                 end)

        assert answer == {["d", "new", "c"], ["new", "c"]}
      end

      test "a limited page refills after its earliest committed matches are deleted or changed",
           %{
             workspace: workspace
           } do
        seed(workspace, [row("a", "A"), row("b", "B"), row("c", "C"), row("d", "D")])

        assert {:ok, rows} =
                 Store.transaction(workspace, fn tx ->
                   :ok = Store.delete(tx, :ci, "a")

                   {:ok, _} =
                     Store.put(tx, :ci, Map.put(row("b", "B"), "lifecycle_state", "retired"))

                   Store.list(tx, :ci, %{
                     where: [lifecycle_state: "active"],
                     order_by: [name: :asc],
                     limit: 2
                   })
                 end)

        assert ids(rows) == ["c", "d"]
      end

      test "a committed page applies its offset once", %{workspace: workspace} do
        seed(workspace, [row("a", "A"), row("b", "B"), row("c", "C"), row("d", "D")])

        assert {:ok, rows} =
                 Store.transaction(workspace, fn tx ->
                   Store.list(tx, :ci, %{where: [], order_by: [name: :asc], limit: 2, offset: 1})
                 end)

        assert ids(rows) == ["b", "c"]
      end
    end
  end

  def row(id, name) do
    %{
      "id" => id,
      "name" => name,
      "ci_type" => "server",
      "lifecycle_state" => "active",
      "criticality" => "high"
    }
  end

  def seed(workspace, rows) do
    # Small commits keep the real-engine fixture's requests bounded too.
    for batch <- Enum.chunk_every(rows, 100) do
      {:ok, :seeded} =
        Store.transaction(workspace, fn tx ->
          Enum.each(batch, fn row -> {:ok, _} = Store.put(tx, :ci, row) end)
          {:ok, :seeded}
        end)
    end
  end

  def ids(rows), do: Enum.map(rows, & &1["id"])
  def pad(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")
end

defmodule Veritas.Core.CIListMemoryTest do
  use Veritas.Core.CIListContract, async: false

  setup do
    previous = Application.get_env(:veritas_core, :store)

    if is_nil(Process.whereis(Veritas.Store.Memory.Server)) do
      start_supervised!(Veritas.Store.Memory.Server)
    end

    :ok = Veritas.Store.Config.configure(Veritas.Store.Memory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:veritas_core, :store, previous),
        else: Application.delete_env(:veritas_core, :store)
    end)

    {:ok,
     workspace: Veritas.Core.Test.StoreCase.unique_workspace(),
     other: Veritas.Core.Test.StoreCase.unique_workspace()}
  end
end

defmodule Veritas.Core.CIListSurrealTest do
  use Veritas.Core.CIListContract, async: false, needs_store: true

  setup do
    alias Veritas.Core.Test.StoreCase

    previous = Application.get_env(:veritas_core, :store)
    StoreCase.pin_store_configuration()
    :ok = Veritas.Store.Config.configure(Veritas.Store.Surreal)
    workspace = StoreCase.unique_workspace()
    other = StoreCase.unique_workspace()

    on_exit(fn ->
      :ok = Veritas.Store.Config.configure(Veritas.Store.Surreal)
      StoreCase.remove_workspace(workspace)
      StoreCase.remove_workspace(other)

      if previous,
        do: Application.put_env(:veritas_core, :store, previous),
        else: Application.delete_env(:veritas_core, :store)
    end)

    :ok = StoreCase.migrate(workspace)
    :ok = StoreCase.migrate(other)
    {:ok, workspace: workspace, other: other}
  end
end
