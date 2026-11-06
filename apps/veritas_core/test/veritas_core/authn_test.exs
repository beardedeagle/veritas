defmodule Veritas.Core.AuthnTest do
  @moduledoc """
  The behaviour `docs/09` §3 and §4 fix for local accounts and sessions.

  These are behavioural tests: each one names the corpus's rule and asserts
  what an observer can see — the store's rows, the Audit Log's entries, the
  answer a caller gets. None of them asserts that a function returns `true`.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Authn
  alias Veritas.Core.{Audit, Principal, Session}
  alias Veritas.Store

  @password "a-fine-passphrase-the-operator-chose-42"
  @email "operator@example.test"

  describe "a local account" do
    test "is created with an Argon2id hash, and the password is not in the store", %{
      workspace: workspace
    } do
      account = create_account(workspace)

      [row] = rows(workspace, :user)

      assert String.starts_with?(row["password_hash"], "$argon2id$")
      assert row["password_hash"] != @password
      refute Enum.any?(Map.values(row), &(&1 == @password))

      # The corpus's floor: `m=64 MiB, t=3, p=1`.
      assert row["password_hash"] =~ ~r/m=65536,t=3,p=1/
      assert account.id == row["id"]
    end

    test "refuses a password that is on the breached list", %{workspace: workspace} do
      assert {:error, :password_breached} =
               Authn.create_account(workspace, %{email: @email, password: "password"})

      assert rows(workspace, :user) == []
    end

    test "refuses a password when the operator's breached list cannot be read", %{
      workspace: workspace
    } do
      System.put_env("VERITAS_BREACHED_PASSWORD_LIST", "/nonexistent/breached.txt")

      on_exit(fn -> System.delete_env("VERITAS_BREACHED_PASSWORD_LIST") end)

      # The list was configured and could not be read, so the check is
      # refused rather than quietly made weaker.
      assert {:error, :breach_list_unavailable} =
               Authn.create_account(workspace, %{email: @email, password: @password})
    end

    test "signs in with the right credential", %{workspace: workspace} do
      account = create_account(workspace)

      assert {:ok, principal} =
               Authn.authenticate(workspace, %{email: @email, password: @password})

      assert principal.id == account.id
      assert principal.workspace == workspace
      assert principal.roles == [:platform_admin]
    end

    test "refuses a wrong credential", %{workspace: workspace} do
      create_account(workspace)

      assert {:error, :invalid_credentials} =
               Authn.authenticate(workspace, %{email: @email, password: "not-the-password"})
    end

    test "refuses an account that does not exist, in the same way", %{workspace: workspace} do
      create_account(workspace)

      refused =
        Authn.authenticate(workspace, %{email: "nobody@example.test", password: @password})

      wrong = Authn.authenticate(workspace, %{email: @email, password: "not-the-password"})

      # The two refusals are indistinguishable to the caller: an answer that
      # says "no such account" is an account-enumeration oracle.
      assert refused == wrong
      assert refused == {:error, :invalid_credentials}
    end

    test "refuses a disabled account", %{workspace: workspace} do
      account = create_account(workspace)

      disable(workspace, account.id)

      assert {:error, :invalid_credentials} =
               Authn.authenticate(workspace, %{email: @email, password: @password})
    end

    test "ends the sessions of an account whose password was reset", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      assert {:ok, _principal} =
               Authn.set_password(workspace, account.id, "another-fine-passphrase-99",
                 actor_id: "operator"
               )

      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session.token)
    end
  end

  describe "a session" do
    test "stores the digest of the token, not the token", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      [row] = rows(workspace, :session)

      assert row["token_digest"] == Session.digest(session.token)
      assert row["token_digest"] != session.token
      assert row["csrf_digest"] != session.csrf_token
      assert row["scope_digest"] != session.scope_token

      # The raw token is nowhere in the row.
      refute Enum.any?(Map.values(row), &(&1 == session.token))
    end

    test "is refused after 30 minutes of idleness", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      created = session.created_at
      later = DateTime.add(created, 31 * 60, :second)

      assert {:error, :session_idle_expired} =
               Authn.resolve_session(workspace, session.token, now: later)
    end

    test "is refused after 12 hours, however often it is used", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      created = session.created_at

      # The idle window slides on use, so the session is kept alive by being
      # used — and it still ends at its absolute lifetime. A privileged
      # session's token rotates on a timer, so the token is followed as it
      # changes.
      token =
        Enum.reduce(1..24, session.token, fn minute, token ->
          at = DateTime.add(created, minute * 29 * 60, :second)

          case Authn.resolve_session(workspace, token, now: at) do
            {:ok, resolved} ->
              resolved.token || token

            {:error, reason} ->
              flunk("the session ended early, at #{minute} minutes: #{inspect(reason)}")
          end
        end)

      after_twelve_hours = DateTime.add(created, 12 * 60 * 60 + 60, :second)

      assert {:error, :session_expired} =
               Authn.resolve_session(workspace, token, now: after_twelve_hours)
    end

    test "rotates when the principal's roles change", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      set_roles(workspace, account.id, ["Requester"])

      assert {:ok, rotated} = Authn.resolve_session(workspace, session.token)
      assert rotated.token != session.token
      assert rotated.roles == [:requester]

      # The old token stops working at once.
      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session.token)
      assert {:ok, _session} = Authn.resolve_session(workspace, rotated.token)
    end

    test "rotates a privileged session after 30 minutes", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      # The session is used before the rotation interval, so it is alive but
      # its token is 20 minutes old.
      at = DateTime.add(session.created_at, 20 * 60, :second)
      assert {:ok, _session} = Authn.resolve_session(workspace, session.token, now: at)

      later = DateTime.add(session.created_at, 31 * 60, :second)
      assert {:ok, rotated} = Authn.resolve_session(workspace, session.token, now: later)
      assert rotated.token != session.token
    end

    test "does not rotate an unprivileged session on a timer", %{workspace: workspace} do
      account = create_account(workspace, roles: ["Requester"])
      {:ok, session} = Authn.establish_session(workspace, account)

      at = DateTime.add(session.created_at, 20 * 60, :second)
      assert {:ok, _session} = Authn.resolve_session(workspace, session.token, now: at)

      later = DateTime.add(session.created_at, 31 * 60, :second)
      assert {:ok, resolved} = Authn.resolve_session(workspace, session.token, now: later)
      assert resolved.token == nil
    end

    test "is refused once it has been ended", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      assert :ok = Authn.revoke_session(workspace, session.token)

      assert {:error, :unknown_session} = Authn.resolve_session(workspace, session.token)
    end

    test "survives a restart of the Node", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      # A second operating-system process, with its own BEAM and nothing in
      # common with this one but the datastore, resolves the same token.
      # A session held in the BEAM would be gone; a session held in the store
      # is not.
      {output, status} = resolve_in_another_node(workspace, session.token)

      assert status == 0, output
      assert output =~ "RESOLVED:#{account.id}"
    end

    test "writes every authentication event to the Audit Log, in order", %{workspace: workspace} do
      account = create_account(workspace)
      {:ok, session} = Authn.establish_session(workspace, account)

      {:error, :invalid_credentials} =
        Authn.authenticate(workspace, %{email: @email, password: "wrong"})

      assert :ok = Authn.revoke_session(workspace, session.token)

      events = audit_events(workspace)

      session_events =
        Enum.filter(events, fn event -> event["subject_table"] == "session" end)

      assert Enum.map(session_events, & &1["to_state"]) == ["active", "refused", "revoked"]

      # The account's own creation is in the chain too, and it comes first.
      assert Enum.any?(events, fn event ->
               event["subject_table"] == "user" and event["to_state"] == "active"
             end)

      # And the chain still verifies.
      assert {:ok, :intact} = Audit.verify(workspace)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp create_account(workspace, opts \\ []) do
    {:ok, account} =
      Authn.create_account(
        workspace,
        %{
          email: Keyword.get(opts, :email, @email),
          display_name: "Operator",
          roles: Keyword.get(opts, :roles, ["Platform Admin"]),
          password: Keyword.get(opts, :password, @password)
        },
        actor_id: "operator"
      )

    account
  end

  defp disable(workspace, account_id) do
    {:ok, _row} =
      Store.transaction(workspace, fn tx ->
        {:ok, user} = Store.fetch(tx, :user, account_id)
        Store.put(tx, :user, Map.put(user, "disabled", true))
      end)
  end

  defp set_roles(workspace, account_id, roles) do
    {:ok, _row} =
      Store.transaction(workspace, fn tx ->
        {:ok, user} = Store.fetch(tx, :user, account_id)
        Store.put(tx, :user, Map.put(user, "roles", roles))
      end)
  end

  # The child process: a separate operating-system process with its own BEAM.
  # It is given the code paths of this one, the store's URL, and the token,
  # and it resolves the token with nothing but the datastore.
  defp resolve_in_another_node(workspace, token) do
    settings = Application.get_env(:veritas_core, :surreal, [])
    url = settings[:url]

    code = """
    Application.put_env(:veritas_core, :environment, :test)
    Application.put_env(:veritas_core, :surreal, url: System.get_env("V_URL"), user: "root", pass: "root")
    Veritas.Store.Config.configure({Veritas.Store.Surreal, []})
    {:ok, _started} = Application.ensure_all_started(:veritas_core)

    case Veritas.Authn.resolve_session(System.get_env("V_WS"), System.get_env("V_TOKEN")) do
      {:ok, session} -> IO.puts("RESOLVED:" <> session.principal_id)
      {:error, reason} -> IO.puts("REFUSED:" <> inspect(reason))
    end
    """

    paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])

    System.cmd(
      "elixir",
      paths ++ ["-e", code],
      env: [
        {"V_URL", url},
        {"V_WS", workspace},
        {"V_TOKEN", token},
        {"VERITAS_SURREAL_URL", url}
      ]
    )
  end
end
