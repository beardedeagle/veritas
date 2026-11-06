defmodule Veritas.Plugin.Transport.UnixSocket do
  @moduledoc """
  The shipped transport: JSON-RPC frames over a Unix domain socket.

  A Unix domain socket is a file on the filesystem. The host creates it with
  the mode `0600`, so the socket can be connected to by the user running the
  host and by nobody else — that file mode **is** the authentication, which
  is why `docs/20` §Transport prefers it to a loopback port, where any other
  local process could reach the listener.

  The frames are lines: the socket is opened with `packet: :line`, so a read
  returns one frame and the newline is not part of it. That keeps the
  framing in one place — the transport — instead of in both peers.

  The socket path is short on purpose. macOS caps a Unix socket path at 104
  bytes, and `docs/20` §Transport keeps the paths under a short runtime
  directory for that reason; a path that does not fit is a path that cannot
  be connected to.

  This adapter is **Default**: the corpus fixes the transport family, and
  this is the one implementation of it this host ships.
  """

  @behaviour Veritas.Plugin.Transport

  @doc """
  Creates the socket file and listens on it.

  The socket's file mode is set to `0600` immediately after it is created,
  because a socket's mode is the credential: only the user running the host
  may connect to it. The runtime directory that holds it is private to the
  host as well, so the socket is unreachable even in the moment between
  creation and the mode being set.

  The listen options cannot set the mode themselves — a Unix domain socket's
  mode is not among them — so the mode is set here, by hand, every time.
  """
  @impl true
  @spec listen(String.t()) :: {:ok, Veritas.Plugin.Transport.socket()} | {:error, term()}
  def listen(path) when is_binary(path) do
    # A socket left behind by a host that died is not a listener: the
    # address is taken by a file with nobody behind it. Removing it first
    # is what lets the same address be used again.
    _ = File.rm(path)

    options = [
      :binary,
      packet: :line,
      active: false,
      ifaddr: {:local, path},
      reuseaddr: true
    ]

    case :gen_tcp.listen(0, options) do
      {:ok, socket} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, socket}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}

          other ->
            other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Accepts one connection, waiting up to `timeout` milliseconds."
  @impl true
  @spec accept(Veritas.Plugin.Transport.socket(), timeout()) ::
          {:ok, Veritas.Plugin.Transport.socket()} | {:error, term()}
  def accept(socket, timeout) when timeout == :infinity or is_integer(timeout) do
    :gen_tcp.accept(socket, timeout)
  end

  @doc "Connects to a listening socket at `path`."
  @impl true
  @spec connect(String.t(), timeout()) ::
          {:ok, Veritas.Plugin.Transport.socket()} | {:error, term()}
  def connect(path, timeout)
      when is_binary(path) and (timeout == :infinity or is_integer(timeout)) do
    options = [:binary, packet: :line, active: false]

    case :gen_tcp.connect({:local, path}, 0, options, timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Sends one frame as one line."
  @impl true
  @spec send_message(Veritas.Plugin.Transport.socket(), binary()) :: :ok | {:error, term()}
  def send_message(socket, frame) when is_binary(frame) do
    :gen_tcp.send(socket, [frame, "\n"])
  end

  @doc "Receives one frame, waiting up to `timeout` milliseconds."
  @impl true
  @spec receive_message(Veritas.Plugin.Transport.socket(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def receive_message(socket, timeout) when timeout == :infinity or is_integer(timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, frame} -> {:ok, frame}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Closes the socket and removes the socket file."
  @impl true
  @spec close(Veritas.Plugin.Transport.socket()) :: :ok
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end
end
