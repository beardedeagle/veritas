defmodule Veritas.Plugin.Test.FakeHost do
  @moduledoc """
  A Host API adapter that answers from a fixed answer instead of the store.

  The plugin boundary has two halves, and this is the half that can be
  tested without a datastore: the host's **own** API — the operations a
  Plugin may call back over the socket — is exercised here against an
  adapter that answers a known shape.

  The adapter that talks to the real store is `Veritas.Plugin.Host.Default`,
  and the store it uses is covered by the core suite. What this proves is
  the part that belongs to the plugin runtime: that a Plugin's request
  crosses the socket, is checked against the Plugin's grant, reaches the
  adapter, and comes back as an answer the Plugin can read.
  """

  @behaviour Veritas.Plugin.Host

  @impl true
  def init(opts), do: opts

  @impl true
  def call(_context, %{"method" => "read_records", "params" => params}, _state) do
    {:ok, %{"rows" => [%{"id" => "ci-1", "table" => params["table"]}]}}
  end

  def call(_context, _request, _state), do: {:error, :unknown_method}

  @impl true
  def read_records(_context, _table, _filter), do: {:ok, %{rows: [], cursor: nil}}

  @impl true
  def write_records(_context, _table, _records), do: {:ok, []}

  @impl true
  def query_graph(_context, _params), do: {:ok, []}

  @impl true
  def publish_event(_context, _type, _payload), do: {:error, :unsupported}
end
