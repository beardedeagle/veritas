defmodule Veritas.Core.SessionChainTest do
  @moduledoc """
  The Audit Log entries a session writes, and the chain they make.

  Two claims under test:

    * **ending every session a Principal holds writes a linked chain.** One
      transaction, one entry per session, and each entry links to the one
      before it. This is `Session.revoke_all/3`, and it had no test at all.

    * **the chain has one writer at a time.** Two writers that each read the
      same head and each link their row to it **fork** the chain, and the
      verification reports the fork under normal load. The WorkspaceLock is
      what prevents that, and this is the test that says so.

  The assertion is the **observable contract**: the chain verifies. It does
  not say which layer makes that true — the write may be serialised at the
  lock, or the row may be made visible to the next read in the same
  transaction — and it must not.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Principal, Session}

  describe "ending every session a Principal holds" do
    test "writes one entry per session, and the chain links them", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      {:ok, _first} = Session.start(principal)
      {:ok, _second} = Session.start(principal)

      assert {:ok, 2} = Session.revoke_all(workspace, principal.id)

      # The chain verifies: the entries are linked, and each links to the one
      # before it.
      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, rows} = Audit.entries(workspace)
      revocations = Enum.filter(rows, &(&1["to_state"] == "revoked"))

      assert length(revocations) == 2

      [first, second] = revocations

      # The second entry links to the first: its prev_hash is the first's
      # hash, and their sequences are consecutive.
      assert second["prev_hash"] == first["hash"]
      assert second["sequence"] == first["sequence"] + 1
    end
  end

  describe "the chain under concurrent writers" do
    test "one writer at a time: the chain still verifies", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      # Ten sign-ins at once, ten times over. Without the lock the writers
      # overlap: they each read the same head and write a row that links to
      # it — a fork, which the verification reports as broken — and they
      # collide on the sequence, so rows are lost as well.
      for _round <- 1..10 do
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> Session.start(principal) end) end)
        |> Enum.map(&Task.await(&1, 30_000))
      end

      {:ok, rows} = Audit.entries(workspace)

      assert {:ok, :intact} = Audit.verify(workspace)

      assert length(rows) == 100

      # And every row links to the one before it.
      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, current] ->
        assert current["prev_hash"] == previous["hash"]
        assert current["sequence"] == previous["sequence"] + 1
      end)
    end
  end
end
