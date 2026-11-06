defmodule Veritas.Core.Store.SurrealIntegrationTest do
  @moduledoc """
  The shipped adapter, against a real SurrealDB.

  These are the tests that cannot be faked: a transaction that really rolls
  back, a schema that really applies, an Audit Log chain that really
  verifies, and a write that really survives the loss of the process that made
  it.

  The server is started by the test — its own port, its own data directory —
  so the suite never depends on a store somebody else left running, and never
  shares state with one that did.

  When the SurrealDB binary cannot be found, the whole module is **excluded**
  and the reason is printed. It is never reported as a pass.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Veritas.Core.Store.Conformance
  alias Veritas.Core.Store.Surreal
  alias Veritas.Core.Test.SurrealServer
  alias Veritas.Core.{Audit, Tickets}

  @actor %{type: "user", id: "integration"}

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

    {:ok, server: server}
  end

  # The contract's obligations against the shipped Adapter are in
  # `veritas_core/store/conformance_test.exs`; they are not repeated here.
  # What this module adds is the part the contract suite cannot do: the loss
  # of the store itself.

  describe "the domain against a real store" do
    setup do
      workspace = "dom_" <> unique_suffix()

      # The step is named, because a reader of a red suite should not have to
      # reconstruct which step failed: the migration is the step, and the
      # store's own address is here so that "the store could not be reached"
      # can be checked rather than guessed at.
      case Surreal.migrate(workspace) do
        :ok ->
          {:ok, workspace: workspace}

        {:error, reason} ->
          flunk(
            "the migration of the Workspace #{workspace} failed: #{inspect(reason)}. " <>
              "The store this suite started is at #{store_url()}; if it is not " <>
              "answering, another suite may have taken its port."
          )
      end
    end

    test "opening a ticket writes the ticket, its detail row and its audit entry", %{
      workspace: workspace
    } do
      assert {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
      assert ticket["ticket_type"] == "incident"
      assert ticket["state"] == "new"

      {:ok, events} = Audit.entries(workspace)
      assert length(events) == 1
      assert hd(events)["subject"] == ticket["id"]
      assert hd(events)["prev_hash"] == nil
    end

    test "a legal transition moves the ticket and extends the chain", %{
      workspace: workspace
    } do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert {:ok, moved} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "acknowledged",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      assert moved["state"] == "acknowledged"

      assert {:ok, :intact} = Audit.verify(workspace)

      {:ok, events} = Audit.entries(workspace)
      assert length(events) == 2
      assert Enum.at(events, 1)["prev_hash"] == Enum.at(events, 0)["hash"]
    end

    test "an illegal transition is refused and writes nothing", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      {:ok, before} = Audit.entries(workspace)

      assert {:error, :illegal_transition} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "closed",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      {:ok, after_events} = Audit.entries(workspace)
      assert length(after_events) == length(before)

      {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "new"
    end

    test "a ticket in one Workspace is invisible in another", %{workspace: workspace} do
      other = workspace <> "_other"
      assert :ok = Surreal.migrate(other)

      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert {:ok, nil} = Tickets.read(other, ticket["id"])
    end

    test "an acknowledged write survives the loss of the process that wrote it", %{
      server: server,
      workspace: workspace
    } do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert {:ok, _moved} =
               Tickets.transition(
                 workspace,
                 ticket["id"],
                 "acknowledged",
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               )

      # The store is lost and started again on the same data directory.
      {:ok, _server} = SurrealServer.restart(server)

      assert {:ok, row} = Tickets.read(workspace, ticket["id"])
      assert row["state"] == "acknowledged"

      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  defp unique_suffix, do: :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

  # The store this suite is talking to.
  defp store_url do
    case Application.get_env(:veritas_core, :surreal) do
      %{url: url} -> url
      _ -> "an unconfigured store"
    end
  end

  defp attrs do
    %{"title" => "Integration ticket", "requester" => "integration", "priority" => "medium"}
  end
end

# The gate. When the binary cannot be found, the integration tests are
# excluded and the reason is printed — never reported as a pass.
case Veritas.Core.Test.SurrealServer.binary() do
  {:ok, path} ->
    IO.puts(:stderr, "[integration] SurrealDB found at #{path} — the integration tests will run")

  :error ->
    ExUnit.configure(exclude: [integration: true])

    IO.puts(:stderr, """

    [integration] EXCLUDED — the SurrealDB binary was not found.

    The integration tests did not run, and they are not counted as passing.
    Looked in $SURREAL_BIN, /tmp/sdb/surreal and $PATH.
    Set SURREAL_BIN to the binary to run them.
    """)
end
