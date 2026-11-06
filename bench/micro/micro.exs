# The isolated hot paths.
#
# docs/13 §Performance Engineering Process names this slot
# "micro/ — benchee, mix bench: hot paths in isolation".
#
# benchee is not in this repository's dependency set, and the dependency set
# is fixed. So the isolated measurements use the harness's own statistics
# code, which has the advantage that one percentile method is used
# everywhere: the numbers here and the numbers in the main report are
# computed the same way, and a percentile that means one thing in the
# report and another in the micro-benchmark would be worth nothing.
#
#     MIX_ENV=test mix run --no-start bench/micro/micro.exs
#
# What is measured here is what is *pure* — the paths that run in process,
# with no store and no network. The product's own isolated hot paths (the CI
# list filter, the Audit Log's hash) are private functions, and measuring
# them in isolation would mean re-implementing them here. The corpus's rule
# about the conformance suite applies: a second implementation of a thing is
# a second thing to keep correct, and it is the one that quietly drifts.

harness = Path.expand("../harness", __DIR__)

order = [
  "stats.ex",
  "budget.ex",
  "raw.ex",
  "counters.ex",
  "explain.ex",
  "web.ex",
  "scenarios.ex",
  "gate.ex",
  "report.ex",
  "fixture.ex",
  "cli.ex"
]

known = Enum.map(order, &Path.join(harness, &1))
rest = harness |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort() |> Kernel.--(known)

for file <- known ++ rest do
  Code.require_file(file)
end

alias Veritas.Core.Bench.{Explain, Gate, Stats}

plan = """
SelectProject [ctx: Db] [projections: id, in, out, kind]
    TableScan [ctx: Db] [table: ci_depends_on, direction: Forward, predicate: out = ci:web - 1, pre_decode_filter: no (unsupported predicate)]
"""

samples = Enum.to_list(1..10_000)

results = [
  %{
    name: "Stats.percentile/2 over 10,000 samples",
    run: fn -> Stats.percentile(samples, 95) end
  },
  %{
    name: "Explain.operators/1 over a plan",
    run: fn -> Explain.operators(plan) end
  },
  %{
    name: "Gate.dataset_fingerprint/1 over a shape",
    run: fn ->
      Gate.dataset_fingerprint(%{depth: 5, fan_out: 12, fan_in: 12, node_count: 250, edge_count: 249})
    end
  }
]

IO.puts("""

Isolated hot paths
==================

""")

IO.puts(
  String.pad_trailing("path", 46) <>
    String.pad_trailing("p50", 12) <>
    String.pad_trailing("p95", 12) <>
    String.pad_trailing("p99", 12) <> "n"
)

Enum.each(results, fn %{name: name, run: run} ->
  stats = Stats.measure(run, samples: 200, warmup: 10)

  IO.puts(
    String.pad_trailing(name, 46) <>
      String.pad_trailing(Stats.format_us(stats.p50), 12) <>
      String.pad_trailing(Stats.format_us(stats.p95), 12) <>
      String.pad_trailing(Stats.format_us(stats.p99), 12) <>
      to_string(stats.samples)
  )
end)

IO.puts("""

These are in-process measurements. They are the paths the benchmark itself
pays for, and the product's private hot paths are not measured here: a
second implementation of them would be a second thing to keep correct.
""")
