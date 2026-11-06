defmodule Veritas.Agentic.LLM.Message do
  @moduledoc """
  One message in a conversation.

  The four roles are the boundary's own: a system instruction, a person's
  turn, the model's turn, and a tool's answer. A tool message carries the
  id of the call it answers, so a result is never ambiguous.
  """

  @typedoc "Who is speaking."
  @type role :: :system | :user | :assistant | :tool

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "One message."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          role: role(),
          content: String.t(),
          tool_calls: [Veritas.Agentic.LLM.ToolCall.t()],
          tool_call_id: String.t() | nil,
          name: String.t() | nil
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            role: :user,
            content: "",
            tool_calls: [],
            tool_call_id: nil,
            name: nil
end
