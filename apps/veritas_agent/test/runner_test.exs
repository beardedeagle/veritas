defmodule Veritas.Agent.RunnerTest do
  @moduledoc """
  The host-owned agent loop, over real HTTP against a local stub.

  The loop is where a tool conversation is assembled, and a tool conversation
  is only correct if the provider is handed the whole of it: the assistant
  turn that asked for the calls, and the results of **every** round so far.
  A round that drops either is a round the model cannot answer.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agent.Test.StubProvider
  alias Veritas.Agentic.Runner
  alias Veritas.Agentic.Tool
  alias Veritas.Core.Principal

  @credential_env "VERITAS_AGENT_RUNNER_TEST_TOKEN"

  setup do
    {:ok, stub} = StubProvider.start_link()

    on_exit(fn -> if Process.alive?(stub), do: StubProvider.stop(stub) end)

    # The chain key is host-owned; the test pins one so the suite does not
    # depend on the operator's own file.
    previous = System.get_env("VERITAS_CHAIN_KEY")
    System.put_env("VERITAS_CHAIN_KEY", "test-chain-key-for-the-agent-suite")
    Veritas.Core.Audit.ChainKey.reset()

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("VERITAS_CHAIN_KEY")
        value -> System.put_env("VERITAS_CHAIN_KEY", value)
      end

      Veritas.Core.Audit.ChainKey.reset()
    end)

    {:ok, stub: stub}
  end

  defp tool_call(id, name, arguments) do
    ~s({
      "id": "#{id}",
      "model": "test-model",
      "choices": [
        {"index": 0,
         "message": {"role": "assistant", "content": "looking",
                     "tool_calls": [{"id": "#{id}", "type": "function",
                                     "function": {"name": "#{name}",
                                                  "arguments": "{\\"id\\":\\"#{arguments}\\"}"}}]},
         "finish_reason": "tool_calls"}
      ],
      "usage": {"prompt_tokens": 10, "completion_tokens": 5}
    })
  end

  defp answer(content) do
    ~s({
      "id": "cmpl-final",
      "model": "test-model",
      "choices": [
        {"index": 0, "message": {"role": "assistant", "content": "#{content}"},
         "finish_reason": "stop"}
      ],
      "usage": {"prompt_tokens": 20, "completion_tokens": 8}
    })
  end

  defp register_tool do
    Tool.Registry.register(%Tool.Spec{
      name: "lookup_ci",
      description: "Looks a configuration item up",
      parameters: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}},
      scope: [],
      side_effect: :read,
      handler: fn arguments, _context -> {:ok, %{"id" => arguments["id"], "name" => "a CI"}} end
    })
  end

  defp configure_provider(stub) do
    System.put_env(@credential_env, "runner-test-token")

    on_exit(fn -> System.delete_env(@credential_env) end)

    previous = Application.get_env(:veritas_core, :providers)

    Application.put_env(:veritas_core, :providers,
      probe: [
        kind: :hosted,
        adapter: :openai_compatible,
        base_url: StubProvider.base_url(stub),
        model: "test-model",
        credential_env: @credential_env,
        capabilities: [:tools]
      ]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:veritas_core, :providers)
        value -> Application.put_env(:veritas_core, :providers, value)
      end
    end)
  end

  defp messages_of(request) do
    %{"messages" => messages} = Jason.decode!(request.body)

    messages
  end

  describe "a tool conversation" do
    test "carries the assistant turn and every round's tool results", %{stub: stub} do
      # Two tool rounds and then an answer. The third request is the one that
      # has to carry the whole conversation.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {200, tool_call("call_a", "lookup_ci", "ci-1")},
        {200, tool_call("call_b", "lookup_ci", "ci-2")},
        {200, answer("the configuration item is a CI")}
      ])

      register_tool()
      configure_provider(stub)

      actor = %Principal{id: "u1", workspace: "agent_test", roles: []}

      assert {:ok, result} =
               Runner.ask("agent_test", "which CI is it?", actor: actor, agent: "probe")

      assert result.answer == "the configuration item is a CI"
      assert result.tools_used == ["lookup_ci", "lookup_ci"]

      assert [_first, _second, third] = StubProvider.requests(stub)

      messages = messages_of(third)
      roles = Enum.map(messages, & &1["role"])

      # The assistant turn that asked for the calls is part of the
      # conversation. Without it the provider is handed a tool result it never
      # asked for.
      assert "assistant" in roles

      assistant_turns = Enum.filter(messages, &(&1["role"] == "assistant"))
      assert Enum.any?(assistant_turns, &(&1["tool_calls"] != nil))

      # The results of every earlier round are still there. A second round that
      # discarded the first round's result loses what the first round learned.
      tool_results = Enum.filter(messages, &(&1["role"] == "tool"))
      tool_call_ids = Enum.map(tool_results, & &1["tool_call_id"])

      assert "call_a" in tool_call_ids
      assert "call_b" in tool_call_ids

      # And the tool result carries the tool's own answer, not a refusal.
      first_result = Enum.find(tool_results, &(&1["tool_call_id"] == "call_a"))
      assert first_result["content"] =~ "ci-1"
    end
  end

  describe "the model" do
    # A form's empty select arrives as `""`, not `nil`. Empty means "the
    # provider's configured model" everywhere the operator can pick one, so
    # the runner must read it that way rather than refusing with `:no_model`.
    test "a blank selection falls back to the provider's configured model", %{stub: stub} do
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, answer("fine")}])
      configure_provider(stub)
      actor = %Principal{id: "u1", workspace: "agent_test", roles: []}

      assert {:ok, result} =
               Runner.ask("agent_test", "hello?", actor: actor, agent: "probe", model: "")

      assert result.model == "test-model"
      assert [request] = StubProvider.requests(stub)
      assert Jason.decode!(request.body)["model"] == "test-model"
    end

    test "an explicit selection is the model the provider is asked for", %{stub: stub} do
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, answer("fine")}])
      configure_provider(stub)
      actor = %Principal{id: "u1", workspace: "agent_test", roles: []}

      assert {:ok, result} =
               Runner.ask("agent_test", "hello?",
                 actor: actor,
                 agent: "probe",
                 model: "other-model"
               )

      # The result names the model that answered, not the configured default.
      assert result.model == "other-model"
      assert [request] = StubProvider.requests(stub)
      assert Jason.decode!(request.body)["model"] == "other-model"
    end

    test "a provider with no model and no selection is refused", %{stub: stub} do
      configure_provider(stub)
      providers = Application.get_env(:veritas_core, :providers)
      Application.put_env(:veritas_core, :providers, put_in(providers, [:probe, :model], nil))
      actor = %Principal{id: "u1", workspace: "agent_test", roles: []}

      assert {:error, :no_model} =
               Runner.ask("agent_test", "hello?", actor: actor, agent: "probe", model: "")

      assert StubProvider.requests(stub) == []
    end
  end

  describe "a tool-free run" do
    # The workflow AI step asks with `tool_names: []`: the model drafts a
    # proposal from recorded context and may not reach a single tool. An
    # empty list must mean *no tools*, not *every tool*.
    test "tool_names: [] sends the provider no tools", %{stub: stub} do
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, answer("a proposal")}])
      register_tool()
      configure_provider(stub)
      actor = %Principal{id: "u1", workspace: "agent_test", roles: []}

      assert {:ok, result} =
               Runner.ask("agent_test", "draft it", actor: actor, agent: "probe", tool_names: [])

      assert result.tools_used == []
      assert [request] = StubProvider.requests(stub)
      body = Jason.decode!(request.body)
      assert body["tools"] in [nil, []]
      assert body["tool_choice"] == nil
    end
  end
end
