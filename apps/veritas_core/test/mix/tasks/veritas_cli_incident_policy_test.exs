defmodule Mix.Tasks.Veritas.CliIncidentPolicyTest do
  @moduledoc """
  Exercises Incident policy through the real CLI parser and account authentication.

  Each case owns a Memory Workspace and restores the adapter, environment and
  Mix shell. Independent transactions inspect configuration and immutable versions;
  audit preservation/refusals are assessed separately from policy mutations.

  JSON inputs are exclusively created beneath this snapshot's workspace-local
  `_build/incident-domain-20261106/cli-policy-fixtures/<workspace>/`. They remain
  as synthetic evidence; no prior directory or file is overwritten or deleted.
  Policy values are explicit elapsed-time fixtures, never product defaults. These
  cases do not qualify migration, bootstrap, real Surreal, providers or delivery.
  """
  use ExUnit.Case, async: false

  alias Veritas.Authn
  alias Veritas.Core.Audit
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @email "cli-policy-admin@example.invalid"
  @password "explicit-cli-policy-fixture-passphrase-42"
  @wrong_password "deliberately-wrong-cli-policy-fixture-password"
  @environment ~w(VERITAS_OPERATOR_EMAIL VERITAS_OPERATOR_PASSWORD VERITAS_ROLE)
  @fixture_root Path.expand(
                  "../../../../../_build/incident-domain-20261106/cli-policy-fixtures",
                  __DIR__
                )
  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)

  setup do
    previous_store = Application.fetch_env(:veritas_core, :store)
    previous_environment = Map.new(@environment, &{&1, System.get_env(&1)})
    workspace = StoreCase.unique_workspace()
    foreign_workspace = workspace <> "_foreign"

    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end

    on_exit(fn ->
      try do
        remove_memory_workspaces([workspace, foreign_workspace])
      after
        case previous_store do
          {:ok, configuration} -> Application.put_env(:veritas_core, :store, configuration)
          :error -> Application.delete_env(:veritas_core, :store)
        end

        Enum.each(previous_environment, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end
    end)

    Application.put_env(:veritas_core, :store, Memory)
    Enum.each(@environment, &System.delete_env/1)
    admin = create_account(workspace, @email, ["Platform Admin"])
    System.put_env("VERITAS_OPERATOR_EMAIL", @email)
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)

    File.mkdir_p!(@fixture_root)
    dir = Path.join(@fixture_root, workspace)
    File.mkdir!(dir)

    {:ok, workspace: workspace, foreign_workspace: foreign_workspace, admin: admin, dir: dir}
  end

  test "show and validation preserve absence while first partial save requires explicit null", ctx do
    before = policy_state(ctx.workspace)
    assert before == %{configuration: nil, versions: [], calendars: []}
    assert {0, %{"result" => empty}} = command(args(ctx, "show"))
    assert is_nil(empty["policy_revision"])
    assert is_nil(empty["draft"])
    assert is_nil(empty["active_version"])

    document = %{"reopen_resolution" => "new_cycle"}
    file = json_file(ctx, "partial", document)
    assert {0, %{"result" => validation}} = command(args(ctx, "validate") ++ ["--file", file])
    assert validation["document"] == document
    assert validation["errors"] == %{}
    assert "priority_rules.individual.immediate" in validation["readiness"]["missing"]
    assert policy_state(ctx.workspace) == before

    rejected = assert_no_policy_effects(ctx, args(ctx, "save") ++ ["--file", file], 1, "usage")
    assert rejected.error["message"] =~ "--policy-revision"

    assert {0, %{"result" => saved}} =
             command(args(ctx, "save") ++ ["--file", file, "--policy-revision", "null"])

    assert saved["policy_revision"] == 1
    assert saved["draft"] == %{"revision" => 1, "document" => document}
    assert is_nil(saved["active_version"])
    state = policy_state(ctx.workspace)
    assert state.configuration["revision"] == 1
    assert state.configuration["draft"] == document
    assert state.versions == []
    assert state.calendars == []
    assert {0, %{"result" => shown}} = command(args(ctx, "show"))
    assert shown == saved
    assert policy_state(ctx.workspace) == state
    assert_policy_audit_revisions(ctx, [1])
  end

  test "invalid supplied values return field errors and cannot replace a valid incomplete draft", ctx do
    original = %{"reopen_resolution" => "new_cycle"}
    file = json_file(ctx, "original", original)
    assert {0, _} = command(args(ctx, "save") ++ ["--file", file, "--policy-revision", "null"])
    before = policy_state(ctx.workspace)

    invalid = %{
      "reopen_resolution" => "synthetic-invalid-reopen-mode",
      "sla_targets" => %{
        "P3" => %{"response" => %{"amount" => 0, "unit" => "minutes", "basis" => "elapsed"}}
      }
    }

    invalid_file = json_file(ctx, "invalid-values", invalid)
    expected_errors = %{
      "reopen_resolution" => "invalid",
      "sla_targets.P3.response.amount" => "positive_integer_required"
    }

    assert {0, %{"result" => validation}} =
             command(args(ctx, "validate") ++ ["--file", invalid_file])

    assert validation["errors"] == expected_errors
    assert policy_state(ctx.workspace) == before
    rejected =
      assert_no_policy_effects(ctx,
        args(ctx, "save") ++ ["--file", invalid_file, "--policy-revision", "1"],
        2, "policy_invalid")

    assert rejected.error["fields"] == expected_errors
    refute Jason.encode!(rejected.error) =~ "synthetic-invalid-reopen-mode"
    assert policy_state(ctx.workspace).configuration["draft"] == original
    assert_policy_audit_revisions(ctx, [1])
  end

  test "malformed JSON and malformed mutation revisions are usage refusals without policy effects", ctx do
    for {text, index} <- Enum.with_index(["not JSON", "[]", "null", "42"]) do
      file = fixture_file(ctx, "malformed-#{index}.json", text)

      for verb <- ~w(validate save) do
        assert_no_policy_effects(ctx,
          args(ctx, verb) ++ ["--file", file, "--policy-revision", "null"], 1, "usage")
      end
    end

    file = json_file(ctx, "valid-for-revision-parsing", %{"reopen_resolution" => "new_cycle"})

    for revision <- ["", "0", "-1", "1.5", "one", "1junk"], verb <- ~w(save publish) do
      assert_no_policy_effects(ctx,
        args(ctx, verb) ++ ["--file", file, "--policy-revision=#{revision}", "--approve"],
        1, "usage")
    end

    assert policy_state(ctx.workspace) == %{configuration: nil, versions: [], calendars: []}
    assert_policy_audit_revisions(ctx, [])
  end

  test "null cannot overwrite an existing configuration and stale save preserves the newer draft", ctx do
    first = json_file(ctx, "first", %{"reopen_resolution" => "new_cycle"})
    second_document = %{"reopen_resolution" => "cumulative"}
    second = json_file(ctx, "second", second_document)
    assert {0, _} = command(args(ctx, "save") ++ ["--file", first, "--policy-revision", "null"])

    assert_no_policy_effects(ctx, args(ctx, "save") ++ ["--file", second], 1, "usage")
    refused_null =
      assert_no_policy_effects(ctx,
        args(ctx, "save") ++ ["--file", second, "--policy-revision", "null"],
        2, "policy_revision_conflict")
    assert refused_null.error["current_revision"] == 1

    assert {0, %{"result" => saved}} =
             command(args(ctx, "save") ++ ["--file", second, "--policy-revision", "1"])
    assert saved["policy_revision"] == 2
    assert saved["draft"] == %{"revision" => 2, "document" => second_document}

    stale =
      assert_no_policy_effects(ctx,
        args(ctx, "save") ++ ["--file", first, "--policy-revision", "1"],
        2, "policy_revision_conflict")
    assert stale.error["current_revision"] == 2
    assert policy_state(ctx.workspace).configuration["draft"] == second_document
    assert_policy_audit_revisions(ctx, [1, 2])
  end

  test "approved CAS publication consumes once and subsequent saves use the continuing configuration revision", ctx do
    document = complete_policy()
    file = json_file(ctx, "complete", document)
    assert {0, _} = command(args(ctx, "save") ++ ["--file", file, "--policy-revision", "null"])

    assert_no_policy_effects(ctx, args(ctx, "publish") ++ ["--approve"], 1, "usage")
    no_approval =
      assert_no_policy_effects(ctx, args(ctx, "publish") ++ ["--policy-revision", "1"],
        2, "approval_required")
    assert_policy_denial(no_approval.new_audit, ctx.admin.id)

    stale =
      assert_no_policy_effects(ctx,
        args(ctx, "publish") ++ ["--policy-revision", "2", "--approve"],
        2, "policy_revision_conflict")
    assert stale.error["current_revision"] == 1

    assert {0, %{"result" => published}} =
             command(args(ctx, "publish") ++ ["--policy-revision", "1", "--approve"])
    assert published["policy_revision"] == 2
    assert is_nil(published["draft"])
    assert published["active"] == document
    assert published["readiness"]["missing"] == []
    version_id = published["active_version"]
    assert is_binary(version_id)
    state = policy_state(ctx.workspace)
    assert state.configuration["revision"] == 2
    assert state.configuration["active_policy_version"] == version_id
    assert is_nil(state.configuration["draft"])
    assert [version] = state.versions
    assert version["id"] == version_id
    assert version["status"] == "published"
    assert version["definition"] == Map.put(document, "calendar_versions", %{})
    assert version["published_by"] == %{"type" => "user", "id" => ctx.admin.id}
    assert state.calendars == []

    replay =
      assert_no_policy_effects(ctx,
        args(ctx, "publish") ++ ["--policy-revision", "1", "--approve"],
        2, "policy_revision_conflict")
    assert replay.error["current_revision"] == 2

    no_draft =
      assert_no_policy_effects(ctx,
        args(ctx, "publish") ++ ["--policy-revision", "2", "--approve"],
        2, "policy_unconfigured")
    assert no_draft.error["missing"] == ["draft"]
    assert policy_state(ctx.workspace) == state

    next_document = %{"reopen_resolution" => "cumulative"}
    next_file = json_file(ctx, "post-publication-partial", next_document)
    rejected_nil =
      assert_no_policy_effects(ctx,
        args(ctx, "save") ++ ["--file", next_file, "--policy-revision", "null"],
        2, "policy_revision_conflict")
    assert rejected_nil.error["current_revision"] == 2

    assert {0, %{"result" => saved}} =
             command(args(ctx, "save") ++ ["--file", next_file, "--policy-revision", "2"])
    assert saved["policy_revision"] == 3
    assert saved["active_version"] == version_id
    assert saved["active"] == document
    assert saved["draft"] == %{"revision" => 3, "document" => next_document}
    assert policy_state(ctx.workspace).versions == [version]

    assert {0, %{"result" => next_published}} =
             command(args(ctx, "publish") ++ ["--policy-revision", "3", "--approve"])
    assert next_published["policy_revision"] == 4
    assert next_published["active_version"] != version_id
    assert next_published["active"] == next_document
    assert is_nil(next_published["draft"])
    assert "priority_rules.individual.immediate" in next_published["readiness"]["missing"]
    final = policy_state(ctx.workspace)
    assert length(final.versions) == 2
    assert Enum.find(final.versions, &(&1["id"] == version_id)) == version
    assert final.configuration["revision"] == 4
    assert final.configuration["active_policy_version"] == next_published["active_version"]
    assert final.calendars == []
    assert {0, %{"result" => shown}} = command(args(ctx, "show"))
    assert shown == next_published
    assert_policy_audit_revisions(ctx, [1, 2, 3, 4])

    publications = Enum.filter(policy_mutations(audit_entries(ctx.workspace)), &Map.has_key?(&1["diff"], "version"))
    assert Enum.map(publications, & &1["diff"]["version"]) == [version_id, next_published["active_version"]]
    assert Enum.all?(publications, &(&1["diff"]["approval"] == %{"type" => "user", "id" => ctx.admin.id}))
  end

  test "missing identity, missing password and invalid credentials cannot change policy", ctx do
    file = json_file(ctx, "authentication-input", %{"reopen_resolution" => "new_cycle"})
    save = args(ctx, "save") ++ ["--file", file, "--policy-revision", "null"]

    System.delete_env("VERITAS_OPERATOR_EMAIL")
    assert_no_policy_effects(ctx, save, 1, "usage")
    System.put_env("VERITAS_OPERATOR_EMAIL", @email)
    System.delete_env("VERITAS_OPERATOR_PASSWORD")
    assert_no_policy_effects(ctx, save, 1, "usage")
    System.put_env("VERITAS_OPERATOR_PASSWORD", @wrong_password)
    assert_no_policy_effects(ctx, save, 2, "not_authorised")
    assert_policy_audit_revisions(ctx, [])
  end

  test "an authenticated auditor is denied administration and foreign credentials cannot target this Workspace", ctx do
    auditor_email = "cli-policy-auditor@example.invalid"
    foreign_email = "cli-policy-foreign-admin@example.invalid"
    auditor = create_account(ctx.workspace, auditor_email, ["Auditor"])
    _foreign = create_account(ctx.foreign_workspace, foreign_email, ["Platform Admin"])
    document = %{"reopen_resolution" => "new_cycle"}
    file = json_file(ctx, "authority-input", document)
    assert {0, _} = command(args(ctx, "save") ++ ["--file", file, "--policy-revision", "null"])
    before = policy_state(ctx.workspace)
    foreign_before = policy_state(ctx.foreign_workspace)

    assert {0, %{"result" => redacted}} = command(args(ctx, "show") ++ ["--as", auditor_email])
    assert redacted["policy_revision"] == 1
    assert is_nil(redacted["draft"])
    assert policy_state(ctx.workspace) == before

    for {verb, options} <- [
          {"validate", ["--file", file]},
          {"save", ["--file", file, "--policy-revision", "1"]},
          {"publish", ["--policy-revision", "1", "--approve"]}
        ] do
      refused = assert_no_policy_effects(ctx, args(ctx, verb) ++ options ++ ["--as", auditor_email], 2)
      assert_policy_denial(refused.new_audit, auditor.id)
    end

    # First prove these exact credentials work in their own Workspace. The CLI
    # foreign-Workspace fence is authentication, not an injected foreign Principal.
    foreign_args = ["incident-policy", "show", "--workspace", ctx.foreign_workspace,
      "--as", foreign_email, "--json"]
    assert {0, %{"result" => foreign_show}} = command(foreign_args)
    assert is_nil(foreign_show["policy_revision"])

    for {verb, options} <- [
          {"validate", ["--file", file]},
          {"save", ["--file", file, "--policy-revision", "1"]},
          {"publish", ["--policy-revision", "1", "--approve"]}
        ] do
      assert_no_policy_effects(ctx, args(ctx, verb) ++ options ++ ["--as", foreign_email],
        2, "not_authorised")
    end

    assert policy_state(ctx.workspace) == before
    assert policy_state(ctx.foreign_workspace) == foreign_before
    assert_policy_audit_revisions(ctx, [1])
    assert {:ok, :intact} = Audit.verify(ctx.foreign_workspace)
  end

  defp assert_no_policy_effects(ctx, argv, expected_exit, expected_code \\ nil) do
    before = policy_state(ctx.workspace)
    audit_before = audit_entries(ctx.workspace)
    assert {^expected_exit, %{"error" => error}} = command(argv)
    assert is_binary(error["code"])
    assert is_binary(error["message"])
    if expected_code, do: assert(error["code"] == expected_code)
    assert policy_state(ctx.workspace) == before
    audit_after = audit_entries(ctx.workspace)
    assert Enum.take(audit_after, length(audit_before)) == audit_before
    appended = Enum.drop(audit_after, length(audit_before))
    assert policy_mutations(appended) == []
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
    %{error: error, new_audit: appended}
  end

  defp assert_policy_denial(events, actor_id) do
    assert Enum.any?(events, fn event ->
             event["subject_table"] == "principal" and event["to_state"] == "refused" and
               event["actor_id"] == actor_id and
               get_in(event, ["diff", "capability"]) == "incident_policy_admin"
           end)
  end

  defp assert_policy_audit_revisions(ctx, revisions) do
    events = policy_mutations(audit_entries(ctx.workspace))
    assert Enum.map(events, & &1["diff"]["revision"]) == revisions
    assert Enum.all?(events, &(&1["actor_id"] == ctx.admin.id and &1["actor_type"] == "user"))
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp policy_mutations(events),
    do: Enum.filter(events, &(&1["subject_table"] == "incident_configuration"))

  defp policy_state(workspace) do
    assert {:ok, result} =
             Store.transaction(workspace, fn tx ->
               assert {:ok, configuration} = Store.fetch(tx, :incident_configuration, "current")
               assert {:ok, versions} = Store.list(tx, :incident_policy_version, %{where: [], order_by: [id: :asc]})
               assert {:ok, calendars} = Store.list(tx, :incident_calendar_version, %{where: [], order_by: [id: :asc]})
               {:ok, %{configuration: configuration, versions: versions, calendars: calendars}}
             end)
    result
  end

  defp audit_entries(workspace) do
    assert {:ok, entries} = Audit.entries(workspace)
    entries
  end

  defp create_account(workspace, email, roles) do
    assert {:ok, principal} =
             Authn.create_account(workspace, %{email: email, password: @password, roles: roles})
    principal
  end

  defp complete_policy do
    rules = for impact <- @impacts, urgency <- @urgencies,
      do: %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}
    targets = Map.new(~w(P1 P2 P3 P4), fn priority ->
      {priority, %{
        "response" => %{"amount" => 60, "unit" => "minutes", "basis" => "elapsed"},
        "resolution" => %{"amount" => 240, "unit" => "minutes", "basis" => "elapsed"}
      }}
    end)
    %{"priority_rules" => rules, "sla_targets" => targets, "reopen_resolution" => "new_cycle"}
  end

  defp args(ctx, verb), do: ["incident-policy", verb, "--workspace", ctx.workspace, "--json"]
  defp json_file(ctx, name, value), do: fixture_file(ctx, name <> ".json", Jason.encode!(value))

  defp fixture_file(ctx, name, content) do
    path = Path.join(ctx.dir, name)
    File.open!(path, [:write, :binary, :exclusive], fn file ->
      :ok = IO.binwrite(file, content)
    end)
    path
  end

  defp command(argv) do
    previous_shell = Mix.shell()
    assert is_nil(Process.whereis(:mix_shell))
    Process.register(self(), :mix_shell)

    try do
      Mix.shell(Mix.Shell.Process)
      code =
        try do
          Mix.Tasks.Veritas.Cli.run(argv)
          0
        catch
          :exit, {:shutdown, code} -> code
        end
      output = collect_output() |> Enum.join("\n")
      refute output =~ @password
      refute output =~ @wrong_password
      {code, Jason.decode!(output)}
    after
      if Process.whereis(:mix_shell) == self(), do: Process.unregister(:mix_shell)
      Mix.shell(previous_shell)
    end
  end

  defp collect_output do
    receive do
      {:mix_shell, :info, [message]} -> [message | collect_output()]
      {:mix_shell, :error, [message]} -> [message | collect_output()]
    after
      0 -> []
    end
  end

  defp remove_memory_workspaces(workspaces) do
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox = state.outbox |> Map.drop(workspaces) |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] in workspaces))
        end)
        %{state | workspaces: Map.drop(state.workspaces, workspaces), outbox: outbox}
      end)
    end
    :ok
  end
end
