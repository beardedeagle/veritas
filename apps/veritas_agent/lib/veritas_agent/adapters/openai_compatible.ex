defmodule Veritas.Agentic.LLM.Adapter.OpenAICompatible do
  @moduledoc """
  The OpenAI-compatible adapter — the reference adapter (`docs/15` §(a)).

  One adapter serves OpenAI, OpenRouter, Groq, Together, vLLM, llama.cpp's
  server, LM Studio, LiteLLM, and Ollama's `/v1` compatibility endpoint. The
  base URL and the credentials are **configuration**, not code.

  ## It is a pure translator

  It holds no product state, it retries nothing (the host owns retries so
  every attempt is auditable), and it never sees a tool's scope or approval
  policy: it receives the `LLM.Tool` projection and nothing else.

  ## It does not degrade

  If the model cannot carry tools and tools were requested, the adapter
  refuses with `%Error{code: :unsupported}` rather than dropping the tools
  and letting the model hallucinate calls (`docs/15` §Tool Registry
  Ownership).
  """

  @behaviour Veritas.Agentic.LLM
  @behaviour Veritas.Agentic.LLM.Adapter

  alias Veritas.Agentic.LLM

  @pool Veritas.Agent.Finch
  @default_timeout 30_000

  @impl Veritas.Agentic.LLM.Adapter
  def id, do: :openai_compatible

  @impl Veritas.Agentic.LLM.Adapter
  def init(config) when is_map(config) do
    case config[:base_url] do
      base_url when is_binary(base_url) and base_url != "" ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           token: config[:token],
           timeout: config[:timeout] || @default_timeout,
           capabilities: config[:capabilities] || [:tools, :json_object]
         }}

      _ ->
        {:error,
         %LLM.Error{
           code: :invalid_request,
           message: "an OpenAI-compatible provider needs a base_url"
         }}
    end
  end

  @impl Veritas.Agentic.LLM
  def complete(%LLM.Request{} = request, config, opts \\ []) do
    body = %{
      model: request.model.id,
      messages: Enum.map(request.messages, &message/1),
      temperature: request.temperature,
      max_tokens: request.max_output_tokens,
      seed: request.seed,
      stop: request.stop_sequences,
      tools: tools(request.tools),
      tool_choice: if(request.tools == [], do: nil, else: "auto")
    }

    post(config, "/chat/completions", body, opts, request.model.id)
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
    case get(config, "/models", authorization(config)) do
      # An entry that names no model cannot be chosen, so it is left out.
      {:ok, %{"data" => data}} when is_list(data) ->
        {:ok,
         for %{"id" => id} when is_binary(id) and id != "" <- data do
           %LLM.Model{
             id: id,
             provider: "openai_compatible",
             supports: config[:capabilities] || [:tools, :json_object]
           }
         end}

      # A catalogue in another shape is a refusal with a reason, not an empty
      # list: an empty choice looks like a provider that has no models.
      {:ok, _other} ->
        {:error,
         %LLM.Error{
           code: :protocol,
           message: "the provider's model list was not in the expected shape"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the wire ────────────────────────────────────────────────────────────────

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
      %{
        id: call.id,
        type: "function",
        function: %{"name" => call.name, "arguments" => Jason.encode!(call.arguments)}
      }
    end)
  end

  defp tools([]), do: nil

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

  defp post(config, path, body, opts, requested_model) do
    headers = [{"content-type", "application/json"} | authorization(config)]

    case request(config, :post, path, headers, Jason.encode!(body), opts) do
      {:ok, response} -> decode(response, requested_model)
      {:error, reason} -> {:error, reason}
    end
  end

  # A body that is not JSON is the Port's protocol error, like a completion's
  # (`decode/2`): the decode error itself carries the whole body, which must
  # not travel to a screen.
  defp get(config, path, headers) do
    with {:ok, response} <- request(config, :get, path, headers, "", []) do
      case Jason.decode(response) do
        {:ok, decoded} ->
          {:ok, decoded}

        {:error, reason} ->
          {:error,
           %LLM.Error{code: :protocol, message: "the provider's answer was not JSON", raw: reason}}
      end
    end
  end

  # The credential goes on every call that needs one — the completion **and**
  # the model list. A provider whose `/models` endpoint requires
  # authentication answers 401 without it, and the operator is then told the
  # credential is bad when it was never sent. A provider that needs no
  # credential gets no `authorization` header at all.
  defp authorization(config) do
    case config[:token] do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
      _other -> []
    end
  end

  defp request(config, method, path, headers, body, opts) do
    timeout = opts[:timeout] || config[:timeout] || @default_timeout
    url = config[:base_url] <> path

    request =
      case method do
        :get -> Finch.build(:get, url, headers)
        :post -> Finch.build(:post, url, headers, body)
      end

    case Finch.request(request, @pool, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, error(status, response_body)}

      {:error, reason} ->
        {:error,
         %LLM.Error{code: :transport, message: Exception.message(reason), retryable: true}}
    end
  end

  # The OpenAI chat-completion shape puts the completion's `id` and `model` at
  # the **top level** of the answer, not on the choice: a choice carries
  # `index`, `message`, `logprobs` and `finish_reason`. `docs/15` §inbound
  # translation says the same, and falls back to the **requested** model when
  # the provider does not echo one back.
  defp decode(body, requested_model) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [choice | _]} = decoded} ->
        message = choice["message"] || %{}

        {:ok,
         %LLM.Response{
           id: decoded["id"] || "",
           model: decoded["model"] || requested_model || "",
           content: message["content"] || "",
           tool_calls: decode_tool_calls(message["tool_calls"]),
           usage: usage(decoded["usage"]),
           finish_reason: finish_reason(choice["finish_reason"]),
           raw: decoded
         }}

      {:ok, other} ->
        {:error,
         %LLM.Error{code: :protocol, message: "the provider answered with no choice", raw: other}}

      {:error, reason} ->
        {:error,
         %LLM.Error{code: :protocol, message: "the provider's answer was not JSON", raw: reason}}
    end
  end

  defp decode_tool_calls(nil), do: []

  defp decode_tool_calls(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}
      arguments = decode_arguments(function["arguments"])

      %LLM.ToolCall{
        id: call["id"] || "",
        name: function["name"] || "",
        arguments: arguments,
        raw_arguments: function["arguments"]
      }
    end)
  end

  defp decode_arguments(nil), do: %{}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: arguments

  defp usage(nil), do: %LLM.Usage{}

  defp usage(usage) do
    %LLM.Usage{
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      raw: usage
    }
  end

  defp finish_reason("stop"), do: :stop
  defp finish_reason("tool_calls"), do: :tool_calls
  defp finish_reason("length"), do: :length
  defp finish_reason("content_filter"), do: :content_filter
  defp finish_reason(_other), do: :other

  defp error(401, _body),
    do: %LLM.Error{code: :authentication, message: "the provider refused the credential"}

  defp error(403, _body),
    do: %LLM.Error{code: :permission_denied, message: "the provider refused the request"}

  # Ollama Cloud, for one, answers an unknown model with 404 on a valid path.
  defp error(404, _body),
    do: %LLM.Error{code: :not_found, message: "the provider has no such model or endpoint"}

  defp error(429, _body),
    do: %LLM.Error{code: :rate_limited, message: "the provider is rate limiting", retryable: true}

  defp error(status, _body),
    do: %LLM.Error{code: :protocol, message: "the provider answered #{status}"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
