defmodule Veritas.Core.StoreEnvironmentTest do
  @moduledoc """
  The environment the suite runs in.

  These tests are about the harness rather than the product: they assert that
  the store the suite is talking to is the one it says it is, and that the
  store answers. Without that, a green suite could be green against a
  datastore nobody intended — or against a dead one.
  """
  use ExUnit.Case, async: false

  @tag :needs_store

  test "the Adapter under test is the shipped one" do
    assert Veritas.Store.adapter() == Veritas.Store.Surreal
  end

  @tag :needs_store

  test "the store the suite is configured with answers" do
    workspace = "environment_probe"

    :ok = Veritas.Core.Test.StoreCase.migrate(workspace)

    assert {:ok, _rows} =
             Veritas.Store.transaction(workspace, fn tx ->
               Veritas.Store.list(tx, :ticket, %{where: [], order_by: []})
             end)

    Veritas.Core.Test.StoreCase.remove_workspace(workspace)
  end
end
