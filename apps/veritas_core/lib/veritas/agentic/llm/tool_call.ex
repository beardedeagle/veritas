defmodule Veritas.Agentic.LLM.ToolCall do
  @moduledoc """
  A tool call as the model asks for it.

  The arguments are the decoded map, and the raw arguments are the string
  the provider sent, kept for the Audit Log's diagnostics and never for the
  domain to read.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "One tool call."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          id: String.t(),
          name: String.t(),
          arguments: map(),
          raw_arguments: String.t() | nil
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            id: "",
            name: "",
            arguments: %{},
            raw_arguments: nil
end
