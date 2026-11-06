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

  defp reconciler, do: :persistent_term.get(@registry, nil)
end
