defmodule Veritas.Dev.Process do
  @moduledoc """
  The operations the process policy needs, and the port they come through.

  A process policy that only runs on the machine that wrote it is not a
  policy. The rules — what is ours, what is never stopped, what is ever a
  candidate — are **one set of rules in Elixir**, and only the gathering of
  facts differs between operating systems. That is what this port is: the
  facts, and the port that answers them.

  ## The abstraction: attachments

  Every platform can answer the same question about a process — *which paths
  is this process attached to?* — and the answer is what makes the rule
  portable:

    * on Unix the attachments are the working directory and the files the
      process has open under the project root;
    * on Windows they are the executable's path and the path-shaped tokens in
      the command line.

  The policy then asks exactly one question of those attachments: **is any
  of them under the project root?** The rule is written once. There is no
  second rule per platform, and there must not be one.

  ## What the port does not do

  It does not decide. It does not know what the project root is, what a
  kept port is, or what the candidate list is. Those are the policy's
  (`Veritas.Dev.Process.Reaper`). It only reports what it sees.

  ## The adapter is substitutable

  The platform adapter is selected at run time
  (`config :veritas_core, :process_adapter, ...`), so a test can put a fake
  in its place and the policy's decisions can be proved without a host —
  which is how the tests run unchanged on Windows and Linux.
  """

  @typedoc "A process holding a listening TCP socket."
  @type listener :: %{
          pid: pos_integer(),
          port: pos_integer(),
          executable: String.t(),
          attachments: [String.t()]
        }

  @typedoc "What is known about a process."
  @type description :: %{
          pid: pos_integer(),
          executable: String.t(),
          attachments: [String.t()]
        }

  @typedoc "A process the launcher started."
  @type started :: %{pid: pos_integer(), log: String.t()}

  @doc """
  Every process holding a listening TCP socket, with the port it holds.
  """
  @callback listeners() :: {:ok, [listener()]} | {:error, term()}

  @doc """
  What is known about a process: its executable and the paths it is attached
  to.
  """
  @callback describe(pid :: pos_integer()) :: {:ok, description()} | {:error, term()}

  @doc """
  Whether the process is alive.
  """
  @callback alive?(pid :: pos_integer()) :: boolean()

  @doc """
  Asks the process to stop.
  """
  @callback stop(pid :: pos_integer()) :: :ok | {:error, term()}

  @doc """
  When the process started, as a Unix timestamp in seconds.

  **A pid is reused; a process's start time is not.** This is what tells a
  registered process apart from whatever now holds its pid, and it is the
  difference between a reaper that stops the process you started and one that
  stops an unrelated process that happens to have the same number.
  """
  @callback started_at(pid :: pos_integer()) :: {:ok, integer()} | {:error, term()}

  @doc """
  Starts a process that outlives the caller, and returns its pid and the
  log it writes to.
  """
  @callback start(command :: [String.t()], opts :: keyword()) ::
              {:ok, started()} | {:error, term()}

  # ── the façade ─────────────────────────────────────────────────────────────

  @doc """
  The adapter in force: the platform's, unless one was configured.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:veritas_core, :process_adapter) || default_adapter()
  end

  @doc """
  The project root: the directory that holds `ops/` and the umbrella's
  `mix.exs`.

  It is found by walking up, so the answer does not depend on which
  directory the task was run from.
  """
  @spec project_root() :: String.t()
  def project_root do
    dir = File.cwd!()

    case find_ancestor(dir, fn candidate ->
           File.dir?(Path.join(candidate, "ops")) and
             File.exists?(Path.join(candidate, "mix.exs"))
         end) do
      nil -> dir
      root -> root
    end
  end

  defp find_ancestor(dir, predicate) do
    if predicate.(dir) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir, do: nil, else: find_ancestor(parent, predicate)
    end
  end

  @doc """
  Every process holding a listening TCP socket, with the port it holds.
  """
  @spec listeners() :: {:ok, [listener()]} | {:error, term()}
  def listeners, do: adapter().listeners()

  @doc """
  What is known about a process.
  """
  @spec describe(pos_integer()) :: {:ok, description()} | {:error, term()}
  def describe(pid), do: adapter().describe(pid)

  @doc """
  Whether the process is alive.
  """
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid), do: adapter().alive?(pid)

  @doc """
  Asks the process to stop.
  """
  @spec stop(pos_integer()) :: :ok | {:error, term()}
  def stop(pid), do: adapter().stop(pid)

  @doc """
  When the process started, as a Unix timestamp in seconds.
  """
  @spec started_at(pos_integer()) :: {:ok, integer()} | {:error, term()}
  def started_at(pid), do: adapter().started_at(pid)

  @doc """
  Starts a process that outlives the caller.
  """
  @spec start([String.t()], keyword()) :: {:ok, started()} | {:error, term()}
  def start(command, opts \\ []), do: adapter().start(command, opts)

  defp default_adapter do
    case :os.type() do
      {:win32, _} -> Veritas.Dev.Process.Windows
      _ -> Veritas.Dev.Process.Unix
    end
  end
end
