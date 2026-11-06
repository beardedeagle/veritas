defmodule Veritas.Core.Store.MemoryInstallTest do
  @moduledoc """
  Installing the in-memory store as the system's Adapter.

  `Veritas.Store.Memory.install/1` points the system at the in-memory store.
  The application starts that store's process at boot, so on a node that is
  already serving, the process is usually already there — and asking for a
  store that is already there must not be an error, and must not raise
  either. It is the function that installs the Adapter, so it has to work on
  a running node: a function whose every normal call raises is a trap for
  whoever calls it next.
  """
  use ExUnit.Case, async: false

  alias Veritas.Store

  setup do
    # The Adapter is a global, and this test changes it.
    previous = Application.get_env(:veritas_core, :store)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:veritas_core, :store)
        previous -> Application.put_env(:veritas_core, :store, previous)
      end
    end)

    :ok
  end

  describe "install/1" do
    test "succeeds when the application has already started the store" do
      # The application starts the in-memory store's process at boot, so in a
      # running node the store is already there. Installing it must be
      # possible there.
      assert is_pid(Process.whereis(Veritas.Store.Memory.Server)),
             "the application does not run the in-memory store"

      assert :ok = Store.Memory.install()
    end

    test "installs the in-memory Adapter" do
      assert :ok = Store.Memory.install()

      assert Store.adapter() == Store.Memory
    end

    test "is safe to call more than once" do
      assert :ok = Store.Memory.install()
      assert :ok = Store.Memory.install()

      assert Store.adapter() == Store.Memory
    end
  end
end
