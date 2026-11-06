defmodule Veritas.Plugin.Health do
  @moduledoc """
  The health check a Plugin's manifest declares.

  `docs/08` §Manifest declares `health.check` as an HTTP endpoint the host
  uses to classify the Plugin as healthy or degraded, and `docs/20` §Manifest
  reconciliation adds the rule that matters: **the protocol heartbeat is
  primary and the HTTP endpoint is supplementary**. A Plugin that answers on
  the socket but whose HTTP endpoint is dead is not a dead Plugin; it is a
  Plugin the host should treat with suspicion, and the two are different
  states.

  So this module answers one question — "does the declared endpoint answer
  successfully?" — and the caller decides what that means. The host uses it
  to mark a running Plugin `:degraded`; the protocol itself is what decides
  whether the Plugin is `:running` or `:quarantined`.

  The check is a plain HTTP/1.1 GET over a socket, with the timeout the
  manifest declares. It is deliberately small: it runs while the host is
  starting a Plugin, and a health check that can hang is a health check that
  can hang the host.
  """

  @type result :: :ok | {:error, term()}

  @doc """
  Checks a health endpoint.

  `timeout_ms` bounds the whole exchange — connect, write and read — because
  a wedged endpoint must not hold the host.
  """
  @spec check(String.t(), pos_integer()) :: result()
  def check(url, timeout_ms) when is_binary(url) and is_integer(timeout_ms) do
    with {:ok, scheme, host, port, path} <- parse_url(url),
         {:ok, socket} <- connect(scheme, host, port, timeout_ms) do
      try do
        request =
          "GET #{path} HTTP/1.1\r\n" <>
            "Host: #{host}:#{port}\r\n" <>
            "User-Agent: veritas-plugin-health\r\n" <>
            "Connection: close\r\n\r\n"

        case send_and_receive(socket, scheme, request, timeout_ms) do
          {:ok, response} -> status(response)
          {:error, reason} -> {:error, reason}
        end
      after
        close(socket, scheme)
      end
    end
  end

  @doc """
  Whether a URL names an endpoint this module can check.
  """
  @spec valid?(term()) :: boolean()
  def valid?(url) when is_binary(url) do
    match?({:ok, _scheme, _host, _port, _path}, parse_url(url))
  end

  def valid?(_url), do: false

  # ── the URL ────────────────────────────────────────────────────────────────

  defp parse_url(url) do
    with [scheme, rest] <- String.split(url, "://", parts: 2),
         true <- scheme in ["http", "https"],
         [host_port, path] <- String.split(rest, "/", parts: 2) do
      {host, port} = split_port(host_port, scheme)
      {:ok, scheme, host, port, "/" <> path}
    else
      _ -> {:error, {:invalid_url, url}}
    end
  end

  defp split_port(host_port, scheme) do
    default = if scheme == "https", do: 443, else: 80

    case String.split(host_port, ":", parts: 2) do
      [host, port] ->
        case Integer.parse(port) do
          {number, ""} -> {host, number}
          _ -> {host_port, default}
        end

      [host] ->
        {host, default}
    end
  end

  # ── the socket ─────────────────────────────────────────────────────────────

  # A connection that cannot be made is an answer, not a crash.
  #
  # `:gen_tcp.connect/4` *exits* on an address it cannot even try — port
  # zero, for instance — rather than returning an error, and a health check
  # that takes the host down with it is worse than no health check at all.
  defp connect(scheme, host, port, timeout_ms) do
    do_connect(scheme, host, port, timeout_ms)
  catch
    :exit, reason -> {:error, reason}
  end

  defp do_connect("http", host, port, timeout_ms) do
    :gen_tcp.connect(host, port, [:binary, active: false], timeout_ms)
  end

  defp do_connect("https", host, port, timeout_ms) do
    _ = Application.ensure_all_started(:ssl)

    :ssl.connect(
      host,
      port,
      [
        :binary,
        active: false,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: :disable,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout_ms
    )
  end

  defp send_and_receive(socket, scheme, request, timeout_ms) do
    case send(socket, scheme, request) do
      :ok ->
        receive(socket, scheme, timeout_ms)

      other ->
        other
    end
  end

  defp send(socket, "http", request), do: :gen_tcp.send(socket, request)
  defp send(socket, "https", request), do: :ssl.send(socket, request)

  defp receive(socket, "http", timeout_ms), do: :gen_tcp.recv(socket, 0, timeout_ms)
  defp receive(socket, "https", timeout_ms), do: :ssl.recv(socket, 0, timeout_ms)

  defp close(socket, "http"), do: :gen_tcp.close(socket)
  defp close(socket, "https"), do: :ssl.close(socket)

  # A health endpoint answers 2xx. Anything else — a 404, a 500, a redirect
  # — is not a healthy endpoint.
  defp status(response) do
    case response do
      "HTTP/1.1 " <> rest ->
        case rest |> String.split(" ", parts: 2) |> List.first() |> Integer.parse() do
          {code, ""} when code >= 200 and code < 300 -> :ok
          {code, ""} -> {:error, {:http_status, code}}
          _ -> {:error, :malformed_response}
        end

      _ ->
        {:error, :malformed_response}
    end
  end
end
