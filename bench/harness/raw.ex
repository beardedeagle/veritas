defmodule Veritas.Core.Bench.Raw do
  @moduledoc """
  A raw SurrealQL statement against the store.

  The Adapter's `request/2` is private, and the harness needs two things it
  does not expose: the **plan** a statement gets (`EXPLAIN`), and the **cost
  of one request** to the store. So the harness speaks the same HTTP dialect
  the Adapter speaks — the same `/sql` endpoint, the same `surreal-ns` and
  `surreal-db` headers, the same credentials — rather than inventing a second
  client that might behave differently from the one under test.

  The credentials come from the Adapter's own configuration
  (`Veritas.Store.Config.options/0`), so the harness cannot accidentally
  measure a different store from the one the product is using.
  """

  @pool :veritas_bench_raw
  @pool_size 4

  @type auth :: :basic | :bearer | :none

  @doc """
  Runs one SurrealQL statement in `workspace` and returns the parsed result.
  """
  @spec statement(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def statement(sql, workspace, opts \\ []) do
    auth = Keyword.get(opts, :auth, :basic)

    with {:ok, url} <- url(),
         {:ok, {status, _headers, body}} <- post(url, sql, workspace, auth),
         {:ok, decoded} <- decode(body) do
      case status do
        200 -> {:ok, decoded}
        other -> {:error, {:http_status, other, decoded}}
      end
    end
  end

  @doc """
  The time one request to the store takes, in microseconds.

  This is the number every other number divides by. The budget's depth-5 row
  says 150-500 ms for a traversal; how many round trips that allows is
  `budget_ms / this_number`. Measured rather than assumed, because the
  Adapter's per-request cost is not the engine's cost — the engine reports
  158 microseconds for the same statement the Adapter takes 12.8 ms to fetch.
  """
  @spec request_latency_us(String.t(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def request_latency_us(sql, workspace, opts \\ []) do
    samples = Keyword.get(opts, :samples, 10)

    case statement(sql, workspace, opts) do
      {:ok, _} ->
        timings =
          for _ <- 1..samples do
            started = :erlang.monotonic_time(:microsecond)
            {:ok, _} = statement(sql, workspace, opts)
            :erlang.monotonic_time(:microsecond) - started
          end

        timings = Enum.sort(timings)
        {:ok, Enum.at(timings, div(length(timings), 2))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The store's url, user and password, as the Adapter sees them.

  The settings are read the way the Adapter reads them —
  `Veritas.Store.Surreal.settings/0` plus the `VERITAS_SURREAL_URL`
  environment variable and the credential defaults — so the harness cannot
  end up measuring a different store from the one the product is using.

  It is deliberately **not** `Veritas.Store.Config.options/0`: under the
  configuration `config/runtime.exs` writes, that accessor matches neither
  the map form nor the `{module, options}` tuple form and returns `[]`, so
  the Adapter falls back to its own settings. The harness follows the
  Adapter, not the accessor.
  """
  @spec connection() :: {:ok, map()} | {:error, term()}
  def connection do
    settings = Veritas.Store.Surreal.settings()

    url = settings[:url] || System.get_env("VERITAS_SURREAL_URL")

    if is_binary(url) do
      {:ok,
       %{
         url: url,
         user: settings[:user] || "root",
         pass: settings[:pass] || "root"
       }}
    else
      {:error, :no_url}
    end
  end

  defp url do
    case connection() do
      {:ok, %{url: url}} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(url, sql, workspace, auth) do
    with :ok <- ensure_pool() do
      request = build_request(:post, url <> "/sql", headers(workspace, auth), body(sql))

      case Finch.request(request, @pool, receive_timeout: 30_000) do
        {:ok, response} ->
          {:ok, {response.status, response.headers, response.body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The type is stated, because a request built from computed values is
  # inferred as dynamic, and `Finch.request/3` wants a request.
  @spec build_request(atom(), String.t(), [{String.t(), String.t()}], String.t()) ::
          Finch.Request.t()
  defp build_request(method, url, headers, body) do
    Finch.build(method, url, headers, body)
  end

  @spec body(String.t()) :: String.t()
  defp body(sql), do: sql

  @spec headers(String.t(), auth()) :: [{String.t(), String.t()}]
  defp headers(workspace, auth) do
    base = [
      {"accept", "application/json"},
      {"content-type", "text/plain"},
      {"surreal-ns", workspace},
      {"surreal-db", workspace}
    ]

    case auth do
      :basic -> base ++ [{"authorization", basic_auth()}]
      :bearer -> base ++ [{"authorization", bearer()}]
      :none -> base
    end
  end

  defp basic_auth do
    case connection() do
      {:ok, %{user: user, pass: pass}} ->
        "Basic " <> Base.encode64("#{user}:#{pass}")

      _ ->
        ""
    end
  end

  # A bearer token is obtained once, from `/signin`, and then presented on
  # every request. The Adapter presents a Basic credential on every request,
  # and the store re-verifies the password each time — which is the single
  # largest cost in the store path. The harness measures both so the
  # difference is a number rather than an opinion.
  defp bearer do
    case bearer_token() do
      {:ok, token} -> "Bearer " <> token
      _ -> ""
    end
  end

  @doc """
  A bearer token for the store, obtained once through `/signin`.

  The token is **cached**, because that is the whole point of it: signing in
  verifies the password, and verifying the password is the expensive part.
  A harness that signed in for every request would measure the cost of the
  sign-in and call it the cost of the request, which is exactly the mistake
  the Adapter makes with its Basic credential.
  """
  @spec bearer_token() :: {:ok, String.t()} | {:error, term()}
  def bearer_token do
    with {:ok, %{url: url}} <- connection() do
      key = {__MODULE__, :bearer_token, url}

      case :persistent_term.get(key, nil) do
        nil ->
          case sign_in(url) do
            {:ok, token} ->
              :persistent_term.put(key, token)
              {:ok, token}

            error ->
              error
          end

        token ->
          {:ok, token}
      end
    end
  end

  defp sign_in(url) do
    with {:ok, %{user: user, pass: pass}} <- connection(),
         :ok <- ensure_pool() do
      body = Jason.encode!(%{"user" => user, "pass" => pass})

      request =
        Finch.build(
          :post,
          url <> "/signin",
          [{"accept", "application/json"}, {"content-type", "application/json"}],
          body
        )

      case Finch.request(request, @pool, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"token" => token}} -> {:ok, token}
            other -> {:error, {:no_token, other}}
          end

        {:ok, %{status: other}} ->
          {:error, {:signin_failed, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Starts the pool the harness speaks to the store through, if it is not
  already running.
  """
  @spec ensure_pool() :: :ok | {:error, term()}
  def ensure_pool do
    case Process.whereis(@pool) do
      nil ->
        case Finch.start_link(name: @pool, pool_size: @pool_size) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:undecodable, reason}}
    end
  end
end
