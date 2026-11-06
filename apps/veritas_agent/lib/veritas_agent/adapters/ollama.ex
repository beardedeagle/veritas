defmodule Veritas.Agentic.LLM.Adapter.Ollama do
  @moduledoc """
  The self-hosted Ollama / llama.cpp adapter (`docs/15` §(c)).

  Ollama's native `/api/chat` is worth a dedicated adapter: its `format`
  field accepts a JSON Schema directly, which is stricter than OpenAI's JSON
  mode, and older Ollama builds handle tool calls more faithfully than their
  OpenAI-compatible shim.

  ## The self-hosted tier needs no credential

  A local runtime has no key, so the adapter sends no `authorization` header
  at all. This is the practical shape of the free-forever commitment: an
  operator who wants no account, no key and no egress chooses this tier.

  ## Capability honesty

  A runtime without tool-call support must say so, and the host must refuse
  to route a tool-using agent to it rather than dropping the tools and
  letting the model hallucinate calls (`docs/15` §(c)). The adapter reports
  what the runtime says it supports, and nothing more.

  ## The answer's end is reported as it happened

  Ollama's native `/api/chat` has no choices: the answer's end is
  `done_reason` at the top level of the body. The adapter reports it in the
  Port's own vocabulary, so an answer the runtime cut short is recorded as
  cut short, and a runtime that says nothing is recorded as `:other` rather
  than as a clean `:stop`.
  """

  @behaviour Veritas.Agentic.LLM
  @behaviour Veritas.Agentic.LLM.Adapter

  alias Veritas.Agentic.LLM

  @pool Veritas.Agent.Finch
  @default_timeout 120_000

  @impl Veritas.Agentic.LLM.Adapter
  def id, do: :ollama

  @impl Veritas.Agentic.LLM.Adapter
  def init(config) when is_map(config) do
    case config[:base_url] do
      base_url when is_binary(base_url) and base_url != "" ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           timeout: config[:timeout] || @default_timeout,
           capabilities: config[:capabilities] || [:tools, :json_object]
         }}

      _ ->
        {:error,
         %LLM.Error{
           code: :invalid_request,
           message: "a self-hosted provider needs the address of its runtime"
         }}
    end
  end

  @impl Veritas.Agentic.LLM
  def complete(%LLM.Request{} = request, config, opts \\ []) do
    body = %{
      model: request.model.id,
      messages: Enum.map(request.messages, &message/1),
      stream: false,
      options: %{
        temperature: request.temperature,
        num_ctx: request.metadata[:context_window]
      },
      tools: tools(request.tools)
    }

    body = if request.tools == [], do: Map.delete(body, :tools), else: body

    case request(config, :post, "/api/chat", body, opts) do
      {:ok, response} -> decode(response)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Agentic.LLM
  def stream(_request, _config, _opts) do
    # The chunk delivery shape is `Veritas.Agentic.LLM.Event`, which
    # `docs/39` §F7 leaves unspecified. The adapter does not invent one.
    {:error,
     %LLM.Error{
       code: :unsupported,
       message: "streaming needs LLM.Event, which docs/15 leaves unspecified"
     }}
  end

  @impl Veritas.Agentic.LLM
  def models(config) do
    case request(config, :get, "/api/tags", %{}, []) do
      {:ok, response} ->
        models =
          response
          |> Map.get("models", [])
          |> Enum.map(fn model ->
            %LLM.Model{
              id: model["name"] || model["model"] || "",
              provider: "ollama",
              supports: config[:capabilities] || [:tools, :json_object]
            }
          end)

        {:ok, models}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message(%LLM.Message{} = message) do
    %{
      role: to_string(message.role),
      content: message.content
    }
    |> maybe_put("tool_call_id", message.tool_call_id)
    |> maybe_put("name", message.name)
    |> maybe_put("tool_calls", tool_calls(message.tool_calls))
  end

  defp tool_calls([]), do: nil

  defp tool_calls(calls) do
    Enum.map(calls, fn %LLM.ToolCall{} = call ->
      %{function: %{"name" => call.name, "arguments" => call.arguments}}
    end)
  end

  defp tools(tools) do
    Enum.map(tools, fn %LLM.Tool{} = tool ->
      %{
        type: "function",
        function: %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp request(config, method, path, body, opts) do
    timeout = opts[:timeout] || config[:timeout] || @default_timeout
    url = config[:base_url] <> path

    finch_request =
      case method do
        # Ollama's own API registers GET and HEAD for `/api/tags` and answers
        # a POST with 405, so the method is part of the contract, not a
        # detail of the body.
        :get ->
          Finch.build(:get, url, [])

        :post ->
          Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))
      end

    case Finch.request(finch_request, @pool, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, reason} ->
            {:error,
             %LLM.Error{
               code: :protocol,
               message: "the runtime's answer was not JSON",
               raw: reason
             }}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, error(status, response_body)}

      {:error, reason} ->
        {:error,
         %LLM.Error{
           code: :transport,
           message: "no runtime at this address: " <> Exception.message(reason),
           retryable: true
         }}
    end
  end

  defp decode(%{"message" => message} = body) do
    {:ok,
     %LLM.Response{
       id: body["id"] || "",
       model: body["model"] || "",
       content: message["content"] || "",
       tool_calls: decode_tool_calls(message["tool_calls"]),
       usage: usage(body),
       finish_reason: finish_reason(body["done_reason"]),
       raw: body
     }}
  end

  defp decode(other) do
    {:error,
     %LLM.Error{code: :protocol, message: "the runtime answered with no message", raw: other}}
  end

  # Ollama's native `/api/chat` has no choices at all: the answer's end is
  # reported as `done_reason` at the **top level** of the body.
  #
  # The vocabulary is the Port's own (`docs/15` §Port), and it is the same one
  # the OpenAI-compatible adapter uses, so the two adapters cannot report the
  # same event differently. The only difference is the spelling: Ollama says
  # `tool_use` for the event the OpenAI shape calls `tool_calls`, and both
  # mean the same thing.
  #
  # A runtime that says nothing says `:other`. The answer is still an answer,
  # and refusing it would turn a missing field into an outage.
  defp finish_reason("stop"), do: :stop
  defp finish_reason("length"), do: :length
  defp finish_reason("tool_use"), do: :tool_calls
  defp finish_reason("tool_calls"), do: :tool_calls
  defp finish_reason("content_filter"), do: :content_filter
  defp finish_reason(_other), do: :other

  defp decode_tool_calls(nil), do: []

  defp decode_tool_calls(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}

      %LLM.ToolCall{
        id: call["id"] || "",
        name: function["name"] || "",
        arguments: function["arguments"] || %{},
        raw_arguments: nil
      }
    end)
  end

  defp usage(body) do
    %LLM.Usage{
      input_tokens: body["prompt_eval_count"],
      output_tokens: body["eval_count"],
      raw: body
    }
  end

  defp error(404, _body),
    do: %LLM.Error{code: :not_found, message: "the runtime has no such endpoint"}

  defp error(400, _body),
    do: %LLM.Error{code: :invalid_request, message: "the runtime refused the request"}

  defp error(status, _body),
    do: %LLM.Error{code: :protocol, message: "the runtime answered #{status}"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
