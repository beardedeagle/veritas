defmodule Veritas.Core.Store.Surreal do
  @moduledoc """
  The SurrealDB Adapter, under its **former** name.

  The Adapter is `Veritas.Store.Surreal` (`docs/32`, ADR-048). This module
  remains so that a reference written against the old name still reaches a
  working store instead of an undefined function.

  It is a complete implementation of the `Veritas.Store` contract — every
  callback is forwarded to the real Adapter — so it can be handed to the
  conformance suite exactly like the Adapter it points at. It holds no
  behaviour of its own, and it will be removed in v0.2.
  """

  @behaviour Veritas.Store

  alias Veritas.Store.Surreal, as: Adapter

  @doc "See `Veritas.Store.Surreal.migrate/1`."
  @spec migrate(String.t()) :: :ok | {:error, Veritas.Store.Error.t()}
  defdelegate migrate(workspace), to: Adapter

  @doc "See `Veritas.Store.Surreal.migration_version/0`."
  @spec migration_version() :: String.t()
  defdelegate migration_version(), to: Adapter

  @doc "See `Veritas.Store.Surreal.settings/0`."
  @spec settings() :: keyword()
  defdelegate settings(), to: Adapter

  @impl Veritas.Store
  defdelegate transaction(workspace, fun, opts \\ []), to: Adapter

  @impl Veritas.Store
  defdelegate fetch(tx, table, record_id), to: Adapter

  @impl Veritas.Store
  defdelegate put(tx, table, record), to: Adapter

  @impl Veritas.Store
  defdelegate delete(tx, table, record_id), to: Adapter

  @impl Veritas.Store
  defdelegate list(tx, table, filter), to: Adapter

  @impl Veritas.Store
  defdelegate next_sequence(tx, key), to: Adapter

  @impl Veritas.Store
  defdelegate relate(tx, kind, from, to, attrs), to: Adapter

  @impl Veritas.Store
  defdelegate unrelate(tx, kind, from, to), to: Adapter

  @impl Veritas.Store
  defdelegate traverse(tx, from, direction, depth, opts), to: Adapter

  @impl Veritas.Store
  defdelegate relation_counts(tx, ids), to: Adapter

  @impl Veritas.Store
  defdelegate impact(tx, ci_id, depth), to: Adapter

  @impl Veritas.Store
  defdelegate put_ci_type(tx, spec), to: Adapter

  @impl Veritas.Store
  defdelegate put_relation_kind(tx, spec), to: Adapter

  @impl Veritas.Store
  defdelegate ci_types(tx), to: Adapter

  @impl Veritas.Store
  defdelegate relation_kinds(tx), to: Adapter

  @impl Veritas.Store
  defdelegate upsert_chunks(tx, subject, chunks), to: Adapter

  @impl Veritas.Store
  defdelegate vector_search(tx, embedding, opts), to: Adapter

  @impl Veritas.Store
  defdelegate fulltext_search(tx, query, opts), to: Adapter

  @impl Veritas.Store
  defdelegate append_samples(tx, samples), to: Adapter

  @impl Veritas.Store
  defdelegate range_samples(tx, target, from, to, opts), to: Adapter

  @impl Veritas.Store
  defdelegate append_audit(tx, event), to: Adapter

  @impl Veritas.Store
  defdelegate changes(tx, since, opts), to: Adapter

  @impl Veritas.Store
  defdelegate describe(), to: Adapter
end
