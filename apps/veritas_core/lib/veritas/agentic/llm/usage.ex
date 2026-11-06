defmodule Veritas.Agentic.LLM.Usage do
  @moduledoc """
  What the answer cost.

  The host computes the cost from its own pricing table and treats the
  provider's figures as advisory (`docs/15` B10), so these numbers are
  recorded, not trusted.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "Token counts."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          raw: map()
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            input_tokens: nil,
            output_tokens: nil,
            cached_input_tokens: nil,
            reasoning_tokens: nil,
            raw: %{}
end
