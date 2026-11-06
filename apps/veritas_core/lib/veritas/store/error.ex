defmodule Veritas.Store.Error do
  @moduledoc """
  The store error taxonomy.

  Every Adapter failure is one of these. The taxonomy is **host-owned**: an
  Adapter maps its engine's native failures onto these codes, and the host
  never pattern-matches on a native error. That is what lets a replacement
  Adapter be dropped in without the domain learning a new vocabulary.

  ## The codes

    * `:unavailable` — the store could not be reached. Retryable.
    * `:timeout` — the store did not answer in time. Retryable.
    * `:conflict` — a concurrent write, a uniqueness violation or a deadlock.
      Retryable, and the host owns the retry so every attempt is auditable.
    * `:not_found` — the record does not exist.
    * `:invalid_request` — the request was malformed, or a constraint
      (a `SCHEMAFULL` field, an `ASSERT`) rejected it.
    * `:unsupported` — the Adapter does not provide the requested capability.
      Never answered with an empty result: an empty result is a lie the caller
      cannot distinguish from "no matches".
    * `:permission_denied` — the store refused the operation.
    * `:protocol` — the store answered, but not in the shape the contract
      requires. A bug in the Adapter or the engine, not in the caller's data.
    * `:internal` — anything else. Always a defect, never a normal outcome.
  """

  @type code ::
          :unavailable
          | :timeout
          | :conflict
          | :not_found
          | :invalid_request
          | :unsupported
          | :permission_denied
          | :protocol
          | :internal

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          details: term(),
          retryable: boolean()
        }

  defexception [:code, :message, :details, :retryable]

  @doc """
  Builds an error.

      %Veritas.Store.Error{code: :conflict, message: "unique index violated"}
  """
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    %__MODULE__{
      code: code,
      message: message,
      details: Keyword.get(opts, :details),
      retryable: Keyword.get(opts, :retryable, default_retryable?(code))
    }
  end

  @doc "Whether an error is worth retrying."
  @spec retryable?(t() | term()) :: boolean()
  def retryable?(%__MODULE__{retryable: retryable}), do: retryable
  def retryable?(_), do: false

  @doc """
  A one-line message for an error, whatever shape it arrives in.

  The CLI and the doctor print this, so a store error reads the same way
  whether it came from the shipped Adapter or from a substitute.

  The **domain's** named refusals are rendered here too, so that the three
  surfaces answer alike. A refusal is one answer: it must read the same way
  whether it came from the CLI, from the GraphQL schema or from a screen, and
  the words belong to one place rather than to each surface.
  """
  @spec message(t() | term()) :: String.t() | nil
  def message(%__MODULE__{message: message}), do: message
  def message({:http_status, status, _body}), do: "the store answered with HTTP #{status}"
  def message({:query_failed, %{"result" => result}}), do: to_string(result)
  def message({:invalid_response, _reason}), do: "the store returned an unreadable response"
  def message({:not_updatable, field}), do: "#{field} is not updatable"
  def message(:not_found), do: "no such record"
  def message(:no_change), do: "the update changes nothing"

  def message(:revision_conflict),
    do: "This changed since you opened it. Reload before trying again."

  def message(:workflow_not_published),
    do: "Publish this workflow before creating a ticket from it."

  def message(:workflow_completed), do: "This workflow is already complete."

  def message(:workflow_step_required),
    do: "Complete the ticket's current workflow step to change its state."

  def message(:ai_draft_required),
    do: "Run the AI step and review its proposal before approving it."

  def message(:not_an_ai_step), do: "The current step is not an AI step."
  def message(:approval_required), do: "A human must explicitly review and approve this step."
  def message(:no_provider), do: "Configure an AI provider in Agent Console → Providers first."
  def message(:no_model), do: "Choose a model from the provider's catalogue before running AI."
  def message(:unknown_adapter), do: "The provider's adapter is not registered in this build."

  def message({:environment_variable_not_set, _name}),
    do:
      "An AI credential is unavailable. Ask a Workspace administrator to check provider credentials."

  def message(%Veritas.Agentic.LLM.Error{message: message}), do: message
  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason)

  defp default_retryable?(:unavailable), do: true
  defp default_retryable?(:timeout), do: true
  defp default_retryable?(:conflict), do: true
  defp default_retryable?(_), do: false
end
