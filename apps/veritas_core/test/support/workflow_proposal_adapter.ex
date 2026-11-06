defmodule Veritas.Core.Test.WorkflowProposalAdapter do
  @moduledoc "Test-only model responses for workflow domain, GraphQL and CLI boundary proofs."
  @behaviour Veritas.Agentic.LLM
  @behaviour Veritas.Agentic.LLM.Adapter
  alias Veritas.Agentic.LLM
  alias Veritas.Agentic.LLM.AdapterRegistry

  def id, do: :workflow_proposal_test
  def init(config), do: {:ok, config}

  def complete(request, _config, opts) do
    response = Process.get(:workflow_proposal_response, "A proposal based on the recorded facts.")

    content =
      cond do
        is_function(response, 2) -> response.(request, opts)
        is_function(response, 1) -> response.(request)
        is_function(response, 0) -> response.()
        true -> response
      end

    case content do
      {:error, _} = error ->
        error

      content ->
        {:ok,
         %LLM.Response{
           id: "workflow-test",
           model: request.model.id,
           content: content,
           finish_reason: :stop
         }}
    end
  end

  def stream(_, _, _), do: {:error, :unsupported}
  def models(_), do: {:ok, []}

  def install do
    previous = Application.get_env(:veritas_core, :providers)
    previous_adapter = AdapterRegistry.fetch(id())
    AdapterRegistry.register(id(), __MODULE__)

    Application.put_env(:veritas_core, :providers,
      workflow_proposal_test: [
        kind: :self_hosted,
        adapter: id(),
        base_url: "http://workflow-test.invalid",
        model: "test-model"
      ]
    )

    fn ->
      if previous,
        do: Application.put_env(:veritas_core, :providers, previous),
        else: Application.delete_env(:veritas_core, :providers)

      table = :ets.whereis(:veritas_agentic_adapters)

      # ExUnit may already have terminated the test process that owned this table.
      try do
        case previous_adapter do
          {:ok, module} -> :ets.insert(table, {id(), module})
          :error -> :ets.delete(table, id())
        end
      rescue
        error in ArgumentError ->
          if :ets.info(table) != :undefined, do: reraise(error, __STACKTRACE__)
      end
    end
  end
end
