defmodule Veritas.Core.Bench.StatsTest do
  @moduledoc """
  The statistics the budget's percentiles are computed with.

  The percentile method is part of the measurement, so it is tested: a
  harness that computed its percentiles differently from run to run would
  make two baselines incomparable without saying so.
  """
  use ExUnit.Case, async: true

  alias Veritas.Core.Bench.Stats

  describe "percentile/2" do
    test "is the nearest rank of the sorted samples" do
      samples = Enum.to_list(1..100)

      assert Stats.percentile(samples, 50) == 50
      assert Stats.percentile(samples, 95) == 95
      assert Stats.percentile(samples, 99) == 99
      assert Stats.percentile(samples, 100) == 100
    end

    test "never invents a value that was not observed" do
      samples = [10, 20, 30, 40]

      for p <- [0, 25, 50, 75, 100] do
        assert Enum.member?(samples, Stats.percentile(samples, p))
      end
    end

    test "on thirty samples the p95 is the twenty-ninth smallest" do
      samples = Enum.to_list(1..30)

      assert Stats.percentile(samples, 95) == 29
      assert Stats.percentile(samples, 50) == 15
    end

    test "is nil for no samples" do
      assert Stats.percentile([], 95) == nil
    end
  end

  describe "measure/2" do
    test "reports p50, p95 and p99 — the percentiles the budget is written in" do
      stats = Stats.measure(fn -> :ok end, samples: 20, warmup: 1)

      assert stats.samples == 20
      assert is_integer(stats.p50)
      assert is_integer(stats.p95)
      assert is_integer(stats.p99)
      assert stats.min <= stats.p50
      assert stats.p50 <= stats.p95
      assert stats.p95 <= stats.p99
      assert stats.p99 <= stats.max
    end

    test "runs the warmup untimed" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Stats.measure(fn -> Agent.update(counter, &(&1 + 1)) end, samples: 5, warmup: 3)

      assert Agent.get(counter, & &1) == 8
    end
  end

  describe "regression_pct/2" do
    test "is positive when the measurement got worse" do
      assert Stats.regression_pct(100, 110) == 10.0
      assert Stats.regression_pct(100, 90) == -10.0
    end

    test "is nil when there is no baseline to compare against" do
      assert Stats.regression_pct(0, 10) == nil
    end
  end

  describe "format_us/1" do
    test "reads the way a person reads a duration" do
      assert Stats.format_us(158) == "158 µs"
      assert Stats.format_us(12_800) == "12.8 ms"
      assert Stats.format_us(1_877_000) == "1.88 s"
    end
  end
end
