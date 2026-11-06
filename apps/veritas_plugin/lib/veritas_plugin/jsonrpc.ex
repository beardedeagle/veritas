defmodule Veritas.Plugin.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 frames — the wire format of the plugin boundary.

  JSON-RPC 2.0 is the format `docs/20` §Transport names: a **request** names a
  method and carries its parameters, a **response** carries the result of a
  request, and an **error response** carries a code and a message. It was
  chosen because a Plugin written in Go, Python, Rust or Node can speak it
  against a socket with no dependency and no commercial tooling at all.

  ## Framing

  One JSON object per line — "JSON Lines". A line is a frame, a frame is a
  line, and neither side has to agree on anything else. The transport reads
  lines, so the framing lives with the bytes rather than with a length
  prefix nobody else has to implement.

  ## The size cap

  A frame is capped at **8 MiB**, the message-size limit `docs/20` §Resource
  Limits sets. The cap is enforced in both directions: an oversized frame is
  refused rather than decoded, because an unbounded frame is an unbounded
  allocation in the host, and the host is the thing that has to stay up.

  ## The codec

  The frames are encoded and decoded with `JSON` from Elixir's standard
  library. That is deliberate: a Plugin host that needs a JSON codec should
  not need a dependency to get one, and the codec must not be the thing that
  decides whether a Plugin can be written in another language.
  """

  @max_message_bytes 8 * 1024 * 1024

  # The codes JSON-RPC 2.0 reserves. They are integers, and the underscore
  # is a literal separator: the value written into the JSON is unchanged.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @server_error -32_000

  @type frame :: map()
  @type id :: integer() | String.t()

  @doc "The largest frame this host will encode or accept, in bytes."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc "The JSON-RPC protocol version this host speaks."
  @spec version() :: String.t()
  def version, do: "2.0"

  @doc "The code for a frame that is not JSON."
  @spec parse_error() :: integer()
  def parse_error, do: @parse_error

  @doc "The code for a frame that is JSON but not a JSON-RPC frame."
  @spec invalid_request() :: integer()
  def invalid_request, do: @invalid_request

  @doc "The code for a method this host does not serve."
  @spec method_not_found() :: integer()
  def method_not_found, do: @method_not_found

  @doc "The code for parameters a method cannot accept."
  @spec invalid_params() :: integer()
  def invalid_params, do: @invalid_params

  @doc "The code for a fault inside the host."
  @spec internal_error() :: integer()
  def internal_error, do: @internal_error

  @doc "The code for a fault that is the host's own (an operation refused)."
  @spec server_error() :: integer()
  def server_error, do: @server_error

  @doc """
  A request frame.

  `id` correlates the response with the request; the host never reuses one
  inside a session.
  """
  @spec request(id(), String.t(), term()) :: frame()
  def request(id, method, params) do
    %{"jsonrpc" => version(), "id" => id, "method" => method, "params" => params}
  end

  @doc """
  A notification frame — a request with no answer expected.
  """
  @spec notification(String.t(), term()) :: frame()
  def notification(method, params) do
    %{"jsonrpc" => version(), "method" => method, "params" => params}
  end

  @doc "A successful response frame."
  @spec response(id(), term()) :: frame()
  def response(id, result) do
    %{"jsonrpc" => version(), "id" => id, "result" => result}
  end

  @doc "An error response frame."
  @spec error_response(id(), integer(), String.t(), term()) :: frame()
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}

    error = if is_nil(data), do: error, else: Map.put(error, "data", data)

    %{"jsonrpc" => version(), "id" => id, "error" => error}
  end

  @doc """
  Encodes a frame.

  Returns the frame as a single line, without the newline: the transport
  adds the line ending, because the transport owns the framing.
  """
  @spec encode(frame()) :: {:ok, binary()} | {:error, String.t()}
  def encode(frame) when is_map(frame) do
    json = JSON.encode!(frame)

    if byte_size(json) > @max_message_bytes do
      {:error,
       "the frame is #{byte_size(json)} bytes, which is over the #{@max_message_bytes} byte limit"}
    else
      {:ok, json}
    end
  rescue
    error -> {:error, "the frame could not be encoded: #{Exception.message(error)}"}
  end

  @doc """
  Decodes a frame.

  A frame that is not JSON, or is JSON but not an object, is refused with the
  reason — never guessed at.
  """
  @spec decode(binary()) :: {:ok, frame()} | {:error, String.t()}
  def decode(data) when is_binary(data) do
    if byte_size(data) > @max_message_bytes do
      {:error,
       "the frame is #{byte_size(data)} bytes, which is over the #{@max_message_bytes} byte limit"}
    else
      case JSON.decode(data) do
        {:ok, frame} when is_map(frame) ->
          {:ok, frame}

        {:ok, other} ->
          {:error, "a frame must be a JSON object, got #{inspect(other)}"}

        {:error, reason} ->
          {:error, "the frame is not JSON: #{inspect(reason)}"}
      end
    end
  rescue
    error -> {:error, "the frame is not JSON: #{Exception.message(error)}"}
  end

  @doc """
  A fresh request identifier.

  Monotonic within a session, so a response can never be mistaken for the
  answer to another request.
  """
  @spec new_id() :: integer()
  def new_id, do: System.unique_integer([:positive, :monotonic])
end
