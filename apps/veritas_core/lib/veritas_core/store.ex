defmodule Veritas.Core.Store do
  @moduledoc """
  **Deprecated.** The statement-based data-access port has been replaced by
  `Veritas.Store` (`docs/32`, ADR-033).

  ## Why this module still exists

  The old port handed the datastore a list of SurrealQL statements. That made
  the datastore a **Fixed** decision in everything but name: the domain spoke
  SurrealQL, so swapping the engine meant rewriting the domain, and the
  "seam" was a function call that happened to take a string.

  The new port is expressed in **domain operations** — a transaction, a
  record, a relation, a sequence — and it forbids a query escape hatch
  precisely so that no Adapter can be a thin wrapper over one engine. That is
  the discipline the agentic port already applies to model providers
  (`docs/15`).

  This module remains for one release so that a test double or a downstream
  integration fails with a *message* rather than a compile error. It will be
  removed in v0.2. **Do not implement it.** Implement `Veritas.Store` instead:
  the conformance suite in `docs/32` is the specification, and
  `Veritas.Store.Memory` is a worked example.

  ## Migrating a test double

      # before
      @behaviour Veritas.Core.Store
      def transaction(_workspace, statements), do: ...

      # after
      @behaviour Veritas.Store
      def transaction(_workspace, fun, _opts), do: ...
  """

  @type workspace :: String.t()

  @callback transaction(workspace(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback query(workspace(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback create(workspace(), atom(), map()) :: {:ok, map()} | {:error, term()}
  @callback read(workspace(), atom(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback update(workspace(), atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback delete(workspace(), atom(), String.t()) :: :ok | {:error, term()}
  @callback impact(workspace(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback migration_version() :: String.t()
  @callback migrate!(workspace()) :: :ok | {:error, term()}

  @doc """
  The Adapter currently installed.

  Kept so that `config :veritas_core, :store_adapter: …` keeps resolving, but
  the returned module must implement `Veritas.Store`.
  """
  @spec adapter() :: module()
  defdelegate adapter(), to: Veritas.Store
end
