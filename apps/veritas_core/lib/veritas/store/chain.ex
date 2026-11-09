defmodule Veritas.Store.Chain do
  @moduledoc """
  The seam through which the host owns the Audit Log's chain.

  The chain algorithm is the **host's**, not the Adapter's. `docs/32` says the
  Adapter stores the chain fields and "never computes a chain", and it puts
  "replacing the Audit Log format or the chain algorithm" outside the
  datastore seam — that is seam 7, the Audit Log's own seam.

  A migration is the one moment the Adapter has to write chain fields it did
  not receive from the host. A legacy row that carries no hash at all has to
  join the chain, or the store refuses the row outright: `hash` is a required
  field of the append-only record (`docs/07`), and the corpus's schema makes
  it non-optional. The Adapter therefore asks the host for the chain through
  this seam and writes what the host returns.

  The host registers its own reconciliation when the application starts:

      Veritas.Store.Chain.register(&Veritas.Core.Audit.reconcile_chain/1)

  With no algorithm registered, the migration leaves the chain alone and says
  so. It does not invent one, and it does not fall back to a chain of its own.
  """

  @registry {__MODULE__, :reconciler}
  @verifier {__MODULE__, :verifier}

  @type row :: map()
  @type assignment :: %{id: String.t(), prev_hash: String.t() | nil, hash: String.t()}

  @doc """
  Registers the host's chain reconciliation.

  The function is given the Workspace's Audit Log rows, as the store returned
  them, and answers the chain each row belongs to: the rows in chain order,
  each with the predecessor's hash and its own.
  """
  @spec register(([row()] -> {:ok, [assignment()]} | {:error, String.t()})) :: :ok
  def register(fun) when is_function(fun, 1) do
    :persistent_term.put(@registry, fun)
    :ok
  end

  @doc "Whether a host has registered its chain."
  @spec registered?() :: boolean()
  def registered?, do: not is_nil(reconciler())

  @doc """
  The host's chain reconciliation over the given rows.

  Answers an error when no host has registered a chain: the migration then
  leaves the chain as it found it rather than inventing one.
  """
  @spec reconcile([row()]) :: {:ok, [assignment()]} | {:error, String.t()}
  def reconcile(rows) do
    case reconciler() do
      nil -> {:error, "no host has registered a chain algorithm"}
      fun -> fun.(rows)
    end
  end

  @doc """
  Registers the host's read-only verification, separately from reconciliation.

  Args:
    fun (function/2): Workspace and complete normalized rows in sequence order.

  Returns:
    `:ok` after registration. The callback retains the host's verification
    verdict; registration does not authorize reconciliation or writes.
  """
  @spec register_verifier((String.t(), [row()] ->
          {:ok, :intact} | {:ok, {:broken_at, non_neg_integer()}} | {:error, term()})) :: :ok
  def register_verifier(fun) when is_function(fun, 2) do
    :persistent_term.put(@verifier, fun)
    :ok
  end

  @doc """
  Verifies the supplied history through the host, without reconciling it.

  Args:
    workspace (String.t()): Workspace whose anchor the host must check.
    rows ([row()]): Complete normalized history in ascending sequence order.

  Returns:
    The host verdict, or an error when no verifier is registered.
  """
  @spec verify(String.t(), [row()]) ::
          {:ok, :intact} | {:ok, {:broken_at, non_neg_integer()}} | {:error, term()}
  def verify(workspace, rows) do
    case :persistent_term.get(@verifier, nil) do
      nil -> {:error, "no host has registered an audit verifier"}
      fun -> fun.(workspace, rows)
    end
  end

  defp reconciler, do: :persistent_term.get(@registry, nil)
end
