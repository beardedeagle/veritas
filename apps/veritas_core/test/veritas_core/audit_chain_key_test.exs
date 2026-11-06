defmodule Veritas.Core.AuditChainKeyTest do
  @moduledoc """
  A Workspace's chain keeps the key it was adopted under, until it adopts the
  next one.

  The rotation is **node-level**: the operator turns the ring once, and every
  Workspace adopts the new key one at a time. A Workspace that has not adopted
  it yet is a Workspace whose chain is under the retired key — and the
  retired key stays in the ring precisely so that such a Workspace keeps
  verifying.

  What it must not do is **mix** the two. An event appended under the new
  key would make the chain a mixture, and a mixture is a chain the
  migration refuses to re-sign: the Workspace would be stuck, and the reason
  it was given ("partly signed and partly not") would not be the reason.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.Audit.ChainKey
  alias Veritas.Core.Tickets

  @actor %{type: "user", id: "u1"}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "veritas_ring_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    File.write!(
      path,
      Jason.encode!(%{
        "current" => "k1",
        "keys" => [%{"id" => "k1", "secret" => secret, "created_at" => "2026-10-27"}]
      })
    )

    File.chmod!(path, 0o600)

    previous_file = System.get_env("VERITAS_CHAIN_KEY_FILE")
    previous_key = System.get_env("VERITAS_CHAIN_KEY")

    # A ring that lives in a **file** is the only kind that can be rotated.
    System.put_env("VERITAS_CHAIN_KEY_FILE", path)
    System.delete_env("VERITAS_CHAIN_KEY")
    ChainKey.reset()

    on_exit(fn ->
      restore_env("VERITAS_CHAIN_KEY_FILE", previous_file)
      restore_env("VERITAS_CHAIN_KEY", previous_key)
      ChainKey.reset()
    end)

    {:ok, ring_path: path}
  end

  test "a chain keeps its key until it adopts the next one", %{workspace: workspace} do
    {:ok, ticket} = open_ticket(workspace)
    assert {:ok, :intact} = Audit.verify(workspace)

    # The node rotates: the ring turns, and the retired key stays in it.
    {:ok, %{from: from, to: to}} = ChainKey.rotate()
    refute from == to

    # The next ordinary append must not sign with the new key. The Workspace
    # has not adopted it, and the retired key is still in the ring.
    {:ok, _moved} =
      Tickets.transition(
        workspace,
        ticket["id"],
        "acknowledged",
        Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
      )

    rows = audit_rows(workspace)

    assert Enum.all?(rows, fn row ->
             ChainKey.key_id(row["hash"]) == {:keyed, from}
           end)

    # One chain, one key: the mixture is what the migration refuses.
    assert {:ok, :intact} = Audit.verify(workspace)

    # And the Workspace is not stuck: the migration says what the operator
    # has to do, which is to adopt the key.
    assert {:error, reason} = Audit.reconcile_chain(rows)
    assert reason =~ "adopt the key first"
    assert reason =~ from
  end

  test "a chain that adopted the new key is signed under it", %{workspace: workspace} do
    {:ok, ticket} = open_ticket(workspace)

    {:ok, %{from: from, to: to}} = ChainKey.rotate()

    {:ok, _moved} =
      Tickets.transition(
        workspace,
        ticket["id"],
        "acknowledged",
        Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
      )

    rows = audit_rows(workspace)
    assert Enum.all?(rows, fn row -> ChainKey.key_id(row["hash"]) == {:keyed, from} end)

    # The adoption: the chain is re-signed under the ring's current key.
    assert {:ok, _event} = Audit.resign_chain(workspace)

    rows = audit_rows(workspace)
    assert Enum.all?(rows, fn row -> ChainKey.key_id(row["hash"]) == {:keyed, to} end)
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp open_ticket(workspace) do
    Tickets.open(
      workspace,
      "incident",
      %{"title" => "Chain key test", "requester" => "u1", "priority" => "high"},
      @actor
    )
  end

  defp audit_rows(workspace) do
    {:ok, rows} = Audit.entries(workspace)
    rows
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
