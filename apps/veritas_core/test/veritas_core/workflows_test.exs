defmodule Veritas.Core.WorkflowsTest do
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.WorkflowProposalAdapter, as: ProposalAdapter

  setup %{workspace: workspace} do
    %{
      admin: Principal.new("owner", workspace, [:platform_admin]),
      operator: Principal.new("operator", workspace, [:incident_manager, :service_desk_agent])
    }
  end

  test "a published workflow creates a real ticket and retains its published version", ctx do
    definition = Workflows.template("incident")
    assert {:ok, workflow} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)

    assert {:ok, published} =
             Workflows.publish(ctx.workspace, workflow["id"], workflow["revision"], ctx.admin)

    assert {:ok, run} =
             Workflows.start(
               ctx.workspace,
               workflow["id"],
               %{"title" => "Checkout unavailable", "answers" => %{"service" => "Checkout"}},
               ctx.operator
             )

    assert {:ok, ticket} = Tickets.read(ctx.workspace, run["ticket"])
    assert ticket["title"] == "Checkout unavailable"
    assert run["data"]["current_step"] == "triage"
    assert run["workflow_revision"] == published["published_revision"]
    changed = Map.put(definition, "name", "Revised response")

    assert {:ok, _} =
             Workflows.save(ctx.workspace, workflow["id"], changed, ctx.admin,
               expected_revision: published["revision"]
             )

    assert {:ok, pinned} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)
    assert pinned["definition"]["name"] == definition["name"]
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "required intake fields refuse creation without leaving a ticket", ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    assert {:error, reason} =
             Workflows.start(ctx.workspace, w["id"], %{"title" => "Incomplete"}, ctx.operator)

    assert reason =~ "Affected service"
    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "invalid graphs and duplicate field identifiers are refused", _ctx do
    d = Workflows.template("incident")

    assert {:error, _} =
             Workflows.validate(put_in(d, ["steps", Access.at(1), "next"], ["missing"]))

    assert {:error, _} = Workflows.validate(put_in(d, ["steps", Access.at(1), "id"], "intake"))
    assert {:error, _} = Workflows.validate(Map.put(d, "steps", []))
  end

  test "editing, publishing and running enforce workspace and role authority", ctx do
    auditor = Principal.new("auditor", ctx.workspace, [:auditor])

    assert {:error, _} =
             Workflows.save(ctx.workspace, nil, Workflows.template("incident"), auditor)

    assert {:error, _} =
             Workflows.save(
               ctx.workspace,
               nil,
               Workflows.template("incident"),
               Principal.new("other", "other", [:platform_admin])
             )

    assert {:error, _} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), nil)
  end

  test "stale edits cannot overwrite a newer draft", ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), ctx.admin)

    assert {:ok, _} =
             Workflows.save(
               ctx.workspace,
               w["id"],
               Map.put(w["definition"], "name", "New name"),
               ctx.admin,
               expected_revision: w["revision"]
             )

    assert {:error, :revision_conflict} =
             Workflows.save(ctx.workspace, w["id"], w["definition"], ctx.admin,
               expected_revision: w["revision"]
             )

    assert {:error, :revision_conflict} =
             Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)
  end

  test "manual steps persist answers and completion, and reject duplicate submission", ctx do
    d =
      Workflows.template("incident")
      |> update_in(["steps"], fn steps ->
        Enum.map(
          steps,
          &Map.put(&1, "kind", if(&1["kind"] == "ai", do: "manual", else: &1["kind"]))
        )
      end)

    {:ok, w} = Workflows.save(ctx.workspace, nil, d, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "A", "answers" => %{"service" => "Checkout"}},
        ctx.operator
      )

    assert {:ok, advanced} =
             Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
               expected_revision: run["revision"]
             )

    assert advanced["data"]["current_step"] == "processing"
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])

    assert {:error, :revision_conflict} =
             Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
               expected_revision: run["revision"]
             )

    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "an AI step cannot complete before a real draft exists", ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "A", "answers" => %{"service" => "Checkout"}},
        ctx.operator
      )

    assert {:error, :ai_draft_required} =
             Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
               expected_revision: run["revision"]
             )

    assert {:ok, %{"state" => "new"}} = Tickets.read(ctx.workspace, run["ticket"])

    assert {:error, :workflow_step_required} =
             Tickets.transition(ctx.workspace, run["ticket"], "acknowledged", ctx.operator)
  end

  test "intake applies its published target state before the next step", ctx do
    definition =
      Workflows.template()
      |> put_in(["steps", Access.at(0), "state"], "acknowledged")
      |> put_in(["steps", Access.at(1), "state"], "in_progress")
      |> put_in(["steps", Access.at(2), "state"], "")

    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    assert {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    assert {:ok, run} =
             Workflows.start(
               ctx.workspace,
               w["id"],
               %{"title" => "A", "answers" => %{"service" => "API"}},
               ctx.operator
             )

    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert run["data"]["current_step"] == "triage"
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "an unauthorized intake transition rolls back the new ticket and run", ctx do
    definition =
      Workflows.template("service_request")
      |> put_in(["steps", Access.at(0), "state"], "triaged")

    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    assert {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)
    requester = Principal.new("requester", ctx.workspace, [:requester])

    assert {:error, _} =
             Workflows.start(
               ctx.workspace,
               w["id"],
               %{"title" => "Access", "answers" => %{"service" => "API"}},
               requester
             )

    assert {:ok, []} = Tickets.list(ctx.workspace)
    assert rows(ctx.workspace, :workflow_run) == []
    refute Enum.any?(audit_events(ctx.workspace), &(&1["subject_table"] == "ticket"))
    assert [refusal] = Enum.filter(audit_events(ctx.workspace), &(&1["to_state"] == "refused"))
    assert refusal["actor_id"] == requester.id
    assert refusal["diff"]["capability"] == "ticket:transition"
    assert refusal["diff"]["ticket_type"] == "service_request"
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "whitespace required fields and unknown answers are refused before creation", ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template(), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    for answers <- [
          %{"service" => " \n\t"},
          %{"service" => "API", "silently_dropped" => "important"}
        ] do
      assert {:error, _} =
               Workflows.start(
                 ctx.workspace,
                 w["id"],
                 %{"title" => "A", "answers" => answers},
                 ctx.operator
               )
    end

    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "optional false checkbox values persist as booleans", ctx do
    definition =
      put_in(Workflows.template(), ["steps", Access.at(0), "fields"], [
        %{"key" => "affected", "label" => "Affected", "type" => "checkbox", "required" => false}
      ])

    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "A", "answers" => %{"affected" => false}},
        ctx.operator
      )

    assert run["data"]["answers"]["intake"]["affected"] == false
  end

  test "intake authorizes the published ticket type even while the draft changes type", ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, _} =
      Workflows.save(ctx.workspace, w["id"], Workflows.template("service_request"), ctx.admin,
        expected_revision: w["revision"]
      )

    requester = Principal.new("requester", ctx.workspace, [:requester])

    assert {:error, _} =
             Workflows.start(
               ctx.workspace,
               w["id"],
               %{"title" => "Forbidden incident", "answers" => %{"service" => "API"}},
               requester
             )

    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "definition validation rejects values which would crash rendering or AI execution", _ctx do
    d = Workflows.template()

    for {path, value} <- [
          {["description"], %{}},
          {["steps", Access.at(1), "instructions"], false},
          {["steps", Access.at(1), "state"], false},
          {["steps", Access.at(1), "model"], 42},
          {["steps", Access.at(0), "fields", Access.at(0), "required"], "true"}
        ] do
      assert {:error, _} = Workflows.validate(put_in(d, path, value))
    end
  end

  test "invalid lifecycle paths cannot become published workflows", ctx do
    d = put_in(Workflows.template(), ["steps", Access.at(1), "state"], "closed")
    {:ok, w} = Workflows.save(ctx.workspace, nil, d, ctx.admin)
    assert {:error, reason} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)
    assert reason =~ "not a legal ticket transition"
    assert {:ok, unpublished} = Workflows.get(ctx.workspace, w["id"], ctx.admin)
    assert unpublished["published_revision"] in [nil, 0]
  end

  test "a machine principal cannot publish, start or complete human-owned workflow work", ctx do
    machine = %{ctx.admin | kind: :agentic}

    d =
      Workflows.template()
      |> update_in(["steps"], &Enum.map(&1, fn step -> Map.put(step, "state", "") end))

    {:ok, w} = Workflows.save(ctx.workspace, nil, d, ctx.admin)
    assert {:error, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], machine)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)
    attrs = %{"title" => "A", "answers" => %{"service" => "API"}}
    assert {:error, _} = Workflows.start(ctx.workspace, w["id"], attrs, machine)
    assert {:ok, []} = Tickets.list(ctx.workspace)
    manual = put_in(d, ["steps", Access.at(1), "kind"], "manual")
    {:ok, w2} = Workflows.save(ctx.workspace, nil, manual, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w2["id"], w2["revision"], ctx.admin)
    {:ok, run} = Workflows.start(ctx.workspace, w2["id"], attrs, ctx.admin)

    assert {:error, _} =
             Workflows.complete(ctx.workspace, run["ticket"], %{}, machine, expected_revision: 1)

    assert {:ok, %{"revision" => 1}} = Workflows.run(ctx.workspace, run["ticket"], ctx.admin)
  end

  describe "AI proposals through the actual host runner with a test-only adapter" do
    setup do
      on_exit(ProposalAdapter.install())
      :ok
    end

    test "blank runtime model selection keeps the step's configured model", ctx do
      definition = put_in(Workflows.template(), ["steps", Access.at(1), "model"], "step-model")
      {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
      {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

      {:ok, run} =
        Workflows.start(
          ctx.workspace,
          w["id"],
          %{"title" => "A", "answers" => %{"service" => "API"}},
          ctx.operator
        )

      {:ok, draft} = Workflows.draft(ctx.workspace, run["ticket"], ctx.operator, model: "")
      assert draft["data"]["outputs"]["triage"]["model"] == "step-model"

      {:ok, draft} =
        Workflows.draft(ctx.workspace, run["ticket"], ctx.operator, model: "another-model")

      assert draft["data"]["outputs"]["triage"]["model"] == "another-model"
    end

    test "empty provider output is refused without persisting a ready proposal", ctx do
      run = ai_run(ctx)
      Process.put(:workflow_proposal_response, " \n")
      assert {:error, reason} = Workflows.draft(ctx.workspace, run["ticket"], ctx.operator)
      assert reason =~ "no usable proposal"

      assert {:ok, %{"revision" => 1, "data" => %{"outputs" => outputs}}} =
               Workflows.run(ctx.workspace, run["ticket"], ctx.operator)

      assert outputs == %{}

      assert {:error, :ai_draft_required} =
               Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                 expected_revision: 1,
                 approve: true
               )
    end

    test "a late AI response cannot replace a proposal already accepted by a human", ctx do
      run = ai_run(ctx)

      assert {:ok, draft} =
               Workflows.draft(ctx.workspace, run["ticket"], ctx.operator,
                 model: "selected-model"
               )

      assert draft["data"]["outputs"]["triage"]["model"] == "selected-model"

      assert {:error, :approval_required} =
               Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                 expected_revision: 2
               )

      Process.put(:workflow_proposal_response, fn ->
        assert {:ok, _} =
                 Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                   expected_revision: 2,
                   approve: true
                 )

        "Late response which must not replace the accepted proposal."
      end)

      assert {:error, :revision_conflict} =
               Workflows.draft(ctx.workspace, run["ticket"], ctx.operator)

      assert {:ok, current} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)
      assert current["revision"] == 3
      assert current["data"]["current_step"] == "processing"
      refute current["data"]["outputs"]["triage"]["text"] =~ "Late response"
      assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])
      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end

    test "returning to an AI step requires a fresh proposal for that visit", ctx do
      [intake, ai, manual | _] = Workflows.template()["steps"]

      steps = [
        intake,
        Map.put(ai, "state", ""),
        Map.merge(manual, %{"state" => "", "fields" => [], "next" => ["triage", "done"]}),
        %{
          "id" => "done",
          "name" => "Finish",
          "kind" => "manual",
          "phase" => "after_action",
          "fields" => [],
          "next" => []
        }
      ]

      {:ok, w} =
        Workflows.save(
          ctx.workspace,
          nil,
          Map.put(Workflows.template(), "steps", steps),
          ctx.admin
        )

      {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

      {:ok, run} =
        Workflows.start(
          ctx.workspace,
          w["id"],
          %{"title" => "Loop", "answers" => %{"service" => "API"}},
          ctx.operator
        )

      Process.put(:workflow_proposal_response, "Approved proposal A")
      {:ok, first_draft} = Workflows.draft(ctx.workspace, run["ticket"], ctx.operator)

      # First-visit proposals from older records have no step_visit marker.
      legacy_draft =
        update_in(first_draft["data"]["outputs"]["triage"], &Map.delete(&1, "step_visit"))

      assert {:ok, _} =
               Veritas.Store.transaction(ctx.workspace, fn tx ->
                 Veritas.Store.put(tx, :workflow_run, legacy_draft)
               end)

      {:ok, _} =
        Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
          expected_revision: 2,
          approve: true
        )

      {:ok, _} =
        Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
          expected_revision: 3,
          next: "triage"
        )

      assert {:error, :ai_draft_required} =
               Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                 expected_revision: 4,
                 approve: true
               )

      Process.put(:workflow_proposal_response, "Unapproved proposal B")
      {:ok, draft} = Workflows.draft(ctx.workspace, run["ticket"], ctx.operator)

      assert [%{"text" => "Approved proposal A", "step_visit" => 1} = accepted] =
               draft["data"]["approved_outputs"]

      assert accepted["approved_by"] == ctx.operator.id
      assert is_binary(accepted["approved_at"])
      assert Workflows.current_output(draft)["text"] == "Unapproved proposal B"
      assert Workflows.approved_output(draft, 1) == accepted
      assert Workflows.approved_output(draft, 3) == nil

      assert {:error, :revision_conflict} =
               Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                 expected_revision: 4,
                 approve: true
               )

      assert {:ok, reloaded} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)
      assert reloaded["data"]["approved_outputs"] == [accepted]

      # Older records may already have overwritten A with B; recover A only from its approval audit.
      assert {:ok, _} =
               Veritas.Store.transaction(ctx.workspace, fn tx ->
                 Veritas.Store.put(
                   tx,
                   :workflow_run,
                   update_in(reloaded["data"], &Map.delete(&1, "approved_outputs"))
                 )
               end)

      assert {:ok, legacy} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)

      assert [%{"text" => "Approved proposal A", "step_visit" => 1} = recovered] =
               legacy["data"]["approved_outputs"]

      assert recovered["approved_by"] == ctx.operator.id
      assert {:ok, _, _} = DateTime.from_iso8601(recovered["approved_at"])
      assert Workflows.current_output(legacy)["text"] == "Unapproved proposal B"

      {:ok, _} =
        Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
          expected_revision: 5,
          approve: true
        )

      assert {:ok, approved_again} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)

      assert [
               %{"text" => "Approved proposal A", "step_visit" => 1},
               %{"text" => "Unapproved proposal B", "step_visit" => 3}
             ] =
               approved_again["data"]["approved_outputs"]

      assert Workflows.approved_output(approved_again, 3)["approved_by"] == ctx.operator.id

      {:ok, _} =
        Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
          expected_revision: 6,
          next: "done"
        )

      assert {:ok, %{"status" => "completed"}} =
               Workflows.complete(ctx.workspace, run["ticket"], %{}, ctx.operator,
                 expected_revision: 7
               )

      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end

    test "AI-generated definitions remain proposals until separately saved and published", ctx do
      definition = Workflows.template()

      Process.put(
        :workflow_proposal_response,
        "```json\n" <> Jason.encode!(definition) <> "\n```"
      )

      assert {:ok, ^definition} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
      assert {:ok, []} = Tickets.list(ctx.workspace)
    end

    test "AI design receives the editor's supported types and real lifecycle rules", ctx do
      Process.put(:workflow_proposal_response, fn request, opts ->
        assert opts[:timeout] == 30_000
        send(self(), {:design_request, request})
        Jason.encode!(Workflows.template())
      end)

      assert {:ok, _} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert_receive {:design_request, request}
      context = design_context(request)
      assert context["field_types"] == ~w(text textarea number select checkbox)
      assert context["step_kinds"] == ~w(intake manual ai approval)
      assert context["phases"] == ~w(intake processing after_action)
      assert context["initial_state"] == "new"

      assert %{"from_state" => "new", "to_state" => "acknowledged"} in context["transitions"]
      refute Enum.any?(context["transitions"], &(&1["to_state"] == "triaged"))
      assert request.tools == []
    end

    test "AI design corrects an unsupported field type once and returns a publishable proposal",
         ctx do
      invalid =
        put_in(
          Workflows.template(),
          ["steps", Access.at(0), "fields", Access.at(0), "type"],
          "string"
        )

      valid = Workflows.template()

      Process.put(:workflow_proposal_response, fn request ->
        calls = Process.get(:design_calls, 0)
        Process.put(:design_calls, calls + 1)

        if calls == 0 do
          Jason.encode!(invalid)
        else
          context = design_context(request)
          assert context["validation_error"] =~ "string"
          assert context["validation_error"] =~ "service"
          assert context["previous_workflow"] == Jason.encode!(invalid)
          Jason.encode!(valid)
        end
      end)

      assert {:ok, ^valid} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert Process.get(:design_calls) == 2
      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
      assert {:ok, saved} = Workflows.save(ctx.workspace, nil, valid, ctx.admin)

      assert {:ok, _} =
               Workflows.publish(ctx.workspace, saved["id"], saved["revision"], ctx.admin)

      assert {:ok, :intact} = Audit.verify(ctx.workspace)
    end

    test "AI design corrects lifecycle errors before returning a proposal", ctx do
      invalid = put_in(Workflows.template(), ["steps", Access.at(1), "state"], "triaged")
      valid = Workflows.template()

      Process.put(:workflow_proposal_response, fn request ->
        calls = Process.get(:design_calls, 0)
        Process.put(:design_calls, calls + 1)

        if calls == 0 do
          Jason.encode!(invalid)
        else
          assert design_context(request)["validation_error"] =~ "new → triaged"
          Jason.encode!(valid)
        end
      end)

      assert {:ok, ^valid} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert Process.get(:design_calls) == 2
      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
    end

    test "AI design preserves invalid-type rejection and stops after one correction", ctx do
      invalid =
        put_in(
          Workflows.template(),
          ["steps", Access.at(0), "fields", Access.at(0), "type"],
          "dropdown"
        )

      Process.put(:workflow_proposal_response, fn _request ->
        Process.put(:design_calls, Process.get(:design_calls, 0) + 1)
        Jason.encode!(invalid)
      end)

      assert {:error, reason} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert reason =~ "dropdown"
      assert reason =~ "service"
      assert Process.get(:design_calls) == 2
      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
      assert {:ok, []} = Tickets.list(ctx.workspace)
    end

    test "AI design does not retry provider failures", ctx do
      Process.put(:workflow_proposal_response, fn _request ->
        Process.put(:design_calls, Process.get(:design_calls, 0) + 1)
        {:error, :provider_failed}
      end)

      assert {:error, :provider_failed} =
               Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin)

      assert Process.get(:design_calls) == 1
    end

    test "a late invalid AI design preserves the error and cannot start a correction", ctx do
      parent = self()

      response = fn _request, opts ->
        send(parent, {:design_call, self(), opts[:timeout]})

        receive do
          :release_response -> "not JSON"
        after
          5_000 -> raise "The fixture response was not released"
        end
      end

      task =
        Task.async(fn ->
          Process.put(:workflow_proposal_response, response)

          Workflows.generate(ctx.workspace, "An incident workflow", "incident", ctx.admin,
            timeout: 1
          )
        end)

      assert_receive {:design_call, responder, 1}, 5_000
      Process.send_after(responder, :release_response, 10)
      assert {:error, reason} = Task.await(task, 5_000)
      assert reason =~ "timed out"
      assert reason =~ "valid workflow object"
      refute_receive {:design_call, _, _}, 0
      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
    end

    test "an unknown design ticket type is refused before requesting a model", ctx do
      Process.put(:workflow_proposal_response, fn _request ->
        send(self(), :unexpected_design_request)
        Jason.encode!(Workflows.template())
      end)

      assert {:error, "Choose a known ticket type."} =
               Workflows.generate(ctx.workspace, "A workflow", "unknown", ctx.admin)

      refute_receive :unexpected_design_request, 0
      assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
    end
  end

  defp design_context(request) do
    request.messages
    |> List.last()
    |> Map.fetch!(:content)
    |> String.split("\n\nRecorded context:\n", parts: 2)
    |> List.last()
    |> Jason.decode!()
  end

  test "proposal-adapter cleanup restores an existing registration" do
    alias Veritas.Agentic.LLM.AdapterRegistry
    on_exit(ProposalAdapter.install())
    AdapterRegistry.register(ProposalAdapter.id(), __MODULE__)
    cleanup = ProposalAdapter.install()
    assert {:ok, ProposalAdapter} = AdapterRegistry.fetch(ProposalAdapter.id())
    cleanup.()
    assert {:ok, __MODULE__} = AdapterRegistry.fetch(ProposalAdapter.id())
  end

  defp ai_run(ctx) do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template(), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "A", "answers" => %{"service" => "API"}},
        ctx.operator
      )

    run
  end
end
