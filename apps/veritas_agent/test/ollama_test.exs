defmodule Veritas.Agent.OllamaTest do
  @moduledoc """
  The self-hosted Ollama adapter, over real HTTP against a local stub.

  The stub answers `/api/tags` for `GET` and `405` for anything else, which is
  what Ollama does: its router registers `GET` and `HEAD` for that path.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agent.Test.StubProvider
  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.Adapter.Ollama

  @tags ~s({
    "models": [
      {"name": "llama3:latest", "model": "llama3:latest"},
      {"name": "qwen2.5:7b", "model": "qwen2.5:7b"}
    ]
  })

  setup do
    {:ok, stub} = StubProvider.start_link()

    on_exit(fn -> if Process.alive?(stub), do: StubProvider.stop(stub) end)

    {:ok, stub: stub}
  end

  defp config(stub) do
    {:ok, config} = Ollama.init(%{base_url: StubProvider.base_url(stub)})

    config
  end

  describe "the model list" do
    test "is fetched with GET", %{stub: stub} do
      # Ollama's router registers GET and HEAD for /api/tags and answers a POST
      # with 405. The adapter built every request as a POST, so the runtime
      # refused the call and no model was ever listed.
      StubProvider.respond(stub, "GET", "/api/tags", [{200, @tags}])

      assert {:ok, models} = Ollama.models(config(stub))

      assert Enum.map(models, & &1.id) == ["llama3:latest", "qwen2.5:7b"]

      assert [request] = StubProvider.requests(stub)
      assert request.method == "GET"
      assert request.path == "/api/tags"
    end

    test "a runtime that refuses the method is answered with a refusal", %{stub: stub} do
      # The shape of the failure the runtime gives for the wrong method: a
      # refusal, not an empty list of models.
      StubProvider.respond(stub, "GET", "/api/tags", [
        {405, ~s({"error":"method not allowed"})}
      ])

      StubProvider.respond(stub, "POST", "/api/tags", [
        {405, ~s({"error":"method not allowed"})}
      ])

      assert {:error, error} = Ollama.models(config(stub))

      assert error.code == :protocol
    end
  end
end
