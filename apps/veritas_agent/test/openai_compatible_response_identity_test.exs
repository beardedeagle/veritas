defmodule Veritas.Agent.OpenAICompatibleResponseIdentityTest do
  @moduledoc """
  Which completion the answer came from, and which model answered.

  The OpenAI chat-completion shape puts the completion's `id` and `model` at
  the **top level** of the answer. A choice carries `index`, `message`,
  `logprobs` and `finish_reason` — and never the id or the model. The adapter
  read both of them from the choice, so `id` and `model` were always the empty
  string and the completion's identity and the model that answered were both
  lost.

  `docs/15` §inbound translation is the specification: `id` from the top
  level, and `model` from the top level with the **requested** model as the
  fallback, because a provider that does not echo the model back still has to
  be answerable for the model that was asked.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agent.Test.StubProvider
  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.Adapter.OpenAICompatible

  @requested_model "the-requested-model"

  setup do
    {:ok, stub} = StubProvider.start_link()

    on_exit(fn -> if Process.alive?(stub), do: StubProvider.stop(stub) end)

    {:ok, stub: stub}
  end

  defp config(stub) do
    {:ok, config} =
      OpenAICompatible.init(%{
        base_url: StubProvider.base_url(stub),
        token: "test-token"
      })

    config
  end

  defp request(model_id) do
    %LLM.Request{
      model: %LLM.Model{id: model_id, provider: "openai_compatible"},
      messages: [%LLM.Message{role: :user, content: "hello"}]
    }
  end

  describe "an answer that names itself" do
    test "carries the id and the model from the top level of the answer", %{stub: stub} do
      # The id and the model are siblings of "choices", not fields of a
      # choice. Reading them off the choice lost both.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {200, ~s({
           "id": "cmpl-77",
           "object": "chat.completion",
           "model": "the-model-that-answered",
           "choices": [
             {"index": 0, "message": {"role": "assistant", "content": "hello there"},
              "logprobs": null, "finish_reason": "stop"}
           ],
           "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}
         })}
      ])

      assert {:ok, response} =
               OpenAICompatible.complete(request(@requested_model), config(stub), [])

      assert response.id == "cmpl-77"
      assert response.model == "the-model-that-answered"
    end

    test "leaves the rest of the answer alone", %{stub: stub} do
      # The fix moves two fields. The content, the tool calls, the usage and
      # the finish reason are read where they were read before.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {200, ~s({
           "id": "cmpl-77",
           "model": "the-model-that-answered",
           "choices": [
             {"index": 0, "message": {"role": "assistant", "content": "hello there",
              "tool_calls": [{"id": "call_1", "type": "function",
                              "function": {"name": "list_cis", "arguments": "{}"}}]},
              "finish_reason": "tool_calls"}
           ],
           "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}
         })}
      ])

      assert {:ok, response} =
               OpenAICompatible.complete(request(@requested_model), config(stub), [])

      assert response.content == "hello there"
      assert response.finish_reason == :tool_calls
      assert response.usage.input_tokens == 11
      assert response.usage.output_tokens == 7
      assert [call] = response.tool_calls
      assert call.id == "call_1"
      assert call.name == "list_cis"
      assert call.arguments == %{}
    end
  end

  describe "an answer that names neither" do
    test "falls back to the requested model, and to an empty id", %{stub: stub} do
      # A provider that does not echo the model back still has to be
      # answerable for the model that was asked for.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {200, ~s({
           "choices": [
             {"index": 0, "message": {"role": "assistant", "content": "hello there"},
              "finish_reason": "stop"}
           ],
           "usage": {"prompt_tokens": 11, "completion_tokens": 7}
         })}
      ])

      assert {:ok, response} =
               OpenAICompatible.complete(request(@requested_model), config(stub), [])

      assert response.id == ""
      assert response.model == @requested_model
    end

    test "the requested model is the one that was sent", %{stub: stub} do
      # The fallback is the model in the request, not a guess: the stub
      # recorded what crossed the socket.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {200, ~s({
           "choices": [
             {"index": 0, "message": {"role": "assistant", "content": "hello there"},
              "finish_reason": "stop"}
           ]
         })}
      ])

      assert {:ok, _response} =
               OpenAICompatible.complete(request(@requested_model), config(stub), [])

      assert [sent] = StubProvider.requests(stub)
      assert Jason.decode!(sent.body)["model"] == @requested_model
    end
  end
end
