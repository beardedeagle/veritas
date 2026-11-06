defmodule Mix.Tasks.Veritas.Reap do
  @shortdoc "Stops the Veritas processes this machine has accumulated"

  @moduledoc """
  Stops the Veritas processes this machine has accumulated.

  The policy is `Veritas.Dev.Process.Reaper` — one implementation, identical
  on every platform, over the facts the platform adapter gathers. This task
  is the surface: it gathers, it reports, and it stops what the policy
  decided.

      mix veritas.reap                     # a dry run: the plan, nothing stopped
      mix veritas.reap --go                # stop what the plan says
      mix veritas.reap --keep=4050         # keep 4050 **as well as** the product's own
      mix veritas.reap --grace=300         # leave a registered process alone for 5 minutes
      mix veritas.reap --json              # the plan as JSON, for a scheduler

  A **dry run is the default**: a policy that stops processes should be
  asked what it would do before it is asked to do it.

  The processes it will consider are `beam.smp` and `surreal` whose
  **attachments** are under the project root, or whose pid is recorded in
  `ops/processes.tsv`. A process serving a kept port is never stopped.

  ## The kept ports

  The ports that are never stopped are the product's own **and** the
  operator's. The operator's list is **added to** the product's own, never
  replaces it: naming a port says what **else** to keep, and the product's
  own ports are kept whether or not the operator restates them.

    1. `--keep=4050` on the command line;
    2. `VERITAS_KEEP_PORTS=4050` in the environment — which is how a
       scheduler states it, because a scheduler has no command line to
       edit;
    3. `VERITAS_SURREAL_PORT=8010` — the port the operator pinned for the
       managed store. The store reads the same variable, so a pinned store
       is kept by the reaper; **set it for the reaper as well**.

  The product's own ports are the web port and the port the project's
  runbook tells an operator to start a store on by hand. The **managed**
  store takes a *free* port unless it is pinned, so no fixed list can name
  it: the store records the port it took in a receipt beside its own pid
  file, and the reaper keeps that port while the process that wrote the
  receipt still holds it. A receipt left behind by a store that has since
  gone is stale, and its port is not kept.
  """

  use Mix.Task

  alias Veritas.Dev.Process.Reaper

  @switches [go: :boolean, keep: :string, grace: :integer, json: :boolean, root: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    plan_opts = [
      keep: keep(opts),
      grace: opts[:grace] || 0,
      root: opts[:root] || Veritas.Dev.Process.project_root()
    ]

    # The process table is read **once**. A dry run reads it and prints the
    # plan; `--go` reads it and acts on that same reading. Reading it twice
    # would let the table change between the two, and the reaper could stop
    # something the plan never named.
    if opts[:go] do
      do_reap(plan_opts)
    else
      case Reaper.plan(plan_opts) do
        {:ok, decisions} ->
          report(decisions, opts)

        {:error, reason} ->
          Mix.raise("the process policy could not read the process table: #{inspect(reason)}")
      end
    end
  end

  # The ports that are never stopped.
  #
  # The list is the **operator's**, and `Veritas.Dev.Process.Reaper.keep_ports/1`
  # reads it: the command line first, then `VERITAS_KEEP_PORTS`, then the
  # product's own ports.
  defp keep(opts) do
    Reaper.keep_ports(keep: opts[:keep])
  end

  defp do_reap(plan_opts) do
    case Reaper.reap(plan_opts) do
      {:ok, stopped} ->
        for decision <- stopped, decision.action == :stopped do
          Mix.shell().info("stopped #{decision.executable} pid #{decision.pid}")
        end

        # A process that could not be stopped is **reported**, not counted
        # away. A summary that says "stopped 1" and says nothing about the
        # thirteen it did not stop is a green run hiding a failure.
        for decision <- stopped, decision.action == :failed do
          Mix.shell().info(
            "could not stop #{decision.executable} pid #{decision.pid}: #{decision.reason}"
          )
        end

        stopped_count = Enum.count(stopped, &(&1.action == :stopped))
        kept = Enum.count(stopped, &(&1.action == :keep))
        failed = Enum.count(stopped, &(&1.action == :failed))

        Mix.shell().info("stopped #{stopped_count}, kept #{kept}, could not stop #{failed}")

        if failed > 0 do
          Mix.raise("#{failed} process(es) could not be stopped; the reasons are above")
        end

      {:error, reason} ->
        Mix.raise(
          "the policy could not read the process table or stop a process: #{inspect(reason)}"
        )
    end
  end

  defp report(decisions, opts) do
    if opts[:json] do
      Mix.shell().info(Jason.encode!(%{decisions: decisions}, pretty: true))
    else
      for decision <- decisions do
        Mix.shell().info(
          "#{decision.action}  #{decision.executable}  pid #{decision.pid}  — #{decision.reason}"
        )
      end

      Mix.shell().info("would stop #{Enum.count(decisions, &(&1.action == :stop))}")
    end
  end
end
