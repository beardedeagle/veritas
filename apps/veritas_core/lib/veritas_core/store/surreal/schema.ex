defmodule Veritas.Core.Store.Surreal.Schema do
  @moduledoc """
  **Moved.** The schema of record is now `Veritas.Store.Surreal.Schema`
  (`docs/32`, ADR-033).

  This module is kept for one release so that a stale reference fails with a
  message rather than a compile error. It will be removed in v0.2.
  """

  @doc "See `Veritas.Store.Surreal.Schema.statements/0`."
  defdelegate statements(), to: Veritas.Store.Surreal.Schema

  @doc "See `Veritas.Store.Surreal.Schema.seed_statements/0`."
  defdelegate seed_statements(), to: Veritas.Store.Surreal.Schema

  @doc "See `Veritas.Store.Surreal.Schema.incident_transitions/0`."
  defdelegate incident_transitions(), to: Veritas.Store.Surreal.Schema

  @doc "See `Veritas.Store.Surreal.Schema.transitions/0`."
  defdelegate transitions(), to: Veritas.Store.Surreal.Schema
end
