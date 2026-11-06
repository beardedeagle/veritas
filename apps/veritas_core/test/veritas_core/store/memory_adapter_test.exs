defmodule Veritas.Core.Store.MemoryAdapterTest do
  @moduledoc """
  The in-memory Adapter writes.

  This module used to be a pin on a defect. `Veritas.Store.Memory` kept its
  data under `:workspaces` while every accessor read it as a top-level
  Workspace key, so the first `put` raised `could not put/update key
  :records on a nil value` inside the server — and the server is supervised by
  the application, so the crash was not contained: a burst of writes exhausted
  the supervisor's restart limit and took the whole application down.

  The fix has landed. The pin is gone, and this is now the positive assertion
  that the second implementation of the contract can write — which is what the
  contract suite's obligations rest on, and what makes the port a **Default**
  rather than a *Fixed* decision (`docs/32`, ADR-033).

  A suite that only ever runs against SurrealDB proves that one engine works.
  This one proves the contract is a contract.
  """
  use ExUnit.Case, async: false

  test "the in-memory Adapter writes a record, and the server survives it" do
    # The application supervises the in-memory server, so it is already
    # running.
    server = Process.whereis(Veritas.Store.Memory.Server)
    assert is_pid(server)

    workspace = "memory_write_#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    assert {:ok, row} =
             Veritas.Store.Memory.transaction(workspace, fn tx ->
               Veritas.Store.Memory.put(tx, :ticket, %{"id" => "t1", "state" => "new"})
             end)

    assert row["id"] == "t1"

    # The write is visible to a later read: the Adapter keeps its own state,
    # and the write did not take the server with it.
    assert {:ok, read} =
             Veritas.Store.Memory.transaction(workspace, fn tx ->
               Veritas.Store.Memory.fetch(tx, :ticket, "t1")
             end)

    assert read["id"] == "t1"
    assert Process.alive?(server), "the in-memory server must survive a write"
  end
end
