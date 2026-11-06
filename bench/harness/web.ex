defmodule Veritas.Core.Bench.Web do
  @moduledoc """
  The web surfaces, reached without a compile-time dependency on them.

  `veritas_core` cannot depend on `veritas_web` — the dependency runs the
  other way — so the harness may not name `Veritas.Web.Endpoint` in a call
  and expect it to compile. It names it at runtime instead, through
  `Module.concat/1`, and checks that the module is loaded before it uses it.

  A benchmark that quietly skipped the web surfaces would be a false signal:
  the CMDB index page is one of the paths the budget names, and a report that
  omitted it would look like a clean run. So `available?/0` is asked first,
  and the report says which surfaces ran and which did not.

  ## Why a real listener

  The page load is measured over HTTP against a running endpoint, not by
  calling the LiveView directly. The reason is the N+1: the cost of a CMDB
  index page is a function of how many store requests the page causes, and
  that is only visible when the page is really served.
  """

  @doc """
  Whether the web application is present in this VM.

  It is when the harness runs in the umbrella, where every application's
  build is on the code path.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(endpoint_module()) and Code.ensure_loaded?(schema_module())
  end

  @doc """
  Starts an endpoint on a free port and returns its base url.
  """
  @spec start_endpoint() :: {:ok, String.t()} | {:error, term()}
  def start_endpoint do
    with {:ok, port} <- free_port() do
      bandit = Module.concat(["Elixir.Bandit"])

      case apply(bandit, :start_link, [[
               plug: endpoint_module(),
               port: port,
               ip: {127, 0, 0, 1},
               startup_log: false
             ]]) do
        {:ok, _pid} -> {:ok, "http://127.0.0.1:#{port}"}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  @doc """
  Fetches a path from the endpoint and returns `{:ok, status, body}`.
  """
  @spec get(String.t(), String.t()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def get(base_url, path) do
    with :ok <- Veritas.Core.Bench.Raw.ensure_pool() do
      request = build_request(:get, base_url <> path, [{"accept", "text/html"}], "")

      case Finch.request(request, :veritas_bench_raw, receive_timeout: 60_000) do
        {:ok, response} -> {:ok, response.status, response.body}
        {:error, reason} -> {:error, reason}
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

  @doc """
  Runs a GraphQL document against the product's schema.
  """
  @spec graphql(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def graphql(document, variables \\ %{}) do
    absinthe = Module.concat(["Elixir.Absinthe"])

    result =
      apply(absinthe, :run, [
        document,
        schema_module(),
        [variables: variables, context: %{}]
      ])

    case result do
      {:ok, %{data: data, errors: nil}} -> {:ok, data}
      {:ok, %{data: data, errors: errors}} -> {:ok, %{data: data, errors: errors}}
      other -> {:error, other}
    end
  end

  defp endpoint_module, do: Module.concat(["Elixir.Veritas.Web.Endpoint"])
  defp schema_module, do: Module.concat(["Elixir.Veritas.Web.GraphQL.Schema"])

  defp free_port do
    case :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
