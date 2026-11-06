defmodule Veritas.Core.Store.ConformanceTest do
  @moduledoc """
  The store contract, run against the shipped Adapter.

  `docs/32` promises the suite "runs in CI for the shipped Adapter on every
  commit". This is that run: one test per obligation of the contract, each
  named by its number, each failing with the Adapter's own words.

  The obligations are executed by `Veritas.Store.Spec` — the normative
  implementation, shared with `mix veritas.store.spec`. This module does not
  re-implement them; a second implementation of the contract is a second
  thing to keep correct, and it is the one that quietly drifts.

  ## Scratch Workspace

  The suite writes to a Workspace of its own and removes it afterwards, so it
  is safe to run against a live store and leaves nothing behind.
  """
  use Veritas.Core.Store.ConformanceCase, adapter: Veritas.Store.Surreal

  alias Veritas.Core.Store.Conformance

  @tag :needs_store

  test "the contract suite executes every obligation it claims to", %{ctx: ctx} do
    {results, _ok?} = Veritas.Store.Spec.run(adapter: ctx.adapter, workspace: ctx.workspace)

    covered = Conformance.covered_obligations(results)

    assert "O-1" in covered
    assert "O-2" in covered
    assert "O-13" in covered
    assert "O-15" in covered
  end

  @tag :needs_store

  test "the obligations the suite does not execute are named, not passed in silence" do
    # `docs/32` has fifteen obligations. The normative suite executes eleven;
    # the vector (O-10), full-text (O-11) and time-series (O-12) obligations
    # are not in its list, so they are reported as not executable rather than
    # passed in silence. If the normative suite grows one, this fails and the
    # gap is closed.
    assert Enum.map(Conformance.not_executable(), &elem(&1, 0)) == ["O-10", "O-11", "O-12"]
  end
end
