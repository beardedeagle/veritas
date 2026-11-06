defmodule Veritas.Agentic.LLM.Response do
  @moduledoc """
  What a model answered.

  A tool call in a response is a **request**, not an action: the host
  decides whether it may run, and the answer says only that the model asked.
  `raw` holds the provider's own payload, which the domain never reads.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "Why the model stopped."
  @type finish_reason :: :stop | :tool_calls | :length | :content_filter | :other

  @typedoc "One answer."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          id: String.t(),
          model: String.t(),
          content: String.t(),
          tool_calls: [Veritas.Agentic.LLM.ToolCall.t()],
          structured: {:ok, map()} | {:error, Veritas.Agentic.LLM.Error.t()} | nil,
          usage: Veritas.Agentic.LLM.Usage.t(),
          finish_reason: finish_reason(),
          raw: map() | nil
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            id: "",
            model: "",
            content: "",
            tool_calls: [],
            structured: nil,
            usage: %Veritas.Agentic.LLM.Usage{},
            finish_reason: :stop,
            raw: nil
end
