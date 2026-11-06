defmodule Veritas.Agentic.LLM.Tool do
  @moduledoc """
  A tool as a model sees it.

  This is **the only projection an adapter ever sees** (`docs/15` §Tool
  Registry Ownership): a name, a description and a JSON Schema. The tool's
  scope, side-effect class, approval policy, timeout and idempotency are
  host-side and never reach a provider.

  The parameters are **host-canonical JSON Schema**, so the same tool
  appears in every adapter's request without rewriting.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "A tool, as the model sees it."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            name: "",
            description: "",
            parameters: %{"type" => "object", "properties" => %{}}
end
