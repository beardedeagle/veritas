defmodule Veritas.Dev.Process.Reaper do
  @moduledoc """
  The process policy: what may be stopped, and what may never be.

  Three rules, and they are the same on every platform because they are
  written here, once, over the facts the port gives
  (`docs/12` §Process Hygiene):

    * **(a) A process is ours** when one of its *attachments* is under the
      project root, or when its pid is recorded in the registry
      (`ops/processes.tsv`). The command name alone never makes a process
      ours: a developer has other BEAM projects on their machine, and a
      name-only rule would stop all of them.

    * **(b) A process serving a kept port is never stopped** — and the keep
      decision resolves to **process ids first**. A BEAM node holds two
      listening sockets: its own port and the Erlang distribution port on a
      random high port. Deciding per socket and acting per process stops the
      very application the keep-list was protecting.

    * **(c) Only `beam.smp` and `surreal` are ever candidates.** The kind
      of process is what makes it a Veritas process at all; the working
      directory is what makes it ours.

  ## The policy is pure decision-making

  `plan/2` answers "what would happen" and `reap/2` does it. The decisions
  are made over a **port**, so a fake adapter proves them without a host,
  and the tests run unchanged on Windows and Linux.
  """

  alias Veritas.Dev.Process

  @typedoc """
  A process the policy has decided about.

  `:stop` and `:keep` are what the **plan** says; `:stopped` and `:failed`
  are what the **reap** reports, and a failure is reported rather than
  counted away.
  """
  @type decision :: %{
          pid: pos_integer(),
          port: pos_integer() | nil,
          executable: String.t(),
          action: :stop | :keep | :stopped | :failed,
          reason: String.t()
        }

  @typedoc """
  The registry of launched processes: the pid, the label, the moment it was
  recorded, and the moment the process started (`nil` for an entry from
  before the start time was recorded).
  """
  @type registry :: %{pos_integer() => {String.t(), integer(), integer() | nil}}

  @default_keep [4000, 8010]
  @candidates ["beam.smp", "surreal"]
  @keep_ports_var "VERITAS_KEEP_PORTS"
  @store_port_var "VERITAS_SURREAL_PORT"

  @doc """
  What the policy would do, without doing it.

  ## Options

    * `:keep` — the ports never stopped. Defaults to `#{inspect(@default_keep)}`.
    * `:grace` — seconds within which a **registered** process is left alone,
      so a reaper that runs every five minutes does not take down something
      that was started two minutes ago.
    * `:registry` — the recorded pids, as `%{pid => {label, started_at}}`.
    * `:root` — the project root; an attachment under it is what makes a
      process ours.
  """
  @spec plan(keyword()) :: {:ok, [decision()]} | {:error, term()}
  def plan(opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Process.adapter()
    grace = Keyword.get(opts, :grace, 0)
    registry = Keyword.get(opts, :registry) || read_registry(opts[:registry_path])
    root = Keyword.get(opts, :root) || File.cwd!()

    with {:ok, listeners} <- adapter.listeners() do
      keep = keep_list(opts) ++ recorded_store_port(listeners, opts)
      keep_pids = keep_pids(listeners, keep)
      me = self_pid()

      decisions =
        listeners
        |> Enum.map(&decide(&1, adapter, keep_pids, grace, registry, root, me))
        |> Enum.reject(&is_nil/1)
        # One decision per **process**: a BEAM node holds two listening
        # sockets, and the plan is about processes.
        |> Enum.uniq_by(& &1.pid)

      # A registered pid is a candidate even when it holds **no listening
      # socket**: the registry is what covers the processes the attachment
      # scan cannot see — a bench, a worker, anything that is not a server.
      # A pid that is not running describes as nothing and is not a candidate.
      seen = MapSet.new(decisions, & &1.pid)

      registered =
        registry
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(seen, &1))
        |> Enum.flat_map(&decide_registered(&1, adapter, keep_pids, grace, registry, root, me))

      {:ok, decisions ++ registered}
    end
  end

  @doc """
  Does what `plan/2` says, and reports what it did.
  """
  @spec reap(keyword()) :: {:ok, [decision()]} | {:error, term()}
  def reap(opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Process.adapter()

    case plan(opts) do
      {:ok, decisions} ->
        stopped =
          Enum.map(decisions, fn decision ->
            case decision.action do
              :stop ->
                case adapter.stop(decision.pid) do
                  :ok -> %{decision | action: :stopped}
                  {:error, reason} -> %{decision | action: :failed, reason: inspect(reason)}
                end

              _ ->
                decision
            end
          end)

        {:ok, stopped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The ports kept when the operator has named none.

  These are the product's own ports: the **web** port, and the port the
  project's own runbook tells an operator to start a store on by hand.

  The **managed** store's port is not in this list, because it is not a fixed
  port: the store takes a free port unless the operator pins it with
  `VERITAS_SURREAL_PORT`, and the port it did take is recorded in a receipt
  the reaper reads. `plan/2` adds that port when the receipt still describes
  the process holding it.
  """
  @spec default_keep() :: [pos_integer()]
  def default_keep, do: @default_keep

  @doc """
  The ports that are never stopped: the product's own, **plus** the
  operator's.

  The operator's list is **added to** the product's own ports and never
  replaces them. An operator who names one extra port must not lose the
  product's own by naming it: the operator's list says what **else** to keep,
  and the product's own ports are kept whether or not the operator restates
  them.

  Read from three places, and all three are kept:

    1. `:keep` — the command line's `--keep=4050`;
    2. `VERITAS_KEEP_PORTS` in the environment — which is how a scheduler
       states it, because a scheduler has no command line to edit and a unit
       file is read far less often than a switch;
    3. `VERITAS_SURREAL_PORT` — the port the operator pinned for the managed
       store. The store reads the same variable, so a pinned store is kept by
       the reaper; the operator must set it for the reaper as well.

  The product's own ports are always in the list, and the managed store's
  actual port is added by `plan/2`, which is where the receipt and the
  process table are both read.

  ## Options

    * `:keep` — the operator's list, as a comma-separated string.
  """
  @spec keep_ports(keyword()) :: [pos_integer()]
  def keep_ports(opts \\ []) do
    Enum.uniq(@default_keep ++ operator_ports(opts) ++ pinned_store_port())
  end

  # The operator's own list, from the command line or from the environment.
  defp operator_ports(opts) do
    case opts[:keep] || System.get_env(@keep_ports_var) do
      nil ->
        []

      list ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.to_integer/1)
    end
  end

  # The port the operator pinned for the managed store — the same variable
  # the store itself reads, so the reaper and the store cannot disagree about
  # it. An operator who pins the port for the store must set it for the
  # reaper too; the task's help says so.
  defp pinned_store_port do
    case System.get_env(@store_port_var) do
      nil -> []
      "" -> []
      value -> [String.to_integer(String.trim(value))]
    end
  end

  # The keep list the plan uses. A caller that has already resolved the
  # operator's list — the task does, through `keep_ports/1` — passes it in; a
  # caller that has not gets the same additive list.
  defp keep_list(opts) do
    case opts[:keep] do
      ports when is_list(ports) -> ports
      _other -> keep_ports(opts)
    end
  end

  # The managed store's **actual** port, when the receipt says so and the
  # store that wrote the receipt is still the process holding that port.
  #
  # The receipt is what makes the product's own live store keepable: the
  # store takes a free port, so no fixed list can name it. It is honoured
  # only while the process that wrote it still holds that port — a receipt
  # left behind by a store that has since gone is **stale**, and the port it
  # names is not kept, so whatever holds it now can be stopped.
  defp recorded_store_port(listeners, opts) do
    case read_receipt(opts) do
      %{"port" => port, "pid" => pid} when is_integer(port) and is_integer(pid) ->
        if Enum.any?(listeners, &(&1.port == port and &1.pid == pid)), do: [port], else: []

      _other ->
        []
    end
  end

  defp read_receipt(opts) do
    opts
    |> receipt_paths()
    |> Enum.find_value(%{}, fn path ->
      with {:ok, contents} <- File.read(path),
           {:ok, receipt} <- Jason.decode(contents) do
        receipt
      else
        _other -> nil
      end
    end)
  end

  # Where the receipt may be. The store writes it beside its own pid file, in
  # the data directory the operator gave it — the same directory the store
  # computes from the same environment the reaper reads.
  defp receipt_paths(opts) do
    case opts[:receipt] do
      nil -> [Veritas.Store.Surreal.Server.receipt_path()]
      path -> [path]
    end
  end

  @doc """
  The pid of the process running this policy.

  `System.pid/0` returns a **string** — and `:os.getpid/0` a charlist — while
  the adapter's pids are integers. The two are compared as integers, or not
  at all: a policy that could not recognise itself would stop the very
  process it is running in.
  """
  @spec self_pid() :: pos_integer()
  def self_pid do
    System.pid()
    |> to_string()
    |> String.to_integer()
  end

  @doc """
  The pids that serve a kept port.

  Resolved to **process ids first**: a BEAM node holds its own port *and*
  the Erlang distribution port, and a per-socket decision would stop the
  application the keep-list was protecting.
  """
  @spec keep_pids([Process.listener()], [pos_integer()]) :: MapSet.t()
  def keep_pids(listeners, keep) do
    Enum.reduce(listeners, MapSet.new(), fn listener, acc ->
      if listener.port in keep, do: MapSet.put(acc, listener.pid), else: acc
    end)
  end

  @doc """
  The registry of launched processes, read from `ops/processes.tsv`.

  Each line is `pid`, `label`, the moment it was recorded, and the moment the
  process **started** — the last is what tells a registered process apart
  from whatever now holds its pid. A line without it is an entry from before
  the start time was recorded, and the pid in it is trusted as it was.
  """
  @spec read_registry(String.t() | nil) :: registry()
  def read_registry(path \\ nil) do
    path = path || Path.join(File.cwd!(), "ops/processes.tsv")

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "\t") do
            [pid, label, recorded] ->
              [{String.to_integer(pid), {label, String.to_integer(recorded), nil}}]

            [pid, label, recorded, started] ->
              [
                {String.to_integer(pid),
                 {label, String.to_integer(recorded), parse_started(started)}}
              ]

            _ ->
              []
          end
        end)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp parse_started(""), do: nil
  defp parse_started("-"), do: nil
  defp parse_started(value), do: String.to_integer(value)

  @doc """
  Records a launched process in the registry.

  The write is **reported**: a registry that did not take the line is a
  registry that does not know the process, and an unregistered process is one
  the reaper will not stop.

  The process's **start time** is recorded with it, so that the reaper can
  tell this process from whatever later holds its pid.
  """
  @spec record(String.t(), pos_integer(), integer() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def record(label, pid, started_at \\ nil, path \\ nil) do
    path = path || Path.join(File.cwd!(), "ops/processes.tsv")
    File.mkdir_p!(Path.dirname(path))
    started = if started_at, do: Integer.to_string(started_at), else: "-"
    line = "#{pid}\t#{label}\t#{System.system_time(:second)}\t#{started}\n"

    case File.write(path, line, [:append]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The three rules, applied to one listener.
  defp decide(listener, adapter, keep_pids, grace, registry, root, me) do
    {executable, attachments} = facts(listener, adapter)
    executable = Path.basename(executable || "")

    decision = fn action, reason ->
      %{
        pid: listener.pid,
        port: listener.port,
        executable: executable,
        action: action,
        reason: reason
      }
    end

    cond do
      # The reaper never stops the process it is running in. It is a BEAM
      # attached to this repository, so without this rule it would stop
      # itself the first time it was run with `--go`.
      listener.pid == me ->
        decision.(:keep, "it is the reaper itself")

      # (b) a kept port is never stopped
      MapSet.member?(keep_pids, listener.pid) ->
        decision.(:keep, "it serves a kept port")

      # (c) only these two kinds are ever candidates
      executable not in @candidates ->
        nil

      # (a) ours, by attachment or by the registry
      not ours?(listener, attachments, registry, root, adapter) ->
        nil

      # the grace period: a registered process that was just started
      too_young?(listener.pid, grace, registry) ->
        decision.(:keep, "it was registered less than #{grace} seconds ago")

      true ->
        decision.(:stop, "it is a Veritas process and it serves no kept port")
    end
  end

  # A registered pid that holds no listening socket. The decision is the same
  # decision: the same three rules, over the same facts.
  defp decide_registered(pid, adapter, keep_pids, grace, registry, root, me) do
    listener = %{pid: pid, port: nil, executable: "", attachments: []}

    case decide(listener, adapter, keep_pids, grace, registry, root, me) do
      nil -> []
      decision -> [decision]
    end
  end

  defp ours?(listener, attachments, registry, root, adapter) do
    registered?(listener.pid, registry, adapter) or attached?(attachments, root)
  end

  # A pid is reused; a process's **start time** is not. So a registered pid is
  # ours only while the process holding it is still the one that was
  # registered — otherwise the reaper would stop an unrelated process that
  # happens to have the same number.
  #
  # An entry from before the start time was recorded is trusted, because the
  # corpus says a registered pid is ours, and an entry that cannot be checked
  # is not a reason to stop something.
  defp registered?(pid, registry, adapter) do
    case Map.get(registry, pid) do
      nil ->
        false

      {_label, _recorded_at, nil} ->
        true

      {_label, _recorded_at, recorded_started_at} ->
        case adapter.started_at(pid) do
          {:ok, started_at} -> same_moment?(started_at, recorded_started_at)
          {:error, _reason} -> true
        end
    end
  end

  # The reading has a second of resolution, so two moments are the same when
  # they are within a couple of seconds of each other.
  defp same_moment?(a, b), do: abs(a - b) <= 2

  # What the port says about a process: its executable and its attachments.
  # The listener row carries neither, so the process is described.
  defp facts(listener, adapter) do
    case adapter.describe(listener.pid) do
      {:ok, description} ->
        {description.executable, description.attachments}

      {:error, _reason} ->
        {listener.executable, listener.attachments}
    end
  end

  # The one question the portability rests on: is any attachment under the
  # project root?
  #
  # The attachments are the ones already gathered for the executable, so the
  # process is described once and asked once.
  defp attached?(attachments, root) do
    Enum.any?(attachments, fn path ->
      case path do
        path when is_binary(path) -> under?(path, root)
        _ -> false
      end
    end)
  end

  defp under?(path, root) do
    absolute = Path.expand(path)
    root = Path.expand(root)

    absolute == root or String.starts_with?(absolute, root <> "/")
  end

  defp too_young?(pid, grace, registry) when grace > 0 do
    case Map.get(registry, pid) do
      {_label, started, _started_at} -> System.system_time(:second) - started < grace
      _ -> false
    end
  end

  defp too_young?(_pid, _grace, _registry), do: false
end
