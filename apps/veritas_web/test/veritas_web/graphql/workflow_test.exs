defmodule Veritas.Web.GraphQL.WorkflowTest do
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  alias Veritas.Core.{Audit, Principal, Tickets, Workflows}
  alias Veritas.Core.Test.WorkflowProposalAdapter, as: ProposalAdapter
  alias Veritas.Web.GraphQL.Schema

  setup %{workspace: workspace} do
    %{
      admin: Principal.new("owner", workspace, [:platform_admin]),
      operator: Principal.new("operator", workspace, [:incident_manager, :service_desk_agent])
    }
  end

  test "GraphQL saves, publishes and completes a ticket with explicit human approval", ctx do
    definition = Workflows.template("incident")

    definition =
      update_in(definition["steps"], fn steps ->
        Enum.map(steps, fn step ->
          if step["kind"] == "ai", do: Map.put(step, "kind", "manual"), else: step
        end)
      end)

    saved = save(ctx, definition)

    published =
      mutate(
        ctx,
        "publishWorkflow",
        "id: $id, expectedRevision: 1",
        %{"id" => saved["id"]},
        "id publishedRevision definition",
        "$id: String!"
      )

    assert published["publishedRevision"] == 1
    assert published["definition"] == definition

    run =
      mutate(
        ctx,
        "startWorkflow",
        "id: $id, inputJson: $input",
        %{
          "id" => saved["id"],
          "input" =>
            Jason.encode!(%{"title" => "Checkout down", "answers" => %{"service" => "Checkout"}})
        },
        "ticket revision status data",
        "$id: String!, $input: String!",
        ctx.operator
      )

    id = run["ticket"]
    assert run["data"]["current_step"] == "triage"

    assert {:ok, %{"title" => "Checkout down", "requester" => "operator"}} =
             Tickets.read(ctx.workspace, id)

    assert complete(ctx, id, 1)["data"]["current_step"] == "processing"
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, id)

    assert complete(ctx, id, 2, %{"work" => "Restored checkout"})["data"]["current_step"] ==
             "resolution"

    result =
      execute(
        "mutation($workspace: String!, $id: String!) { completeWorkflowStep(workspace: $workspace, ticketId: $id, expectedRevision: 3, answersJson: \"{\\\"evidence\\\":\\\"Health checks pass\\\"}\") { revision } }",
        %{"workspace" => ctx.workspace, "id" => id},
        ctx.operator
      )

    assert error(result) =~ "explicitly review and approve"
    assert {:ok, %{"state" => "in_progress"}} = Tickets.read(ctx.workspace, id)

    assert complete(ctx, id, 3, %{"evidence" => "Health checks pass"}, true)["data"][
             "current_step"
           ] == "follow_up"

    finished = complete(ctx, id, 4)
    assert finished["status"] == "completed"
    assert {:ok, %{"state" => "closed"}} = Tickets.read(ctx.workspace, id)
    assert {:ok, persisted} = Workflows.run(ctx.workspace, id, ctx.operator)
    assert persisted["data"]["answers"]["resolution"]["evidence"] == "Health checks pass"

    assert Enum.any?(
             audit_events(ctx.workspace),
             &(&1["actor_id"] == "operator" and &1["reason"] == "Human approved workflow step")
           )

    assert {:ok, :intact} = Audit.verify(ctx.workspace)

    result =
      execute(
        "query($workspace: String!, $id: String!) { ticketWorkflow(workspace: $workspace, ticketId: $id) { status revision data } workflows(workspace: $workspace) { id } workflow(workspace: $workspace, id: \"#{saved["id"]}\") { id } }",
        %{"workspace" => ctx.workspace, "id" => id},
        ctx.operator
      )

    refute result[:errors]
    assert result[:data]["ticketWorkflow"]["status"] == "completed"
    assert result[:data]["workflows"] == [%{"id" => saved["id"]}]
    assert result[:data]["workflow"]["id"] == saved["id"]
  end

  test "stale GraphQL saves preserve the newer draft", ctx do
    saved = save(ctx, Workflows.template("incident"))
    changed = Map.put(Workflows.template("incident"), "name", "New response")

    variables = %{
      "workspace" => ctx.workspace,
      "id" => saved["id"],
      "definition" => Jason.encode!(changed)
    }

    query =
      "mutation($workspace: String!, $id: String!, $definition: String!) { saveWorkflow(workspace: $workspace, id: $id, definitionJson: $definition, expectedRevision: 1) { revision } }"

    assert execute(query, variables, ctx.admin)[:data]["saveWorkflow"]["revision"] == 2
    assert error(execute(query, variables, ctx.admin)) =~ "changed"

    assert {:ok, %{"name" => "New response", "revision" => 2}} =
             Workflows.get(ctx.workspace, saved["id"], ctx.admin)
  end

  test "missing identity, insufficient roles and another Workspace cannot create a workflow",
       ctx do
    query =
      "mutation($workspace: String!, $definition: String!) { saveWorkflow(workspace: $workspace, definitionJson: $definition) { id } }"

    variables = %{
      "workspace" => ctx.workspace,
      "definition" => Jason.encode!(Workflows.template("incident"))
    }

    for actor <- [nil, ctx.operator, Principal.new("other", "other_workspace", [:platform_admin])] do
      result = execute(query, variables, actor)
      assert result[:errors]
      assert result[:data]["saveWorkflow"] == nil
    end

    assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
  end

  test "malformed JSON inputs are useful refusals, with no ticket writes", ctx do
    for {field, args} <- [
          {"saveWorkflow", "definitionJson: $input"},
          {"startWorkflow", "id: \"missing\", inputJson: $input"},
          {"completeWorkflowStep",
           "ticketId: \"missing\", expectedRevision: 1, answersJson: $input"}
        ],
        input <- ["not json", "[]", "null", "42"] do
      query =
        "mutation($workspace: String!, $input: String!) { #{field}(workspace: $workspace, #{args}) { id } }"

      assert error(execute(query, %{"workspace" => ctx.workspace, "input" => input}, ctx.admin)) =~
               "valid JSON object"
    end

    assert {:ok, []} = Tickets.list(ctx.workspace)
  end

  test "GraphQL does not treat an AI draft request or approval flag as a substitute for a proposal",
       ctx do
    {:ok, w} = Workflows.save(ctx.workspace, nil, Workflows.template("incident"), ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "Investigate", "answers" => %{"service" => "Checkout"}},
        ctx.operator
      )

    vars = %{"workspace" => ctx.workspace, "id" => run["ticket"]}

    result =
      execute(
        "mutation($workspace: String!, $id: String!) { completeWorkflowStep(workspace: $workspace, ticketId: $id, expectedRevision: 1, approve: true) { id } }",
        vars,
        ctx.operator
      )

    assert error(result) =~ "AI"
    assert {:ok, %{"revision" => 1}} = Workflows.run(ctx.workspace, run["ticket"], ctx.operator)

    result =
      execute(
        "mutation($workspace: String!, $id: String!) { draftWorkflowStep(workspace: $workspace, ticketId: $id) { id } }",
        vars,
        nil
      )

    assert result[:errors]
    assert {:ok, %{"state" => "new"}} = Tickets.read(ctx.workspace, run["ticket"])
  end

  test "GraphQL AI generation and drafting preserve model choice and human acceptance", ctx do
    on_exit(ProposalAdapter.install())
    definition = Workflows.template()
    Process.put(:workflow_proposal_response, Jason.encode!(definition))

    generated =
      execute(
        "mutation($workspace: String!) { generateWorkflow(workspace: $workspace, prompt: \"Handle outages\", ticketType: \"incident\") }",
        %{"workspace" => ctx.workspace},
        ctx.admin
      )

    refute generated[:errors], inspect(generated)
    assert generated[:data]["generateWorkflow"] == definition
    assert {:ok, []} = Workflows.list(ctx.workspace, ctx.admin)
    {:ok, w} = Workflows.save(ctx.workspace, nil, definition, ctx.admin)
    {:ok, _} = Workflows.publish(ctx.workspace, w["id"], w["revision"], ctx.admin)

    {:ok, run} =
      Workflows.start(
        ctx.workspace,
        w["id"],
        %{"title" => "Outage", "answers" => %{"service" => "API"}},
        ctx.operator
      )

    Process.put(
      :workflow_proposal_response,
      "A triage proposal from the test-only model adapter."
    )

    draft =
      mutate(
        ctx,
        "draftWorkflowStep",
        "ticketId: $id, model: \"chosen-review-model\"",
        %{"id" => run["ticket"]},
        "id revision data",
        "$id: String!",
        ctx.operator
      )

    assert draft["data"]["outputs"]["triage"]["model"] == "chosen-review-model"
    assert {:ok, %{"state" => "new"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert complete(ctx, run["ticket"], 2, %{}, true)["data"]["current_step"] == "processing"
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(ctx.workspace, run["ticket"])
    assert {:ok, :intact} = Audit.verify(ctx.workspace)
  end

  test "HTTP workflow mutations use the authenticated session and require its CSRF proof", %{
    conn: conn,
    workspace: workspace
  } do
    %{conn: signed_in, csrf_token: csrf, principal: principal} =
      sign_in(conn, workspace, roles: ["Platform Admin"])

    payload =
      Jason.encode!(%{
        "query" =>
          "mutation($workspace: String!, $definition: String!) { saveWorkflow(workspace: $workspace, definitionJson: $definition) { id revision } }",
        "variables" => %{
          "workspace" => workspace,
          "definition" => Jason.encode!(Workflows.template())
        }
      })

    request = put_req_header(signed_in, "content-type", "application/json")
    refused = post(request, "/graphql", payload)
    assert refused.status == 403
    assert {:ok, []} = Workflows.list(workspace, principal)

    accepted =
      request |> put_req_header(Veritas.Web.Auth.csrf_header(), csrf) |> post("/graphql", payload)

    body = json_response(accepted, 200)
    refute body["errors"], inspect(body)
    id = body["data"]["saveWorkflow"]["id"]
    assert {:ok, %{"revision" => 1}} = Workflows.get(workspace, id, principal)

    assert Enum.any?(
             audit_events(workspace),
             &(&1["subject"] == id and &1["actor_id"] == principal.id)
           )

    assert {:ok, :intact} = Audit.verify(workspace)
  end

  defp save(ctx, definition) do
    mutate(
      ctx,
      "saveWorkflow",
      "definitionJson: $definition",
      %{"definition" => Jason.encode!(definition)},
      "id revision",
      "$definition: String!"
    )
  end

  defp complete(ctx, id, revision, answers \\ %{}, approve \\ false) do
    mutate(
      ctx,
      "completeWorkflowStep",
      "ticketId: $id, expectedRevision: $revision, answersJson: $answers, approve: $approve",
      %{
        "id" => id,
        "revision" => revision,
        "answers" => Jason.encode!(answers),
        "approve" => approve
      },
      "id status revision data",
      "$id: String!, $revision: Int!, $answers: String!, $approve: Boolean!",
      ctx.operator
    )
  end

  defp mutate(ctx, field, args, variables, selection, declarations, actor \\ nil) do
    result =
      execute(
        "mutation($workspace: String!, #{declarations}) { #{field}(workspace: $workspace, #{args}) { #{selection} } }",
        Map.put(variables, "workspace", ctx.workspace),
        actor || ctx.admin
      )

    refute result[:errors], inspect(result)
    result[:data][field]
  end

  defp execute(query, variables, principal) do
    assert {:ok, result} =
             Absinthe.run(query, Schema, variables: variables, context: %{principal: principal})

    result
  end

  defp error(result), do: Enum.map_join(result[:errors] || [], "; ", & &1[:message])
end
