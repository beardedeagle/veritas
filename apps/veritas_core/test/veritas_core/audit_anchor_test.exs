defmodule Veritas.Core.AuditAnchorTest do
  @moduledoc """
  The anchor is the chain's head, held **outside** the store, and it is what
  makes the chain's *length* evidence: a chain that has been cut short no
  longer reaches the head that was anchored.

  That only holds while the anchor is there to be compared against. An
  anchor that cannot be read, or that has been deleted although the
  Workspace was checkpointed, is a finding about the host's own state — and
  it must not be reported as "intact". "Intact" is a claim about the
  evidence, and the evidence of the length is missing.

  A Workspace that was **never** anchored is a different case: its chain is
  still signed, so an attacker cannot forge a row, and the verification says
  so. `anchored?/1` is what tells the two apart.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.Audit
  alias Veritas.Core.Audit.ChainKey
  alias Veritas.Core.Tickets
  alias Veritas.Store.Error

  @actor %{type: "user", id: "u1"}

  setup do
    key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    previous_key = System.get_env("VERITAS_CHAIN_KEY")
    previous_anchor = System.get_env("VERITAS_CHAIN_ANCHOR_DIR")

    anchor_dir =
      Path.join(
        System.tmp_dir!(),
        "veritas_anchor_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.mkdir_p!(anchor_dir)

    System.put_env("VERITAS_CHAIN_KEY", key)
    System.put_env("VERITAS_CHAIN_ANCHOR_DIR", anchor_dir)
    ChainKey.reset()

    on_exit(fn ->
      restore_env("VERITAS_CHAIN_KEY", previous_key)
      restore_env("VERITAS_CHAIN_ANCHOR_DIR", previous_anchor)
      ChainKey.reset()
    end)

    {:ok, anchor_dir: anchor_dir}
  end

  describe "a chain that was never anchored" do
    test "is intact, and says that it is not anchored", %{workspace: workspace} do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      refute Audit.anchored?(workspace)

      # The chain is signed, so it cannot be forged; it can be shortened, and
      # the verification says so rather than pretending otherwise.
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "a chain that was anchored" do
    test "an anchor that cannot be read is not intact", %{
      workspace: workspace,
      anchor_dir: anchor_dir
    } do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert {:ok, %{anchored: true}} = Audit.checkpoint(workspace)

      # The anchor is there, and it is not a document this host can read.
      File.write!(anchor_file(anchor_dir, workspace), "this is not an anchor")

      assert {:error, reason} = Audit.verify(workspace)
      assert Error.message(reason) =~ "anchor"
    end

    test "an anchor that is gone is not intact", %{workspace: workspace, anchor_dir: anchor_dir} do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert {:ok, %{anchored: true}} = Audit.checkpoint(workspace)

      # The anchor is gone. The Workspace was checkpointed, so the evidence
      # of its chain's length was removed rather than never existing.
      File.rm!(anchor_file(anchor_dir, workspace))

      assert {:error, reason} = Audit.verify(workspace)
      assert Error.message(reason) =~ "anchor"
    end

    test "an intact anchor leaves the chain intact", %{workspace: workspace} do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert {:ok, %{anchored: true}} = Audit.checkpoint(workspace)

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp anchor_file(anchor_dir, workspace), do: Path.join(anchor_dir, workspace <> ".anchor.json")

  defp attrs do
    %{"title" => "Anchor test", "requester" => "u1", "priority" => "high"}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
