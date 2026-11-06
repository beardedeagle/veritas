defmodule Veritas.Core.AuditChainTest do
  @moduledoc """
  The Audit Log's chain is **signed**, and the signature is what makes it
  evidence rather than decoration.

  A chain whose hash anyone can recompute is not evidence: an attacker who
  can write to the store can read the chain, change it, and recompute every
  hash, and the verification will report it as intact. That was the defect
  the signing fixes, and it is what these tests are about.

  Each test therefore takes a chain the host wrote and changes it **the way
  an attacker with store access would** — through the store, not through the
  host — and shows that the verification refuses it. A test that only proved
  the payload was rejected by a happy path would prove nothing: the whole
  point is that the change lands in the datastore and still does not verify.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Tickets}
  alias Veritas.Core.Audit.ChainKey
  alias Veritas.Store

  @actor %{type: "user", id: "u1"}

  setup do
    key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    other_key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

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

    {:ok, key: key, other_key: other_key, anchor_dir: anchor_dir}
  end

  describe "the key ring" do
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
          "keys" => [
            %{"id" => "k1", "secret" => secret, "created_at" => "2026-10-27"}
          ]
        })
      )

      File.chmod!(path, 0o600)

      previous_file = System.get_env("VERITAS_CHAIN_KEY_FILE")
      previous_key = System.get_env("VERITAS_CHAIN_KEY")

      # A ring that lives in a **file** is the only kind that can be
      # rotated: a ring supplied as one key has nowhere to keep the retired
      # one.
      System.put_env("VERITAS_CHAIN_KEY_FILE", path)
      System.delete_env("VERITAS_CHAIN_KEY")
      ChainKey.reset()

      on_exit(fn ->
        restore_env("VERITAS_CHAIN_KEY_FILE", previous_file)
        restore_env("VERITAS_CHAIN_KEY", previous_key)
        ChainKey.reset()
      end)

      {:ok, ring_path: path, secret: secret}
    end

    test "the current key is the one that signs, and the retired key stays in the ring", %{
      ring_path: path
    } do
      {:ok, %{from: from, to: to}} = ChainKey.rotate()

      assert from == "k1"
      refute to == from

      # The new key is the one that signs.
      {:ok, signature} = ChainKey.sign("a payload")
      assert ChainKey.key_id(signature) == {:keyed, to}

      # And the retired key is still in the ring, so the events it signed
      # still verify.
      {:ok, ring} = ChainKey.load()
      assert Enum.any?(ring.keys, fn key -> key.id == from end)
      assert File.exists?(path)
    end

    test "a row signed under a retired key is unverifiable, not tampered", %{
      workspace: workspace,
      ring_path: path
    } do
      {:ok, ticket} = open_ticket(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      # The key is retired, and then dropped while the events it signed are
      # still in the chain.
      {:ok, %{from: "k1"}} = ChainKey.rotate()
      {:ok, _ring} = ChainKey.drop_key("k1")

      # Unverifiable: nothing has been proven about the data, because the
      # host can no longer check it. It is **not** tampered — that would be a
      # claim about the evidence.
      assert {:error, _reason} = Audit.verify(workspace)
      refute match?({:ok, {:broken_at, _index}}, Audit.verify(workspace))
      assert File.exists?(path)
    end

    test "the rotation is node-level: it turns the ring and leaves every Workspace's chain where it was",
         %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, %{from: from, to: to}} = ChainKey.rotate()

      # The ring turned ...
      {:ok, ring} = ChainKey.load()
      assert ring.current == to

      # ... and no chain moved: the rows still carry the key they were signed
      # with, and the chain still verifies. The per-Workspace step is the
      # adoption, and only the adoption is audited.
      assert Enum.all?(audit_rows(workspace), fn row ->
               ChainKey.key_id(row["hash"]) == {:keyed, from}
             end)

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a row signed under a retired key still verifies while the ring holds it", %{
      workspace: workspace
    } do
      {:ok, ticket} = open_ticket(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, _rotation} = ChainKey.rotate()

      # The key is retired but still in the ring, so the chain still checks.
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a migration may not change the signing key of a chain that is already keyed", %{
      workspace: workspace
    } do
      {:ok, ticket} = open_ticket(workspace)

      # The ring turns. The chain is signed under the key it replaced, and
      # the migration is not allowed to move it: only the operator's audited
      # adoption may.
      {:ok, %{from: from}} = ChainKey.rotate()

      rows = audit_rows(workspace)
      assert {:error, reason} = Audit.reconcile_chain(rows)
      assert reason =~ "rotate and adopt the key first"
      assert reason =~ from
    end
  end

  describe "a chain the host wrote" do
    test "verifies", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)

      {:ok, _moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "is signed, and says which key signed it", %{workspace: workspace} do
      {:ok, _ticket} = open_ticket(workspace)
      [event | _] = audit_rows(workspace)

      assert {:keyed, "default"} = ChainKey.key_id(event["hash"])
    end

    test "covers the diff, the timestamp and the content", %{workspace: workspace} do
      {:ok, _ticket} = open_ticket(workspace)
      [event | _] = audit_rows(workspace)

      # The diff is in the signed payload: it says what changed.
      assert event["diff"]["state"] == "new"
      # And the timestamp: the moment the event was recorded.
      assert %DateTime{} = event["timestamp"]
    end
  end

  describe "a row an attacker changed" do
    test "whose diff was rewritten is refused", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      rewrite(workspace, ticket["id"], fn row ->
        Map.put(row, "diff", %{"state" => "closed"})
      end)

      assert {:ok, {:broken_at, 0}} = Audit.verify(workspace)
    end

    test "whose timestamp was rewritten is refused", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)

      rewrite(workspace, ticket["id"], fn row ->
        Map.put(row, "timestamp", ~U[2026-01-01 01:00:00Z])
      end)

      assert {:ok, {:broken_at, 0}} = Audit.verify(workspace)
    end

    test "whose timestamp came back with fewer fractional digits still verifies", %{
      workspace: workspace,
      key: key
    } do
      {:ok, ticket} = open_ticket(workspace)

      # The store may hand a timestamp back with fewer fractional digits than
      # it was given: ".082" where it was given ".082000". The same instant,
      # written with fewer digits, is the same instant, and the encoding is a
      # function of the instant.
      row = audit_row_for(workspace, ticket["id"])
      signed = %{row | "timestamp" => ~U[2026-01-01 00:00:00.082000Z]}
      signed = Map.put(signed, "hash", sign_with(signed, signed["diff"], key))
      rewrite_row(signed, workspace, fn stored -> stored end)

      # The same instant, in three digits instead of six. The value is in
      # microseconds either way — the precision says how many digits to
      # print, not what the instant is.
      trimmed = %{signed["timestamp"] | microsecond: {82_000, 3}}
      rewrite(workspace, ticket["id"], fn _row -> Map.put(signed, "timestamp", trimmed) end)

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "whose actor was rewritten is refused", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)

      rewrite(workspace, ticket["id"], fn row -> Map.put(row, "actor_id", "someone-else") end)

      assert {:ok, {:broken_at, 0}} = Audit.verify(workspace)
    end

    test "whose sequence was renumbered is refused", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)

      {:ok, moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      # The first row is renumbered: the order of the chain changes, and the
      # link that should join the rows no longer joins them.
      rewrite(workspace, ticket["id"], fn row ->
        Map.put(row, "sequence", row["sequence"] + 100)
      end)

      assert {:ok, {:broken_at, _index}} = Audit.verify(workspace)

      # And the row that was renumbered is not where it was: the chain is
      # walked in sequence order, and the renumbered row has moved to the
      # end of it.
      assert [first | _] = audit_rows(workspace)
      assert first["subject"] == moved["id"]
    end
  end

  describe "a chain an attacker forged" do
    test "is refused when it was re-signed with a key the host does not hold", %{
      workspace: workspace,
      other_key: other_key
    } do
      {:ok, ticket} = open_ticket(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      # The attacker rewrites the row and recomputes the signature — with a
      # key they made up. They do not have the host's key.
      rewrite(workspace, ticket["id"], fn row ->
        diff = %{"state" => "closed"}
        row |> Map.put("diff", diff) |> Map.put("hash", sign_with(row, diff, other_key))
      end)

      assert {:ok, {:broken_at, 0}} = Audit.verify(workspace)
    end

    test "is refused when the whole history was rewritten and re-signed", %{
      workspace: workspace,
      other_key: other_key
    } do
      {:ok, ticket} = open_ticket(workspace)

      {:ok, _moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      # Every row is rewritten and every signature recomputed with a key the
      # host does not hold. Nothing about the chain is left as it was.
      for row <- audit_rows(workspace) do
        diff = %{"state" => "forged"}

        row
        |> Map.put("diff", diff)
        |> Map.put("hash", sign_with(row, diff, other_key))
        |> rewrite_row(workspace, fn stored -> stored end)
      end

      assert {:ok, {:broken_at, _index}} = Audit.verify(workspace)
    end

    test "is accepted when it is re-signed with the host's own key — which is what the key buys",
         %{
           workspace: workspace,
           key: key
         } do
      {:ok, ticket} = open_ticket(workspace)

      # The key is the capability. Anybody who holds it can write a row that
      # verifies, which is the same property every keyed signature has, and
      # the reason the key is host-held and never stored beside the data.
      rewrite(workspace, ticket["id"], fn row ->
        diff = %{"state" => "closed"}
        row |> Map.put("diff", diff) |> Map.put("hash", sign_with(row, diff, key))
      end)

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "a chain an attacker cut short" do
    test "is refused when the chain is anchored", %{workspace: workspace} do
      {:ok, ticket} = open_ticket(workspace)

      {:ok, moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      # The head of the chain is written outside the store.
      assert {:ok, %{anchored: true}} = Audit.checkpoint(workspace)
      assert {:ok, :intact} = Audit.verify(workspace)

      # The attacker deletes the last event. The chain that is left still
      # verifies against itself — that is why the anchor exists.
      delete(workspace, moved["id"])

      assert {:ok, {:broken_at, _index}} = Audit.verify(workspace)
    end

    test "is not noticed when the chain is not anchored, and that is stated", %{
      workspace: workspace
    } do
      {:ok, ticket} = open_ticket(workspace)

      {:ok, moved} =
        Tickets.transition(
          workspace,
          ticket["id"],
          "acknowledged",
          Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
        )

      refute Audit.anchored?(workspace)

      delete(workspace, moved["id"])

      # A chain with no anchor is still signed — the attacker cannot forge a
      # row — but it can be shortened without the verification noticing. The
      # anchor is what closes that, and `anchored?/1` says which case this
      # deployment is in.
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "the upgrade from an unkeyed chain" do
    test "re-signs a legacy chain instead of refusing it", %{workspace: workspace} do
      # A row written before the chain was keyed: the old algorithm, over
      # the old payload, with no key in the hash.
      legacy = legacy_row(workspace, "legacy_1")
      put_audit_row(workspace, legacy)

      # Signing a chain that has no signing key yet is the upgrade, not a
      # change of key, so the migration may do it.
      assert {:ok, [assignment]} = Audit.reconcile_chain([legacy])

      # The chain comes back signed.
      assert {:keyed, "default"} = ChainKey.key_id(assignment.hash)
    end

    test "refuses a legacy row whose content was tampered with", %{workspace: workspace} do
      legacy = legacy_row(workspace, "legacy_2")

      # The legacy algorithm never covered the diff — that was the defect
      # this chain fixes. It did cover the actor, so a tampered actor is
      # caught even in a legacy row.
      tampered = Map.put(legacy, "actor_id", "someone-else")

      assert {:error, reason} = Audit.reconcile_chain([tampered])
      assert reason =~ "does not match its own hash"
    end

    test "refuses a chain that is half signed and half not", %{workspace: workspace} do
      legacy = legacy_row(workspace, "legacy_3")
      {:ok, _ticket} = open_ticket(workspace)
      [keyed | _] = audit_rows(workspace)

      assert {:error, reason} = Audit.reconcile_chain([legacy, keyed])
      assert reason =~ "partly signed and partly not"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp open_ticket(workspace) do
    Tickets.open(
      workspace,
      "incident",
      %{"title" => "Chain test", "requester" => "u1", "priority" => "high"},
      @actor
    )
  end

  defp audit_rows(workspace) do
    {:ok, rows} = Audit.entries(workspace)
    rows
  end

  # The Audit Log row **about** a subject. The row's own id is the event's,
  # not the subject's: the subject is what the row is about. A subject has
  # more than one row — a ticket that was opened and then moved has two — so
  # the caller says which one it means.
  defp audit_row_for(workspace, subject) do
    workspace |> audit_rows() |> rows_about(subject) |> List.first() || raise_no_row(subject)
  end

  defp last_audit_row_for(workspace, subject) do
    workspace |> audit_rows() |> rows_about(subject) |> List.last() || raise_no_row(subject)
  end

  defp rows_about(rows, subject), do: Enum.filter(rows, &(&1["subject"] == subject))

  defp raise_no_row(subject), do: raise("no audit row about #{subject}")

  # Read a row, change it, and write it back — the way an attacker with
  # store access would, and not through the host.
  defp rewrite(workspace, subject, change) do
    audit_row_for(workspace, subject) |> rewrite_row(workspace, change)
  end

  # The same, for a row the test already holds.
  defp rewrite_row(row, workspace, change) do
    row = change.(row)

    {:ok, _row} =
      Store.transaction(workspace, fn tx -> Store.put(tx, :audit_event, row) end)

    row
  end

  defp delete(workspace, subject) do
    row = last_audit_row_for(workspace, subject)

    :ok =
      Store.transaction(workspace, fn tx -> Store.delete(tx, :audit_event, row["id"]) end)

    :ok
  end

  defp put_audit_row(workspace, row) do
    {:ok, _row} =
      Store.transaction(workspace, fn tx -> Store.put(tx, :audit_event, row) end)

    row
  end

  # The signature an attacker computes with a key the host does not hold.
  defp sign_with(row, diff, key_hex) do
    event = row |> Audit.event() |> Map.put(:diff, diff)
    payload = Audit.payload(%{hash: row["prev_hash"], sequence: nil}, event)
    secret = Base.decode16!(key_hex, case: :mixed)
    mac = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    "default:" <> mac
  end

  # A row in the shape the chain had before it was keyed: the old payload,
  # the old algorithm, and no key in the hash.
  defp legacy_row(workspace, id) do
    %{
      "id" => id,
      "workspace" => workspace,
      "subject" => "legacy-subject",
      "subject_table" => "ticket",
      "from_state" => nil,
      "to_state" => "new",
      "actor_type" => "user",
      "actor_id" => "u1",
      "timestamp" => ~U[2026-01-01 00:00:00Z],
      "reason" => "opened",
      "correlation_id" => nil,
      "prev_hash" => nil,
      "sequence" => 1,
      "diff" => %{"state" => "new"}
    }
    |> Map.put("hash", legacy_hash())
  end

  defp legacy_hash do
    payload =
      [
        "",
        "legacy-subject",
        "ticket",
        "",
        "new",
        "user",
        "u1",
        "opened",
        ""
      ]
      |> Enum.join("|")

    ChainKey.legacy_mac(payload)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
