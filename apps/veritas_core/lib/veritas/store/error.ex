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

  @doc """
  Returns transport-safe error data without engine bodies or submitted values.

  Args:
    reason: An internal store failure or named domain refusal.

  Returns:
    A map with a stable string code, generic message and allowlisted details.
  """
  @spec public(term()) :: map()
  def public(%__MODULE__{}),
    do: %{code: "store_error", message: "The operation could not be persisted. Try again later."}

  def public({kind, current}) when kind in [:domain_revision_conflict, :policy_revision_conflict] and
      (is_integer(current) or is_nil(current)),
    do: %{code: Atom.to_string(kind), message: "This changed. Reload before trying again.", current_revision: current}

  def public({:policy_version_conflict, current}) when is_binary(current) or is_nil(current),
    do: %{code: "policy_version_conflict", message: "The active policy changed. Reload before trying again.", current_version: current}

  def public({kind, errors}) when kind in [:invalid_domain_fields, :policy_invalid] and is_map(errors),
    do: %{code: Atom.to_string(kind), message: "Check the highlighted fields.", fields: public_fields(errors)}

  def public({:policy_unconfigured, %{missing: paths, operation: operation}}) do
    %{code: "policy_unconfigured", message: "Required Incident policy configuration is missing.",
      missing: public_paths(paths), operation: public_operation(operation)}
  end

  def public({:principal_required, %{operation: operation}}),
    do: %{code: "principal_required", message: "An authorized Principal is required.", operation: public_operation(operation)}

  def public({:not_updatable, field}) do
    details = if safe_path?(field), do: %{field: field}, else: %{}
    Map.merge(%{code: "not_updatable", message: "This field cannot be changed here."}, details)
  end
  def public({:missing_fields, fields}),
    do: %{code: "missing_fields", message: "Complete the required fields.", missing: public_paths(fields)}
  def public({:invalid_transition, _, _}),
    do: %{code: "invalid_transition", message: "This state transition is not allowed."}
  def public({kind, _}) when kind in [:invalid_ticket_type, :invalid_answers, :invalid_definition,
      :invalid_choice, :step_type_mismatch, :missing_attribute, :invalid_classification],
    do: %{code: Atom.to_string(kind), message: "The supplied fields are not valid for this operation."}

  def public(reason) when reason in [:revision_conflict, :workflow_not_published, :workflow_completed,
      :workflow_step_required, :ai_draft_required, :not_an_ai_step, :approval_required,
      :no_provider, :no_model, :unknown_adapter, :not_found, :no_change, :not_draftable,
      :cannot_read_draft, :no_revision, :incompatible_output],
    do: %{code: Atom.to_string(reason), message: message(reason)}

  def public(reason) when reason in [:clock_evidence_required, :timezone_provider_unavailable,
      :forbidden, :unauthorized, :scope_denied, :human_required, :role_required,
      :workspace_denied, :no_state, :unsupported, :invalid_request],
    do: %{code: Atom.to_string(reason), message: "The operation was refused (#{reason})."}

  def public(_), do: %{code: "operation_refused", message: "The operation could not be completed."}

  defp public_fields(errors) do
    Map.new(for {path, code} <- errors, safe_path?(path),
      into: [], do: {path, if(is_atom(code), do: Atom.to_string(code), else: "invalid")})
  end

  defp public_paths(paths) when is_list(paths), do: Enum.filter(paths, &safe_path?/1)
  defp public_paths(_), do: []
  defp safe_path?(path) when is_binary(path),
    do: byte_size(path) <= 200 and Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, path)
  defp safe_path?(_), do: false
  defp public_operation(operation) when operation in [:create, :content, :assign, :amend, :read,
      :transition, :advance, :publish, :derive_priority, :acknowledge, :response, :resolution, :reopen, :hold, :clock],
    do: Atom.to_string(operation)
  defp public_operation(_), do: "incident"

  defp default_retryable?(:unavailable), do: true
  defp default_retryable?(:timeout), do: true
  defp default_retryable?(:conflict), do: true
  defp default_retryable?(_), do: false
end
