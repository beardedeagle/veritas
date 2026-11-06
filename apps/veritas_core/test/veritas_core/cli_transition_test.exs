defmodule Veritas.Core.CliTransitionTest do
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.Tickets

  @password "a-fine-passphrase-the-operator-chose-42"

  setup %{workspace: workspace} do
    for variable <- ["VERITAS_OPERATOR_EMAIL", "VERITAS_OPERATOR_PASSWORD"] do
      previous = System.get_env(variable)
      System.delete_env(variable)

      on_exit(fn ->
        if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
      end)
    end

    {:ok, ticket} = Tickets.open(workspace, "incident", %{}, %{type: "user", id: "requester"})

    %{
      ticket: ticket,
      args: [
        "transition",
        "--workspace",
        workspace,
        "--id",
        ticket["id"],
        "--to-state",
        "acknowledged",
        "--json"
      ]
    }
  end

  test "an actor label is refused as authority", %{
    args: args,
    workspace: workspace,
    ticket: ticket
  } do
    {code, output} = cli(args ++ ["--actor", "forged"])
    assert code == 1
    assert Enum.join(output) =~ "--as"
    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
  end

  test "authentication is required", %{args: args} do
    assert {1, _} = cli(args)
    assert {1, _} = cli(args ++ ["--as", "manager@example.test"])
    System.put_env("VERITAS_OPERATOR_PASSWORD", "wrong")
    assert {2, _} = cli(args ++ ["--as", "manager@example.test"])
  end

  test "an authenticated operational role can transition without account-admin privilege", %{
    workspace: workspace,
    args: args
  } do
    {:ok, principal} =
      Veritas.Authn.create_account(workspace, %{
        email: "manager@example.test",
        password: @password,
        roles: ["Incident Manager"]
      })

    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)
    {code, output} = cli(args ++ ["--as", "manager@example.test"])
    assert code == 0, Enum.join(output, "\n")
    event = List.last(audit_events(workspace))
    assert event["actor_id"] == principal.id
    refute Enum.join(output) =~ @password
  end

  test "an authenticated auditor is refused", %{workspace: workspace, args: args, ticket: ticket} do
    {:ok, _} =
      Veritas.Authn.create_account(workspace, %{
        email: "auditor@example.test",
        password: @password,
        roles: ["Auditor"]
      })

    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)
    {code, output} = cli(args ++ ["--as", "auditor@example.test"])
    assert code == 2
    refute Enum.join(output) =~ @password
    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
  end

  test "the operator email can come from the environment", %{workspace: workspace, args: args} do
    {:ok, principal} =
      Veritas.Authn.create_account(workspace, %{
        email: "manager@example.test",
        password: @password,
        roles: ["Incident Manager"]
      })

    System.put_env("VERITAS_OPERATOR_EMAIL", "  manager@example.test  ")
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

    {code, output} = cli(args)
    assert code == 0, Enum.join(output, "\n")
    assert List.last(audit_events(workspace))["actor_id"] == principal.id
    refute Enum.join(output) =~ @password
  end

  test "an explicit identity overrides the environment", %{workspace: workspace, args: args} do
    {:ok, principal} =
      Veritas.Authn.create_account(workspace, %{
        email: "manager@example.test",
        password: @password,
        roles: ["Incident Manager"]
      })

    System.put_env("VERITAS_OPERATOR_EMAIL", "missing@example.test")
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

    {code, output} = cli(args ++ ["--as", "manager@example.test"])
    assert code == 0, Enum.join(output, "\n")
    assert List.last(audit_events(workspace))["actor_id"] == principal.id
  end

  test "an invalid explicit identity never falls back to the environment", %{
    workspace: workspace,
    args: args,
    ticket: ticket
  } do
    {:ok, _} =
      Veritas.Authn.create_account(workspace, %{
        email: "manager@example.test",
        password: @password,
        roles: ["Incident Manager"]
      })

    System.put_env("VERITAS_OPERATOR_EMAIL", "manager@example.test")
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

    {code, output} = cli(args ++ ["--as", "missing@example.test"])
    assert code == 2
    assert Enum.join(output) =~ "credentials were refused"
    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
  end

  test "an environment identity still needs valid credentials and policy authority", %{
    workspace: workspace,
    args: args,
    ticket: ticket
  } do
    {:ok, _} =
      Veritas.Authn.create_account(workspace, %{
        email: "auditor@example.test",
        password: @password,
        roles: ["Auditor"]
      })

    System.put_env("VERITAS_OPERATOR_EMAIL", "auditor@example.test")
    System.put_env("VERITAS_OPERATOR_PASSWORD", "wrong")
    {2, output} = cli(args)
    assert Enum.join(output) =~ "credentials were refused"

    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)
    {2, output} = cli(args)
    assert Enum.join(output) =~ "role matrix"
    assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, ticket["id"])
  end

  test "blank environment identities are treated as unset", %{args: args} do
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

    for email <- ["", "   "] do
      System.put_env("VERITAS_OPERATOR_EMAIL", email)
      {code, output} = cli(args)
      assert code == 1
      assert Enum.join(output) =~ "--as"
      assert Enum.join(output) =~ "VERITAS_OPERATOR_EMAIL"
    end
  end

  defp cli(args) do
    Process.register(self(), :mix_shell)
    Mix.shell(Mix.Shell.Process)

    try do
      code =
        try do
          Mix.Tasks.Veritas.Cli.run(args)
          0
        catch
          :exit, {:shutdown, code} -> code
          :exit, {reason, _} -> reason
          :exit, reason -> reason
        end

      {code, collect()}
    after
      case Process.info(self(), :registered_name) do
        {:registered_name, :mix_shell} -> Process.unregister(:mix_shell)
        _ -> :ok
      end
    end
  end

  defp collect do
    receive do
      {:mix_shell, :info, [message]} -> [message | collect()]
      {:mix_shell, :error, [message]} -> [message | collect()]
    after
      0 -> []
    end
  end
end
