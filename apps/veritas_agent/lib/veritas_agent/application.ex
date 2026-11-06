defmodule Veritas.Agent.Application do
  @moduledoc """
  Supervises the agent runtime.

  Two children, and the split is the corpus's (`docs/15` §Port constraints):

    * the **HTTP pool** the adapters use. An adapter brings its own
      dependencies and its own children, so the pool belongs to
      `veritas_agent`'s supervisor and not to the host's;
    * the **adapter registrations**. The catalogue is runtime data, so
      nothing about the choice is compiled in (`docs/15` §Configuration).

  The adapters themselves are pure translators with no state of their own,
  so there is nothing to supervise beyond the pool.
  """
  use Application

  alias Veritas.Agentic.LLM.Adapter
  alias Veritas.Agentic.LLM.AdapterRegistry

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Veritas.Agent.Finch}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: Veritas.Agent.Supervisor) do
      {:ok, _pid} = started ->
        # The catalogue is runtime data, so the adapters are registered when
        # the application starts rather than compiled in.
        register_adapters()
        started

      other ->
        other
    end
  end

  @doc """
  Registers the adapters this application ships.

  The catalogue is keyed by adapter id, so an operator may substitute an
  adapter without a restart and without touching a domain module
  (`docs/15` B4).
  """
  @spec register_adapters() :: :ok
  def register_adapters do
    AdapterRegistry.register(Adapter.OpenAICompatible.id(), Adapter.OpenAICompatible)
    AdapterRegistry.register(Adapter.Ollama.id(), Adapter.Ollama)
    :ok
  end
end
