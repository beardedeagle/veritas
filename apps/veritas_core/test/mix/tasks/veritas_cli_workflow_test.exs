defmodule Mix.Tasks.Veritas.CliWorkflowTest do
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Tickets, Workflows}
  alias Veritas.Core.Test.WorkflowProposalAdapter, as: ProposalAdapter
  @password "workflow-test-password-for-local-fixtures-42"

  setup %{workspace: workspace} do
    for variable <- ~w(VERITAS_OPERATOR_EMAIL VERITAS_OPERATOR_PASSWORD VERITAS_ROLE) do
      previous = System.get_env(variable)
      System.delete_env(variable)

      on_exit(fn ->
        if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
      end)
    end

    {:ok, admin} =
      Veritas.Authn.create_account(workspace, %{
        email: "owner@example.test",
        password: @password,
        roles: ["Platform Admin"]
      })

    System.put_env("VERITAS_OPERATOR_EMAIL", "owner@example.test")
    System.put_env("VERITAS_OPERATOR_PASSWORD", @password)
    dir = Path.join(System.tmp_dir!(), "workflow_cli_#{workspace}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{admin: admin, dir: dir}
  end

  test "template JSON can become a saved and published workflow through the CLI", ctx do
    assert {0, definition} = command(["workflow", "template", "--type", "incident"])
    assert definition["ticket_type"] == "incident"
    path = json_file(ctx, "definition", definition)
    assert {0, %{"result" => saved}} = command(args(ctx, "save") ++ ["--file", path])
    assert saved["revision"] == 1

    assert {0, %{"result" => published}} =
             command(args(ctx, "publish") ++ ["--id", saved["id"], "--revision", "1"])

    assert published["published_revision"] == 1
    assert {0, %{"result" => [listed]}} = command(args(ctx, "list"))
    assert listed["id"] == saved["id"]
    assert {0, %{"result" => shown}} = command(args(ctx, "show") ++ ["--id", saved["id"]])
    assert shown["published_definition"] == definition
    assert {:ok, persisted} = Workflows.get(ctx.workspace, saved["id"], ctx.admin)
    assert persisted["published_revision"] == 1

    assert Enum.any?(
             audit_events(ctx.workspace),
             &(&1["subject"] == saved["id"] and &1["actor_id"] == ctx.admin.id)
           )

    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "CLI intake and completion apply the persisted workflow and reject stale progress", ctx do
    [intake | _] = Workflows.template()["steps"]

    definition =
      Map.put(Workflows.template(), "steps", [
        Map.merge(intake, %{"state" => "acknowledged", "next" => ["work"]}),
        %{
          "id" => "work",
          "name" => "Record follow-up",
          "kind" => "approval",
          "phase" => "after_action",
          "state" => "in_progress",
          "fields" => [
            %{
              "key" => "work",
              "label" => "Work performed",
              "type" => "textarea",
              "required" => true
            }
          ],
          "next" => []
        }
      ])

    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    input =
      json_file(ctx, "intake", %{"title" => "API unavailable", "answers" => %{"service" => "API"}})

    assert {0, %{"result" => run}} =
             command(args(ctx, "start") ++ ["--id", w["id"], "--file", input])

    assert {:ok, %{"state" => "acknowledged", "requester" => requester}} =
             Tickets.read(ctx.workspace, run["ticket"])

    assert requester == ctx.admin.id
    assert {0, %{"result" => reloaded}} = command(args(ctx, "run") ++ ["--id", run["ticket"]])
    assert reloaded["data"]["current_step"] == "work"
    answer = json_file(ctx, "answer", %{"work" => "Verified recovery and captured lessons"})

    complete =
      args(ctx, "complete") ++ ["--id", run["ticket"], "--revision", "1", "--file", answer]

    assert {2, _} = command(complete)
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert {0, %{"result" => finished}} = command(complete ++ ["--approve"])
    assert finished["status"] == "completed"
    assert finished["data"]["answers"]["work"]["work"] =~ "captured lessons"

    assert {2, %{"error" => %{"code" => "revision_conflict"}}} =
             command(complete ++ ["--approve"])

    assert {:ok, %{"state" => "in_progress"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "workflow commands require authenticated authority and never accept an actor label", ctx do
    System.delete_env("VERITAS_OPERATOR_EMAIL")
    assert {1, _} = command(args(ctx, "list"))
    System.put_env("VERITAS_OPERATOR_EMAIL", "owner@example.test")

    assert {1, %{"error" => %{"message" => message}}} =
             command(args(ctx, "list") ++ ["--actor", "forged"])

    assert message =~ "--as"
    System.put_env("VERITAS_OPERATOR_PASSWORD", "wrong")

    assert {2, %{"error" => %{"message" => "the operator's credentials were refused"}}} =
             command(args(ctx, "list"))
  end

  test "an authenticated auditor cannot save a workflow", ctx do
    {:ok, _} =
      Veritas.Authn.create_account(ctx.workspace, %{
        email: "auditor@example.test",
        password: @password,
        roles: ["Auditor"]
      })

    path = json_file(ctx, "definition", Workflows.template())
    assert {2, _} = command(args(ctx, "save") ++ ["--as", "auditor@example.test", "--file", path])
    assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
  end

  test "workflow command mistakes give actionable usage errors", ctx do
    for {options, expected} <- [
          {["workflow", "unknown", "--json"], "workflow expects"},
          {args(ctx, "publish"), "--id"},
          {args(ctx, "publish") ++ ["--id", "missing"], "--revision"},
          {args(ctx, "save"), "--file"},
          {args(ctx, "generate"), "--prompt"},
          {args(ctx, "list") ++ ["--made-up", "x"], "Unknown workflow option"}
        ] do
      assert {1, %{"error" => %{"message" => message}}} = command(options)
      assert message =~ expected
    end
  end

  test "malformed file input is refused without writing a workflow", ctx do
    path = Path.join(ctx.dir, "invalid.json")

    for content <- ["not json", "[]", "null"] do
      File.write!(path, content)

      assert {1, %{"error" => %{"message" => message}}} =
               command(args(ctx, "save") ++ ["--file", path])

      assert message =~ "readable JSON object"
    end

    assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
  end

  test "CLI AI generation and drafting use the host runner and require separate human acceptance",
       ctx do
    on_exit(ProposalAdapter.install())
    definition = Workflows.template()
    Process.put(:workflow_proposal_response, Jason.encode!(definition))

    assert {0, %{"result" => ^definition}} =
             command(args(ctx, "generate") ++ ["--prompt", "Handle API outages"])

    assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "API down", "answers" => %{"service" => "API"}},
        ctx.admin
      )

    Process.put(
      :workflow_proposal_response,
      "A triage proposal from the test-only model adapter."
    )

    assert {0, %{"result" => draft}} =
             command(
               args(ctx, "draft") ++ ["--id", run["ticket"], "--model", "chosen-review-model"]
             )

    assert draft["data"]["outputs"]["triage"]["model"] == "chosen-review-model"
    assert {:ok, %{"state" => "new"}} = Tickets.read(ctx.workspace, run["ticket"])
    complete = args(ctx, "complete") ++ ["--id", run["ticket"], "--revision", "2"]
    assert {2, _} = command(complete)
    assert {0, _} = command(complete ++ ["--approve"])
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  defp args(ctx, verb), do: ["workflow", verb, "--workspace", ctx.workspace, "--json"]

  defp json_file(ctx, name, value) do
    path = Path.join(ctx.dir, name <> ".json")
    File.write!(path, Jason.encode!(value))
    path
  end

  defp command(args) do
    previous_shell = Mix.shell()
    Process.register(self(), :mix_shell)
    Mix.shell(Mix.Shell.Process)

    try do
      code =
        try do
          Mix.Tasks.Veritas.Cli.run(args)
          0
        catch
          :exit, {:shutdown, code} -> code
        end

      output = collect() |> Enum.join("\n")
      refute output =~ @password
      {code, Jason.decode!(output)}
    after
      Process.unregister(:mix_shell)
      Mix.shell(previous_shell)
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
