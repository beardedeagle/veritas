defmodule Veritas.Agentic.LLM.Request do
  @moduledoc """
  What the host asks a model.

  The request is host-owned: the host assembles the tool list from the
  registry, and the adapter may not add, remove, rewrite or reorder it
  (`docs/15` §Tool Registry Ownership).

  The `metadata` map carries the host's own bookkeeping — the run id, the
  Workspace, the correlation id — and never a credential.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "The shape the answer must take, when one is asked for."
  @type response_format :: %{
          type: :json_schema | :json,
          schema: map(),
          name: String.t() | nil
        }

  @typedoc "One request."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          model: Veritas.Agentic.LLM.Model.t(),
          messages: [Veritas.Agentic.LLM.Message.t()],
          tools: [Veritas.Agentic.LLM.Tool.t()],
          response_format: response_format() | nil,
          temperature: float() | nil,
          max_output_tokens: pos_integer() | nil,
          seed: integer() | nil,
          stop_sequences: [String.t()],
          metadata: map()
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            model: nil,
            messages: [],
            tools: [],
            response_format: nil,
            temperature: nil,
            max_output_tokens: nil,
            seed: nil,
            stop_sequences: [],
            metadata: %{}
end
