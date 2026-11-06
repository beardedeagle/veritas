defmodule Veritas.Agent.OllamaFinishReasonTest do
  @moduledoc """
  The end of an answer, as the runtime reported it.

  Ollama's native `/api/chat` has no choices at all: the answer's end is
  `done_reason` at the **top level** of the body. The adapter reported
  `:stop` whatever the runtime said, so an answer the runtime cut short was
  handed to the domain as a completed one, and a runtime that said nothing
  was recorded as a clean stop.

  The vocabulary is the Port's own (`docs/15` §Port), and it is the same one
  the OpenAI-compatible adapter uses. The last test in this file is the guard
  that keeps the two adapters from drifting apart: the same event, reported
  the same way by both.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agent.Test.StubProvider
  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.Adapter.{Ollama, OpenAICompatible}

  setup do
    {:ok, stub} = StubProvider.start_link()

    on_exit(fn -> if Process.alive?(stub), do: StubProvider.stop(stub) end)

    {:ok, stub: stub}
  end

  defp ollama_config(stub) do
    {:ok, config} = Ollama.init(%{base_url: StubProvider.base_url(stub)})
    config
  end

  defp openai_config(stub) do
    {:ok, config} =
      OpenAICompatible.init(%{
        base_url: StubProvider.base_url(stub),
        token: "test-token"
      })

    config
  end

  defp request do
    %LLM.Request{
      model: %LLM.Model{id: "llama3:latest", provider: "ollama"},
      messages: [%LLM.Message{role: :user, content: "hello"}]
    }
  end

  # Ollama's native answer: no choices, the end of the answer at the top.
  defp ollama_body(done_reason) do
    body = %{
      "model" => "llama3:latest",
      "message" => %{"role" => "assistant", "content" => "hello"},
      "done" => true,
      "prompt_eval_count" => 26,
      "eval_count" => 298
    }

    case done_reason do
      nil -> body
      reason -> Map.put(body, "done_reason", reason)
    end
  end

  # The OpenAI-compatible answer: the end of the answer on the choice.
  defp openai_body(finish_reason) do
    choice = %{"index" => 0, "message" => %{"role" => "assistant", "content" => "hello"}}

    choice =
      case finish_reason do
        nil -> choice
        reason -> Map.put(choice, "finish_reason", reason)
      end

    %{
      "id" => "chatcmpl-1",
      "model" => "test-model",
      "choices" => [choice],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7}
    }
  end

  defp ollama_finish_reason(stub, done_reason) do
    StubProvider.respond(stub, "POST", "/api/chat", [
      {200, Jason.encode!(ollama_body(done_reason))}
    ])

    {:ok, response} = Ollama.complete(request(), ollama_config(stub))
    response.finish_reason
  end

  defp openai_finish_reason(stub, finish_reason) do
    StubProvider.respond(stub, "POST", "/chat/completions", [
      {200, Jason.encode!(openai_body(finish_reason))}
    ])

    {:ok, response} = OpenAICompatible.complete(request(), openai_config(stub), [])
    response.finish_reason
  end

  describe "an answer the runtime cut short" do
    test "is reported as length, not as a clean stop", %{stub: stub} do
      # The runtime says it stopped because it ran out of tokens. Reporting
      # :stop tells the domain the answer was complete when it was not.
      assert ollama_finish_reason(stub, "length") == :length
    end

    test "is reported as a tool call when the runtime says so", %{stub: stub} do
      assert ollama_finish_reason(stub, "tool_use") == :tool_calls
    end
  end

  describe "an answer whose end the runtime does not say" do
    test "is reported as :other, not as a clean stop", %{stub: stub} do
      # The runtime did not say how it ended. The honest answer is "it did not
      # say", which is what :other means; :stop would be a claim the runtime
      # never made.
      assert ollama_finish_reason(stub, nil) == :other
    end
  end

  describe "the two adapters" do
    test "report the same event the same way", %{stub: stub} do
      # The Port's vocabulary, one event at a time. Ollama spells the
      # tool-call event "tool_use" where the OpenAI shape spells it
      # "tool_calls"; they are the same event.
      events = [
        {"stop", "stop"},
        {"length", "length"},
        {"tool_use", "tool_calls"},
        {"tool_calls", "tool_calls"},
        {"content_filter", "content_filter"},
        {"something_else", "something_else"}
      ]

      for {ollama_reason, openai_reason} <- events do
        assert ollama_finish_reason(stub, ollama_reason) ==
                 openai_finish_reason(stub, openai_reason),
               "the adapters disagree about #{ollama_reason} / #{openai_reason}"
      end
    end

    test "report an absent reason the same way", %{stub: stub} do
      assert ollama_finish_reason(stub, nil) == openai_finish_reason(stub, nil)
    end
  end
end
