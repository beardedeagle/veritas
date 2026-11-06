defmodule Veritas.Agent.OpenAICompatibleTest do
  @moduledoc """
  The OpenAI-compatible adapter, over real HTTP against a local stub.

  Every bug this file pins was on the wire: a response body that was decoded
  twice, a model list that was never authenticated, a header list that lost
  its first element. The stub records what it received, so the assertions are
  made on the bytes that crossed the socket, not on the adapter's internals.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agent.Test.StubProvider
  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.Adapter.OpenAICompatible

  @completion ~s({
    "id": "cmpl-1",
    "model": "test-model",
    "choices": [
      {"index": 0, "message": {"role": "assistant", "content": "hello there"},
       "finish_reason": "stop"}
    ],
    "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}
  })

  @models ~s({
    "object": "list",
    "data": [{"id": "model-a", "object": "model"}, {"id": "model-b", "object": "model"}]
  })

  setup do
    {:ok, stub} = StubProvider.start_link()

    on_exit(fn -> if Process.alive?(stub), do: StubProvider.stop(stub) end)

    {:ok, stub: stub}
  end

  defp config(stub, opts) do
    {:ok, config} =
      OpenAICompatible.init(%{
        base_url: StubProvider.base_url(stub),
        token: Keyword.get(opts, :token, "test-token")
      })

    config
  end

  defp request do
    %LLM.Request{
      model: %LLM.Model{id: "test-model", provider: "openai_compatible"},
      messages: [%LLM.Message{role: :user, content: "hello"}]
    }
  end

  defp header(request, name) do
    case Enum.find(request.headers, fn {key, _value} -> key == name end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  describe "a completion" do
    test "is decoded, with its usage", %{stub: stub} do
      # The response body is a binary, and the adapter decodes it once. When it
      # evaluated the usage key on the binary itself, this raised
      # FunctionClauseError on a valid HTTP 200 completion.
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, @completion}])

      assert {:ok, response} = OpenAICompatible.complete(request(), config(stub, []), [])

      assert response.content == "hello there"
      assert response.finish_reason == :stop

      # The usage is read out of the decoded body, not out of the binary.
      assert response.usage.input_tokens == 11
      assert response.usage.output_tokens == 7
    end

    test "carries the content type and the credential", %{stub: stub} do
      # The header list was built with `tl/1`, which drops the first element.
      # One of the two headers was therefore lost on every call.
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, @completion}])

      assert {:ok, _response} = OpenAICompatible.complete(request(), config(stub, []), [])

      assert [request] = StubProvider.requests(stub)

      assert header(request, "content-type") == "application/json"
      assert header(request, "authorization") == "Bearer test-token"
    end

    test "carries no authorization header when there is no credential", %{stub: stub} do
      # The other half of the same bug: with no credential the list kept an
      # empty authorization header and dropped the content type instead.
      StubProvider.respond(stub, "POST", "/chat/completions", [{200, @completion}])

      assert {:ok, _response} =
               OpenAICompatible.complete(request(), config(stub, token: nil), [])

      assert [request] = StubProvider.requests(stub)

      assert header(request, "content-type") == "application/json"
      assert header(request, "authorization") == nil
    end
  end

  describe "the model list" do
    test "is decoded", %{stub: stub} do
      # The model list evaluated `.body` on the response binary, so a valid
      # HTTP 200 model list raised BadMapError instead of listing the models.
      StubProvider.respond(stub, "GET", "/models", [{200, @models}])

      assert {:ok, models} = OpenAICompatible.models(config(stub, []))

      assert Enum.map(models, & &1.id) == ["model-a", "model-b"]
      assert Enum.all?(models, &(&1.provider == "openai_compatible"))
    end

    test "carries the credential", %{stub: stub} do
      # The model list was fetched with empty headers, so a provider whose
      # /models needs authentication answered 401 even though a credential was
      # configured.
      StubProvider.respond(stub, "GET", "/models", [{200, @models}], require_authorization: true)

      assert {:ok, models} = OpenAICompatible.models(config(stub, []))

      assert Enum.map(models, & &1.id) == ["model-a", "model-b"]

      assert [request] = StubProvider.requests(stub)
      assert request.method == "GET"
      assert header(request, "authorization") == "Bearer test-token"
    end

    test "that is not JSON is refused in plain words, without the provider's body", %{
      stub: stub
    } do
      # A gateway page instead of a catalogue. The decode error carries the
      # whole body, and the console used to print it into the flash.
      StubProvider.respond(stub, "GET", "/models", [{200, "<html>gateway says hello</html>"}])

      assert {:error, %LLM.Error{code: :protocol, message: message}} =
               OpenAICompatible.models(config(stub, []))

      assert message == "the provider's answer was not JSON"
      refute message =~ "gateway"
    end

    test "in the wrong shape is refused, not read as an empty catalogue", %{stub: stub} do
      # An empty select looks like a provider with no models; the operator is
      # owed the reason instead.
      StubProvider.respond(stub, "GET", "/models", [{200, ~s({"models": [{"name": "x"}]})}])

      assert {:error, %LLM.Error{code: :protocol}} = OpenAICompatible.models(config(stub, []))
    end

    test "drops entries that name no model", %{stub: stub} do
      StubProvider.respond(stub, "GET", "/models", [
        {200, ~s({"data": [{"id": "model-a"}, {"id": ""}, {"object": "model"}, "junk"]})}
      ])

      assert {:ok, models} = OpenAICompatible.models(config(stub, []))
      assert Enum.map(models, & &1.id) == ["model-a"]
    end
  end

  describe "a refusal" do
    test "for a model the provider lacks names the model as a possible cause", %{stub: stub} do
      # Ollama Cloud answers an unknown model with 404 (checked live on
      # 2026-11-05); "no such endpoint" alone sent the operator the wrong way.
      StubProvider.respond(stub, "POST", "/chat/completions", [
        {404, ~s({"error": {"message": "model x not found", "type": "not_found_error"}})}
      ])

      assert {:error, %LLM.Error{code: :not_found, message: message}} =
               OpenAICompatible.complete(request(), config(stub, []), [])

      assert message =~ "no such model"
    end
  end
end
