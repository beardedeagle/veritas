defmodule Veritas.Web.Shell.Plug do
  @moduledoc """
  Puts the shell state on the connection.

  The shell is rendered by the root layout, around the page, so it needs its
  facts before the route runs. This plug is where they are collected.

  It is in the `:browser` pipeline, which means it runs for every HTML
  request — controller pages and LiveView pages alike. The LiveView's own
  render is not involved, so a LiveView re-render never re-sends the
  navigation.

  It reads nothing that can time out. If the datastore is unreachable, the
  shell still renders and the page behind it says what went wrong.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    Plug.Conn.assign(conn, :shell, Veritas.Web.Shell.Context.state(conn))
  end
end
