defmodule Veritas.Core.DeliveryChainTest do
  @moduledoc """
  The chain, written by the writers that are not the session's.

  A session is not the only thing that appends to the Audit Log: a
  Configuration Item, a Delivery record, a refused authorisation and the
  doctor's deployment fact all append too. Every one of them reads the chain's
  head and links its row to it, so every one of them has to take the
  Workspace's lock — otherwise two writers read the same head, both link to
  it, and the chain forks.

  This is that claim, proved: writers through **delivery**, **ci**,
  **policy** and **doctor**, all at once, and the chain that comes out
  verifies — with no two rows claiming the same predecessor and no sequence
  number lost to a collision.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, CI, Delivery, Doctor, Policy, Principal}

  @server_type %{
    "id" => "server",
    "name" => "server",
    "plural" => "servers",
    "required" => [],
    "schema" => %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string"}}
    }
  }

  describe "one writer at a time" do
    test "a Delivery record alone leaves a chain that verifies", %{workspace: workspace} do
      assert {:ok, _program} = Delivery.create_program(workspace, %{"name" => "alone"})

      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "a Configuration Item alone leaves a chain that verifies", %{workspace: workspace} do
      {:ok, _type} = CI.register_type(workspace, @server_type)

      assert {:ok, _ci} = CI.create(workspace, ci_attrs("alone"))

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  describe "writers that are not the session's" do
    test "leave one chain that verifies", %{workspace: workspace} do
      {:ok, _type} = CI.register_type(workspace, @server_type)

      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      # Ten rounds of writers, all at once, in one Workspace. Every writer is
      # awaited, so every row that was going to be written has been written —
      # and the results are asserted **after** the chain, because the chain is
      # the claim.
      results =
        for round <- 1..10 do
          writers = [
            Task.async(fn -> CI.create(workspace, ci_attrs("ci-#{round}-a")) end),
            Task.async(fn -> CI.create(workspace, ci_attrs("ci-#{round}-b")) end),
            Task.async(fn -> Delivery.create_program(workspace, %{"name" => "p-#{round}-a"}) end),
            Task.async(fn -> Delivery.create_program(workspace, %{"name" => "p-#{round}-b"}) end),
            Task.async(fn -> denied(principal, workspace) end),
            Task.async(fn -> Doctor.report(workspace) end)
          ]

          Enum.map(writers, &Task.await(&1, 30_000))
        end

      # The chain verifies: every row links to the one before it.
      {:ok, rows} = Audit.entries(workspace)

      assert {:ok, :intact} = Audit.verify(workspace)

      # No two rows claim the same predecessor. The first row's predecessor is
      # nothing; every other row's is a hash, and a hash that appears twice is
      # a fork.
      prev_hashes = Enum.map(rows, & &1["prev_hash"])
      assert length(Enum.uniq(prev_hashes)) == length(prev_hashes)

      # And no sequence number was lost to a collision: a writer that lost the
      # race did not write its row, and the chain would be shorter than the
      # work.
      sequences = rows |> Enum.map(& &1["sequence"]) |> Enum.sort()
      assert sequences == Enum.to_list(1..length(sequences))

      # And the four that write a row wrote one, and the refusal was refused.
      for round <- results do
        for result <- Enum.take(round, 4) do
          assert {:ok, _row} = result
        end

        assert {:deny, _reason} = Enum.at(round, 4)
      end
    end
  end

  defp ci_attrs(name) do
    %{
      "ci_type" => "server",
      "name" => name,
      "lifecycle_state" => "active",
      "criticality" => "medium",
      "owner" => "u1",
      "attributes" => %{"region" => "eu-west-1"}
    }
  end

  # A refusal the role cannot do, which is written to the chain as a denial.
  defp denied(principal, workspace) do
    Policy.authorize(principal, "account:administrate", %{workspace: workspace})
  end
end
