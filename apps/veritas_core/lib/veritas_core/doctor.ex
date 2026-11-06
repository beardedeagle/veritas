defmodule Veritas.Core.Doctor do
  @moduledoc """
  The diagnostic surface: what the system is, and whether it is healthy.

  The `veritas doctor` command is an operator's first stop, so it answers
  four questions in one pass:

    * **the datastore** — which Adapter is installed, what it declares it can
      do, and whether it answers;
    * **the schema** — which version the Adapter expects, and whether the
      Workspace is at it;
    * **the Audit Log** — whether the chain still verifies;
    * **the cluster** — the local Node (BEAM), the peers it can see, and the
      topology class the deployment is actually running.

  A fault is named, not merely counted. The output says what is wrong and
  what to do about it, because a diagnostic that only says "unhealthy" sends
  the operator back to the logs.

  The report is plain data, so the CLI can print it or emit it as JSON
  without a second implementation.

  **The doctor never raises.** A datastore that is down is a *finding*, not a
  crash: the operator needs the other three answers even when the store is
  unreachable, and a diagnostic that dies with the thing it diagnoses is
  useless exactly when it is needed.
  """

  alias Veritas.Core.Audit
  alias Veritas.Core.Policy
  alias Veritas.Core.WorkspaceLock
  alias Veritas.Store
  alias Veritas.Store.Error

  @doc """
  Builds the report for a Workspace.

  Returns a map with a `:healthy` boolean.
  """
  @spec report(Store.workspace()) :: map()
  def report(workspace \\ "default") do
    datastore = datastore(workspace)
    schema = schema(workspace)
    audit = audit(workspace)
    cluster = cluster()
    deployment = deployment(workspace)

    healthy =
      datastore[:reachable] and schema[:migrated] and audit[:intact] == true and
        (cluster[:distribution] == :alive or datastore[:engine][:clustered] != true)

    %{
      healthy: healthy,
      workspace: workspace,
      deployment: deployment,
      datastore: datastore,
      schema: schema,
      audit: audit,
      cluster: cluster,
      orphan: orphan()
    }
  end

  @doc """
  Formats a report for a human.

  The layout is the one the operations documentation uses: a table of checks,
  then the remedy for each fault.
  """
  @spec format(map()) :: String.t()
  def format(report) do
    datastore = report.datastore
    schema = report.schema
    audit = report.audit
    cluster = report.cluster

    """
    Veritas doctor — workspace #{report.workspace} — node #{cluster.node} — #{timestamp()}

    CHECK                 STATUS   DETAIL
    --------------------------------------------------------------------------------------
    Deployment profile     INFO     #{report.deployment[:profile]} (#{profile_detail(report.deployment)})
    Datastore adapter     INFO     #{datastore[:adapter]} (#{datastore[:contract_version]})
    Datastore reachable   #{status(datastore[:reachable])}     #{datastore[:detail]}
    Capabilities          INFO     #{Enum.join(datastore[:capabilities] || [], ", ")}
    Schema version        #{status(schema[:migrated])}     expected #{schema[:expected]}, workspace is at #{schema[:actual]}
    Audit Log chain       #{status(audit[:intact] == true)}     #{audit[:detail]}
    Distribution          #{distribution_status(cluster, datastore)}     #{cluster[:detail]}
    Orphaned store        #{status(report.orphan[:orphaned] == false)}     #{report.orphan[:detail]}

    #{verdict(report)}

    #{remedies(report)}
    """
  end

  # A profile that changed what a role may do is a deployment fact, and it is
  # recorded in the Audit Log. The detail says whether it was: an operator
  # reading this knows whether the Log holds the profile they are running.
  defp profile_detail(deployment) do
    if deployment[:recorded] do
      "recorded in the Audit Log"
    else
      "not recorded — the Audit Log could not be written"
    end
  end

  # A store running against this node's data directory when the node is not
  # running it is an **orphan**: nothing will stop it, and it holds a port,
  # the data directory and its memory. It is invisible in the node's own
  # logs, which is why the operator has to be told.
  defp orphan do
    dir = Veritas.Store.Surreal.Server.data_dir()
    pidfile = Path.join(Path.dirname(dir), "veritas.store.pid")

    case store_port(pidfile) do
      nil ->
        %{orphaned: false, detail: "no store is running against #{dir}"}

      port ->
        if listening?(port) do
          if node_running?() do
            %{
              orphaned: false,
              detail: "the node's own store is running on port #{port}"
            }
          else
            %{
              orphaned: true,
              detail: "a store is running on port #{port} against #{dir}, and no node owns it"
            }
          end
        else
          %{orphaned: false, detail: "no store is running against #{dir}"}
        end
    end
  end

  defp store_port(pidfile) do
    case File.read(pidfile) do
      {:ok, contents} ->
        case contents |> String.trim() |> String.split(" ") |> Enum.at(1) |> Integer.parse() do
          {port, _rest} -> port
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, {:active, false}], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  # Is the node that owns this data directory running? The web surface is
  # where a node is.
  defp node_running? do
    case Application.get_env(:veritas_web, Veritas.Web.Endpoint) do
      %{http: [%{port: port}]} -> listening?(port)
      _other -> false
    end
  end

  # ── the checks ────────────────────────────────────────────────────────────

  defp datastore(workspace) do
    adapter = Store.adapter()

    base = %{
      adapter: inspect(adapter),
      contract_version: Store.contract_version(),
      capabilities: [],
      engine: %{},
      reachable: false,
      detail: "the adapter could not be reached"
    }

    described = safe(fn -> adapter.describe() end)

    case described do
      {:error, _reason} ->
        base

      {:ok, description} ->
        capabilities = Map.get(description, :capabilities, [])
        engine = Map.get(description, :engine, %{})

        case probe(adapter, workspace) do
          :ok ->
            %{
              base
              | reachable: true,
                capabilities: capabilities,
                engine: engine,
                detail: "answering on #{engine[:url] || "the configured endpoint"}"
            }

          {:error, reason} ->
            %{
              base
              | capabilities: capabilities,
                engine: engine,
                detail: Error.message(reason) || inspect(reason)
            }
        end
    end
  end

  # A read is the cheapest honest liveness probe: it exercises the connection,
  # the credentials and the Workspace scope at once.
  defp probe(adapter, workspace) do
    case adapter.transaction(workspace, fn tx ->
           Store.list(tx, :workspace, %{where: [], limit: 1})
         end) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Error.new(:unavailable, Exception.message(error))}
  end

  defp schema(workspace) do
    adapter = Store.adapter()

    expected =
      if function_exported?(adapter, :migration_version, 0),
        do: adapter.migration_version(),
        else: "unknown"

    base = %{
      expected: expected,
      actual: "unknown",
      migrated: false,
      detail: "the schema could not be read"
    }

    case probe(adapter, workspace) do
      :ok ->
        actual = actual_version(adapter, workspace)

        detail =
          if actual == expected,
            do: "at the expected version",
            else: "at version #{actual}"

        %{base | actual: actual, migrated: actual == expected, detail: detail}

      {:error, reason} ->
        %{base | detail: Error.message(reason) || inspect(reason)}
    end
  end

  defp actual_version(adapter, workspace) do
    case adapter.transaction(workspace, fn tx ->
           Store.list(tx, :schema_version, %{where: [], limit: 1})
         end) do
      {:ok, [row | _]} -> to_string(row["version"] || "unknown")
      {:ok, _rows} -> "unknown"
      {:error, _reason} -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  defp audit(workspace) do
    case safe(fn -> Audit.verify(workspace) end) do
      {:ok, {:ok, :intact}} ->
        %{intact: true, broken_at: nil, detail: "intact"}

      {:ok, {:ok, {:broken_at, index}}} ->
        %{intact: false, broken_at: index, detail: "broken at event #{index}"}

      {:ok, {:ok, {:error, reason}}} ->
        %{intact: nil, broken_at: nil, detail: Error.message(reason) || inspect(reason)}

      {:ok, _other} ->
        %{intact: nil, broken_at: nil, detail: "the chain could not be verified"}

      {:error, reason} ->
        %{intact: nil, broken_at: nil, detail: Error.message(reason) || inspect(reason)}
    end
  end

  # The deployment profile in force, and whether it has been recorded.
  #
  # A profile changes what a role may do, so it is a **deployment fact** and
  # a deployment fact belongs in the Audit Log. It is recorded when it
  # changes — and when it is first seen — so the Log holds the profile the
  # Workspace was last operated under, rather than a row per diagnostic run.
  defp deployment(workspace) do
    profile = Policy.profile_name()

    %{
      profile: profile,
      recorded: record_deployment(workspace, profile)
    }
  end

  defp record_deployment(workspace, profile) do
    previous = last_deployment_profile(workspace)

    if previous == profile do
      true
    else
      case append_deployment(workspace, profile, previous) do
        {:ok, _sequence} -> true
        {:error, _reason} -> false
      end
    end
  end

  defp last_deployment_profile(workspace) do
    case safe(fn -> Audit.entries(workspace) end) do
      {:ok, {:ok, entries}} ->
        entries
        |> Enum.reverse()
        |> Enum.find(&(&1["subject_table"] == "deployment"))
        |> case do
          nil -> nil
          entry -> entry["to_state"]
        end

      _ ->
        nil
    end
  end

  defp append_deployment(workspace, profile, previous) do
    # The lock is **outside** `safe/1`, so `safe/1` still catches exactly what
    # it caught before — a fault in the transaction — and the shape below is
    # unchanged. The lock covers the transaction, so the chain has one writer
    # at a time.
    WorkspaceLock.with_lock(workspace, fn ->
      safe(fn ->
        Store.transaction(workspace, fn tx ->
          Audit.append(tx, workspace, %{
            subject: "deployment",
            subject_table: "deployment",
            from_state: previous,
            to_state: profile,
            actor: %{type: "system", id: "doctor"},
            reason: "the deployment profile in force",
            correlation_id: nil,
            diff: %{"profile" => profile}
          })
        end)
      end)
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :not_recorded}
    end
  end

  defp cluster do
    distribution = if Node.alive?(), do: :alive, else: :not_alive
    peers = Node.list()

    detail =
      case distribution do
        :alive ->
          "alive, peers: #{if peers == [], do: "none", else: Enum.join(peers, ", ")}"

        :not_alive ->
          "not alive — this Node is standalone"
      end

    %{
      node: to_string(node()),
      distribution: distribution,
      peers: peers,
      topology: topology(distribution, peers),
      detail: detail
    }
  end

  # The free build is a single-node store, so the topology class is what
  # tells an operator whether a Node failure loses writes or not.
  defp topology(:alive, [_ | _]), do: "multi-node store"
  defp topology(_distribution, _peers), do: "single-node store, failover by audited promotion"

  # ── output ────────────────────────────────────────────────────────────────

  defp verdict(%{healthy: true}) do
    "All checks passed."
  end

  defp verdict(report) do
    faults =
      []
      |> maybe_fault(report.datastore[:reachable], "the datastore is not answering")
      |> maybe_fault(report.schema[:migrated], "the schema is not at the expected version")
      |> maybe_fault(report.audit[:intact] == true, "the audit chain does not verify")
      |> maybe_fault(
        report.cluster[:distribution] == :alive or
          report.datastore[:engine][:clustered] != true,
        "distribution is not alive"
      )

    "FAULTS FOUND: " <> Enum.join(faults, "; ")
  end

  defp maybe_fault(faults, true, _message), do: faults
  defp maybe_fault(faults, _false, message), do: faults ++ [message]

  defp remedies(report) do
    remedies =
      []
      |> remedy(
        not report.datastore[:reachable],
        report.datastore[:detail],
        "check the store is running and the credentials are right"
      )
      |> remedy(
        not report.schema[:migrated],
        report.schema[:detail],
        "run `mix veritas.cli migrate --workspace #{report.workspace}`"
      )
      |> remedy(
        report.audit[:intact] == false,
        report.audit[:detail],
        "the chain is broken: restore from a checkpoint, do not continue writing"
      )
      |> remedy(
        report.cluster[:distribution] != :alive and
          report.datastore[:engine][:clustered] == true,
        report.cluster[:detail],
        "start the Node with distribution enabled and the release cookie set"
      )

    if remedies == [] do
      "No remedy needed."
    else
      "REMEDY\n" <> Enum.map_join(remedies, "\n", &("  " <> &1))
    end
  end

  defp remedy(remedies, false, _detail, _action), do: remedies
  defp remedy(remedies, true, detail, action), do: remedies ++ ["#{detail} — #{action}"]

  # A standalone Node is the *expected* shape of the free build, so it is
  # reported, not failed. It becomes a fault only when the store says it is
  # a cluster and the Node is not in one.
  defp distribution_status(cluster, datastore) do
    cond do
      cluster[:distribution] == :alive -> "OK     "
      datastore[:engine][:clustered] == true -> "FAIL   "
      true -> "INFO   "
    end
  end

  defp status(true), do: "OK     "
  defp status(false), do: "FAIL   "
  defp status(_other), do: "UNKNOWN"

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # A check that raises is a finding, not a crash.
  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, Error.new(:internal, Exception.message(error))}
  end
end
