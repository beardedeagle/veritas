defmodule Veritas.Agentic.Audit do
  @moduledoc """
  What an Agent Run writes to the Audit Log.

  The Audit Log is the **record**; the console's timeline is a projection of
  it (`docs/39` §7.3). Every entry carries the run id, the tool, the scope
  the tool needed, the policy checks evaluated, the outcome and the
  correlation id.

  ## The arguments are digested, never recorded raw

  A tool's arguments may carry a restricted value, so the entry carries a
  **digest** of them and never the arguments themselves. A secret never
  reaches the Log at all: the digest is of the arguments, and a credential
  is never an argument.

  ## Reasoning is not evidence

  The Log records the decision, the tool, the outcome — not the model's
  prose (`docs/04`).
  """

  alias Veritas.Core.Audit
  alias Veritas.Core.WorkspaceLock
  alias Veritas.Store

  @doc """
  Records a tool call and its outcome.

  The `diff` carries what the Log needs and nothing more: the tool's name,
  the digest of the arguments, the scope the tool needed, the policy's
  verdict and the outcome.
  """
  @spec record_tool_call(Store.workspace(), map()) ::
          {:ok, Store.seq()} | {:error, Store.Error.t()}
  def record_tool_call(workspace, event) when is_binary(workspace) and is_map(event) do
    entry = %{
      subject: event[:run_id] || "agent",
      subject_table: "agent_run",
      from_state: event[:from_state],
      to_state: event[:to_state] || "completed",
      actor: event[:actor] || %{type: "agentic_actor", id: "unknown"},
      reason: event[:reason],
      correlation_id: event[:correlation_id],
      diff:
        %{
          "run_id" => event[:run_id],
          "tool" => event[:tool],
          "arguments_digest" => arguments_digest(event[:arguments] || %{}),
          "scope" => event[:scope] || [],
          "policy" => event[:policy],
          "outcome" => event[:outcome],
          "provider" => event[:provider],
          "model" => event[:model]
        }
        |> without_nils()
    }

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx -> Audit.append(tx, workspace, entry) end)
    end)
  end

  @doc """
  The digest of a tool's arguments.

  The arguments themselves are not recorded: the digest is what proves two
  runs asked the same thing without writing what they asked.
  """
  @spec arguments_digest(map()) :: String.t()
  def arguments_digest(arguments) when is_map(arguments) do
    :sha256
    |> :crypto.hash(Jason.encode!(arguments))
    |> Base.encode16(case: :lower)
  end

  # A diff with a `nil` in it is not written with one.
  #
  # The store does not agree on a null field — one engine keeps it, one drops
  # it — so a diff that carried a null would hash a value the store cannot
  # reproduce, and the row would not verify when it was read back. A field
  # that is not set is simply not in the diff.
  defp without_nils(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end
end
