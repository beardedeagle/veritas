defmodule Veritas.Core.Store.MemoryConformanceTest do
  @moduledoc """
  The store contract, run against the in-memory Adapter.

  This is the module that makes the port a *Default* rather than a *Fixed*
  decision (`docs/32`, ADR-033). A suite that only ever runs against
  SurrealDB proves that one engine works; a suite that runs against two
  implementations of the same contract proves the contract is a contract.

  `Veritas.Store.Memory` is the second implementation: it keeps the Audit
  Log chain, the per-Workspace sequence, the outbox and the Workspace
  isolation, and it is the reference an Adapter author reads before writing
  their own.

  It is also the one most likely to fail an obligation, because it is the
  one with no engine underneath it: every obligation is checked against
  behaviour the real store would have provided. A failure here is a finding
  about the Adapter, and it is reported as one.
  """
  # This run was a job of its own while the Adapter crashed on its first
  # write. The crash is fixed, so the Adapter is part of the default suite
  # again — which is the point: the port has two implementations, and the
  # suite runs against both.
  use Veritas.Core.Store.ConformanceCase, adapter: Veritas.Store.Memory

  @tag :needs_store

  test "the in-memory Adapter is installed for the run" do
    assert Veritas.Store.adapter() == Veritas.Store.Memory
  end
end
