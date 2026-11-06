defmodule Veritas.Agentic.LLM.Error do
  @moduledoc """
  A refusal, in the boundary's own words.

  The codes are the host's, not the provider's: a native code rides in
  `provider_code` and is opaque. `retryable` is the host's judgement —
  retries are host-owned so every attempt is an auditable row (`docs/15`
  §Port constraints).

  A message never carries a credential. The adapter redacts before it
  builds the error.
  """

  @typedoc "The schema version of this struct."
  @type schema_version :: pos_integer()

  @typedoc "Why a call was refused."
  @type code ::
          :timeout
          | :rate_limited
          | :overloaded
          | :invalid_request
          | :authentication
          | :permission_denied
          | :not_found
          | :content_filter
          | :transport
          | :protocol
          | :cancelled
          | :unsupported
          | :budget_exceeded
          | :internal

  @typedoc "One refusal."
  @type t :: %__MODULE__{
          schema_version: schema_version(),
          code: code(),
          message: String.t(),
          provider_code: term() | nil,
          retryable: boolean(),
          retry_after_ms: pos_integer() | nil,
          raw: term() | nil
        }

  @schema_version 1

  @doc "The schema version of this struct."
  @spec schema_version() :: schema_version()
  def schema_version, do: @schema_version

  defstruct schema_version: @schema_version,
            code: :internal,
            message: "",
            provider_code: nil,
            retryable: false,
            retry_after_ms: nil,
            raw: nil
end
