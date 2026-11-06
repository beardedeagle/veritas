defmodule Veritas.Core.Bench.Stats do
  @moduledoc """
  Timing, percentiles and an allocation proxy.

  The budget in `docs/13` is written in p50/p95/p99, so the harness reports
  p50/p95/p99 and never a single number. One number is a summary of a
  distribution the reader cannot check, and a number nobody can reproduce is
  not a measurement.

  ## The percentile method

  **Nearest rank** over the sorted sample list: the p-th percentile is the
  value at index `ceil(p / 100 * n) - 1`. It never invents a value that was
  not observed, it does not need the interpolation that makes two
  implementations disagree about the same data, and the same samples always
  produce the same percentiles — which is what makes a baseline comparable to
  a later run.

  ## The allocation proxy

  `:erlang.statistics(:garbage_collection)` reports the words the VM has
  reclaimed. Words reclaimed is not words allocated, but it moves with
  allocation pressure: a scenario that allocates more reclaims more. It is
  reported as a **proxy**, labelled as one, and it is the metric the
  allocation regression gate compares.

  ## Variance

  A benchmark that reports only its percentiles hides the spread. The report
  carries the minimum, the maximum, the mean and the standard deviation
  beside them, because a p95 that came from a bimodal distribution is a
  different finding from a p95 that came from a tight one.
  """

  @type sample :: %{duration_us: non_neg_integer(), value: term(), words: non_neg_integer()}

  @doc """
  Runs `fun` `samples` times and returns the distribution of how long it took.

  ## Options

    * `:samples` — how many timed runs. Default 30.
    * `:warmup` — how many untimed runs first. Default 3. A cold VM is not
      the steady state the budget describes, and a first run that pays for
      the first request to a server is not a sample of the operation.

  The function is called with no arguments and its return value is kept with
  the timing, so a scenario can report *what* it measured as well as how long
  it took.
  """
  @spec measure((-> term()), keyword()) :: map()
  def measure(fun, opts \\ []) when is_function(fun, 0) do
    samples = Keyword.get(opts, :samples, 30)
    warmup = Keyword.get(opts, :warmup, 3)

    Enum.each(1..warmup//1, fn _ -> fun.() end)

    collected =
      Enum.map(1..samples//1, fn _ -> sample(fun) end)

    durations = collected |> Enum.map(& &1.duration_us) |> Enum.sort()
    words = collected |> Enum.map(& &1.words) |> Enum.sum()

    %{
      samples: length(collected),
      p50: percentile(durations, 50),
      p95: percentile(durations, 95),
      p99: percentile(durations, 99),
      min: List.first(durations),
      max: List.last(durations),
      mean: mean(durations),
      stddev: stddev(durations),
      words: words,
      values: Enum.map(collected, & &1.value)
    }
  end

  @doc """
  The nearest-rank percentile of a sorted list of numbers, in microseconds.
  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _p), do: nil

  def percentile(sorted, p) when is_list(sorted) and p >= 0 and p <= 100 do
    n = length(sorted)
    rank = p |> Kernel./(100) |> Kernel.*(n) |> Float.ceil() |> trunc()
    rank = max(rank, 1)
    Enum.at(sorted, rank - 1)
  end

  @doc """
  Formats a duration in microseconds the way a person reads it.
  """
  @spec format_us(number()) :: String.t()
  def format_us(us) when is_number(us) do
    cond do
      us < 1_000 -> "#{round(us)} µs"
      us < 1_000_000 -> "#{Float.round(us / 1_000, 2)} ms"
      true -> "#{Float.round(us / 1_000_000, 2)} s"
    end
  end

  @doc """
  The mean of a list of numbers, or `nil` for an empty list.
  """
  @spec mean([number()]) :: number() | nil
  def mean([]), do: nil

  def mean(values) do
    Enum.sum(values) / length(values)
  end

  @doc """
  The population standard deviation of a list of numbers.
  """
  @spec stddev([number()]) :: number() | nil
  def stddev([]), do: nil

  def stddev(values) do
    m = mean(values)
    squared = Enum.map(values, fn v -> (v - m) * (v - m) end)
    variance = Enum.sum(squared) / length(values)
    :math.sqrt(variance)
  end

  @doc """
  The percentage by which `now` is worse than `before`. Positive is worse.
  """
  @spec regression_pct(number(), number()) :: number() | nil
  def regression_pct(0, _now), do: nil
  def regression_pct(before, now), do: (now - before) / before * 100

  defp sample(fun) do
    {_gcs_before, words_before, _} = :erlang.statistics(:garbage_collection)
    started = :erlang.monotonic_time(:microsecond)
    value = fun.()
    finished = :erlang.monotonic_time(:microsecond)
    {_gcs_after, words_after, _} = :erlang.statistics(:garbage_collection)

    %{
      duration_us: finished - started,
      value: value,
      words: max(words_after - words_before, 0)
    }
  end
end
