defmodule Veritas.Plugin.Transport do
  @moduledoc """
  The seam the plugin boundary is spoken over.

  A **transport** moves frames between the host and a Plugin process.
  `docs/20` §Transport fixes the wire to JSON-RPC 2.0 over a Unix domain
  socket on Linux and macOS and a named pipe on Windows, with no localhost
  TCP port ever opened: a UDS is authenticated by filesystem ACL, needs no
  TLS, and needs no port allocation.

  This module is the **adapter seam** around that decision, in Plug's idiom:
  the behaviour is tiny, the implementation is substitutable, and the
  substitution is a configuration fact rather than a rewrite.

  ## The implementations

    * `Veritas.Plugin.Transport.UnixSocket` — the shipped adapter. It
      listens on a Unix domain socket whose file mode is `0600`, so only the
      user running the host may connect to it.
    * `Veritas.Plugin.Transport.Test` — the shipped test harness. It never
      opens a socket, so a Plugin author can test an adapter without a
      process, a port or a race.

  ## Why a seam at all

  The named pipe on Windows is a different mechanism behind the same
  behaviour, and a Plugin author testing against a mock should not have to
  start an OS process to do it. The behaviour is the contract; the adapters
  are the choices.

  A transport is **Default**: this behaviour is the corpus's shape, and the
  host ships one implementation and tests against another. The choice of a
  Unix domain socket rather than a TCP port is **Fixed** by `docs/20`, for
  the reasons that document gives.
  """

  @type socket :: term()
  @type path :: String.t()

  @doc """
  Opens a listening socket at `path`.

  The host listens and the Plugin connects: the Plugin is the process that
  has to prove itself, and a client that has to knock is easier to refuse
  than a listener that has to accept.
  """
  @callback listen(path()) :: {:ok, socket()} | {:error, term()}

  @doc "Accepts one connection on a listening socket."
  @callback accept(socket(), timeout()) :: {:ok, socket()} | {:error, term()}

  @doc "Connects to a listening socket at `path`."
  @callback connect(path(), timeout()) :: {:ok, socket()} | {:error, term()}

  @doc "Sends one frame."
  @callback send_message(socket(), binary()) :: :ok | {:error, term()}

  @doc """
  Receives one frame, waiting up to `timeout` milliseconds.

  Returns `{:error, :timeout}` when nothing arrives in time, which is how a
  wedged Plugin is told apart from a slow one.
  """
  @callback receive_message(socket(), timeout()) :: {:ok, binary()} | {:error, term()}

  @doc "Closes the socket."
  @callback close(socket()) :: :ok
end
