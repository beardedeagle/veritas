defmodule Veritas.Agentic.Runner do
  @moduledoc """
  The host-owned loop, on its read-only path.

  The loop is **host code** (`docs/15` §Agent Loop Ownership): the model
  call is a port call and everything else — the tool list, the scope check,
  the approval decision, the audit, the cost accounting — is Veritas. A
  framework that owned the loop would own the approval gate with it.

  ## What this is, and what it is not

  This is the **read-only** path: a question, the tools the actor may read,
  and an answer. A tool call is executed only when the tool is a read and
  the actor's scopes allow it.

  It is **not** the whole runner. The approval gate, the persisted
  `agent_action_requests`, the delegation record and the state machine are
  `docs/39` §9 step 6, and a write tool is refused here rather than
  executed. A write needs a human's decision, and this path has no gate to
  ask.

  ## The audit is the record

  Every tool call is written to the Audit Log with the digest of its
  arguments, the scope it needed, the policy's verdict and the outcome — so
  an agent's reach into the CMDB is indistinguishable from a person's for
  audit (`docs/08`).
  """

  alias Veritas.Agentic.{Audit, LLM, LLM.AdapterRegistry, Provider, Tool}
  alias Veritas.Core.Principal

  @typedoc "The answer to a question."
  @type result :: %{
          answer: String.t(),
          steps: [map()],
          provider: String.t() | nil,
          model: String.t() | nil,
          tools_used: [String.t()]
        }

  @max_turns 4

  @doc """
  Asks a question and answers it.

  The provider is chosen by the corpus's precedence
  (`run override > agent spec > Workspace setting > global default`), and
  the **effective selection** is returned so the caller can record it on the
  run row — a historical run is replayable with its original provider.
  """
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def ask(workspace, question, opts \\ []) when is_binary(workspace) and is_binary(question) do
    opts =
      Keyword.put_new_lazy(opts, :workspace_provider, fn ->
        Provider.Registry.workspace_provider(workspace)
      end)

    with {:ok, provider, tier} <- Provider.Registry.select(workspace, opts),
         {:ok, adapter} <- adapter_for(provider),
         {:ok, config} <- init_adapter(adapter, provider),
         {:ok, model} <- model_for(provider, opts) do
      run(%{
        workspace: workspace,
        question: question,
        adapter: adapter,
        config: config,
        model: model,
        provider: provider,
        tier: tier,
        opts: opts,
        steps: [],
        messages: []
      })
    else
      {:error, :no_provider} -> {:error, :no_provider}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The selected provider's current model catalogue; credentials stay inside the adapter."
  def models(workspace, opts \\ []) do
    opts =
      Keyword.put_new_lazy(opts, :workspace_provider, fn ->
        Provider.Registry.workspace_provider(workspace)
      end)

    with {:ok, provider, _tier} <- Provider.Registry.select(workspace, opts),
         {:ok, adapter} <- adapter_for(provider),
         {:ok, config} <- init_adapter(adapter, provider) do
      adapter.models(config)
    end
  end

  defp run(turn) do
    request = request(turn)

    case turn.adapter.complete(request, turn.config, timeout: turn.opts[:timeout]) do
      {:ok, %LLM.Response{} = response} -> answer(turn, response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer(turn, response) do
    case response.tool_calls do
      [] ->
        {:ok, result(turn, response)}

      calls ->
        steps = Enum.map(calls, &execute(turn, &1))

        if length(turn.steps) >= @max_turns do
          {:ok, result(turn, response)}
        else
          next = %{
            turn
            | steps: turn.steps ++ steps,
              messages: turn.messages ++ conversation(response, calls, steps)
          }

          case turn.adapter.complete(request(next), next.config, timeout: next.opts[:timeout]) do
            {:ok, %LLM.Response{} = next_response} -> answer(next, next_response)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # The conversation the provider receives: the system instruction, the
  # question, and then every tool round that has happened — the assistant
  # turn that asked for the calls, then one tool message per call.
  defp request(turn) do
    specs = tools_for(turn)

    %LLM.Request{
      model: turn.model,
      messages:
        [
          %LLM.Message{role: :system, content: turn.opts[:system_prompt] || system_prompt()},
          %LLM.Message{role: :user, content: turn.question}
        ] ++ turn.messages,
      tools: Enum.map(specs, &Tool.Spec.llm_projection/1),
      metadata: %{"workspace" => turn.workspace, "agent" => turn.opts[:agent]}
    }
  end

  defp execute(turn, %LLM.ToolCall{} = call) do
    specs = tools_for(turn)
    spec = Enum.find(specs, &(&1.name == call.name))
    scope = (spec && spec.scope) || []

    outcome =
      case spec do
        nil ->
          {:error, :unknown_tool}

        %{side_effect: :read} ->
          Tool.Registry.call(call.name, call.arguments, %{
            workspace: turn.workspace,
            actor: turn.opts[:actor],
            agent: turn.opts[:agent],
            run_id: turn.opts[:run_id]
          })

        _ ->
          # A write needs a human's decision. There is no approval gate on
          # this path, so the tool is refused rather than executed.
          {:error, :approval_required}
      end

    step = %{
      tool: call.name,
      scope: scope,
      policy: if(spec, do: "scope checked", else: "unknown tool"),
      outcome: outcome_tag(outcome)
    }

    _audit =
      Audit.record_tool_call(turn.workspace, %{
        run_id: turn.opts[:run_id] || "agent",
        tool: call.name,
        arguments: call.arguments,
        scope: scope,
        policy: step.policy,
        outcome: step.outcome,
        provider: turn.provider.id,
        model: turn.model.id,
        actor: audit_actor(turn.opts[:actor]),
        correlation_id: turn.opts[:correlation_id],
        reason: "the agent called a tool"
      })

    %{result: tool_result(call, outcome), step: step}
  end

  defp result(turn, response) do
    steps = Enum.map(turn.steps, & &1.step)

    %{
      answer: response.content,
      steps: steps,
      provider: turn.provider.id,
      model: turn.model.id,
      tools_used: Enum.map(steps, & &1.tool)
    }
  end

  defp tool_result(call, {:ok, value}) do
    %{"tool_call_id" => call.id, "content" => inspect(value)}
  end

  defp tool_result(call, {:error, reason}) do
    %{"tool_call_id" => call.id, "content" => "refused: #{inspect(reason)}"}
  end

  defp tool_messages(steps) do
    Enum.map(steps, fn step ->
      %LLM.Message{
        role: :tool,
        content: step.result["content"],
        tool_call_id: step.result["tool_call_id"]
      }
    end)
  end

  # One tool round, in the order the OpenAI-compatible format requires: the
  # assistant turn that carried the tool calls, then one tool message per
  # call, each answering one call by its id. Without the assistant turn the
  # provider is handed a tool result it never asked for; without the
  # accumulation, a second round loses what the first round learned.
  defp conversation(response, calls, steps) do
    assistant = %LLM.Message{
      role: :assistant,
      content: response.content,
      tool_calls: calls
    }

    [assistant | tool_messages(steps)]
  end

  defp outcome_tag({:ok, _value}), do: "ok"
  defp outcome_tag({:error, _reason}), do: "refused"

  defp tools_for(turn) do
    tools = Tool.Registry.list_for(turn.opts[:agent] || "agent", turn.opts[:actor])

    case turn.opts[:tool_names] do
      nil -> tools
      names when is_list(names) -> Enum.filter(tools, &(&1.name in names))
    end
  end

  defp adapter_for(nil), do: {:error, :no_provider}

  defp adapter_for(provider) do
    case AdapterRegistry.fetch(provider.adapter) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :unknown_adapter}
    end
  end

  # The credential is read **here**, at call time, from the environment
  # variable the provider names. It is never stored and never carried in a
  # domain context: the only thing the registry holds is the variable's name.
  defp init_adapter(adapter, provider) do
    with {:ok, token} <- Provider.Registry.resolve_credential(provider) do
      case adapter.init(%{
             base_url: provider.base_url,
             token: token,
             timeout: 30_000,
             capabilities: provider.capabilities
           }) do
        {:ok, config} -> {:ok, config}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # An operator's model choice arrives from a form, where "no choice" is the
  # empty string rather than nil. Empty means the provider's configured model;
  # only a provider with no model of its own and no selection is refused.
  defp model_for(provider, opts) do
    model_id = present_model(opts[:model]) || present_model(provider.model)

    if model_id do
      {:ok, %LLM.Model{id: model_id, provider: provider.adapter}}
    else
      {:error, :no_model}
    end
  end

  defp present_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_model(_model), do: nil

  defp system_prompt do
    "You are the Veritas assistant. You answer questions about the configuration " <>
      "items by calling the tools you are given. You never invent an answer a tool did not give you."
  end

  defp audit_actor(nil), do: %{type: "agentic_actor", id: "unknown"}
  defp audit_actor(principal), do: Principal.audit_actor(principal)
end
