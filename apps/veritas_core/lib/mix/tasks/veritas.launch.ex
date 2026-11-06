defmodule Mix.Tasks.Veritas.Launch do
  @shortdoc "Starts a process that outlives the caller, and records it"

  @moduledoc """
  Starts a process that outlives the caller, and records it.

      mix veritas.launch bench mix veritas.bench --samples 5
      mix veritas.launch web mix phx.server

  The pid is written to `ops/processes.tsv` with the label and the moment it
  started. That registry is what makes the process **ours** for the reaper
  even when its working directory is somewhere else — and what lets a
  grace period leave a process that was just started alone.

  This is the Elixir the shell version used to be: the same contract, the same
  registry, and a platform adapter under it that knows how to detach a
  process on the host it is running on.
  """

  use Mix.Task

  alias Veritas.Dev.Process
  alias Veritas.Dev.Process.Reaper

  @switches %{"--log" => :log, "--registry" => :registry}

  @impl Mix.Task
  def run(argv) do
    {opts, rest} = split_switches(argv)

    case rest do
      [label | command] ->
        launch(label, command, opts)

      [] ->
        Mix.raise(
          "usage: mix veritas.launch [--log PATH] [--registry PATH] <label> <command> [args...]\n" <>
            "  example: mix veritas.launch bench mix veritas.bench --samples 5"
        )
    end
  end

  # The launcher's own switches come **before** the label; everything from the
  # label onwards is the command, passed through verbatim, with its own flags
  # untouched.
  #
  #   mix veritas.launch --log var/log/bench.log bench mix veritas.bench --samples 5
  #
  # `OptionParser` cannot do this on its own: given an unknown switch it
  # either refuses (`parse!`) or swallows the switch **and its value**
  # (`parse`), which would take the command's own flags with it. So the
  # launcher reads its own switches by hand and stops at the first argument
  # that is not one of them.
  defp split_switches(argv), do: take_switches(argv, [])

  defp take_switches([], taken), do: {Enum.reverse(taken), []}

  # `--log path` — the switch and its value.
  defp take_switches([arg, value | rest], taken) when is_map_key(@switches, arg) do
    take_switches(rest, [{@switches[arg], value} | taken])
  end

  # `--log=path` — the other spelling of the same switch. Anything else is
  # the start of the command, and it is passed on as it is.
  defp take_switches([arg | rest], taken) do
    case String.split(arg, "=", parts: 2) do
      [name, value] ->
        case @switches[name] do
          nil -> {Enum.reverse(taken), [arg | rest]}
          key -> take_switches(rest, [{key, value} | taken])
        end

      _ ->
        {Enum.reverse(taken), [arg | rest]}
    end
  end

  # The registry is the same file the reaper reads.
  defp registry_path, do: Path.join(Veritas.Dev.Process.project_root(), "ops/processes.tsv")

  defp launch(label, command, opts) do
    log = opts[:log] || Path.join(Veritas.Dev.Process.project_root(), "var/log/#{label}.log")
    File.mkdir_p!(Path.dirname(log))

    case Process.start(command, log: log) do
      {:ok, started} ->
        record(label, started, log, opts)

      {:error, reason} ->
        Mix.raise("the process could not be started: #{inspect(reason)}")
    end
  end

  # The registry is what makes the process ours for the reaper. A process
  # that is running but not registered is a process the reaper will not stop,
  # so a registry that could not be written is a failed launch: the process
  # is stopped again and the reason is said.
  defp record(label, started, log, opts) do
    case Reaper.record(
           label,
           started.pid,
           started_at(started.pid),
           opts[:registry] ||
             registry_path()
         ) do
      :ok ->
        Mix.shell().info("#{label} is running: pid #{started.pid}, log #{log}")

      {:error, reason} ->
        stopped = Process.stop(started.pid)

        Mix.raise(
          "the registry could not be written (#{inspect(reason)}), so the process was " <>
            "stopped again (#{inspect(stopped)}); it would have been left behind"
        )
    end
  end

  # The moment the process started, so the reaper can tell it from whatever
  # later holds its pid. A pid is reused; a start time is not.
  defp started_at(pid) do
    case Process.started_at(pid) do
      {:ok, started_at} -> started_at
      {:error, _reason} -> nil
    end
  end
end
