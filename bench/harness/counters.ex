defmodule Veritas.Core.Bench.Counters do
  @moduledoc """
  Counts the HTTP round trips a scenario makes.

  Latency says how slow a path is. Round trips say **why**. A traversal that
  takes 900 ms because it made 70 requests and a traversal that takes 900 ms
  because the store is slow are different defects with different owners, and
  only one of them is an N+1.

  The count comes from Finch's own telemetry, so it counts the requests the
  Adapter really made without the Adapter being told to count them. The
  Adapter is not modified; the harness watches it.

  Finch emits a **span**: `[:finch, :request, :start]` and
  `[:finch, :request, :stop]`, with the pool under `:name` in the metadata.
  The count is taken from the stop event, which is the one that says a
  request finished.

  ## Attribution

  Finch emits `[:finch, :request]` in the process that made the request, and
  the handler forwards the event to the process that started the counter. The
  count is therefore attributed to the **pool** the request went to, which is
  what separates the product's store traffic from the harness's own
  statements.
  """

  @handler "veritas-bench-finch-counter"

  @doc """
  Starts counting. Returns the number of round trips already pending.
  """
  @spec start() :: :ok
  def start do
    drain()

    case :telemetry.attach(@handler, [:finch, :request, :stop], &__MODULE__.handle/4, self()) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  The telemetry handler.

  It is a remote capture rather than an anonymous function: a local function
  as a telemetry handler is called through a closure, and the library warns
  about exactly that.
  """
  @spec handle(term(), map(), map(), pid()) :: :ok
  def handle(_event, _measurements, metadata, pid) do
    send(pid, {:finch_request, metadata[:name]})
  end

  @doc """
  Stops counting and returns the number of round trips that were made.
  """
  @spec stop() :: non_neg_integer()
  def stop do
    :telemetry.detach(@handler)
    count()
  end

  @doc """
  The round trips seen so far, by pool.
  """
  @spec count() :: non_neg_integer()
  def count do
    drain()
  end

  @doc """
  The round trips seen so far, grouped by pool name.
  """
  @spec by_pool() :: %{optional(term()) => non_neg_integer()}
  def by_pool do
    drain_by_pool()
  end

  @doc """
  Runs `fun` and returns its value together with the round trips it made.
  """
  @spec measure((-> term())) :: {term(), non_neg_integer()}
  def measure(fun) when is_function(fun, 0) do
    start()
    value = fun.()
    {value, stop()}
  end

  # The harness's own requests are not the product's store traffic. A page
  # load is one request to the endpoint, and counting it as a store round
  # trip would say the traversal made more requests than it made.
  @own_pool :veritas_bench_raw

  defp drain do
    drain_by_pool()
    |> Map.reject(fn {pool, _count} -> pool == @own_pool end)
    |> Map.values()
    |> Enum.sum()
  end

  defp drain_by_pool do
    receive do
      {:finch_request, pool} ->
        Map.update(drain_by_pool(), pool, 1, &(&1 + 1))
    after
      0 -> %{}
    end
  end
end
