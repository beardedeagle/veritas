defmodule Veritas.Core.Store.MigrationChainTest do
  @moduledoc """
  The migration path through the Audit Log chain.

  The conformance suite (`veritas_core/store/spec.ex`) exercises the chain
  through the ordinary read path. These tests exercise the **migration** path,
  which reads the chain with a statement of its own, and which is the path a
  real upgrade takes: a store that already holds signed history is migrated
  forward by the product's own migrator.

  Two things have to hold there, and neither is visible from the ordinary read
  path:

    * a row that was signed correctly still verifies afterwards. The chain is
      signed over a *canonical* form of the row, and the migration used to
      read the row in the engine's own shape rather than the shape every
      other read returns. A timestamp is a datetime in one shape and a string
      in the other, and the canonical form tags them differently — so the same
      row verified through one path and failed through the other.

    * a chain the migration **refuses** is reported as a failure. A refusal
      means the historical signatures were not replaced; saying the migration
      succeeded reported an adoption that did not happen.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Veritas.Core.Store.Surreal
  alias Veritas.Core.Test.SurrealServer
  alias Veritas.Core.{Audit, Tickets}

  @actor %{type: "user", id: "migration-chain"}

  setup_all do
    {:ok, server} = SurrealServer.start()

    previous = Application.get_env(:veritas_core, :surreal)

    Application.put_env(:veritas_core, :surreal,
      url: SurrealServer.url(server),
      user: "root",
      pass: "root"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:veritas_core, :surreal, previous)
      else
        Application.delete_env(:veritas_core, :surreal)
      end

      SurrealServer.stop(server)
    end)

    {:ok, server: server, url: SurrealServer.url(server)}
  end

  describe "the migration path through the chain" do
    setup do
      workspace = "chain_" <> unique_suffix()

      case Surreal.migrate(workspace) do
        :ok -> {:ok, workspace: workspace}
        {:error, reason} -> flunk("the migration of #{workspace} failed: #{inspect(reason)}")
      end
    end

    test "a correctly signed row still verifies after the migration reads the chain", %{
      workspace: workspace
    } do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, events} = Audit.entries(workspace)
      assert length(events) == 1

      # The migration reads the chain with a statement of its own. The row is
      # signed over the canonical form of the row, and the canonical form
      # tags a timestamp by its type — a datetime and a string are different
      # canonical values. The migration must read the row the way every other
      # read does, or a correctly signed row verifies through one path and
      # fails through the other, and the upgrade of a store that holds real
      # history fails.
      assert :ok = Surreal.migrate(workspace)

      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, after_events} = Audit.entries(workspace)
      assert hd(after_events)["hash"] == hd(events)["hash"]
    end

    test "a refused chain is reported as a failure, not as a successful migration", %{
      workspace: workspace,
      url: url
    } do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      {:ok, events} = Audit.entries(workspace)
      assert length(events) == 1

      # The row is tampered with: its hash no longer matches its content, so
      # the chain cannot be established and must be left as it was found.
      tamper(url, workspace, hd(events)["id"])

      # A refusal means the historical signatures were not replaced. The
      # migration said `:ok`, the caller recorded a successful adoption, and
      # the CLI printed a success that did not happen.
      assert {:error, _reason} = Surreal.migrate(workspace)
    end
  end

  defp unique_suffix, do: :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

  defp attrs,
    do: %{
      "title" => "Migration chain ticket",
      "requester" => "integration",
      "priority" => "medium"
    }

  # Writes straight to the store, which is the only way to tamper with a row
  # the Adapter signed.
  defp tamper(url, workspace, id) do
    statement = "UPDATE audit_event:#{id} SET hash = 'a hash that does not match the row';"

    {:ok, _body} =
      Finch.build(
        :post,
        url <> "/sql",
        [
          {"accept", "application/json"},
          {"content-type", "text/plain"},
          {"surreal-ns", workspace},
          {"surreal-db", workspace},
          {"authorization", "Basic " <> Base.encode64("root:root")}
        ],
        statement
      )
      |> Finch.request(:veritas_store_pool, [])
  end
end

# The gate. When the binary cannot be found, the migration tests are excluded
# and the reason is printed — never reported as a pass.
case Veritas.Core.Test.SurrealServer.binary() do
  {:ok, path} ->
    IO.puts(
      :stderr,
      "[integration] SurrealDB found at #{path} — the migration chain tests will run"
    )

  :error ->
    ExUnit.configure(exclude: [integration: true])

    IO.puts(:stderr, """

    [integration] EXCLUDED — the SurrealDB binary was not found.

    The migration chain tests did not run, and they are not counted as passing.
    Looked in $SURREAL_BIN, /tmp/sdb/surreal and $PATH.
    Set SURREAL_BIN to the binary to run them.
    """)
end
