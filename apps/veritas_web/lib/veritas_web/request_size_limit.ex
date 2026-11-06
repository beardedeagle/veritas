defmodule Veritas.Web.RequestSizeLimit do
  @moduledoc """
  Refuses a request whose body is larger than the limit.

  The limit is checked on the declared `Content-Length`, before the body is
  read, so an oversized request costs a header and a response rather than a
  buffer. A request that declares no length is stopped by the parser's own
  limit instead.

  It answers with a small JSON body and the status a client expects for a
  body it is not allowed to send, rather than raising: an oversized request
  is a client error, not a fault in the server.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    max = Keyword.get(opts, :max_bytes, 1_000_000)

    case declared_length(conn) do
      length when is_integer(length) and length > max ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          413,
          Jason.encode!(%{"errors" => [%{"message" => "the request body is too large"}]})
        )

      _ ->
        conn
    end
  end

  defp declared_length(conn) do
    conn
    |> Plug.Conn.get_req_header("content-length")
    |> Enum.find_value(fn value ->
      case Integer.parse(value) do
        {length, ""} -> length
        _ -> nil
      end
    end)
  end
end
