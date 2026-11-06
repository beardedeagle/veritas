defmodule Veritas.Core.CliAccountTest do
  @moduledoc """
  The operator's path to a local account, and where the token lives.

  Two things are proved here, and both are about the token rather than the
  account:

    * the token **never reaches a terminal, an error message or a command
      line** — it is written to a file at mode 0600, and the command says
      where it is;
    * the token is **single-use** and **bound to its Workspace**, so a token
      that leaks cannot bootstrap twice and cannot bootstrap anywhere else.
  """
  use Veritas.Core.Test.StoreCase, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Veritas.Authn
  alias Veritas.Core.{Audit, BootstrapToken}

  @password "a-fine-passphrase-the-operator-chose-42"
  @email "admin@example.test"

  setup do
    previous_email = System.get_env("VERITAS_OPERATOR_EMAIL")
    System.delete_env("VERITAS_OPERATOR_EMAIL")

    on_exit(fn ->
      if previous_email,
        do: System.put_env("VERITAS_OPERATOR_EMAIL", previous_email),
        else: System.delete_env("VERITAS_OPERATOR_EMAIL")
    end)

    # The token file is node-held. The test must not write to the
    # operator's own file, so it points it at a scratch path.
    path =
      Path.join(
        System.tmp_dir!(),
        "veritas-bootstrap-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}.json"
      )

    System.put_env("VERITAS_BOOTSTRAP_TOKEN_FILE", path)
    on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN_FILE") end)

    :ok
  end

  describe "issuing a token" do
    test "does not print it, and says where it is", %{workspace: workspace} do
      {code, output} = cli(["account", "bootstrap-token", "--workspace", workspace])
      assert code == 0

      printed = Enum.join(output, "\n")
      path = extract_path(printed)

      {:ok, token} = BootstrapToken.read_token(path)

      # The token is not on the terminal.
      refute printed =~ token

      # The path is, and the file is the owner's alone.
      assert printed =~ path
      # The file is the owner's alone: the permission bits are 0600. (The
      # mode carries the file-type bits too, so they are masked off.)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "writes the token into the file it names", %{workspace: workspace} do
      {0, output} = cli(["account", "bootstrap-token", "--workspace", workspace])
      path = extract_path(Enum.join(output, "\n"))

      {:ok, token} = BootstrapToken.read_token(path)
      assert is_binary(token)
      assert byte_size(token) > 32
    end
  end

  defmodule ClipboardFixture do
    @moduledoc false
    @behaviour Veritas.Dev.Clipboard
    @impl true
    def copy(text) do
      send(self(), {:clipboard_input, text})
      Process.get(:clipboard_result, {:error, :clipboard_unavailable})
    end
  end

  describe "clipboard issuance reporting" do
    setup do
      previous = Application.fetch_env(:veritas_core, :clipboard_adapter)
      Application.put_env(:veritas_core, :clipboard_adapter, ClipboardFixture)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:veritas_core, :clipboard_adapter, value)
          :error -> Application.delete_env(:veritas_core, :clipboard_adapter)
        end
      end)

      :ok
    end

    @tag :tmp_dir
    test "copy failure says the issued file remains usable", %{workspace: workspace, tmp_dir: dir} do
      path = Path.join(dir, "issued-token")

      {0, output} =
        cli(["account", "bootstrap-token", "--workspace", workspace, "--file", path, "--copy"])

      printed = Enum.join(output, "\n")
      assert printed =~ "clipboard unavailable"
      assert printed =~ "token remains available in the file"
      assert printed =~ path
      assert {:ok, token} = BootstrapToken.read_token(path)
      assert_receive {:clipboard_input, ^token}
      refute printed =~ token
      refute printed =~ "also on the clipboard"
    end

    @tag :tmp_dir
    test "JSON retains copied false on refusal without leaking the token", %{
      workspace: workspace,
      tmp_dir: dir
    } do
      path = Path.join(dir, "issued-token")

      {0, output} =
        cli([
          "account",
          "bootstrap-token",
          "--workspace",
          workspace,
          "--file",
          path,
          "--copy",
          "--json"
        ])

      printed = Enum.join(output, "\n")

      assert %{"bootstrap_token" => %{"copied" => false, "path" => ^path}} =
               Jason.decode!(printed)

      assert {:ok, token} = BootstrapToken.read_token(path)
      assert_receive {:clipboard_input, ^token}
      refute printed =~ token
    end

    @tag :tmp_dir
    test "successful copy is reported and sends only the token", %{
      workspace: workspace,
      tmp_dir: dir
    } do
      Process.put(:clipboard_result, :ok)
      path = Path.join(dir, "issued-token")

      {0, output} =
        cli(["account", "bootstrap-token", "--workspace", workspace, "--file", path, "--copy"])

      printed = Enum.join(output, "\n")
      assert printed =~ "also on the clipboard"
      refute printed =~ "clipboard unavailable"
      assert {:ok, token} = BootstrapToken.read_token(path)
      assert_receive {:clipboard_input, ^token}
      refute printed =~ token
    end
  end

  describe "the first account" do
    test "is created with the token from the file", %{workspace: workspace} do
      System.put_env("VERITAS_OPERATOR_EMAIL", "   ")
      {0, output} = cli(["account", "bootstrap-token", "--workspace", workspace])
      path = extract_path(Enum.join(output, "\n"))
      {:ok, token} = BootstrapToken.read_token(path)

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
      refute Enum.join(output, "\n") =~ token

      assert {:ok, principal} =
               Authn.authenticate(workspace, %{email: @email, password: @password})

      assert principal.roles == [:platform_admin]

      # And the creation is in the Audit Log.
      events = audit_events(workspace)

      assert Enum.any?(events, fn event ->
               event["subject_table"] == "user" and event["to_state"] == "active"
             end)
    end

    test "is created with the token from the environment", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

      System.put_env("VERITAS_BOOTSTRAP_TOKEN", token)

      on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN") end)

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
      refute Enum.join(output, "\n") =~ token

      assert {:ok, _principal} =
               Authn.authenticate(workspace, %{email: @email, password: @password})
    end

    test "is created with the token from standard input", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

      {{code, output}, _captured} =
        with_io(
          token <> "\n",
          fn ->
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
              "--bootstrap-token-stdin"
            ])
          end
        )

      assert code == 0, output
      refute Enum.join(output, "\n") =~ token

      assert {:ok, _principal} =
               Authn.authenticate(workspace, %{email: @email, password: @password})
    end

    test "cannot be created with the token on the command line", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

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
          "--bootstrap-token",
          token
        ])

      # The option is refused, and nothing is created.
      assert code == 1
      assert Enum.join(output, "\n") =~ "removed"

      assert {:error, :account_missing} = Authn.account_id(workspace, @email)
    end

    test "cannot be created twice with the same token", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

      System.put_env("VERITAS_BOOTSTRAP_TOKEN", token)

      on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN") end)

      {code, _output} =
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

      assert code == 0

      # The token is spent: the file no longer holds it, and a second
      # attempt with the same token is refused.
      assert {:error, :no_token_in_the_file} =
               BootstrapToken.read_token(BootstrapToken.secret_path(workspace))

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          "second@example.test",
          "--password",
          @password,
          "--role",
          "platform_admin"
        ])

      assert code == 2
      assert Enum.join(output, "\n") =~ "refused"
    end

    test "cannot be created in another Workspace with the token", %{workspace: workspace} do
      {_path, token} = issue_token(workspace)

      System.put_env("VERITAS_BOOTSTRAP_TOKEN", token)

      on_exit(fn -> System.delete_env("VERITAS_BOOTSTRAP_TOKEN") end)

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          "another_workspace",
          "--email",
          @email,
          "--password",
          @password,
          "--role",
          "platform_admin"
        ])

      assert code == 2
      assert Enum.join(output, "\n") =~ "refused"
    end

    test "the password is never echoed", %{workspace: workspace} do
      issue_token(workspace)

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

      assert code == 0
      refute Enum.join(output, "\n") =~ @password
    end

    test "a role the Policy does not know is refused", %{workspace: workspace} do
      issue_token(workspace)

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
          "Chief Executive"
        ])

      assert code == 2
      assert Enum.join(output, "\n") =~ "docs/02"
    end
  end

  describe "the operator path" do
    setup %{workspace: workspace} do
      issue_token(workspace)

      {0, _output} =
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

      :ok
    end

    test "an administrator may create another account", %{workspace: workspace} do
      System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

      on_exit(fn -> System.delete_env("VERITAS_OPERATOR_PASSWORD") end)

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          "agent@example.test",
          "--password",
          @password,
          "--role",
          "service_desk_agent",
          "--as",
          @email
        ])

      assert code == 0, output

      assert {:ok, principal} =
               Authn.authenticate(workspace, %{email: "agent@example.test", password: @password})

      assert principal.roles == [:service_desk_agent]
    end

    test "the environment identity supports creating accounts and resetting passwords", %{
      workspace: workspace
    } do
      System.put_env("VERITAS_OPERATOR_EMAIL", @email)
      System.put_env("VERITAS_OPERATOR_PASSWORD", @password)
      on_exit(fn -> System.delete_env("VERITAS_OPERATOR_PASSWORD") end)

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          "agent@example.test",
          "--password",
          @password,
          "--role",
          "service_desk_agent"
        ])

      assert code == 0, Enum.join(output, "\n")

      new_password = "another-fine-passphrase-99"

      {code, output} =
        cli([
          "account",
          "set-password",
          "--workspace",
          workspace,
          "--email",
          "agent@example.test",
          "--password",
          new_password
        ])

      assert code == 0, Enum.join(output, "\n")

      assert {:ok, _} =
               Authn.authenticate(workspace, %{
                 email: "agent@example.test",
                 password: new_password
               })

      assert {:ok, admin} = Authn.authenticate(workspace, %{email: @email, password: @password})
      assert List.last(audit_events(workspace))["actor_id"] == admin.id
    end

    test "an operator who does not administer the Workspace is refused", %{workspace: workspace} do
      # A Service Desk Agent may work tickets. It may not administer
      # accounts: the Policy says so, and the CLI asks the Policy.
      {:ok, _} =
        Authn.create_account(
          workspace,
          %{
            email: "agent@example.test",
            display_name: "Agent",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

      on_exit(fn -> System.delete_env("VERITAS_OPERATOR_PASSWORD") end)

      {code, output} =
        cli([
          "account",
          "create",
          "--workspace",
          workspace,
          "--email",
          "another@example.test",
          "--password",
          @password,
          "--role",
          "service_desk_agent",
          "--as",
          "agent@example.test"
        ])

      assert code == 2
      assert Enum.join(output, "\n") =~ "does not hold authority"
    end

    test "a password reset ends the sessions of the account", %{workspace: workspace} do
      System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

      on_exit(fn -> System.delete_env("VERITAS_OPERATOR_PASSWORD") end)

      {:ok, admin} = Authn.authenticate(workspace, %{email: @email, password: @password})
      {:ok, session} = Authn.establish_session(workspace, admin)

      {code, output} =
        cli([
          "account",
          "set-password",
          "--workspace",
          workspace,
          "--email",
          @email,
          "--password",
          "another-fine-passphrase-99",
          "--as",
          @email
        ])

      assert code == 0, output

      # The old password no longer works, and the new one does.
      assert {:error, :invalid_credentials} =
               Authn.authenticate(workspace, %{email: @email, password: @password})

      assert {:ok, _principal} =
               Authn.authenticate(workspace, %{
                 email: @email,
                 password: "another-fine-passphrase-99"
               })

      # And the reset is in the Audit Log.
      events = audit_events(workspace)

      assert Enum.any?(events, fn event ->
               event["subject_table"] == "user" and event["reason"] =~ "reset"
             end)

      # The session the reset ended is gone.
      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session.token)
    end
  end

  describe "the Audit Log" do
    test "records the operator's own actions", %{workspace: workspace} do
      issue_token(workspace)

      {0, _output} =
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

      events = audit_events(workspace)

      created =
        Enum.find(events, fn event ->
          event["subject_table"] == "user" and event["to_state"] == "active"
        end)

      assert created
      assert created["actor_type"] == "operator"
      assert created["actor_id"] == "bootstrap"
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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
