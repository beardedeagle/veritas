defmodule Veritas.Core.PrincipalTest do
  @moduledoc """
  The role vocabulary a Principal carries.

  `docs/09` §4 records that `docs/02` and `docs/08` define different role
  sets, that `docs/02` is normative, and that no implementation may pick a
  vocabulary until `docs/08` is amended. So these tests pin the set this
  implementation uses — the `docs/02` one — and pin what happens to a role
  that is not in it.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Principal

  describe "the vocabulary" do
    test "is the docs/02 role set" do
      names = Principal.role_names() |> Map.values() |> Enum.sort()

      assert names == [
               "Agentic Actor",
               "Auditor",
               "CAB Chair",
               "CAB Member",
               "CI Steward",
               "Change Manager",
               "Incident Manager",
               "Platform Admin",
               "Problem Manager",
               "Requester",
               "Service Desk Agent",
               "Service Desk Manager",
               "Vulnerability Owner"
             ]
    end

    test "is the set docs/09 §4 names" do
      # The twelve ITIL roles, plus the Agentic Actor.
      assert map_size(Principal.role_names()) == 13
    end
  end

  describe "reading a role name" do
    test "accepts the corpus's spelling" do
      assert Principal.known_role("Service Desk Agent") == :service_desk_agent
      assert Principal.known_role("CAB Chair") == :cab_chair
      assert Principal.known_role("Agentic Actor") == :agentic_actor
    end

    test "ignores case and surrounding space" do
      assert Principal.known_role("  service desk agent ") == :service_desk_agent
      assert Principal.known_role("cAb ChAiR") == :cab_chair
    end

    test "accepts the machine spelling of a role" do
      # A name that arrives from a directory, a configuration file or a command
      # line is a token, not a sentence. The corpus spells the role as words
      # and the store carries the token, so the two must meet.
      assert Principal.known_role("platform_admin") == :platform_admin
      assert Principal.known_role("service_desk_agent") == :service_desk_agent
      assert Principal.known_role("CI_STEWARD") == :ci_steward
    end

    test "refuses a name that is not in the vocabulary" do
      assert Principal.known_role("Chief Executive") == nil
      assert Principal.known_role("") == nil
      assert Principal.known_role(nil) == nil
    end
  end

  describe "a principal" do
    test "drops a role it does not know rather than mapping it onto a nearby one" do
      principal = Principal.new("u1", "ws", ["Requester", "Chief Executive"])

      assert principal.roles == [:requester]
    end

    test "carries the corpus's spelling of its roles" do
      principal = Principal.new("u1", "ws", ["Service Desk Agent"])

      assert Principal.role_strings(principal) == ["Service Desk Agent"]
    end

    test "reads a role given in the machine spelling" do
      # An account created with the token spelling holds its authority. It
      # did not: the role was stored and then not recognised, so the account
      # was powerless and said nothing about why.
      principal = Principal.new("u1", "ws", ["platform_admin"])

      assert principal.roles == [:platform_admin]
    end

    test "holds no authority when every role it was given is unknown" do
      principal = Principal.new("u1", "ws", ["Chief Executive"])

      assert principal.roles == []
    end

    test "is recorded in the Audit Log as the kind of actor it is" do
      human = Principal.new("u1", "ws", ["Requester"])
      agent = Principal.new("a1", "ws", ["Agentic Actor"], kind: :agentic)

      assert Principal.audit_actor(human) == %{type: "user", id: "u1"}
      assert Principal.audit_actor(agent) == %{type: "agentic_actor", id: "a1"}
    end
  end
end
