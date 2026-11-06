defmodule Veritas.Web.WorkflowLiveTest do
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase
  import Phoenix.LiveViewTest
  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Core.{Audit, Tickets, Workflows}
  alias Veritas.Web.ScriptedAdapter

  setup %{conn: conn, workspace: workspace} do
    sign_in(conn, workspace, roles: ["Platform Admin", "Incident Manager", "Service Desk Agent"])
  end

  test "rendered editor saves and publishes an editable intake", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, view, _} = live(conn, "/workflows/new")
    assert render(view) =~ "Publish workflow"

    view
    |> form("#workflow-metadata", %{
      name: "Checkout incident response",
      description: "A real service workflow"
    })
    |> render_change()

    view
    |> form("#workflow-step", %{
      "step" => %{
        "name" => "Report an outage",
        "fields" => %{"0" => %{"label" => "Service affected"}}
      }
    })
    |> render_change()

    view |> element("#workflow-publish") |> render_click()
    assert {:ok, [workflow]} = Workflows.list(workspace, principal)
    assert_patch(view, "/workflows/#{workflow["id"]}")
    assert workflow["published_revision"] == 1
    assert workflow["published_definition"]["name"] == "Checkout incident response"

    assert hd(workflow["published_definition"]["steps"])["fields"] |> hd() |> Map.fetch!("label") ==
             "Service affected"

    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "a refused publish keeps its saved draft, so a corrected retry publishes it", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, view, _} = live(conn, "/workflows/new")
    view |> element("button[phx-value-id=triage]") |> render_click()
    view |> form("#workflow-step", %{"step" => %{"state" => "closed"}}) |> render_change()

    assert view |> element("#workflow-publish") |> render_click() =~
             "is not a legal ticket transition"

    # The draft was saved before publication was refused, and the editor holds it.
    assert {:ok, [draft]} = Workflows.list(workspace, principal)
    assert draft["revision"] == 1
    assert draft["published_revision"] in [nil, 0]
    assert render(view) =~ "Draft v1"

    view |> form("#workflow-step", %{"step" => %{"state" => "acknowledged"}}) |> render_change()
    view |> element("#workflow-publish") |> render_click()

    assert {:ok, [published]} = Workflows.list(workspace, principal)
    assert published["id"] == draft["id"]
    assert_patch(view, "/workflows/#{published["id"]}")
    assert published["revision"] == 2
    assert published["published_revision"] == 2
    triage = Enum.find(published["published_definition"]["steps"], &(&1["id"] == "triage"))
    assert triage["state"] == "acknowledged"
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "rendered intake creates a persisted ticket and opens its workflow", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, w} = Workflows.save(workspace, nil, Workflows.template(), principal)
    {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)
    {:ok, view, _} = live(conn, "/workflows/#{w["id"]}/intake")
    assert render(view) =~ "Affected service"

    result =
      view
      |> form("#workflow-intake", %{
        "title" => "Checkout is unavailable",
        "description" => "Requests fail",
        "answers" => %{"service" => "Checkout"}
      })
      |> render_submit()

    {:ok, run_view, _} = follow_redirect(result, conn)
    assert render(run_view) =~ "AI triage"
    assert {:ok, [ticket]} = Tickets.list(workspace)
    assert {:ok, run} = Workflows.run(workspace, ticket["id"], principal)
    assert run["data"]["answers"]["intake"]["service"] == "Checkout"
    assert has_element?(run_view, "#workflow-ai")
    refute has_element?(run_view, "#workflow-complete button:not([disabled])")
  end

  test "manual step advances through the rendered button and survives reload", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    definition =
      Workflows.template()
      |> update_in(["steps"], fn steps ->
        Enum.map(steps, fn s ->
          if s["id"] == "triage", do: Map.put(s, "kind", "manual"), else: s
        end)
      end)

    {:ok, w} = Workflows.save(workspace, nil, definition, principal)
    {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)

    {:ok, run} =
      Workflows.start(
        workspace,
        w["id"],
        %{"title" => "A real ticket", "answers" => %{"service" => "API"}},
        principal
      )

    path = "/workflows/tickets/#{run["ticket"]}"
    {:ok, view, _} = live(conn, path)
    view |> form("#workflow-complete") |> render_submit()
    assert render(view) =~ "Investigate and restore"
    assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(workspace, run["ticket"])
    {:ok, reloaded, _} = live(conn, path)
    assert render(reloaded) =~ "Work performed"
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "a forged intake submit missing a required field is refused and stores no ticket", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, w} = Workflows.save(workspace, nil, Workflows.template(), principal)
    {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)
    {:ok, view, _} = live(conn, "/workflows/#{w["id"]}/intake")

    # The rendered field is `required`; a forged event skips the browser and must still be refused by the domain.
    assert render_submit(view, "create", %{"title" => "No service named", "answers" => %{}}) =~
             "Affected service is required."

    assert {:ok, []} = Tickets.list(workspace)
  end

  test "a saved draft reopens with its edited steps after reload, and a stale save is refused", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, view, _} = live(conn, "/workflows/new")

    view
    |> form("#workflow-metadata", %{
      name: "Access request handling",
      description: "Edited in the rendered editor"
    })
    |> render_change()

    view |> element("button[phx-value-id=processing]") |> render_click()

    view
    |> form("#workflow-step", %{"step" => %{"name" => "Manager sign-off", "kind" => "approval"}})
    |> render_change()

    view |> element("#workflow-add-field") |> render_click()

    view
    |> form("#workflow-step", %{
      "step" => %{
        "fields" => %{
          "1" => %{
            "label" => "Approver notes",
            "key" => "approver_notes",
            "type" => "textarea",
            "required" => "true"
          }
        }
      }
    })
    |> render_change()

    view |> element("#workflow-save") |> render_click()
    assert {:ok, [w]} = Workflows.list(workspace, principal)
    assert_patch(view, "/workflows/#{w["id"]}")
    assert w["published_revision"] in [nil, 0]

    {:ok, reopened, html} = live(conn, "/workflows/#{w["id"]}")
    assert html =~ "Access request handling"
    assert html =~ "Draft v1"
    reopened |> element("button[phx-value-id=processing]") |> render_click()
    html = render(reopened)
    assert html =~ "Manager sign-off"
    assert html =~ "Approver notes"
    assert html =~ ~s(<option value="approval" selected)
    step = Enum.find(w["definition"]["steps"], &(&1["id"] == "processing"))
    assert step["kind"] == "approval"
    assert Enum.map(step["fields"], & &1["key"]) == ["work", "approver_notes"]
    assert Enum.at(step["fields"], 1)["required"] == true

    # Another session saves first; the reopened editor's revision is now stale.
    {:ok, _} =
      Workflows.save(
        workspace,
        w["id"],
        Map.put(w["definition"], "description", "Changed elsewhere"),
        principal,
        expected_revision: w["revision"]
      )

    assert reopened |> element("#workflow-save") |> render_click() =~
             "This changed since you opened it"

    assert {:ok, %{"revision" => 2, "definition" => %{"description" => "Changed elsewhere"}}} =
             Workflows.get(workspace, w["id"], principal)
  end

  test "a branch step routes through the rendered selector and refuses a destination outside the branch",
       %{conn: conn, workspace: workspace, principal: principal} do
    steps = [
      %{
        "id" => "intake",
        "name" => "Report",
        "kind" => "intake",
        "phase" => "intake",
        "instructions" => "",
        "fields" => [],
        "next" => ["decide"]
      },
      %{
        "id" => "decide",
        "name" => "Decide the path",
        "kind" => "manual",
        "phase" => "processing",
        "instructions" => "",
        "fields" => [],
        "next" => ["fix", "escalate"]
      },
      %{
        "id" => "fix",
        "name" => "Fix it here",
        "kind" => "manual",
        "phase" => "processing",
        "instructions" => "",
        "fields" => [],
        "next" => []
      },
      %{
        "id" => "escalate",
        "name" => "Escalate to the vendor",
        "kind" => "manual",
        "phase" => "after_action",
        "instructions" => "",
        "fields" => [],
        "next" => []
      }
    ]

    {:ok, w} =
      Workflows.save(workspace, nil, Map.put(Workflows.template(), "steps", steps), principal)

    {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)
    {:ok, run} = Workflows.start(workspace, w["id"], %{"title" => "Which way?"}, principal)
    {:ok, view, _} = live(conn, "/workflows/tickets/#{run["ticket"]}")
    assert has_element?(view, "#workflow-complete select[name=next] option[value=fix]")
    assert has_element?(view, "#workflow-complete select[name=next] option[value=escalate]")
    refute has_element?(view, "#workflow-complete select[name=next] option[value=intake]")
    # Forged: a destination the published branch does not offer.
    assert render_submit(view, "complete", %{"next" => "intake"}) =~
             "Choose one of the configured next steps."

    assert {:ok, %{"data" => %{"current_step" => "decide"}}} =
             Workflows.run(workspace, run["ticket"], principal)

    # Forged: no destination at all.
    assert render_submit(view, "complete", %{}) =~ "Choose one of the configured next steps."
    view |> form("#workflow-complete", %{"next" => "escalate"}) |> render_submit()
    assert render(view) =~ "Escalate to the vendor"

    assert {:ok,
            %{
              "data" => %{"current_step" => "escalate", "completed_steps" => ["intake", "decide"]}
            }} = Workflows.run(workspace, run["ticket"], principal)

    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "branch destinations chosen in the rendered selector are saved and survive reload", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, view, _} = live(conn, "/workflows/new")
    view |> element("button[phx-value-id=processing]") |> render_click()

    assert has_element?(
             view,
             "#workflow-step select[multiple] option[value=resolution][selected]"
           )

    refute has_element?(view, "#workflow-step select[multiple] option[value=follow_up][selected]")

    view
    |> form("#workflow-step", %{"step" => %{"next" => ["resolution", "follow_up"]}})
    |> render_change()

    view |> element("#workflow-save") |> render_click()
    assert {:ok, [w]} = Workflows.list(workspace, principal)

    assert Enum.find(w["definition"]["steps"], &(&1["id"] == "processing"))["next"] == [
             "resolution",
             "follow_up"
           ]

    {:ok, reopened, _} = live(conn, "/workflows/#{w["id"]}")
    reopened |> element("button[phx-value-id=processing]") |> render_click()

    assert has_element?(
             reopened,
             "#workflow-step select[multiple] option[value=resolution][selected]"
           )

    assert has_element?(
             reopened,
             "#workflow-step select[multiple] option[value=follow_up][selected]"
           )
  end

  test "a field added after another was removed gets its own identifier and the draft saves", %{
    conn: conn,
    workspace: workspace,
    principal: principal
  } do
    {:ok, view, _} = live(conn, "/workflows/new")
    view |> element("button[phx-value-id=processing]") |> render_click()
    view |> element("#workflow-add-field") |> render_click()
    view |> element("#workflow-add-field") |> render_click()
    view |> element("button[phx-click=remove-field][phx-value-index='1']") |> render_click()
    view |> element("#workflow-add-field") |> render_click()
    view |> element("#workflow-save") |> render_click()
    # Before the fix the third add reused field_3 and the domain refused the save.
    assert {:ok, [w]} = Workflows.list(workspace, principal)

    keys =
      Enum.find(w["definition"]["steps"], &(&1["id"] == "processing"))["fields"]
      |> Enum.map(& &1["key"])

    assert keys == ["work", "field_3", "field_4"]
  end

  describe "with a configured provider" do
    setup do
      AdapterRegistry.register(ScriptedAdapter.id(), ScriptedAdapter)

      Application.put_env(:veritas_core, :providers,
        scripted: [base_url: "http://scripted.invalid", model: "scripted-1"]
      )

      on_exit(fn -> Application.delete_env(:veritas_core, :providers) end)
      :ok
    end

    test "Design with AI corrects an unknown field type and publishes through rendered controls",
         %{
           conn: conn,
           workspace: workspace,
           principal: principal
         } do
      Application.put_env(:veritas_core, :providers,
        scripted: [base_url: "http://workflow-design-repair.invalid", model: "scripted-1"]
      )

      {:ok, view, _} = live(conn, "/workflows/new")

      view
      |> form("#workflow-generate", %{
        "prompt" => "Design an incident workflow for checkout latency with AI triage and review.",
        "model" => ""
      })
      |> render_submit()

      assert render_async(view, 5_000) =~ "AI drafted the workflow"

      assert has_element?(
               view,
               ~s(#workflow-metadata input[value="AI checkout incident response"])
             )

      assert {:ok, []} = Workflows.list(workspace, principal)
      view |> element("#workflow-publish") |> render_click()
      assert {:ok, [published]} = Workflows.list(workspace, principal)
      assert published["published_revision"] == published["revision"]

      result =
        view
        |> element(~s(a[href="/workflows/#{published["id"]}/intake"]))
        |> render_click()

      {:ok, intake, _} = follow_redirect(result, conn)

      result =
        intake
        |> form("#workflow-intake", %{
          "title" => "Checkout latency",
          "answers" => %{"service" => "Checkout"}
        })
        |> render_submit()

      {:ok, run_view, _} = follow_redirect(result, conn)
      assert render(run_view) =~ "AI triage"
      assert {:ok, [ticket]} = Tickets.list(workspace)
      assert {:ok, run} = Workflows.run(workspace, ticket["id"], principal)
      assert run["workflow"] == published["id"]
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "an invalid AI design preserves the person's existing editor draft", %{
      conn: conn,
      workspace: workspace,
      principal: principal
    } do
      Application.put_env(:veritas_core, :providers,
        scripted: [base_url: "http://workflow-design-invalid.invalid", model: "scripted-1"]
      )

      {:ok, view, _} = live(conn, "/workflows/new")
      view |> form("#workflow-metadata", %{name: "Keep my draft"}) |> render_change()

      view
      |> form("#workflow-generate", %{"prompt" => "Design an incident workflow.", "model" => ""})
      |> render_submit()

      html = render_async(view, 5_000)
      assert html =~ "dropdown"
      assert html =~ "service"
      assert has_element?(view, ~s(#workflow-metadata input[value="Keep my draft"]))
      assert has_element?(view, "#workflow-generate button[type=submit]:not([disabled])")
      assert {:ok, []} = Workflows.list(workspace, principal)
      assert {:ok, []} = Tickets.list(workspace)
    end

    test "the whole flow: live model catalogue, AI proposal, explicit approvals, follow-up, persisted outputs and audit",
         %{conn: conn, workspace: workspace, principal: principal} do
      {:ok, w} = Workflows.save(workspace, nil, Workflows.template(), principal)
      {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)

      {:ok, run} =
        Workflows.start(
          workspace,
          w["id"],
          %{"title" => "Checkout is unavailable", "answers" => %{"service" => "Checkout"}},
          principal
        )

      path = "/workflows/tickets/#{run["ticket"]}"
      {:ok, view, _} = live(conn, path)

      # The model list comes from the provider's catalogue, not from a hardcoded option.
      refute render(view) =~ ~s(<option value="scripted-1")
      view |> element("#workflow-load-models") |> render_click()
      assert render_async(view, 5_000) =~ ~s(<option value="scripted-1")

      # Forged approval before any proposal exists is refused; the ticket does not move.
      assert render_submit(view, "complete", %{"approved" => "true"}) =~
               "Run the AI step and review its proposal before approving it."

      assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, run["ticket"])

      # The AI step runs with the selected catalogue model and produces a proposal, not a completion.
      view |> form("#workflow-ai", %{"model" => "scripted-1"}) |> render_submit()
      html = render_async(view, 10_000)
      assert html =~ "AI proposal · awaiting your review"
      assert html =~ "The answer, from the tool the agent called."
      assert html =~ "scripted / scripted-1"

      assert {:ok,
              %{
                "data" => %{
                  "current_step" => "triage",
                  "outputs" => %{"triage" => %{"model" => "scripted-1", "provider" => "scripted"}}
                }
              }} = Workflows.run(workspace, run["ticket"], principal)

      # Forged completion without the approval checkbox is refused.
      assert render_submit(view, "complete", %{}) =~
               "A human must explicitly review and approve this step."

      assert {:ok, %{"state" => "new"}} = Tickets.read(workspace, run["ticket"])

      # Rendered approval advances to the manual step and moves the ticket.
      view |> form("#workflow-complete", %{"approved" => "true"}) |> render_submit()
      assert render(view) =~ "Investigate and restore"
      assert {:ok, %{"state" => "acknowledged"}} = Tickets.read(workspace, run["ticket"])

      # Manual step with a required field; the approval step needs evidence and the checkbox.
      view
      |> form("#workflow-complete", %{"answers" => %{"work" => "Rolled back the deploy"}})
      |> render_submit()

      assert render(view) =~ "Verify resolution"

      assert render_submit(view, "complete", %{
               "answers" => %{"evidence" => "Synthetic checks green"}
             }) =~ "A human must explicitly review and approve this step."

      view
      |> form("#workflow-complete", %{
        "answers" => %{"evidence" => "Synthetic checks green"},
        "approved" => "true"
      })
      |> render_submit()

      assert render(view) =~ "AI after-action review"
      assert {:ok, %{"state" => "resolved"}} = Tickets.read(workspace, run["ticket"])

      # Follow-up: the after-action AI step, approved, finishes the workflow.
      view |> form("#workflow-ai", %{"model" => ""}) |> render_submit()
      assert render_async(view, 10_000) =~ "AI proposal · awaiting your review"
      view |> form("#workflow-complete", %{"approved" => "true"}) |> render_submit()
      html = render(view)
      assert html =~ "The work and follow-up are recorded."

      assert {:ok, %{"status" => "completed", "data" => data}} =
               Workflows.run(workspace, run["ticket"], principal)

      assert data["completed_steps"] == [
               "intake",
               "triage",
               "processing",
               "resolution",
               "follow_up"
             ]

      assert data["answers"]["processing"]["work"] == "Rolled back the deploy"
      assert data["answers"]["resolution"]["evidence"] == "Synthetic checks green"
      assert data["outputs"]["follow_up"]["text"] =~ "The answer"
      assert {:ok, %{"state" => "closed"}} = Tickets.read(workspace, run["ticket"])

      # Reload: the recorded work, answers and approved AI outputs are all still there.
      {:ok, reloaded, html} = live(conn, path)
      assert html =~ "Completed"
      assert html =~ "Rolled back the deploy"
      assert html =~ "Synthetic checks green"
      assert html =~ "Approved AI output"
      refute has_element?(reloaded, "#workflow-complete")
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "looping back to an AI step hides the earlier proposal and keeps approval locked until a fresh one",
         %{conn: conn, workspace: workspace, principal: principal} do
      [intake, ai, manual | _] = Workflows.template()["steps"]

      done = %{
        "id" => "done",
        "name" => "Finish",
        "kind" => "manual",
        "phase" => "after_action",
        "instructions" => "",
        "fields" => [],
        "next" => []
      }

      steps = [
        intake,
        Map.put(ai, "state", ""),
        Map.merge(manual, %{"state" => "", "fields" => [], "next" => ["triage", "done"]}),
        done
      ]

      {:ok, w} =
        Workflows.save(workspace, nil, Map.put(Workflows.template(), "steps", steps), principal)

      {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)

      {:ok, run} =
        Workflows.start(
          workspace,
          w["id"],
          %{"title" => "Needs rework", "answers" => %{"service" => "API"}},
          principal
        )

      {:ok, view, _} = live(conn, "/workflows/tickets/#{run["ticket"]}")

      view |> form("#workflow-ai", %{"model" => ""}) |> render_submit()
      assert render_async(view, 10_000) =~ "AI proposal · awaiting your review"
      view |> form("#workflow-complete", %{"approved" => "true"}) |> render_submit()
      # The manual step sends the work back to the AI step.
      view |> form("#workflow-complete", %{"next" => "triage"}) |> render_submit()

      # The proposal approved on the first visit is history, not a fresh proposal for this visit.
      html = render(view)
      refute html =~ "AI proposal · awaiting your review"
      assert html =~ "Approved AI output"
      assert has_element?(view, "#workflow-ai button[type=submit]", "Run AI step")
      assert has_element?(view, "#workflow-complete button[type=submit][disabled]")

      assert render_submit(view, "complete", %{"approved" => "true"}) =~
               "Run the AI step and review its proposal before approving it."

      assert {:ok, %{"data" => %{"current_step" => "triage"}}} =
               Workflows.run(workspace, run["ticket"], principal)

      view |> form("#workflow-ai", %{"model" => ""}) |> render_submit()
      assert render_async(view, 10_000) =~ "AI proposal · awaiting your review"
      assert has_element?(view, "#workflow-ai button[type=submit]", "Regenerate proposal")
      refute has_element?(view, "#workflow-complete button[type=submit][disabled]")
    end

    test "the editor lists the provider's catalogue for an AI step and for the designer", %{
      conn: conn,
      workspace: workspace,
      principal: principal
    } do
      {:ok, view, _} = live(conn, "/workflows/new")
      view |> element("button[phx-value-id=triage]") |> render_click()
      refute render(view) =~ ~s(<option value="scripted-1")
      view |> element("#workflow-step-load-models") |> render_click()
      html = render_async(view, 5_000)
      assert html =~ ~s(<datalist id="workflow-model-catalogue"><option value="scripted-1")
      assert html =~ ~s(<option value="scripted-1">scripted-1</option>)
      view |> form("#workflow-step", %{"step" => %{"model" => "scripted-1"}}) |> render_change()
      view |> element("#workflow-save") |> render_click()
      assert {:ok, [w]} = Workflows.list(workspace, principal)
      assert Enum.find(w["definition"]["steps"], &(&1["id"] == "triage"))["model"] == "scripted-1"
    end
  end

  test "recorded work shows the latest approved AI output per step and never a pending re-draft",
       %{conn: conn, workspace: workspace, principal: principal} do
    on_exit(Veritas.Core.Test.WorkflowProposalAdapter.install())
    [intake, ai, manual | _] = Workflows.template()["steps"]

    done = %{
      "id" => "done",
      "name" => "Finish",
      "kind" => "manual",
      "phase" => "after_action",
      "instructions" => "",
      "fields" => [],
      "next" => []
    }

    steps = [
      intake,
      Map.put(ai, "state", ""),
      Map.merge(manual, %{"state" => "", "fields" => [], "next" => ["triage", "done"]}),
      done
    ]

    {:ok, w} =
      Workflows.save(workspace, nil, Map.put(Workflows.template(), "steps", steps), principal)

    {:ok, _} = Workflows.publish(workspace, w["id"], w["revision"], principal)

    {:ok, run} =
      Workflows.start(
        workspace,
        w["id"],
        %{"title" => "History", "answers" => %{"service" => "API"}},
        principal
      )

    path = "/workflows/tickets/#{run["ticket"]}"
    a = "Proposal A, approved on the first visit."
    b = "Proposal B, approved on the second visit."

    Process.put(:workflow_proposal_response, a)
    {:ok, _} = Workflows.draft(workspace, run["ticket"], principal)
    {:ok, view, _} = live(conn, path)
    view |> form("#workflow-complete", %{"approved" => "true"}) |> render_submit()
    view |> form("#workflow-complete", %{"next" => "triage"}) |> render_submit()

    Process.put(:workflow_proposal_response, b)
    {:ok, _} = Workflows.draft(workspace, run["ticket"], principal)
    {:ok, view, _} = live(conn, path)
    # B is the proposal under review; A is still the approved output recorded for the step.
    assert has_element?(view, "#workflow-recorded details", a)
    refute has_element?(view, "#workflow-recorded", b)
    assert render(view) =~ b

    view |> form("#workflow-complete", %{"approved" => "true"}) |> render_submit()
    {:ok, reloaded, _} = live(conn, path)
    assert has_element?(reloaded, "#workflow-recorded details", b)
    refute has_element?(reloaded, "#workflow-recorded", a)
    # The earlier approval is kept in the run's chronological history, not dropped.
    assert {:ok, %{"data" => %{"approved_outputs" => approved}}} =
             Workflows.run(workspace, run["ticket"], principal)

    assert Enum.map(approved, & &1["text"]) == [a, b]
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  test "an unauthorized forged publish is refused and stores no workflow", %{workspace: workspace} do
    %{conn: auditor_conn, principal: auditor} =
      sign_in(Phoenix.ConnTest.build_conn(), workspace,
        email: "auditor@example.test",
        roles: ["Auditor"]
      )

    {:ok, view, _} = live(auditor_conn, "/workflows/new")
    refute has_element?(view, "#workflow-publish")
    assert render_click(view, "publish", %{}) =~ "Refused" or render(view) =~ "authority"
    assert {:ok, []} = Workflows.list(workspace, auditor)
  end
end
