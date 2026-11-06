defmodule Veritas.Agentic.LLM.Model do
  @moduledoc """
  A model the provider reports.

  The `supports` list is **capability honesty**: a build without tool-call
  support must say so, and the host must refuse to route a tool-using agent
  to it rather than silently dropping the tools (`docs/15` §(c)). A model
  that claims a capability it does not have is a conformance failure.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "What a model can do."
  @type capability ::
          :tools
          | :parallel_tools
          | :json_schema
          | :json_object
          | :streaming
          | :vision
          | :seed
          | :system_prompt
          | :reasoning

  @typedoc "One model."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          id: String.t(),
          provider: String.t(),
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          supports: [capability()],
          input_cost_per_mtok: float() | nil,
          output_cost_per_mtok: float() | nil,
          metadata: map()
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            id: "",
            provider: "",
            context_window: nil,
            max_output_tokens: nil,
            supports: [],
            input_cost_per_mtok: nil,
            output_cost_per_mtok: nil,
            metadata: %{}
end
