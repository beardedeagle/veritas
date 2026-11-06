defmodule Veritas.Plugin.Host.Operations do
  @moduledoc """
  The Host API this host offers a Plugin.

  These are the **host-mediated capability calls** of `docs/20` §Data
  Access: a Plugin holds a capability, not a data-plane handle. It cannot
  write SurrealQL, it cannot open a scoped session, and it cannot hold a
  cursor; it asks the host for a named operation and the host decides whether
  the Plugin's grant covers it.

  Four operations, each with the capability it needs:

  | Method | Capability |
  |---|---|
  | `host.read_records` | `ci:read` or `ticket:read`, by the table asked for |
  | `host.write_records` | `ci:write` or `ticket:write`, by the table asked for |
  | `host.query_graph` | `graph:query` |
  | `host.publish_event` | `ingest:publish` |

  The table is built at compile time by `Veritas.Plugin.Host.Builder`, so
  what the host serves is a literal in this module rather than something
  assembled while the host is busy.

  The method names are the corpus's, with the `host.` prefix this host adds
  so a Plugin's own methods and the host's methods cannot be confused on one
  socket.
  """

  use Veritas.Plugin.Host.Builder

  operation "read_records",
    scope: {:by_param, "table", %{"ci" => :ci_read, "ticket" => :ticket_read}}

  operation "write_records",
    scope: {:by_param, "table", %{"ci" => :ci_write, "ticket" => :ticket_write}}

  operation "query_graph", scope: :graph_query

  operation "publish_event", scope: :ingest_publish

  @doc """
  The operation a method names, if this host serves it.

  Both `"host.read_records"` and `"read_records"` name the same operation: a
  Plugin may use either, and the host answers both.
  """
  @spec lookup(String.t()) :: {:ok, {String.t(), keyword()}} | :error
  def lookup(method) when is_binary(method) do
    name = String.replace_prefix(method, "host.", "")

    case Enum.find(__host_operations__(), fn {operation, _opts} -> operation == name end) do
      nil -> :error
      operation -> {:ok, operation}
    end
  end

  @doc """
  The capabilities a call to this method needs.

  An operation the host does not serve needs no capability — it is refused
  as an unknown method before any capability is consulted.
  """
  @spec scopes(String.t(), map()) :: [atom()]
  def scopes(method, params) when is_binary(method) and is_map(params) do
    case lookup(method) do
      {:ok, {_name, opts}} -> scope_list(Keyword.fetch!(opts, :scope), params)
      :error -> []
    end
  end

  def scopes(_method, _params), do: []

  defp scope_list(scope, _params) when is_atom(scope), do: [scope]

  defp scope_list({:by_param, key, mapping}, params) do
    case Map.get(params, key) do
      nil -> []
      value -> List.wrap(mapping[value])
    end
  end
end
