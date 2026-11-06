defmodule Veritas.Core.PolicyTest do
  @moduledoc """
  The behaviour `docs/09` §4 fixes for the authorisation decision point.

  The role matrix under test is the one in `docs/02` §Roles and RACI. These
  tests read that matrix as the corpus writes it: a role acts on a ticket
  type when it holds R or A there, and the hard rules beside the matrix are
  enforced as the exceptions they are.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Policy, Principal}

  describe "the default answer" do
    test "is refusal", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Requester"])

      assert {:deny, reason} =
               Policy.authorize(principal, "not:a:capability", %{workspace: workspace})

      assert reason =~ "not in the vocabulary"
    end

    test "is refusal for a principal that holds no role", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, [])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:read", %{workspace: workspace})

      assert reason =~ "holds no role"
    end

    test "is refusal for a request with no workspace context", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Platform Admin"])

      assert {:deny, reason} = Policy.authorize(principal, "ticket:read", %{})
      assert reason =~ "no workspace context"
    end

    test "is refusal when the ticket type is not named", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:write", %{workspace: workspace})

      assert reason =~ "names no ticket type"
    end

    test "ignores a role that is not in the vocabulary", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Chief Executive"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:read", %{workspace: workspace})

      assert reason =~ "holds no role"
    end
  end

  describe "the role matrix" do
    test "a Requester may write a Service Request and may not write an Incident", %{
      workspace: workspace
    } do
      principal = Principal.new("u1", workspace, ["Requester"])

      assert :allow =
               Policy.authorize(principal, "ticket:write", %{
                 workspace: workspace,
                 ticket_type: "service_request"
               })

      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:write", %{
                 workspace: workspace,
                 ticket_type: "incident"
               })
    end

    test "a Service Desk Agent may move an Incident but may not move a Change", %{
      workspace: workspace
    } do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      assert :allow =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "incident"
               })

      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "change"
               })
    end

    test "an Incident Manager may move an Incident", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Incident Manager"])

      assert :allow =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "incident"
               })
    end

    test "a Platform Admin holds no transition rights in the enterprise profile", %{
      workspace: workspace
    } do
      with_profile(:enterprise, fn ->
        principal = Principal.new("u1", workspace, ["Platform Admin"])

        for type <- Policy.ticket_types() do
          assert {:deny, _reason} =
                   Policy.authorize(principal, "ticket:transition", %{
                     workspace: workspace,
                     ticket_type: Atom.to_string(type)
                   })
        end
      end)
    end

    test "an Auditor may read the Audit Log but may move nothing", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Auditor"])

      assert :allow = Policy.authorize(principal, "audit:read", %{workspace: workspace})

      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "incident"
               })
    end

    test "an Agentic Actor holds no R and no A anywhere", %{workspace: workspace} do
      principal = Principal.new("a1", workspace, ["Agentic Actor"], kind: :agentic)

      # It may read — the matrix gives it "consulted" — but it may not act.
      assert :allow = Policy.authorize(principal, "ticket:read", %{workspace: workspace})

      for type <- Policy.ticket_types() do
        assert {:deny, _reason} =
                 Policy.authorize(principal, "ticket:write", %{
                   workspace: workspace,
                   ticket_type: Atom.to_string(type)
                 })
      end
    end

    test "a Requester may withdraw their own Service Request and may not authorise one", %{
      workspace: workspace
    } do
      principal = Principal.new("u1", workspace, ["Requester"])

      assert :allow =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "service_request",
                 to_state: "cancelled",
                 requester: "u1"
               })

      # Somebody else's request.
      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "service_request",
                 to_state: "cancelled",
                 requester: "u2"
               })

      # An authorisation, which the corpus says a Requester never gives.
      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "service_request",
                 to_state: "authorized",
                 requester: "u1"
               })
    end

    test "only the CI Steward writes CI records", %{workspace: workspace} do
      steward = Principal.new("u1", workspace, ["CI Steward"])
      requester = Principal.new("u2", workspace, ["Requester"])

      assert :allow = Policy.authorize(steward, "ci:write", %{workspace: workspace})
      assert {:deny, _reason} = Policy.authorize(requester, "ci:write", %{workspace: workspace})

      # Both may read: the CMDB is shared substrate.
      assert :allow = Policy.authorize(requester, "ci:read", %{workspace: workspace})
    end

    test "only the Platform Admin administers accounts", %{workspace: workspace} do
      admin = Principal.new("u1", workspace, ["Platform Admin"])
      agent = Principal.new("u2", workspace, ["Service Desk Agent"])
      auditor = Principal.new("u3", workspace, ["Auditor"])

      assert :allow =
               Policy.authorize(admin, "account:administrate", %{workspace: workspace})

      assert {:deny, _reason} =
               Policy.authorize(agent, "account:administrate", %{workspace: workspace})

      assert {:deny, _reason} =
               Policy.authorize(auditor, "account:administrate", %{workspace: workspace})

      # And not in another Workspace: an administrator administers their own.
      assert {:deny, _reason} =
               Policy.authorize(admin, "account:administrate", %{workspace: "another_workspace"})
    end
  end

  describe "the workspace" do
    test "a principal is refused in another workspace", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:read", %{workspace: "another-workspace"})

      assert reason =~ "acts in"
      assert reason =~ "another-workspace"
    end
  end

  describe "separation of duty" do
    test "the author of a Change may not authorise it", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Change Manager"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "change",
                 to_state: "authorized",
                 author_id: "u1"
               })

      assert reason =~ "authored this record"
    end

    test "the requester of a Change may not authorise it", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["CAB Chair"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "change",
                 to_state: "authorized",
                 requester_id: "u1"
               })

      assert reason =~ "requested this record"
    end

    test "a sole implementer may not also authorise", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["CAB Chair"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "change",
                 to_state: "authorized",
                 implementer_id: "u1",
                 sole_implementer: true
               })

      assert reason =~ "sole implementer"
    end

    test "a CAB member who owns the affected CI must abstain", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["CAB Member"])

      assert {:deny, reason} =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "change",
                 to_state: "authorized",
                 ci_owner_id: "u1"
               })

      assert reason =~ "owns the affected CI"
    end

    test "a move that is not an authorisation is not caught by the rule", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      assert :allow =
               Policy.authorize(principal, "ticket:transition", %{
                 workspace: workspace,
                 ticket_type: "incident",
                 to_state: "acknowledged",
                 author_id: "u1"
               })
    end
  end

  describe "the deployment profile" do
    test "the default is the home lab, so one operator can run the product" do
      assert Policy.profile() == :home_lab
      assert Policy.profile_name() == "home lab"
    end

    test "the operator chooses it with one environment variable" do
      System.put_env("VERITAS_DEPLOYMENT_PROFILE", "enterprise")

      on_exit(fn -> System.delete_env("VERITAS_DEPLOYMENT_PROFILE") end)

      assert Policy.profile() == :enterprise
    end

    test "in the home lab a Platform Admin holds the union of the working roles", %{
      workspace: workspace
    } do
      with_profile(:home_lab, fn ->
        principal = Principal.new("u1", workspace, ["Platform Admin"])

        # The union: the roles that work tickets may write and move them.
        assert :allow =
                 Policy.authorize(principal, "ticket:write", %{
                   workspace: workspace,
                   ticket_type: "incident"
                 })

        assert :allow =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "incident"
                 })

        # And the roles that own the configuration records write them.
        assert :allow =
                 Policy.authorize(principal, "ci:write", %{workspace: workspace})

        assert :allow =
                 Policy.authorize(principal, "delivery:write", %{workspace: workspace})
      end)
    end

    test "in the enterprise profile the same Platform Admin is refused", %{
      workspace: workspace
    } do
      with_profile(:enterprise, fn ->
        principal = Principal.new("u1", workspace, ["Platform Admin"])

        assert {:deny, _reason} =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "incident"
                 })

        assert {:deny, _reason} =
                 Policy.authorize(principal, "ci:write", %{workspace: workspace})
      end)
    end

    test "the profile changes nothing for the other roles", %{workspace: workspace} do
      with_profile(:home_lab, fn ->
        principal = Principal.new("u1", workspace, ["Auditor"])

        assert {:deny, _reason} =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "incident"
                 })
      end)
    end

    test "in the home lab a Platform Admin may authorise a record they raised", %{
      workspace: workspace
    } do
      with_profile(:home_lab, fn ->
        principal = Principal.new("u1", workspace, ["Platform Admin"])

        # The one-operator case: the operator raised the Change and is the
        # one who decides it. The home-lab profile is the operator's
        # statement that they are running the product alone.
        assert :allow =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "change",
                   to_state: "authorized",
                   requester_id: "u1"
                 })

        assert :allow =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "vulnerability",
                   to_state: "accepted_risk",
                   requester_id: "u1"
                 })

        assert :allow =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "problem",
                   to_state: "closed",
                   requester_id: "u1"
                 })
      end)
    end

    test "in the enterprise profile the same authorisation is refused, and the refusal names the rule",
         %{
           workspace: workspace
         } do
      with_profile(:enterprise, fn ->
        principal = Principal.new("u1", workspace, ["CAB Chair"])

        assert {:deny, reason} =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "change",
                   to_state: "authorized",
                   requester_id: "u1"
                 })

        assert reason =~ "separation of duty"
        assert reason =~ "requested this record"
      end)
    end

    test "the enterprise profile refuses a Platform Admin's transition by the role matrix, and says so",
         %{
           workspace: workspace
         } do
      with_profile(:enterprise, fn ->
        principal = Principal.new("u1", workspace, ["Platform Admin"])

        assert {:deny, reason} =
                 Policy.authorize(principal, "ticket:transition", %{
                   workspace: workspace,
                   ticket_type: "change",
                   to_state: "authorized"
                 })

        assert reason =~ "role matrix"
        assert reason =~ "does not hold authority"
      end)
    end

    test "the note says that the rule did not bind, and only in the home lab", %{
      workspace: workspace
    } do
      principal = Principal.new("u1", workspace, ["Platform Admin"])

      context = %{
        workspace: workspace,
        ticket_type: "change",
        to_state: "authorized",
        requester_id: "u1"
      }

      with_profile(:home_lab, fn ->
        note = Policy.authorisation_note(principal, context)

        assert note["separation_of_duty"] =~ "home-lab profile"
      end)

      with_profile(:enterprise, fn ->
        assert Policy.authorisation_note(principal, context) == nil
      end)
    end

    test "an authorisation event records the profile that was in force" do
      # The question "whose decision was this?" has to be answerable from the
      # running system, and the profile is part of the answer.
      assert Policy.profile_fact("change", "authorized") == %{"profile" => "home lab"}
      assert Policy.profile_fact("vulnerability", "accepted_risk") == %{"profile" => "home lab"}
      assert Policy.profile_fact("problem", "closed") == %{"profile" => "home lab"}

      # A transition that is not an authorisation carries no profile fact.
      assert Policy.profile_fact("incident", "acknowledged") == nil
    end
  end

  # Runs the block with the deployment profile in force, and puts the
  # operator's own setting back afterwards.
  defp with_profile(profile, fun) do
    previous = Application.get_env(:veritas_core, :deployment_profile)

    Application.put_env(:veritas_core, :deployment_profile, profile)

    on_exit(fn ->
      if previous do
        Application.put_env(:veritas_core, :deployment_profile, previous)
      else
        Application.delete_env(:veritas_core, :deployment_profile)
      end
    end)

    fun.()
  end

  describe "the record of a denial" do
    test "a refusal is written to the Audit Log", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Requester"])

      assert {:deny, _reason} =
               Policy.authorize(principal, "ticket:write", %{
                 workspace: workspace,
                 ticket_type: "incident"
               })

      assert {:ok, events} = Audit.entries(workspace)

      denial =
        Enum.find(events, fn event ->
          event["subject_table"] == "principal" and event["to_state"] == "refused"
        end)

      assert denial
      assert denial["subject"] == "u1"
      assert denial["to_state"] == "refused"
      assert denial["diff"]["capability"] == "ticket:write"
      assert denial["diff"]["workspace"] == workspace
      assert {:ok, :intact} = Audit.verify(workspace)
    end

    test "an allowance is not written to the Audit Log as a denial", %{workspace: workspace} do
      principal = Principal.new("u1", workspace, ["Service Desk Agent"])

      assert :allow =
               Policy.authorize(principal, "ticket:read", %{workspace: workspace})

      assert {:ok, events} = Audit.entries(workspace)

      refute Enum.any?(events, fn event -> event["subject_table"] == "principal" end)
    end
  end
end
