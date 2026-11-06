defmodule Veritas.Agentic.LLM.Adapter do
  @moduledoc """
  What an adapter must expose besides the Port's callbacks.

  An adapter is a **pure translator** with no product state (`docs/15`
  §Adapter Design). It identifies itself, and it validates its configuration
  once so that a misconfigured provider is refused before a call is made.

  The adapter's identifier is the key the catalogue is built on, and it is
  what a Provider registry entry names.
  """

  @doc """
  The adapter's identifier, as the catalogue knows it.

  `:ollama`, `:openai_compatible`, `:anthropic` — the names the corpus uses.
  """
  @callback id() :: atom()

  @doc """
  Validates the configuration and returns it, or refuses it.

  Returns the normalised configuration the callbacks then take, so an adapter
  never re-parses its own configuration on every call.
  """
  @callback init(config :: map()) ::
              {:ok, map()} | {:error, Veritas.Agentic.LLM.Error.t()}
end
