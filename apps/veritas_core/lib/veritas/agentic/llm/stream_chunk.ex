defmodule Veritas.Agentic.LLM.StreamChunk do
  @moduledoc """
  One piece of an answer as it arrives.

  The chunk is the delivery vehicle for `opts[:on_event]`. `docs/39` §F7
  reads this as the vehicle rather than a public boundary struct, which is
  the reading that makes B8's count of eight work — but it is a reading, not
  a ruling, so the struct is here and the count is reported.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "What a chunk carries."
  @type kind :: :text | :reasoning | :tool_call_delta | :tool_call | :usage | :done

  @typedoc "One chunk."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          seq: non_neg_integer(),
          kind: kind(),
          text: String.t() | nil,
          tool_call: Veritas.Agentic.LLM.ToolCall.t() | nil,
          usage: Veritas.Agentic.LLM.Usage.t() | nil,
          raw: term() | nil
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            seq: 0,
            kind: :text,
            text: nil,
            tool_call: nil,
            usage: nil,
            raw: nil
end
