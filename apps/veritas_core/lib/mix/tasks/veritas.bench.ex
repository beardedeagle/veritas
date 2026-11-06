defmodule Mix.Tasks.Veritas.Bench do
  @shortdoc "Runs the performance benchmark and the gate"

  @moduledoc """
  Runs the performance benchmark against the budget in `docs/13`.

      mix veritas.bench                  # report only
      mix veritas.bench --check          # report, and fail the build on a finding
      mix veritas.bench --help           # every option

  ## Where the harness lives

  The harness is in `bench/harness/`, at the repository root, where
  `docs/13` §Performance Engineering Process puts the benchmark tree.

  It is **loaded at runtime**, not compiled into the application. That is
  the point: `mix test` compiles the product and the product's tests, and
  nothing else. A defect in the benchmark instrument must never be able to
  break the product's own test suite — which is what happens when the
  instrument lives in `test/support/`, where the test environment compiles
  it as part of the application.

  So the modules are not in the application's compiled path at all. They are
  read and compiled by this task, in dependency order, when the task runs.

  ## Where it runs

  The harness uses `Veritas.Core.Test.SurrealServer` to start a store of
  its own, and that helper is compiled in the test environment only. So the
  task re-runs itself under `MIX_ENV=test` when it is not already there: a
  person can type `mix veritas.bench` and get a benchmark, and a pipeline
  can type `MIX_ENV=test mix veritas.bench` and skip the hop.

  ## The store

  By default the harness starts its **own** SurrealDB — its own port, its own
  data directory — and removes it afterwards. It never falls back to the
  configured default store, because on a developer machine that default is
  usually somebody's *empty* store, and a benchmark against an empty store
  measures nothing while looking like it worked.
  """

  use Mix.Task

  # The order the harness is loaded in. A file that calls a module defined
  # in a later file would be compiled against a module that is not loaded
  # yet, and the compiler would say so.
  @load_order [
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

  @impl Mix.Task
  def run(argv) do
    if Mix.env() == :test do
      System.halt(run_harness(argv))
    else
      reexec(argv)
    end
  end

  defp run_harness(argv) do
    harness_dir = Path.join([repo_root(), "bench", "harness"])

    if File.dir?(harness_dir) do
      case load_harness(harness_dir) do
        :ok ->
          cli = Module.concat(["Elixir.Veritas.Core.Bench.CLI"])
          cli.main(argv)

        {:error, reason} ->
          Mix.shell().error("the benchmark harness did not load: #{inspect(reason)}")
          2
      end
    else
      Mix.shell().error("the benchmark harness is not at #{harness_dir}")
      2
    end
  end

  defp load_harness(dir) do
    known = Enum.map(@load_order, &Path.join(dir, &1))
    rest = dir |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort() |> Kernel.--(known)

    if rest != [] do
      Mix.shell().info(
        "note: #{Path.basename(hd(rest))} and #{length(rest) - 1} other file(s) are not in the " <>
          "load order of mix veritas.bench; add them to it so they load after what they use."
      )
    end

    # A build that once compiled the harness into the application still has
    # its beams on the code path. They are unloaded first, so the copy this
    # task loads is the copy that runs.
    purge_loaded_harness()

    Enum.reduce_while(known ++ rest, :ok, fn file, :ok ->
      case Code.require_file(file) do
        {:module, _module} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {file, reason}}}

        _other ->
          {:cont, :ok}
      end
    end)
  end

  defp purge_loaded_harness do
    for {module, _file} <- :code.all_loaded(),
        to_string(module) |> String.starts_with?("Elixir.Veritas.Core.Bench.") do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end

  @doc """
  The repository's root, found by walking up from this task.
  """
  @spec repo_root() :: String.t()
  def repo_root do
    find_root(Path.expand(__DIR__))
  end

  defp find_root(dir) do
    if File.exists?(Path.join(dir, "mix.exs")) and File.dir?(Path.join(dir, "apps")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        dir
      else
        find_root(parent)
      end
    end
  end

  defp reexec(argv) do
    Mix.shell().info("mix veritas.bench measures the test build; re-running with MIX_ENV=test.")

    {status, _output} =
      System.cmd("mix", ["veritas.bench" | argv],
        env: [{"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    System.halt(status)
  end
end
