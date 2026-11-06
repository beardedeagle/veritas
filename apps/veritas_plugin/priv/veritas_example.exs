# The host's example Plugin.
#
# A Plugin is a separate OS process speaking JSON-RPC 2.0 over a Unix domain
# socket, exactly as `docs/20` §Transport describes. This program is that
# process: it is started by the host, it reads its bootstrap secret from its
# inherited stdin, it connects to the socket the host is listening on, and
# it answers the calls the host makes.
#
# It has no datastore credentials, no host module in its code path, and no
# way to reach the store: everything it needs to know, it was told.
#
# The tools it registers:
#
#   * `echo`     — returns its first parameter. The smallest possible proof
#                  that a call crossed the boundary and came back.
#   * `ping`     — answers `pong`. The liveness signal `docs/20` describes.
#   * `ask_host` — calls a host-mediated operation back over the same
#                  socket, so the other direction of the boundary can be
#                  exercised.
#   * `crash`    — exits the process. A conformance affordance: a host that
#                  does not survive a Plugin dying is not a host with a
#                  boundary.

defmodule VeritasExample do
  @protocol "veritas.plugin.v1"

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        notify("veritas-example: " <> describe(reason))
        System.halt(1)
    end
  rescue
    error ->
      # Nothing may escape this function. A Plugin process that dies with an
      # uncaught exception cannot report *why* it died: the Elixir launcher
      # starts every VM with `-noshell`, so the standard error device the
      # report would be written to is not there — and the failure to report
      # the failure kills the VM and leaves a crash dump in the host's
      # working directory. So the Plugin says what happened, in the one
      # place that is still open, and exits cleanly.
      notify("veritas-example: crashed: " <> Exception.message(error))
      System.halt(1)
  catch
    kind, reason ->
      notify("veritas-example: crashed: " <> inspect({kind, reason}))
      System.halt(1)
  end

  # Writes a line to the host, if the host is still listening.
  #
  # The group leader is the host's pipe, and the host closes it when it
  # stops a Plugin — so this write can fail, and a failure to write a
  # shutdown notice must not become a crash.
  defp notify(message) do
    IO.puts(message)
  rescue
    _ -> :ok
  end

  defp run(args) do
    with {:ok, options} <- parse_args(args),
         {:ok, bootstrap} <- read_bootstrap(),
         {:ok, manifest} <- read_manifest(options.manifest_path),
         {:ok, socket} <- connect(options.socket_path) do
      session = %{
        socket: socket,
        next_id: 1,
        pending: %{},
        plugin_id: manifest["id"],
        version: manifest["version"],
        secret: bootstrap["secret"],
        generation: bootstrap["install_generation"]
      }

      with :ok <- send_frame(session, hello(session, options)),
           :ok <- await_welcome(session),
           :ok <- send_frame(session, ready()) do
        serve(session)
      end
    end
  end

  # ── the handshake ──────────────────────────────────────────────────────────

  defp hello(session, options) do
    %{
      "jsonrpc" => "2.0",
      "id" => session.next_id,
      "method" => "hello",
      "params" => %{
        "plugin_id" => session.plugin_id,
        "version" => session.version,
        "protocol" => @protocol,
        "manifest_sha256" => digest(options.manifest_path)
      }
    }
  end

  defp ready do
    %{
      "jsonrpc" => "2.0",
      "method" => "ready",
      "params" => %{
        "registrations" => [
          %{
            "kind" => "tool",
            "name" => "echo",
            "required_scopes" => ["ci:read"],
            "description" => "Returns its first parameter."
          },
          %{
            "kind" => "tool",
            "name" => "ping",
            "required_scopes" => ["ci:read"],
            "description" => "Answers pong."
          },
          %{
            "kind" => "tool",
            "name" => "ask_host",
            "required_scopes" => ["ci:read"],
            "description" => "Calls a host-mediated operation over the same socket."
          },
          %{
            "kind" => "tool",
            "name" => "env",
            "required_scopes" => [],
            "description" => "Returns the environment this process was given."
          },
          %{
            "kind" => "tool",
            "name" => "crash",
            "required_scopes" => ["ci:read"],
            "description" => "Exits the process. A conformance affordance."
          }
        ]
      }
    }
  end

  # The Plugin authenticates the host: the session token is an HMAC over
  # the bootstrap secret the Plugin was given on stdin, so a host that does
  # not hold that secret cannot produce it.
  defp await_welcome(session) do
    with {:ok, frame} <- receive_frame(session),
         {:ok, result} <- result_of(frame),
         :ok <- verify_token(session, result) do
      :ok
    end
  end

  defp verify_token(session, result) do
    expected = session_token(session)

    if Map.get(result, "session_token") == expected do
      :ok
    else
      {:error, "the host did not prove it holds the bootstrap secret"}
    end
  end

  defp session_token(session) do
    message =
      "veritas.plugin.session:" <> session.plugin_id <> ":" <> to_string(session.generation)

    :hmac
    |> :crypto.mac(:sha256, session.secret, message)
    |> Base.url_encode64(padding: false)
  end

  # ── serving ────────────────────────────────────────────────────────────────

  defp serve(session) do
    case receive_frame(session) do
      {:ok, frame} ->
        session
        |> handle_frame(frame)
        |> serve()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The Plugin calls the host. The answer comes back later, so the call the
  # host made is held until it does.
  defp ask_host(session, plugin_request_id, params) do
    table = table_of(params)
    host_request_id = session.next_id + 1

    frame = %{
      "jsonrpc" => "2.0",
      "id" => host_request_id,
      "method" => "host.read_records",
      "params" => %{"table" => table, "filter" => %{"where" => [], "limit" => 5}}
    }

    session = %{
      session
      | next_id: host_request_id,
        pending: Map.put(session.pending, host_request_id, plugin_request_id)
    }

    send_frame(session, frame)
    session
  end

  # The parameters of a JSON-RPC call may be an object or an array, and a
  # Plugin author should not have to care which one the host used.
  defp table_of([%{"table" => table} | _rest]), do: table
  defp table_of(%{"table" => table}), do: table
  defp table_of(_params), do: "ci"

  defp handle_frame(session, %{"method" => method, "id" => id} = frame) do
    params = Map.get(frame, "params")

    case method do
      "echo" ->
        send_frame(session, result(id, first_param(params)))

      "ping" ->
        send_frame(session, result(id, "pong"))

      "crash" ->
        IO.puts(:stderr, "veritas-example: crashing on request")
        System.halt(9)

      "ask_host" ->
        ask_host(session, id, params)

      "env" ->
        send_frame(session, result(id, System.get_env()))

      _other ->
        send_frame(session, error(id, -32601, "no such method"))
    end
  end

  # A response from the host: the answer to a call the Plugin made.
  defp handle_frame(session, %{"id" => id, "result" => result}) do
    case Map.pop(session.pending, id) do
      {nil, _pending} ->
        session

      {plugin_request_id, pending} ->
        send_frame(session, result(plugin_request_id, result))
        %{session | pending: pending}
    end
  end

  defp handle_frame(session, %{"id" => id, "error" => %{"message" => message}}) do
    case Map.pop(session.pending, id) do
      {nil, _pending} ->
        session

      {plugin_request_id, pending} ->
        send_frame(session, error(plugin_request_id, -32000, message))
        %{session | pending: pending}
    end
  end

  defp handle_frame(session, %{"method" => method}) do
    IO.puts(:stderr, "veritas-example: ignoring the notification #{method}")
    session
  end

  defp handle_frame(session, _frame), do: session

  # ── the wire ───────────────────────────────────────────────────────────────

  defp send_frame(session, frame) do
    :gen_tcp.send(session.socket, [JSON.encode!(frame), "\n"])
  end

  defp receive_frame(session) do
    case :gen_tcp.recv(session.socket, 0, :infinity) do
      {:ok, data} -> {:ok, JSON.decode!(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp result(id, value) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => value}
  end

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp result_of(frame) do
    case Map.fetch(frame, "result") do
      {:ok, result} -> {:ok, result}
      :error -> {:error, "the host did not answer the handshake"}
    end
  end

  defp first_param(params) when is_list(params), do: List.first(params)
  defp first_param(params) when is_map(params), do: Map.get(params, "value")
  defp first_param(_params), do: nil

  # ── the start-up ───────────────────────────────────────────────────────────

  defp parse_args(args) do
    options = %{socket_path: nil, manifest_path: nil}

    case parse_args(args, options) do
      %{socket_path: socket, manifest_path: manifest} when is_binary(socket) and is_binary(manifest) ->
        {:ok, %{socket_path: socket, manifest_path: manifest}}

      options ->
        {:error,
         "the host did not say where the socket and the manifest are (#{inspect(options)})"}
    end
  end

  defp parse_args([], options), do: options

  defp parse_args(["--veritas-socket", value | rest], options),
    do: parse_args(rest, %{options | socket_path: value})

  defp parse_args(["--veritas-manifest", value | rest], options),
    do: parse_args(rest, %{options | manifest_path: value})

  defp parse_args([_unknown | rest], options), do: parse_args(rest, options)

  # The bootstrap secret arrives on the inherited stdin — never in argv,
  # never in the environment.
  defp read_bootstrap do
    case IO.read(:stdio, :line) do
      :eof ->
        {:error, "the host gave no bootstrap secret"}

      {:error, reason} ->
        {:error, reason}

      line ->
        case JSON.decode(String.trim(line)) do
          {:ok, %{"secret" => secret, "install_generation" => generation}} ->
            {:ok, %{"secret" => secret, "install_generation" => generation}}

          _other ->
            {:error, "the bootstrap secret could not be read"}
        end
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, json} ->
        case JSON.decode(json) do
          {:ok, manifest} -> {:ok, manifest}
          _other -> {:error, "the installed manifest could not be read"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp digest(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp connect(path) do
    options = [:binary, packet: :line, active: false]

    case :gen_tcp.connect({:local, path}, 0, options) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end

VeritasExample.main(System.argv())
