defmodule Veritas.Store.Surreal.ReceiptTest do
  @moduledoc """
  The managed store's **receipt**: the port it took and the pid it took it on.

  The receipt is what lets the reaper keep the product's own live store. The
  store takes a *free* port unless the operator pins it, so no fixed list of
  ports can name it — the receipt says which port this store took, and the
  reaper keeps the process holding it.

  Two things are proved here:

    * a store the **node** asked for publishes itself and writes the receipt;
    * a store started on its own — a test, a tool — writes **no** receipt, so
      it cannot claim to be the product's live store, and the reaper cannot
      keep the wrong thing while stopping the right one.

  The publishing case writes into the application's environment, because that
  is what publishing *is*; the environment is put back when the test ends.
  """
  use ExUnit.Case, async: false

  alias Veritas.Store.Surreal.Server

  setup do
    case Veritas.Core.Test.SurrealServer.binary() do
      {:ok, binary} ->
        root = scratch_dir()
        data_dir = Path.join(root, "surreal")
        File.mkdir_p!(data_dir)

        settings = %{
          binary: binary,
          bind: "127.0.0.1",
          port: free_port(),
          url: "http://127.0.0.1:#{free_port()}",
          data_dir: data_dir,
          ready_timeout: 30_000,
          storage: "rocksdb"
        }

        {:ok, settings: settings, root: root}

      :error ->
        {:ok, skip: "no SurrealDB binary to start"}
    end
  end

  @tag :integration
  test "a store started on its own writes no receipt", %{settings: settings, root: root} do
    assert {:ok, _pid} = start_supervised({Server, settings: settings})

    refute File.exists?(Path.join(root, "veritas.store.json"))
  end

  @tag :integration
  test "a published store writes the receipt that names its port and its pid", %{
    settings: settings,
    root: root
  } do
    # Publishing writes into the application environment twice: the Adapter's
    # settings and the store's own configuration. Both are put back, or the
    # rest of the run would read a store that this test has stopped.
    surreal_before = Application.get_env(:veritas_core, :surreal)
    store_before = Application.get_env(:veritas_core, :store)

    on_exit(fn ->
      Application.put_env(:veritas_core, :surreal, surreal_before)
      Application.put_env(:veritas_core, :store, store_before)
    end)

    assert {:ok, _pid} = start_supervised({Server, [settings: settings, publish: true]})

    receipt = Path.join(root, "veritas.store.json")
    assert File.exists?(receipt)

    assert %{"port" => port, "pid" => pid} = receipt |> File.read!() |> Jason.decode!()

    # The receipt names the port the store took and the process holding it.
    assert port == settings.port
    assert is_integer(pid) and pid > 0
  end

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "veritas_receipt_test_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(dir)
    dir
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
