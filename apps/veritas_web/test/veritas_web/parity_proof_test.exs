defmodule Veritas.Web.ParityProofTest do
  @moduledoc """
  Independently specified behavioral proof of docs/04:479's CI by-type mode.

  Each surface must return all matching CIs, exclude a different type, and
  return no CIs for a known but unpopulated type. These expectations are not
  read from the parity inventory. UI filtering uses its rendered GET form;
  there is no synthetic positive LiveView event. Nothing here certifies the
  attribute/relationship modes or the shared filter-language requirement.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.CI
  alias Veritas.Web.GraphQL.Schema

  setup %{conn: conn, workspace: workspace} do
    # All three types are offered by the rendered filter; application stays empty.
    for type <- ~w(server database application) do
      assert {:ok, _} =
               CI.register_type(workspace, %{
                 "id" => type,
                 "name" => type,
                 "plural" => type <> "s",
                 "schema" => %{"type" => "object", "properties" => %{}}
               })
    end

    rows =
      for {type, name} <- [
            {"server", "parity-web-01"},
            {"server", "parity-web-02"},
            {"database", "parity-db-01"}
          ] do
        assert {:ok, row} = CI.create(workspace, %{"ci_type" => type, "name" => name})
        row
      end

    %{conn: signed_in, principal: principal} = sign_in(conn, workspace)
    %{conn: signed_in, principal: principal, seeded_rows: rows}
  end

  @tag parity_proof: "ci.query.by_type.cli"
  test "ci.query.by_type.cli", %{workspace: workspace} do
    assert cli_rows(workspace, "server") == [
             {"parity-web-01", "server"},
             {"parity-web-02", "server"}
           ]

    assert cli_rows(workspace, "database") == [{"parity-db-01", "database"}]
    assert cli_rows(workspace, "application") == []
  end

  @tag parity_proof: "ci.query.by_type.graphql"
  test "ci.query.by_type.graphql", %{workspace: workspace, principal: principal} do
    assert graphql_rows(workspace, principal, "server") == [
             {"parity-web-01", "server"},
             {"parity-web-02", "server"}
           ]

    assert graphql_rows(workspace, principal, "database") == [{"parity-db-01", "database"}]
    assert graphql_rows(workspace, principal, "application") == []
  end

  @tag parity_proof: "ci.query.by_type.ui"
  test "ci.query.by_type.ui", %{conn: conn, seeded_rows: rows, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/cmdb/cis")

    # Positive control: all three seeded rows are initially reachable.
    for row <- rows, do: assert(has_element?(view, ci_link(row, workspace), row["name"]))

    {:ok, filtered, _html} = submit_type_filter(view, conn, "server")
    assert_ci_rows(filtered, rows, "server", workspace)

    {:ok, databases, _html} = submit_type_filter(filtered, conn, "database")
    assert_ci_rows(databases, rows, "database", workspace)

    # The rendered "any" choices must mean unset, not a literal empty filter.
    {:ok, any_type, _html} = submit_type_filter(databases, conn, "")
    for row <- rows, do: assert(has_element?(any_type, ci_link(row, workspace), row["name"]))

    {:ok, empty, _html} = submit_type_filter(any_type, conn, "application")
    for row <- rows, do: refute(has_element?(empty, ci_link(row, workspace)))
  end

  defp submit_type_filter(view, conn, type) do
    assert has_element?(view, ~s(form[method=get] select[name=type] option[value="#{type}"]))
    assert has_element?(view, "form[method=get] button[type=submit]", "filter")

    # Submit the actual GET form, including hidden fields and blank defaults.
    # Do not strip empty values here: normalization belongs to the product UI.
    submitted = view |> form("form[method=get]", %{"type" => type}) |> submit_form(conn)
    assert submitted.method == "GET"
    assert %{"type" => ^type, "lifecycle" => "", "criticality" => ""} = submitted.params
    live(submitted)
  end

  defp assert_ci_rows(view, rows, type, workspace) do
    for row <- rows do
      if row["ci_type"] == type do
        assert has_element?(view, ci_link(row, workspace), row["name"])
      else
        refute has_element?(view, ci_link(row, workspace))
      end
    end
  end

  defp ci_link(row, workspace), do: ~s(a[href="/cmdb/cis/#{row["id"]}?workspace=#{workspace}"])

  defp graphql_rows(workspace, principal, type) do
    assert {:ok, result} =
             Absinthe.run(
               """
               query ByType($workspace: String!, $type: String!) {
                 cis(workspace: $workspace, ciType: $type) { name ciType }
               }
               """,
               Schema,
               variables: %{"workspace" => workspace, "type" => type},
               context: %{principal: principal}
             )

    assert result[:errors] == nil, inspect(result[:errors])
    Enum.sort(Enum.map(result[:data]["cis"], &{&1["name"], &1["ciType"]}))
  end

  defp cli_rows(workspace, type) do
    old_shell = Mix.shell()
    old_role = System.get_env("VERITAS_ROLE")
    Process.register(self(), :mix_shell)
    Mix.shell(Mix.Shell.Process)

    try do
      # The CLI intentionally exits after reporting JSON. Accept only its
      # documented success tuple; refusals and other exits must still fail.
      assert catch_exit(
               Mix.Tasks.Veritas.Cli.run([
                 "ci",
                 "list",
                 "--workspace",
                 workspace,
                 "--type",
                 type,
                 "--json"
               ])
             ) == {:shutdown, 0}

      output = collect_output([])
      assert {:ok, %{"cis" => rows}} = Jason.decode(output)
      assert is_list(rows)
      Enum.sort(Enum.map(rows, &{&1["name"], &1["ci_type"]}))
    after
      Process.unregister(:mix_shell)
      Mix.shell(old_shell)

      if old_role,
        do: System.put_env("VERITAS_ROLE", old_role),
        else: System.delete_env("VERITAS_ROLE")
    end
  end

  defp collect_output(parts) do
    receive do
      {:mix_shell, :info, [message]} -> collect_output([message | parts])
      {:mix_shell, :error, [message]} -> flunk("CLI error: #{message}")
    after
      0 -> parts |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
