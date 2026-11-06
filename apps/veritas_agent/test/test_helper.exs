# The live-provider suite reaches a real provider with a real credential; it
# runs only when asked for by tag, never as part of the default run.
ExUnit.start(exclude: [:live_provider])

# The provider registry reads and writes through the store. The suite uses the
# in-memory adapter, so it needs no datastore and leaves nothing behind.
Veritas.Store.Config.configure({Veritas.Store.Memory, []})

defmodule Veritas.Agent.Test.StubProvider do
  @moduledoc """
  A local HTTP server that stands in for a model provider.

  The adapters under test speak real HTTP — that is the whole point of these
  tests, because the bugs they pin are on the wire: a body decoded twice, a
  method that is wrong, a header that was dropped. So the stub is a real
  server on the loopback interface, and the assertions are made on what it
  actually received.

  Nothing here reaches the internet. The port is ephemeral and the socket is
  closed when the test ends.

  ## The routes

  A route is registered for a method and a path, with the answers the stub
  gives. The answers are a **sequence**: the first request to that route gets
  the first answer, the second gets the second, and the last answer is
  repeated after that. A route may also require an `authorization` header, in
  which case a request without one is answered `401` — which is how a
  provider that needs a credential behaves.

  A request to a path that exists under another method is answered `405`,
  which is how Ollama answers a `POST` to `/api/tags`.
  """

  use GenServer

  # ── the API ─────────────────────────────────────────────────────────────────

  @doc "Starts the stub. The port is ephemeral."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The base URL a provider is configured with."
  def base_url(pid), do: GenServer.call(pid, :base_url)

  @doc "Every request the stub received, oldest first."
  def requests(pid), do: GenServer.call(pid, :requests)

  @doc "Forgets the requests, keeping the routes."
  def reset(pid), do: GenServer.call(pid, :reset)

  @doc """
  Registers what the stub answers for a method and a path.

  `answers` is a list of `{status, body}` pairs, given out in order.
  """
  def respond(pid, method, path, answers, opts \\ []) do
    GenServer.call(pid, {:respond, method, path, answers, opts})
  end

  @doc "Stops the stub and closes its socket."
  def stop(pid), do: GenServer.stop(pid)

  # ── the server ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        backlog: 16
      ])

    {:ok, port} = :inet.port(listen)
    owner = self()

    spawn_link(fn -> accept_loop(listen, owner) end)

    {:ok,
     %{
       listen: listen,
       port: port,
       routes: %{},
       counts: %{},
       requests: []
     }}
  end

  @impl true
  def handle_call(:base_url, _from, state) do
    {:reply, "http://127.0.0.1:#{state.port}", state}
  end

  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | requests: [], counts: %{}}}
  end

  def handle_call({:respond, method, path, answers, opts}, _from, state) do
    route = %{answers: answers, require_authorization: opts[:require_authorization] == true}
    routes = Map.put(state.routes, {method, path}, route)

    {:reply, :ok, %{state | routes: routes, counts: Map.delete(state.counts, {method, path})}}
  end

  def handle_call({:response_for, request}, _from, state) do
    key = {request.method, request.path}
    count = Map.get(state.counts, key, 0)

    state = %{state | counts: Map.put(state.counts, key, count + 1)}

    reply =
      case Map.fetch(state.routes, key) do
        {:ok, route} ->
          if route.require_authorization and not authorized?(request) do
            {401, ~s({"error":"the credential is required"})}
          else
            answer(route.answers, count)
          end

        :error ->
          # The path may exist under another method: that is a 405, not a 404.
          if Enum.any?(state.routes, fn {{_method, path}, _route} -> path == request.path end) do
            {405, ~s({"error":"the method is not allowed"})}
          else
            {404, ~s({"error":"no such endpoint"})}
          end
      end

    {:reply, http(reply), state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  # The answers are a sequence: the first request gets the first, and the last
  # answer is repeated after the sequence runs out.
  defp answer(answers, count) do
    Enum.at(answers, min(count, length(answers) - 1))
  end

  defp authorized?(request) do
    Enum.any?(request.headers, fn {name, _value} -> String.downcase(name) == "authorization" end)
  end

  defp http({status, body}) do
    reason =
      case status do
        200 -> "OK"
        401 -> "Unauthorized"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        _other -> "Status"
      end

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end

  # ── the wire ────────────────────────────────────────────────────────────────

  defp accept_loop(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, owner) end)
        accept_loop(listen, owner)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, owner) do
    case read_request(socket) do
      {:ok, request} ->
        send(owner, {:received, request})
        response = GenServer.call(owner, {:response_for, request})
        :gen_tcp.send(socket, response)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, head, rest} <- read_head(socket, "") do
      {method, path, headers} = parse_head(head)
      body = read_body(socket, rest, headers)

      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp read_head(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [head, rest] -> {:ok, head, rest}
          [_only] -> read_head(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ") do
      [method, path | _rest] ->
        headers =
          for line <- header_lines,
              [name, value] <- [String.split(line, ":", parts: 2)],
              is_binary(value),
              do: {String.downcase(String.trim(name)), String.trim(value)}

        {String.upcase(method), path, headers}

      _other ->
        {"GET", "/", []}
    end
  end

  defp read_body(socket, rest, headers) do
    case content_length(headers) do
      0 ->
        rest

      length when byte_size(rest) >= length ->
        binary_part(rest, 0, length)

      length ->
        rest <> read_exactly(socket, length - byte_size(rest))
    end
  end

  defp content_length(headers) do
    case Enum.find(headers, fn {name, _value} -> name == "content-length" end) do
      {_name, value} -> String.to_integer(String.trim(value))
      nil -> 0
    end
  end

  defp read_exactly(_socket, 0), do: ""

  defp read_exactly(socket, count), do: read_exactly(socket, count, "")

  defp read_exactly(_socket, 0, acc), do: acc

  defp read_exactly(socket, count, acc) do
    case :gen_tcp.recv(socket, count, 5_000) do
      {:ok, data} -> read_exactly(socket, count - byte_size(data), acc <> data)
      {:error, _reason} -> acc
    end
  end
  @impl true
  def handle_info({:received, request}, state) do
    {:noreply, %{state | requests: [request | state.requests]}}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
