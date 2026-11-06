defmodule Veritas.Store.Config do
  @moduledoc """
  Which Adapter is installed, and whether it is usable.

  The datastore is a **Default**: the shipped Adapter is one implementation of
  the `Veritas.Store` contract, and an operator may substitute another
  (`docs/32`, ADR-033). This module is the whole of that mechanism:

    * `adapter/0` resolves the configured Adapter module.
    * `configure/1` sets it, and is what a boot check calls.
    * `validate!/0` proves the Adapter is present, implements the contract and
      declares its capabilities — and **fails loudly** when it does not.

  ## Failing loudly

  A missing or broken Adapter must never degrade into a datastore that
  silently stops persisting. `validate!/0` raises, and the application
  supervisor refuses to start, so a misconfigured deployment fails at boot
  rather than at the first write.

  ## Configuration

      config :veritas_core, :store,
        adapter: Veritas.Store.Surreal,
        options: [url: "http://127.0.0.1:8000", user: "root", pass: "root"]

  The Adapter may also be given as `{module, options}`. The legacy
  `:store_adapter` key is honoured so an existing configuration keeps working.

  ## Credentials

  A shipped default credential is a **published** credential: it is in this
  repository, in every clone of it, and in every fork. Veritas is a
  self-hosted service whose datastore holds a customer's CMDB, so the boot
  check refuses a default credential in production:

      * production — the boot check **raises** and the application does not
        start;
      * every other environment — the boot check **warns loudly**, because a
        single-node local store with nothing configured is how Veritas is
        meant to be tried;
      * `VERITAS_STORE_ALLOW_DEFAULT_CREDENTIALS=true` — the named opt-out.
        The operator is told loudly instead of refused.
  """

  require Logger

  alias Veritas.Store
  alias Veritas.Store.Error

  @default_adapter Veritas.Store.Surreal

  # The password the shipped configuration used to carry. It is refused in
  # production and warned about everywhere else.
  @default_password "root"

  # The callbacks the port declares. Listed here as well as in the behaviour,
  # because the behaviour's own list cannot be read at compile time.
  @required_callbacks [
    transaction: 3,
    fetch: 3,
    put: 3,
    delete: 3,
    list: 3,
    next_sequence: 2,
    relate: 5,
    unrelate: 4,
    traverse: 5,
    impact: 3,
    put_ci_type: 2,
    put_relation_kind: 2,
    ci_types: 1,
    relation_kinds: 1,
    upsert_chunks: 3,
    vector_search: 3,
    fulltext_search: 3,
    append_samples: 2,
    range_samples: 5,
    append_audit: 2,
    changes: 3,
    describe: 0
  ]

  @doc """
  The configured Adapter module.

  Falls back to the shipped SurrealDB Adapter when nothing is configured, so
  a default deployment works with no configuration at all.
  """
  @spec adapter() :: module()
  def adapter do
    module = resolve()

    unless implements_contract?(module) do
      raise "the configured store adapter #{inspect(module)} does not implement the " <>
              "#{Store.contract_version()} contract; missing: " <>
              "#{Enum.join(missing_callbacks(module), ", ")}"
    end

    module
  end

  defp resolve do
    case Application.get_env(:veritas_core, :store) do
      {module, _options} when is_atom(module) -> module
      %{adapter: module} when is_atom(module) -> module
      module when is_atom(module) and not is_nil(module) -> module
      _ -> legacy_adapter()
    end
  end

  # The check is memoised per module: it is a property of the module, not of
  # the call, and it runs on every operation.
  defp implements_contract?(module) do
    case :persistent_term.get({__MODULE__, :contract, module}, :unknown) do
      :unknown ->
        result =
          Code.ensure_loaded?(module) and
            Enum.all?(@required_callbacks, fn {name, arity} ->
              function_exported?(module, name, arity)
            end)

        :persistent_term.put({__MODULE__, :contract, module}, result)
        result

      result ->
        result
    end
  end

  @doc "The options the configured Adapter was given."
  @spec options() :: keyword()
  def options do
    case Application.get_env(:veritas_core, :store) do
      {_module, options} when is_list(options) -> options
      %{options: options} when is_list(options) -> options
      _ -> legacy_options()
    end
  end

  @doc """
  Points the system at a different Adapter.

  Takes effect immediately, for the running system: the next call to
  `adapter/0` resolves to the new module. The boot check calls
  `validate!/0` afterwards.
  """
  @spec configure(module() | {module(), keyword()}) :: :ok
  def configure({module, options}) when is_atom(module) and is_list(options) do
    # The options are **merged**, not replaced. Naming an Adapter is not a
    # request to forget how to reach the store: a caller that says
    # `configure({Veritas.Store.Surreal, []})` means "the SurrealDB Adapter,
    # with the settings you already have", and losing the credentials there
    # would fail every write with an authentication error that looks like a
    # store fault rather than a configuration one.
    Application.put_env(:veritas_core, :store, {module, Keyword.merge(options(), options())})
    :ok
  end

  def configure(module) when is_atom(module) do
    Application.put_env(:veritas_core, :store, {module, options()})
    :ok
  end

  @doc """
  Proves the configured Adapter is usable, or raises.

  Checks that the module exists, implements every callback of the port, and
  answers `describe/0`. An Adapter that does not implement the contract is a
  broken deployment and must not be allowed to serve traffic.
  """
  @spec validate!() :: :ok
  def validate! do
    module = resolve()

    unless Code.ensure_loaded?(module) and function_exported?(module, :__info__, 1) do
      raise "the configured store adapter #{inspect(module)} does not exist"
    end

    missing = missing_callbacks(module)

    unless missing == [] do
      raise "the configured store adapter #{inspect(module)} does not implement " <>
              "the #{Store.contract_version()} contract; missing: #{Enum.join(missing, ", ")}"
    end

    unless function_exported?(module, :describe, 0) do
      raise "the configured store adapter #{inspect(module)} does not implement " <>
              "the #{Store.contract_version()} contract; missing: describe/0"
    end

    validate_credentials!()

    :ok
  end

  # The datastore credential.
  #
  # The rule is **Fixed**: a deployment that reaches its datastore with a
  # known password is not a deployment that can be described as safe, and no
  # configuration value should be able to argue otherwise. The *consequence* is
  # a **Default**: the operator may accept a default credential deliberately,
  # by name, and be told loudly rather than refused.
  defp validate_credentials! do
    options = options()

    if credentials_in_play?(options) do
      case credential_problem(options) do
        :ok ->
          :ok

        problem ->
          if production?() and not allow_default_credentials?() do
            raise credential_refusal(problem)
          else
            Logger.warning(
              "[veritas.store] the datastore credential is #{describe_problem(problem)}. " <>
                refusal_note()
            )

            :ok
          end
      end
    else
      :ok
    end
  end

  # Why it was allowed, which is not the same reason in the two cases: a
  # development deployment is allowed a default credential because there is
  # nothing else to configure, and a production deployment is allowed one
  # because an operator said so by name.
  defp refusal_note do
    if production?() do
      "This is refused in production. You allowed it explicitly with " <>
        "VERITAS_STORE_ALLOW_DEFAULT_CREDENTIALS=true: nothing but you can reach " <>
        "this deployment, and the password is in every clone of this repository."
    else
      "This is refused in production. It is allowed here because this is a " <>
        "#{environment()} deployment with nothing else configured: do not put one " <>
        "of these on a network."
    end
  end

  # The credential the Adapter will actually use. The store options are
  # written from the same values as the Adapter's own fallback key, so the
  # two agree; the fallback is still consulted, because an Adapter that
  # falls back to it must be judged on the password it would use.
  defp effective_password(options) do
    case Keyword.fetch(options, :pass) do
      {:ok, pass} -> pass
      :error -> fallback_options() |> Keyword.get(:pass)
    end
  end

  defp credential_problem(options) do
    case effective_password(options) do
      nil -> :missing
      "" -> :empty
      @default_password -> :default
      _ -> :ok
    end
  end

  # A store that was given no credentials at all is not a store with a
  # default credential — it is the in-memory Adapter, or a configuration that
  # has not been written yet. Neither is this check's business.
  defp credentials_in_play?(options) do
    Keyword.has_key?(options, :pass) or Keyword.has_key?(options, :user) or
      Keyword.has_key?(options, :url) or
      (fallback_options() != [] and
         (Keyword.has_key?(fallback_options(), :pass) or
            Keyword.has_key?(fallback_options(), :user) or
            Keyword.has_key?(fallback_options(), :url)))
  end

  defp fallback_options do
    case Application.get_env(:veritas_core, :surreal) do
      options when is_list(options) -> options
      _ -> []
    end
  end

  defp production? do
    environment() == :prod
  end

  defp environment do
    Application.get_env(:veritas_core, :environment, :prod)
  end

  defp allow_default_credentials? do
    Application.get_env(:veritas_core, :allow_default_credentials, false) == true
  end

  defp describe_problem(:default), do: "the shipped default"
  defp describe_problem(:empty), do: "empty"
  defp describe_problem(:missing), do: "not configured"

  defp credential_refusal(problem) do
    """
    the datastore credential is #{describe_problem(problem)}.

    A self-hosted Veritas must not reach its datastore with a known credential:
    the password is in this repository, in every clone of it, and in every
    fork, and the datastore holds the CMDB.

    Set VERITAS_SURREAL_PASS to a real password and start again. If you are
    certain that nothing but you can reach this deployment, set
    VERITAS_STORE_ALLOW_DEFAULT_CREDENTIALS=true and you will be warned
    loudly instead of refused.
    """
  end

  @doc """
  The capabilities the configured Adapter declares, or `[]` when it cannot be
  reached.
  """
  @spec capabilities() :: [Store.capability()]
  def capabilities do
    case adapter().describe() do
      %{capabilities: capabilities} when is_list(capabilities) -> capabilities
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Whether the configured Adapter provides a capability.

  Used by the domain to refuse a call it cannot honour, rather than pretending
  the capability exists.
  """
  @spec provides?(Store.capability()) :: boolean()
  def provides?(capability), do: capability in capabilities()

  @doc """
  A typed error for a capability the Adapter does not have.
  """
  @spec unsupported(Store.capability()) :: Error.t()
  def unsupported(capability) do
    Error.new(
      :unsupported,
      "the configured store adapter does not provide the #{capability} capability",
      details: %{capability: capability, adapter: adapter()}
    )
  end

  defp missing_callbacks(module) do
    Enum.flat_map(@required_callbacks, fn {name, arity} ->
      if function_exported?(module, name, arity), do: [], else: ["#{name}/#{arity}"]
    end)
  end

  defp legacy_adapter do
    case Application.get_env(:veritas_core, :store_adapter) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> @default_adapter
    end
  end

  defp legacy_options do
    case Application.get_env(:veritas_core, :store) do
      nil -> []
      %{options: options} when is_list(options) -> options
      _ -> []
    end
  end
end
