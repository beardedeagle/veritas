defmodule Veritas.Core.Bench.CLI do
  @moduledoc """
  Runs the benchmark and applies the gate.

  The order of the run is the order of the arguments of `--check`:

    1. **The store.** By default the harness starts its **own** SurrealDB, on
       its own port, with its own data directory — the same helper the
       integration tests use. A benchmark that needs a store somebody else
       started is a benchmark that measures somebody else's state, and a
       benchmark that needs an environment variable is a benchmark that does
       not run on a clean checkout.

       `--store-url` points it at a store that is already running. The
       harness never falls back to the configured default, because the
       default on a developer machine is somebody's *empty* store, and a
       benchmark against an empty store measures nothing.

    2. **The fixture.** The graph the budget assumes, seeded into a scratch
       Workspace of the harness's own.

    3. **The scenarios.** Each one measured with the round trips it made.

    4. **The EXPLAIN gate.** The plan the store chose for every hot query.

    5. **The gate.** Budget breaches, regressions against the committed
       baseline, plan drift, the round-trip ceiling and the node cap.

    6. **The cleanup.** The scratch Workspace is removed and the store the
       harness started is stopped. A benchmark that leaves its data behind
       changes what it measures on the next run.
  """

  alias Veritas.Core.Bench.{Counters, Explain, Fixture, Gate, Raw, Report, Scenarios, Stats}
  alias Veritas.Core.Test.SurrealServer

  @default_workspace_prefix "veritas_bench"

  @doc """
  Entry point. Returns the process exit code.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    case parse(argv) do
      {:help, text} ->
        IO.puts(text)
        0

      {:error, reason} ->
        IO.puts(:stderr, "mix veritas.bench: #{reason}")
        2

      {:ok, options} ->
        run(options)
    end
  end

  @doc """
  The usage text.
  """
  @spec usage() :: String.t()
  def usage do
    """
    mix veritas.bench — the performance benchmark and the gate.

        --samples N        samples per scenario (default 30)
        --check            apply the full gate: budget breaches, regressions,
                           plan drift, the round-trip ceiling, the node cap
        --check-deterministic
                           apply only the gates that do not depend on how
                           fast the machine is: plan drift, the round-trip
                           ceiling, the node cap
        --store-url URL    measure against a store that is already running
                           (default: start an isolated one of the harness's own)
        --workspace NAME   the Workspace to seed (default: a generated one)
        --wide             seed the shape that reaches the 5,000-node cap
        --accept-baseline  write this run as the committed baseline
        --json PATH        write the JSON report here
                           (default: bench/last-run.json)
        --load-environment declare this run to be on the dedicated
                           load-test environment
        --no-web           skip the web surfaces
        --help             this text
    """
  end

  # ── the run ───────────────────────────────────────────────────────────────

  defp run(options) do
    samples = Keyword.get(options, :samples)

    case open_store(options) do
      {:ok, store} ->
        # The store this run started is stopped whether the run finished, failed
        # or raised. A benchmark that leaves a database running behind it is a
        # benchmark that leaks a process every time it is used — and a leaked
        # store is one nobody can clean up afterwards.
        try do
          run_with_store(samples, store, options)
        after
          stop_store(store)
        end

      {:error, reason} ->
        IO.puts(:stderr, "mix veritas.bench: #{inspect(reason)}")
        2
    end
  end

  defp run_with_store(samples, store, options) do
    with {:ok, workspace} <- workspace(options),
         {:ok, _apps} <- start_apps(store),
         {:ok, _migrated} <- migrate(workspace),
         {:ok, shape} <- seed(workspace, options),
         {:ok, base_url} <- endpoint(options),
         {:ok, results} <- measure_all(samples, workspace, shape, base_url),
         {:ok, explain} <- Explain.check(workspace, sample_id: shape.root_id),
         {:ok, store_cost} <- store_cost(workspace),
         {:ok, run} <- assemble(options, workspace, shape, store, results, explain, store_cost),
         :ok <- persist(run, options) do
      Report.print(run)

      cleanup(workspace, store)

      if gated?(options) and Gate.failing?(run.findings), do: 1, else: 0
    else
      {:error, reason} ->
        IO.puts(:stderr, "mix veritas.bench: #{inspect(reason)}")
        2
    end
  end

  # ── the store ─────────────────────────────────────────────────────────────

  defp open_store(options) do
    case Keyword.get(options, :store_url) do
      nil ->
        case SurrealServer.start() do
          {:ok, server} ->
            {:ok, %{url: SurrealServer.url(server), server: server, owned: true}}

          {:error, :no_binary} ->
            {:error,
             "no SurrealDB binary was found (looked at $SURREAL_BIN and /tmp/sdb/surreal). " <>
               "The harness starts its own store; give it one with --store-url, or install the " <>
               "binary. The CI script .github/scripts/performance_gate.sh extracts one from the " <>
               "pinned image."}

          {:error, reason} ->
            {:error, {:cannot_start_store, reason}}
        end

      url ->
        {:ok, %{url: url, server: nil, owned: false}}
    end
  end

  # The Adapter is told where the store is before anything starts, so the
  # pool it opens points at the store the harness is measuring.
  defp start_apps(store) do
    # The settings are the Adapter's own, with the harness's store url
    # substituted for the configured one.
    options = Keyword.merge(Veritas.Store.Surreal.settings(), [url: store.url])

    Application.put_env(:veritas_core, :surreal, options)

    Application.put_env(
      :veritas_core,
      :store,
      adapter: Veritas.Store.Surreal,
      options: options
    )

    Application.put_env(:veritas_core, :environment, :test)
    Application.put_env(:veritas_core, :allow_default_credentials, true)

    # The harness owns this VM. If the application is already running — Mix
    # may have started it — it is stopped and started again, because the
    # store pool opens its connections when the application boots, and it
    # must open them against the store under test rather than against
    # whatever was configured when it first booted.
    stop_apps()

    case Application.ensure_all_started(:veritas_core) do
      {:ok, _apps} ->
        case Application.ensure_all_started(:veritas_web) do
          {:ok, _} -> {:ok, :started}
          {:error, reason} -> {:error, {:cannot_start_web, reason}}
        end

      {:error, reason} ->
        {:error, {:cannot_start_core, reason}}
    end
  end

  defp stop_apps do
    started = Enum.map(Application.started_applications(), &elem(&1, 0))

    for app <- [:veritas_web, :veritas_core], app in started do
      Application.stop(app)
    end

    :ok
  end

  defp migrate(workspace) do
    case Veritas.Store.Surreal.migrate(workspace) do
      :ok -> {:ok, :migrated}
      {:error, reason} -> {:error, {:migration_failed, reason}}
    end
  end

  defp workspace(options) do
    case Keyword.get(options, :workspace) do
      nil ->
        suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower) |> String.slice(0, 8)
        {:ok, "#{@default_workspace_prefix}_#{suffix}"}

      name ->
        {:ok, name}
    end
  end

  # ── the fixture ───────────────────────────────────────────────────────────

  defp seed(workspace, options) do
    name = if Keyword.get(options, :wide), do: "wide", else: "w3"

    case Fixture.build(workspace, Fixture.shape(name)) do
      {:ok, built} ->
        {:ok, built}

      {:error, reason} ->
        {:error, {:fixture_failed, reason}}
    end
  end

  # ── the endpoint ──────────────────────────────────────────────────────────

  defp endpoint(options) do
    if Keyword.get(options, :no_web) do
      {:ok, nil}
    else
      if Veritas.Core.Bench.Web.available?() do
        case Veritas.Core.Bench.Web.start_endpoint() do
          {:ok, url} -> {:ok, url}
          {:error, reason} -> {:error, {:cannot_start_endpoint, reason}}
        end
      else
        {:ok, nil}
      end
    end
  end

  # ── the scenarios ─────────────────────────────────────────────────────────

  defp measure_all(samples, workspace, shape, base_url) do
    context = %{workspace: workspace, root_id: shape.root_id, base_url: base_url}

    # `--no-web` means "do not measure the web surfaces". A scenario the
    # operator deliberately asked to skip is **not** a scenario that failed,
    # so it is not measured at all — it is left out of the results, and the
    # results are what the gate reads. Reporting it as an error would make
    # every `--no-web` run fail the gate for the sin of skipping, which is
    # the same shape of lie as a page that prints "0 relations" when it
    # could not ask.
    scenarios =
      Scenarios.all(context)
      |> Enum.reject(fn scenario ->
        base_url == nil and scenario.kind in [:web, :graphql]
      end)

    results =
      Enum.map(scenarios, fn scenario ->
        sample_count = samples || scenario.samples

        {value, round_trips} = Counters.measure(fn -> scenario.run.() end)

        stats =
          Stats.measure(fn -> scenario.run.() end, samples: sample_count, warmup: 1)

        %{
          scenario: scenario,
          stats: stats,
          round_trips: round_trips,
          nodes_visited: nodes_visited(value),
          errors: Enum.count(stats.values, &match?({:error, _}, &1)),
          error: error_of(value)
        }
      end)

    {:ok, results}
  end

  defp nodes_visited({:ok, %{nodes: nodes}}) when is_list(nodes), do: length(nodes)
  defp nodes_visited({:ok, %{dependents: dependents}}) when is_list(dependents), do: length(dependents)
  defp nodes_visited(_), do: nil

  defp error_of({:ok, _}), do: nil
  defp error_of({:error, reason}), do: reason

  # ── the cost of one request ───────────────────────────────────────────────

  defp store_cost(workspace) do
    statement = "SELECT * FROM ci LIMIT 1;"

    basic = Raw.request_latency_us(statement, workspace, auth: :basic, samples: 10)
    bearer = Raw.request_latency_us(statement, workspace, auth: :bearer, samples: 10)

    {:ok,
     %{
       request_us_basic: unwrap(basic),
       request_us_bearer: unwrap(bearer),
       error: error_of(basic) || error_of(bearer)
     }}
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(_), do: nil

  # ── the run, assembled ────────────────────────────────────────────────────

  defp assemble(options, workspace, shape, store, results, explain, store_cost) do
    baseline = load_baseline()

    findings =
      Gate.evaluate(results,
        baseline: baseline,
        # The ceiling is derived from what the **product** pays per request.
        # The Adapter authenticates once and presents a bearer token on every
        # request (see `Veritas.Store.Surreal.authorization/1`), so charging
        # the Basic cost here would price the round-trip ceiling against a
        # credential the product no longer sends — and would make every
        # request look 50x more expensive than it is.
        per_request_us: store_cost.request_us_bearer,
        node_budget: Gate.node_budget()
      )

    findings = findings ++ explain_findings(explain)

    findings =
      if Keyword.get(options, :check_deterministic) do
        Enum.filter(findings, &(&1.kind in [:explain, :round_trips, :node_cap]))
      else
        findings
      end

    dataset = %{
      workspace: workspace,
      depth: shape.depth,
      fan_out: shape.fan_out,
      fan_in: shape.fan_in,
      node_count: shape.node_count,
      edge_count: shape.edge_count,
      fingerprint: Gate.dataset_fingerprint(shape)
    }

    findings = findings ++ baseline_findings(baseline, dataset, options)

    {:ok,
     %{
       mode: mode(options),
       environment: environment(options),
       dataset: dataset,
       store: Map.merge(store_cost, %{url: store.url}),
       results: results,
       explain: explain,
       findings: findings,
       passing?: not Gate.failing?(findings)
     }}
  end

  defp mode(options) do
    cond do
      Keyword.get(options, :check) -> "check"
      Keyword.get(options, :check_deterministic) -> "check-deterministic"
      true -> "report"
    end
  end

  # Whether this run applies a gate.
  #
  # `OptionParser` gives a boolean switch the value `true` when it is
  # present and leaves the key **absent** when it is not. `Keyword.get/2`
  # therefore answers `nil` for "not asked for", and `nil or nil` is a
  # `BadBooleanError` in Elixir — `or` demands booleans. So the question
  # "is a gate applied?" is answered here, once, with an explicit
  # comparison that yields a boolean either way.
  defp gated?(options) do
    Keyword.get(options, :check) == true or Keyword.get(options, :check_deterministic) == true
  end

  defp environment(options) do
    if Keyword.get(options, :load_environment), do: "load-test", else: "smoke"
  end

  # docs/13: "A run with no matching baseline is a **no-baseline result, not
  # a pass**." So a missing baseline, or one recorded over a different
  # dataset, is a finding in a gated run.
  defp baseline_findings(nil, _dataset, options) do
    gated? = gated?(options)

    if gated? do
      [
        %{
          severity: :breach,
          kind: :baseline,
          scenario: nil,
          row: nil,
          label: "the committed baseline",
          measured_us: nil,
          target_us: nil,
          detail:
            "there is no committed baseline for this dataset, so this run is a " <>
              "no-baseline result and not a pass. Record one with --accept-baseline."
        }
      ]
    else
      []
    end
  end

  defp baseline_findings(baseline, dataset, options) do
    gated? = gated?(options)
    recorded = get_in(baseline, ["dataset", "fingerprint"])

    if gated? and recorded != dataset.fingerprint do
      [
        %{
          severity: :breach,
          kind: :baseline,
          scenario: nil,
          row: nil,
          label: "the committed baseline",
          measured_us: nil,
          target_us: nil,
          detail:
            "the committed baseline was recorded over a different dataset " <>
              "(#{inspect(recorded)} against #{inspect(dataset.fingerprint)}), so this run is a " <>
              "no-baseline result and not a pass."
        }
      ]
    else
      []
    end
  end

  defp explain_findings(explain) do
    Enum.flat_map(explain, fn result ->
      if result.verdict == :pass do
        []
      else
        [
          %{
            severity: :breach,
            kind: :explain,
            scenario: result.id,
            row: result.budget_ref,
            label: result.label,
            measured_us: nil,
            target_us: nil,
            detail: "EXPLAIN: #{result.reason}"
          }
        ]
      end
    end)
  end

  # ── the baseline ──────────────────────────────────────────────────────────

  @doc """
  The path of the committed baseline.

  It is the corpus's `bench/baseline/` slot, and it is keyed by the dataset
  fingerprint, so a baseline recorded over a different graph is not
  comparable and is treated as no baseline at all.
  """
  @spec baseline_path() :: String.t()
  def baseline_path do
    Path.join([repo_root(), "bench", "baseline", "baseline.json"])
  end

  @doc """
  The path of the JSON report.
  """
  @spec report_path() :: String.t()
  def report_path do
    Path.join([repo_root(), "bench", "last-run.json"])
  end

  @doc """
  The repository's root directory.
  """
  @spec repo_root() :: String.t()
  def repo_root do
    case env_root() do
      nil -> find_repo_root(Path.expand(__DIR__))
      root -> root
    end
  end

  defp env_root do
    case System.get_env("VERITAS_REPO_ROOT") do
      nil -> nil
      "" -> nil
      root -> Path.expand(root)
    end
  end

  defp find_repo_root(dir) do
    if File.exists?(Path.join(dir, "mix.exs")) and File.dir?(Path.join(dir, "apps")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        dir
      else
        find_repo_root(parent)
      end
    end
  end

  defp load_baseline do
    path = baseline_path()

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> nil
    end
  end

  defp persist(run, options) do
    json_path = Keyword.get(options, :json, report_path())
    File.mkdir_p!(Path.dirname(json_path))
    File.write!(json_path, Jason.encode!(Report.to_map(run), pretty: true))

    if Keyword.get(options, :accept_baseline) do
      write_baseline(run)
    end

    :ok
  end

  defp write_baseline(run) do
    breaches =
      run.findings
      |> Enum.filter(&(&1.severity in [:breach, :defect]))
      |> Enum.group_by(& &1.scenario, & &1.row)
      |> Map.new(fn {scenario, rows} -> {scenario, Enum.reject(rows, &is_nil/1)} end)

    scenarios =
      Map.new(run.results, fn result ->
        {result.scenario.id,
         %{
           "p50_us" => result.stats.p50,
           "p95_us" => result.stats.p95,
           "p99_us" => result.stats.p99,
           "words" => result.stats.words,
           "round_trips" => result.round_trips,
           "samples" => result.stats.samples
         }}
      end)

    baseline = %{
      "version" => 1,
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "environment" => run.environment,
      "dataset" => run.dataset,
      "store" => run.store,
      "scenarios" => scenarios,
      "breaches" => breaches
    }

    path = baseline_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(baseline, pretty: true))
  end

  # ── the cleanup ───────────────────────────────────────────────────────────

  defp cleanup(workspace, store) do
    credentials =
      Veritas.Store.Surreal.settings()
      |> Keyword.take([:user, :pass])

    Fixture.cleanup(workspace, url: store.url, credentials: credentials)

    stop_store(store)

    :ok
  end

  # The store the harness started is stopped. A store the owner named with
  # `--store-url` is theirs, and is left running.
  defp stop_store(store) do
    if store.owned do
      case store.server do
        nil -> :ok
        server -> SurrealServer.stop(server)
      end
    else
      :ok
    end
  end

  # ── the arguments ─────────────────────────────────────────────────────────

  defp parse(argv) do
    {options, _rest, invalid} = OptionParser.parse(argv, strict: [samples: :integer, check: :boolean, check_deterministic: :boolean, store_url: :string, workspace: :string, wide: :boolean, accept_baseline: :boolean, json: :string, load_environment: :boolean, no_web: :boolean, help: :boolean])

    cond do
      invalid != [] ->
        {:error, "unknown option(s): #{inspect(invalid)}"}

      options[:help] ->
        {:help, usage()}

      true ->
        {:ok, options}
    end
  end
end
