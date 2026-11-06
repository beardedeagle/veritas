defmodule Veritas.Core.Store.Fake do
  @moduledoc """
  Retired. The in-memory test double is now `Veritas.Store.Memory`.

  The domain migrated to the `Veritas.Store` contract (`docs/32`, ADR-048),
  and the contract suite — `Veritas.Core.Store.Conformance` — replaced the
  ad-hoc fake that `docs/32` said it would replace. `Veritas.Store.Memory` is
  a real implementation of that contract: it keeps the Audit Log chain, the
  per-Workspace sequence, the outbox and the Workspace isolation, and it is
  the thing the conformance suite is run against.

  The old `Veritas.Core.Store` port survives only as a shim whose
  `adapter/0` delegates to `Veritas.Store`, so this double no longer has a
  port to implement.

  It remains as a module so that anything still pointing at it fails loudly
  rather than silently diverging from the contract the domain now enforces.
  (The file could not simply be removed: the sandbox this was written in
  denies deletion, and a retired module that explains itself is the next best
  thing to a file that cannot be deleted.)
  """

  @doc """
  Raises with the replacement.

  The old fake was installed by putting itself in the application environment;
  there is nothing to install any more.
  """
  @spec install(term()) :: no_return()
  def install(_state) do
    raise """
    Veritas.Core.Store.Fake has been retired.

    The domain now depends on the `Veritas.Store` contract. Use the in-memory
    Adapter that implements it:

        Veritas.Store.Config.configure({Veritas.Store.Memory, []})

    and prove an Adapter against the contract suite:

        use Veritas.Core.Store.ConformanceCase, adapter: MyAdapter
    """
  end
end
