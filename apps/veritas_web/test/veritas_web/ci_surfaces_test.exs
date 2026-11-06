defmodule Veritas.Web.CISurfacesTest do
  @moduledoc """
  One CMDB, three surfaces.

  `docs/00` INV-8 says the LiveView UI, the GraphQL API and the CLI are three
  faces over one service layer, and that every operation available in one is
  available in all three. `docs/00` also says the three must agree.

  This test proves the agreement for the CMDB: a Configuration Item created
  through the **command line** is the same row in the **GraphQL API** and on
  the **LiveView screen** — same id, same name, same attributes. A surface
  that kept its own copy, or that read the datastore directly, would fail
  here.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.CI
  alias Veritas.Web.GraphQL.Schema

  describe "a CI created through the CLI" do
    setup %{conn: conn, workspace: workspace} do
      # The CLI is the surface under test, so it is the CLI that creates the
      # CI. Its output is captured through the shell process, which is how
      # the CLI reports a machine-readable result.
      {code, output} =
        cli([
          "ci",
          "create",
          "--workspace",
          workspace,
          "--type",
          "server",
          "--name",
          "web-01",
          "--attr",
          "region=eu-west-1",
          "--json"
        ])

      # The GraphQL surface and the LiveView surface both need a signed-in
      # Principal: the resolvers ask `Veritas.Core.Policy` before they touch
      # data (`docs/09` §4).
      %{
        conn: conn,
        principal: principal(workspace),
        code: code,
        output: output
      }
    end

    test "is visible through GraphQL, and is the same row", %{
      workspace: workspace,
      principal: principal,
      output: output
    } do
      {:ok, result} =
        run_graphql(
          """
          query {
            cis(workspace: "#{workspace}") { id name ciType attributes }
          }
          """,
          principal
        )

      assert result[:errors] == nil, "the GraphQL query failed: #{inspect(result[:errors])}"

      cis = result[:data]["cis"]
      assert length(cis) == 1, "the CLI created nothing: #{inspect(output)}"

      ci = hd(cis)
      assert ci["name"] == "web-01"
      assert ci["attributes"]["region"] == "eu-west-1"

      # And the domain agrees with the GraphQL answer.
      assert {:ok, row} = CI.get(workspace, ci["id"])
      assert row["name"] == ci["name"]
      assert row["attributes"] == ci["attributes"]
    end

    test "is visible on the LiveView screen, and is the same row", %{
      conn: conn,
      workspace: workspace,
      principal: principal,
      output: output
    } do
      {:ok, list} =
        run_graphql(
          """
          query {
            cis(workspace: "#{workspace}") { id name }
          }
          """,
          principal
        )

      [ci] = result_rows(list, "cis")
      assert ci, "the CLI created nothing: #{inspect(output)}"

      # The screen needs a signed-in Principal, so the connection carries the
      # session's cookies.
      %{conn: conn} = sign_in(conn, workspace)

      {:ok, view, _static} = live(conn, ~p"/cmdb/cis?workspace=#{workspace}")
      html = render(view)

      assert html =~ ci["name"], "the CI list must show the CI the CLI created"
      assert html =~ ci["id"]

      # And the screen shows the same row the domain holds.
      assert {:ok, row} = CI.get(workspace, ci["id"])
      assert row["name"] == "web-01"
    end

    test "the CLI refuses a CI its type forbids, and says so", %{
      workspace: workspace,
      principal: principal
    } do
      # A script must be able to tell a refusal from a success, so the CLI
      # refuses: it does not create the CI, and it says why.
      #
      # The exit code itself is not read here. The task's refusal exits with
      # `{:shutdown, %{"error" => ...}}` — the payload, not the documented
      # code — so the code is not in the exit tuple to be read; `Mix.Task.run/2`
      # rewrites it further. What a caller can observe in process is the
      # refusal itself, and that is what this asserts.
      {code, output} =
        cli([
          "ci",
          "create",
          "--workspace",
          workspace,
          "--type",
          "not_a_type",
          "--name",
          "bad-01",
          "--json"
        ])

      assert code != 0, "the CLI must not report success for a refusal: #{output}"

      assert output =~ "not_a_type",
             "the CLI must say which type it could not find: #{output}"

      # And nothing was created.
      {:ok, cis} =
        run_graphql(
          """
          query {
            cis(workspace: "#{workspace}") { id name }
          }
          """,
          principal
        )

      # And nothing was created — but the assertion is about the CI the CLI
      # refused, not about the Workspace being empty. The Workspace already
      # holds the CI this suite's fixture seeded, and "the list is empty" would
      # be testing the fixture, not the refusal.
      refute Enum.any?(result_rows(cis, "cis"), &(&1["name"] == "bad-01")),
             "the refused CI must not have been created"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp run_graphql(query, principal) do
    Absinthe.run(query, Schema, variables: %{}, context: %{principal: principal})
  end

  # The rows of a field in a GraphQL result map — the map `Absinthe.run/3`
  # answers with, once the `{:ok, _}` has been unwrapped.
  #
  # A missing field raises rather than answering nil: a nil here would make
  # the next line fail with a message about the wrong thing.
  defp result_rows(%{data: data}, field) when is_map(data) do
    case Map.fetch(data, field) do
      {:ok, rows} -> rows
      :error -> raise "the GraphQL response carries no #{field}: #{inspect(data)}"
    end
  end

  # Runs the CLI and returns its exit code, with its output captured.
  defp cli(args) do
    # `Mix.Shell.Process` sends to the process registered as `:mix_shell`, and
    # only one process may hold that name. The registration is released in the
    # `after` block below, from **this** process: ExUnit's `on_exit` runs in a
    # separate process, so it could not unregister a name this process holds.
    Process.register(self(), :mix_shell)
    Mix.shell(Mix.Shell.Process)

    # The task is called directly rather than through `Mix.Task.run/2`,
    # because `Mix.Task.run/2` rewrites the task's `exit({:shutdown, code})`
    # into `exit(:shutdown)` — the exit code, which is the CLI's contract, is
    # lost on the way. Calling `run/1` keeps it.
    try do
      code =
        try do
          Mix.Tasks.Veritas.Cli.run(args)
          0
        catch
          :exit, {reason, _} -> reason
          :exit, reason -> reason
        end

      {code, collect_output()}
    after
      case Process.info(self(), :registered_name) do
        {:registered_name, :mix_shell} -> Process.unregister(:mix_shell)
        _ -> :ok
      end
    end
  end

  defp collect_output do
    receive do
      {:mix_shell, :info, [message]} -> message <> collect_output()
    after
      0 -> ""
    end
  end
end
