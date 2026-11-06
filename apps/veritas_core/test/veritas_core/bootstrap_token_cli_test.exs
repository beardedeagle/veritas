defmodule Veritas.Core.BootstrapTokenCliTest do
  @moduledoc """
  The bootstrap token at the command line: what it costs when the account is
  refused, and what is left on disk when it is not.

  A bootstrap token is a **one-time** credential, and the two things that
  make it one are proved here:

    * a token that was claimed for an account that was then refused is
      **still a token**. The account creation can be refused — a malformed
      email, a password on the breached-password list, a Workspace that
      already has accounts — and none of those refusals is the token being
      used. A token that is burned by a refusal is a credential the operator
      has to go and get again for a reason that has nothing to do with
      security;

    * the **delivery copy** is emptied when the token is spent. A token that
      is spent and still readable on disk is a token that can be presented
      again, and the file the operator was told to move it from is the file
      that holds it.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Authn
  alias Veritas.Core.BootstrapToken

  @password "a-fine-passphrase-the-operator-chose-42"
  @email "admin@example.test"

  setup do
    # The token file is node-held. The test must not write to the operator's
    # own file, so it points it at a scratch path.
    path =
      Path.join(
        System.tmp_dir!(),
        "veritas-bootstrap-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}.json"
      )

    System.put_env("VERITAS_BOOTSTRAP_TOKEN_FILE", path)
    on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN_FILE") end)

    :ok
  end

  describe "a refused account" do
    test "does not burn the token", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

      # The token is presented from the environment, so that the command
      # never has to ask for it: this test is about what the refusal does to
      # the token, not about where the token came from.
      System.put_env("VERITAS_BOOTSTRAP_TOKEN", token)
      on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN") end)

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          "not-an-email",
          "--password",
          @password,
          "--role",
          "platform_admin"
        ])

      # The account is refused, and nothing is created.
      assert code == 2, output
      assert Enum.join(output, "\n") =~ "email"
      assert {:error, :account_missing} = Authn.account_id(workspace, @email)

      # The token was not used, so it is still a token: the same token
      # creates the account when the inputs are good.
      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          @email,
          "--password",
          @password,
          "--role",
          "platform_admin"
        ])

      assert code == 0, output

      assert {:ok, _principal} =
               Authn.authenticate(workspace, %{email: @email, password: @password})
    end
  end

  describe "the delivery copy" do
    test "is emptied when the token is spent", %{workspace: workspace} do
      delivery =
        Path.join(
          System.tmp_dir!(),
          "veritas-delivery-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}.secret"
        )

      {code, output} =
        cli(["account", "bootstrap-token", "--workspace", workspace, "--file", delivery])

      assert code == 0, output

      {:ok, token} = BootstrapToken.read_token(delivery)
      assert token != ""

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          @email,
          "--password",
          @password,
          "--role",
          "platform_admin",
          "--bootstrap-token-file",
          delivery
        ])

      assert code == 0, output

      # The delivery copy is gone: the token was spent, and a spent token
      # that is still on disk can be presented again.
      assert {:error, :no_token_in_the_file} = BootstrapToken.read_token(delivery)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Issues a token and returns the path it was written to and the token
  # itself. The test reads the token from the file, the way an operator
  # would move it into a password manager.
  defp issue_token(workspace) do
    {code, output} = cli(["account", "bootstrap-token", "--workspace", workspace])
    assert code == 0

    path = extract_path(Enum.join(output, "\n"))
    {:ok, token} = BootstrapToken.read_token(path)

    {path, token}
  end

  defp extract_path(printed) do
    case Regex.run(~r/written to (\S+) \(mode 0600\)/, printed) do
      [_, path] -> path
      _ -> raise "the command did not say where the token was written: #{printed}"
    end
  end

  # Runs the CLI and returns its exit code and the messages it printed.
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
