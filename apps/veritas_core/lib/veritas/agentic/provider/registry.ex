defmodule Veritas.Agentic.Provider.Registry do
  @moduledoc """
  The Workspace-scoped registry of provider **instances**.

  This is not the adapter catalogue (`Veritas.Agentic.LLM.AdapterRegistry`),
  which says which adapter *code* is compiled in. The registry says which
  providers **this Workspace** uses — id, kind, endpoint, model and a
  *reference* to a credential (`docs/39` §3.1).

  ## The registry is empty on a fresh install

  Not "defaulted to something": **empty**. Neither tier is a default; the
  choice is the operator's, made per Workspace (`docs/39` §3.1). A Veritas
  install can have working AI with no key and no account by choosing the
  self-hosted tier.

  ## Selection precedence

  `run override > agent spec > Workspace setting > global default`
  (`docs/15` §Configuration). The effective selection is recorded on the run
  row, so a historical run is replayable with its original provider.

  ## Where it is stored

  Through the **Store port**, never straight to the adapter: a provider
  entry is domain data, and the corpus's rule for domain data is the port
  (`docs/32`). The table it needs — a provider registry — is named in the
  report as a change owed by the region this module does not touch.
  """

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Core.Audit
  alias Veritas.Core.Principal
  alias Veritas.Core.WorkspaceLock
  alias Veritas.Store

  @typedoc """
  Who acted, as the Audit Log records it (`Veritas.Core.Principal.audit_actor/1`).
  """
  @type actor :: %{type: String.t(), id: String.t()}

  @typedoc """
  A provider entry.

  `credential_env` is the **name of the environment variable** that holds the
  provider's key — the credential is held as a reference and resolved at
  execution, and in this build the environment is where it is resolved from.

  `capability_floor_acknowledged` is the operator's **acceptance** of the
  contractual floor for a hosted provider, and the two fields beside it say
  **who accepted it and when**. It is a record, never a condition: a provider
  whose floor has not been acknowledged is still perfectly usable, because what
  is missing then is the evidence that anybody was shown the risk.
  """
  @type t :: %{
          id: String.t(),
          kind: :self_hosted | :hosted,
          adapter: atom(),
          base_url: String.t() | nil,
          model: String.t() | nil,
          credential_env: String.t() | nil,
          capability_floor_acknowledged: boolean(),
          capability_floor_acknowledged_by: actor() | nil,
          capability_floor_acknowledged_at: DateTime.t() | nil,
          capabilities: [atom()]
        }

  @table :provider

  @doc """
  The Workspace's providers.
  """
  @spec list(Store.workspace()) :: {:ok, [t()]} | {:error, Store.Error.t()}
  def list(workspace) when is_binary(workspace) do
    case Store.transaction(workspace, fn tx ->
           Store.list(tx, @table, %{where: []})
         end) do
      {:ok, rows} -> {:ok, Enum.map(rows, &entry/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One provider, by its Workspace-local id.
  """
  @spec fetch(Store.workspace(), String.t()) :: {:ok, t() | nil} | {:error, Store.Error.t()}
  def fetch(workspace, id) when is_binary(workspace) and is_binary(id) do
    case Store.transaction(workspace, fn tx -> Store.fetch(tx, @table, id) end) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, entry(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds a provider, or replaces the one with that id.

  ## The contractual floor is a record, not a condition

  A hosted provider carries data out of the estate, so the operator is shown
  the risk — that the provider may train on what it receives, may retain it
  beyond the window it states, and names its own subprocessors — and accepts
  it. The acceptance is recorded here, with **who** accepted it and **when**,
  and it is written to the Audit Log.

  Nothing here refuses a provider because the acceptance is missing. A
  provider whose floor has not been acknowledged is still perfectly usable:
  the acceptance is evidence that the risk was shown to somebody, not a
  condition on calling the provider.

  `opts[:actor]` is the Principal that accepted it. The registry stamps the
  attribution itself, so a caller cannot record an acceptance nobody made.
  """
  @spec put(Store.workspace(), t(), keyword()) :: {:ok, t()} | {:error, Store.Error.t()}
  def put(workspace, provider, opts \\ []) when is_binary(workspace) and is_map(provider) do
    actor = audit_actor(opts[:actor])
    requested = provider.capability_floor_acknowledged == true

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        save(tx, workspace, provider, requested, actor, opts)
      end)
    end)
  end

  # The row is written first, and the acceptance is recorded in the Log in the
  # SAME transaction: a record of an acceptance that did not happen is not a
  # record. The entry is only handed back once both are done.
  defp save(tx, workspace, provider, requested, actor, opts) do
    with {:ok, previous} <- Store.fetch(tx, @table, provider.id) do
      was = acknowledged?(previous)
      acknowledgement = acknowledgement(previous, requested, actor)
      row = row(provider, acknowledgement)

      with {:ok, stored} <- Store.put(tx, @table, row) do
        if was == requested do
          {:ok, entry(stored)}
        else
          event = acceptance_event(stored, was, requested, acknowledgement, actor, opts)
          record_acceptance(tx, workspace, stored, event)
        end
      end
    end
  end

  # The acceptance is recorded ONLY when it changed. Saving a provider again
  # with the same answer writes nothing, so the Log holds one entry per
  # decision and not one per save.
  defp record_acceptance(tx, workspace, stored, event) do
    with {:ok, _audit} <- Audit.append(tx, workspace, event) do
      {:ok, entry(stored)}
    end
  end

  @doc """
  The contractual floor, in the words the operator has to accept.

  A provider hosted by somebody else decides what happens to the data it
  receives. The operator is told that, plainly, and accepts it — and the
  acceptance is recorded with their name against it. This is the text the
  console shows before the setup completes.

  The disclosure names the **training** risk first, because a provider that
  trains on what it receives is the risk an operator is least likely to have
  been told about anywhere else.
  """
  @spec capability_floor_disclosure(t() | nil) :: String.t()
  def capability_floor_disclosure(provider \\ nil) do
    name =
      case provider do
        %{id: id} -> id
        _other -> "This provider"
      end

    """
    #{name} is hosted by somebody else, so everything you send it — prompts, ticket text, CI attributes — leaves your estate, and the provider decides what happens to it there:

      * it may use that data to train its models,
      * it may retain that data for longer than the retention window it states,
      * it may hand it to the subprocessors it names.

    Accepting this records that the risk was shown to you, that you accepted it, and who accepted it. The provider is usable either way: this is a record of your decision, not a switch.
    """
  end

  @doc """
  Removes a provider.
  """
  @spec delete(Store.workspace(), String.t()) :: :ok | {:error, Store.Error.t()}
  def delete(workspace, id) when is_binary(workspace) and is_binary(id) do
    case Store.transaction(workspace, fn tx -> Store.delete(tx, @table, id) end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The provider a run should use.

  The tiers are tried in the corpus's order, and the first one that names a
  provider wins:

    1. `run_override` — this run's own choice.
    2. `agent_spec` — the agent's default.
    3. the **Workspace setting** — this Workspace's registry.
    4. the **global default** — the operator's configuration.

  The result is `{:ok, provider, tier}` so the caller can record **which**
  tier chose it, on the run row.
  """
  @spec select(Store.workspace(), keyword()) ::
          {:ok, t() | nil, atom()} | {:error, Store.Error.t()}
  def select(workspace, opts \\ []) do
    case opts[:run_override] do
      %{id: _id} = provider ->
        {:ok, provider, :run_override}

      id when is_binary(id) ->
        case fetch(workspace, id) do
          {:ok, nil} -> select_below(workspace, opts)
          {:ok, provider} -> {:ok, provider, :run_override}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        select_below(workspace, opts)
    end
  end

  @doc """
  The providers the operator configured for the whole deployment.

  The **global default** tier: configuration, not a Workspace's own
  registry (`docs/15` §Configuration). It is read from the runtime
  configuration, so changing it needs no restart and no recompile.

  A provider's configuration may be written as a keyword list or as a map.
  Both are ordinary shapes an operator writes, and both are read the same way.

  A configuration the host cannot read, or a provider whose adapter is not in
  the catalogue, is **refused** rather than raising: this path runs on every
  provider selection, so a crash here over one mistyped entry would take the
  whole agentic surface down. `global_refusals/0` says which providers were
  refused and why.
  """
  @spec global() :: [t()]
  def global do
    global_entries()
    |> Enum.flat_map(fn
      {:ok, provider} -> [provider]
      {:error, _refusal} -> []
    end)
  end

  @doc """
  The configured global providers this build cannot use, and why.

  A refusal is an answer: the operator is told which entry is wrong and
  what is wrong with it, rather than being told that no provider exists.
  """
  @spec global_refusals() :: [map()]
  def global_refusals do
    global_entries()
    |> Enum.flat_map(fn
      {:error, refusal} -> [refusal]
      {:ok, _provider} -> []
    end)
  end

  @doc """
  The provider this Workspace names, or `nil`.

  The **Workspace setting** is one of the four tiers the selection walks
  (`run override > agent spec > Workspace setting > global default`). The
  registry carries no "selected" marker, so the Workspace's provider is the
  first one by id — a deterministic choice — and a caller that used it says
  so, so the operator can see which provider answered.

  A Workspace whose registry cannot be read names no provider, and the tier
  below answers.
  """
  @spec workspace_provider(Store.workspace()) :: t() | nil
  def workspace_provider(workspace) when is_binary(workspace) do
    case list(workspace) do
      {:ok, []} -> nil
      {:ok, providers} -> providers |> Enum.sort_by(& &1.id) |> hd()
      {:error, _reason} -> nil
    end
  end

  @doc """
  The credential the entry names, read at call time.

  The entry names the **environment variable** that holds the key, and the key
  is read from the environment when the provider is called. The key itself is
  never stored, never carried in a domain context, never put on a screen, and
  never written to the Audit Log.

  An entry that names no variable is a provider that needs no key — the
  self-hosted tier. An entry that names a variable which is not set is
  **refused**, and the refusal names the variable: the operator is told which
  one to set, rather than being told that a call failed.
  """
  @spec resolve_credential(t()) :: {:ok, String.t() | nil} | {:error, term()}
  def resolve_credential(%{credential_env: nil}), do: {:ok, nil}

  def resolve_credential(%{credential_env: ""}), do: {:ok, nil}

  def resolve_credential(%{credential_env: name}) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:environment_variable_not_set, name}}
    end
  end

  defp select_below(workspace, opts) do
    case opts[:agent_spec] do
      %{id: _id} = provider ->
        {:ok, provider, :agent_spec}

      id when is_binary(id) ->
        case fetch(workspace, id) do
          {:ok, nil} -> select_workspace(workspace, opts)
          {:ok, provider} -> {:ok, provider, :agent_spec}
          {:error, _reason} -> select_workspace(workspace, opts)
        end

      _ ->
        select_workspace(workspace, opts)
    end
  end

  defp select_workspace(workspace, opts) do
    case opts[:workspace_provider] do
      %{id: _id} = provider ->
        {:ok, provider, :workspace_setting}

      id when is_binary(id) ->
        case fetch(workspace, id) do
          {:ok, nil} -> select_global(opts)
          {:ok, provider} -> {:ok, provider, :workspace_setting}
          # A registry that cannot be read is a registry with no entries in
          # it: the Workspace names no provider, and the tier below answers.
          {:error, _reason} -> select_global(opts)
        end

      _ ->
        select_global(opts)
    end
  end

  defp select_global(opts) do
    case opts[:global_provider] do
      nil ->
        case global() do
          [provider | _] -> {:ok, provider, :global_default}
          [] -> global_unusable(nil)
        end

      id when is_binary(id) ->
        case Enum.find(global(), &(&1.id == id)) do
          nil -> global_unusable(id)
          provider -> {:ok, provider, :global_default}
        end

      provider ->
        {:ok, provider, :global_default}
    end
  end

  # A refused provider is an answer, not an absence. When the global tier has
  # nothing usable, the caller is told which entry was refused and why —
  # rather than being told that no provider exists, which sends the operator
  # looking in the wrong place.
  defp global_unusable(named) do
    case global_refusals() do
      [] -> {:ok, nil, :none}
      refusals -> {:error, {:no_usable_provider, %{named: named, refusals: refusals}}}
    end
  end

  defp entry(row) do
    %{
      id: row["id"],
      kind: kind(row["kind"]),
      adapter: adapter(row["adapter"], row["id"]),
      base_url: row["base_url"],
      model: row["model"],
      credential_env: row["credential_env"],
      capability_floor_acknowledged: row["capability_floor_acknowledged"] == true,
      capability_floor_acknowledged_by: stored_actor(row["capability_floor_acknowledged_by"]),
      capability_floor_acknowledged_at: stored_at(row["capability_floor_acknowledged_at"]),
      capabilities: row["capabilities"] || []
    }
  end

  defp row(provider, acknowledgement) do
    %{
      "id" => provider.id,
      "workspace" => provider[:workspace],
      "kind" => to_string(provider.kind),
      "adapter" => to_string(provider.adapter),
      "base_url" => provider.base_url,
      "model" => provider.model,
      "credential_env" => provider.credential_env,
      "capability_floor_acknowledged" => provider.capability_floor_acknowledged == true,
      "capabilities" => provider.capabilities
    }
    |> put_acknowledgement(acknowledgement)
  end

  # A value that is not set is **not written**: the store drops a null field
  # from the flexible object it writes, and the canonical encoding tells an
  # absent key from a key whose value is null.
  defp put_acknowledgement(row, %{by: nil, at: nil}), do: row

  defp put_acknowledgement(row, %{by: by, at: at}) do
    row
    |> Map.put("capability_floor_acknowledged_by", %{"type" => by.type, "id" => by.id})
    |> Map.put("capability_floor_acknowledged_at", at)
  end

  defp global_kind(config) do
    case config_value(config, :kind) do
      "hosted" -> :hosted
      :hosted -> :hosted
      _other -> :self_hosted
    end
  end

  # The adapter is named by an id the **catalogue** already holds. A name it
  # does not hold is refused: `String.to_atom/1` would make the atom table a
  # function of whatever a configuration said, and `String.to_existing_atom/1`
  # would raise on a name that is not interned. Neither is an answer.
  #
  # A provider that names no adapter of its own is named by its own id — the
  # shape an operator writes when the provider *is* the adapter.
  defp global_adapter(config, id) do
    case config_value(config, :adapter) do
      nil -> AdapterRegistry.resolve_id(to_string(id))
      adapter -> AdapterRegistry.resolve_id(adapter)
    end
  end

  # The global tier names its credential the way the Workspace tier does:
  # by the environment variable that holds it. A global hosted provider with
  # no reference cannot authenticate, and refusing it here is better than
  # resolving a credential that was never named.
  defp global_credential_env(config) do
    config_value(config, :credential_env) || config_value(config, :credential_ref)
  end

  defp global_entries do
    case Application.get_env(:veritas_core, :providers, []) do
      list when is_list(list) -> Enum.map(list, &global_entry/1)
      map when is_map(map) -> Enum.map(Enum.to_list(map), &global_entry/1)
      other -> [{:error, %{id: "providers", reason: {:unsupported_configuration, other}}}]
    end
  end

  defp global_entry({id, config}) do
    case global_adapter(config, id) do
      {:ok, adapter} -> {:ok, build_global(id, config, adapter)}
      {:error, reason} -> {:error, %{id: to_string(id), reason: reason}}
    end
  end

  defp global_entry(other) do
    {:error, %{id: inspect(other), reason: :not_a_provider_entry}}
  end

  defp build_global(id, config, adapter) do
    acknowledged = config_value(config, :capability_floor_acknowledged, false) == true

    {by, at} =
      if acknowledged do
        {global_actor(config), global_at(config)}
      else
        {nil, nil}
      end

    %{
      id: to_string(id),
      kind: global_kind(config),
      adapter: adapter,
      base_url: config_value(config, :base_url),
      model: config_value(config, :model),
      credential_env: global_credential_env(config),
      capability_floor_acknowledged: acknowledged,
      capability_floor_acknowledged_by: by,
      capability_floor_acknowledged_at: at,
      capabilities: config_value(config, :capabilities, [])
    }
  end

  # A provider's configuration may be written as a keyword list or as a map.
  # Both are ordinary shapes an operator writes, and reading one must not
  # depend on the other: a configuration the host cannot read is a refusal,
  # never a crash on the path that selects a provider.
  defp config_value(config, key, default \\ nil)

  defp config_value(config, key, default) when is_list(config) do
    if keyword?(config), do: Keyword.get(config, key, default), else: default
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp keyword?(list) when is_list(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) -> true
      _other -> false
    end)
  end

  defp kind(value) do
    case value do
      "hosted" -> :hosted
      "self_hosted" -> :self_hosted
      :hosted -> :hosted
      _ -> :self_hosted
    end
  end

  defp adapter(value, id) do
    case value do
      nil -> adapter_id(id)
      value when is_binary(value) -> adapter_id(value)
      adapter when is_atom(adapter) -> adapter
      _other -> adapter_id(id)
    end
  end

  # A persisted identifier comes back from the store as a string, and the
  # adapter catalogue is keyed by atoms, so it is normalised on the way in.
  # The atom already exists for every adapter that is compiled in; an
  # identifier that names none is left as it was found rather than interned,
  # because the store is not a place to grow the atom table.
  defp adapter_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp adapter_id(value), do: value

  # ── the contractual floor ───────────────────────────────────────────────────

  # The attribution the stored row carries.
  #
  # An acceptance that has not changed keeps the attribution it already has: a
  # re-save by the same principal is not a new acceptance, and the record of
  # the first one stands. An acceptance by somebody else is a new acceptance,
  # and it is stamped afresh.
  defp acknowledgement(previous, true, actor) do
    stored_by = previous && previous["capability_floor_acknowledged_by"]

    if previous && previous["capability_floor_acknowledged"] == true &&
         same_actor?(stored_by, actor) do
      %{
        by: stored_actor(stored_by),
        at: stored_at(previous["capability_floor_acknowledged_at"])
      }
    else
      %{by: actor, at: DateTime.utc_now()}
    end
  end

  defp acknowledgement(_previous, _requested, _actor), do: %{by: nil, at: nil}

  # The Audit Log entry for a change of the acceptance.
  #
  # The entry records the **decision** — what the operator accepted, and who —
  # so the chain says what was agreed even if the store later holds a
  # different row.
  defp acceptance_event(stored, was, requested, acknowledgement, actor, opts) do
    %{
      subject: stored["id"],
      subject_table: "provider",
      from_state: acknowledgement_state(was),
      to_state: acknowledgement_state(requested),
      actor: actor,
      reason:
        if(requested,
          do: "the operator accepted the provider's contractual floor",
          else: "the operator withdrew the acceptance of the provider's contractual floor"
        ),
      correlation_id: opts[:correlation_id],
      diff: acceptance_diff(stored, requested, acknowledgement)
    }
  end

  defp acknowledged?(nil), do: false
  defp acknowledged?(row), do: row["capability_floor_acknowledged"] == true

  defp acknowledgement_state(true), do: "acknowledged"
  defp acknowledgement_state(false), do: "not_acknowledged"

  # What the entry records about the decision.
  #
  # The values are strings and booleans. A `nil` in a diff does not verify, and
  # a datetime nested inside a flexible object is the one value a store may
  # not hand back exactly as it was given — so the moment is written as the
  # text it is.
  defp acceptance_diff(stored, requested, acknowledgement) do
    %{
      "provider" => stored["id"],
      "kind" => stored["kind"],
      "endpoint" => stored["base_url"],
      "model" => stored["model"],
      "capability_floor_acknowledged" => requested,
      "acknowledged_by" => actor_label(acknowledgement.by),
      "acknowledged_at" => iso8601(acknowledgement.at)
    }
    |> without_nils()
  end

  defp actor_label(nil), do: nil
  defp actor_label(actor), do: actor.type <> ":" <> actor.id

  defp iso8601(nil), do: nil
  defp iso8601(at), do: DateTime.to_iso8601(at)

  # A value that is not set is **not written**: the store drops a null field
  # from the flexible object it writes, and the canonical encoding tells an
  # absent key from a key whose value is null.
  defp without_nils(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  # The Principal that accepted, as the Audit Log records an actor.
  defp audit_actor(nil), do: %{type: "unknown", id: "unknown"}
  defp audit_actor(%Principal{} = principal), do: Principal.audit_actor(principal)

  defp audit_actor(%{type: type, id: id}) when is_binary(type) and is_binary(id),
    do: %{type: type, id: id}

  defp audit_actor(%{"type" => type, "id" => id}) when is_binary(type) and is_binary(id),
    do: %{type: type, id: id}

  defp audit_actor(_other), do: %{type: "unknown", id: "unknown"}

  # The actor as it comes back from the store, where the keys are strings.
  defp stored_actor(nil), do: nil

  defp stored_actor(%{"type" => type, "id" => id}) when is_binary(type) and is_binary(id),
    do: %{type: type, id: id}

  defp stored_actor(%{type: type, id: id}) when is_binary(type) and is_binary(id),
    do: %{type: type, id: id}

  defp stored_actor(_other), do: nil

  defp same_actor?(stored, actor) when is_map(stored) and is_map(actor) do
    Map.get(stored, "type", Map.get(stored, :type)) == actor.type and
      Map.get(stored, "id", Map.get(stored, :id)) == actor.id
  end

  defp same_actor?(_stored, _actor), do: false

  # The moment, as it comes back from the store.
  defp stored_at(%DateTime{} = at), do: at

  defp stored_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp stored_at(_other), do: nil

  # The global tier names who accepted, in the configuration.
  defp global_actor(config) do
    case config_value(config, :capability_floor_acknowledged_by) do
      nil -> nil
      %{"type" => type, "id" => id} -> %{type: type, id: id}
      %{type: type, id: id} -> %{type: type, id: id}
      name when is_binary(name) -> %{type: "operator", id: name}
      _other -> nil
    end
  end

  defp global_at(config) do
    case config_value(config, :capability_floor_acknowledged_at) do
      nil -> nil
      %DateTime{} = at -> at
      value when is_binary(value) -> stored_at(value)
      _other -> nil
    end
  end
end
