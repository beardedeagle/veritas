defmodule Veritas.Core.ProviderRegistryGlobalTest do
  @moduledoc """
  The **global default** tier of provider selection, as an operator writes it.

  A provider's configuration may be a keyword list or a map; both are
  ordinary shapes and both are read the same way.

  The global tier is reached on every provider selection, so a configuration
  the host cannot read — or a provider whose adapter is not in the
  catalogue — is **refused**, with a reason, rather than raising over. A
  crash on this path would take the whole agentic surface down because of
  one mistyped entry.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider.Registry

  # A name no atom has ever been made for, built at run time so that the
  # compiler cannot intern it.
  @uninterned "adapter_" <> "name_" <> "never_" <> "interned"

  @probe :global_config_probe

  setup do
    # The catalogue holds the adapter ids the host knows. The probe stands in
    # for a shipped adapter so the test does not depend on which
    # applications a given test run starts.
    AdapterRegistry.register(@probe, __MODULE__)

    on_exit(fn -> Application.delete_env(:veritas_core, :providers) end)

    :ok
  end

  defp configure(config), do: Application.put_env(:veritas_core, :providers, config)

  describe "the configuration's shape" do
    test "a keyword-list configuration is read" do
      configure([
        {"local",
         [
           kind: :self_hosted,
           adapter: @probe,
           base_url: "http://127.0.0.1:11434",
           model: "llama3",
           capabilities: [:tools]
         ]}
      ])

      assert [provider] = Registry.global()
      assert provider.id == "local"
      assert provider.adapter == @probe
      assert provider.base_url == "http://127.0.0.1:11434"
      assert provider.model == "llama3"
      assert provider.kind == :self_hosted
      assert provider.capabilities == [:tools]
      assert Registry.global_refusals() == []
    end

    test "a map configuration is read the same way" do
      configure([
        {"local",
         %{
           kind: :self_hosted,
           adapter: @probe,
           base_url: "http://127.0.0.1:11434",
           model: "llama3",
           capabilities: [:tools]
         }}
      ])

      assert [provider] = Registry.global()
      assert provider.id == "local"
      assert provider.adapter == @probe
      assert provider.base_url == "http://127.0.0.1:11434"
      assert provider.model == "llama3"
      assert provider.kind == :self_hosted
      assert provider.capabilities == [:tools]
      assert Registry.global_refusals() == []
    end

    test "a configuration that is neither a list nor a map is refused, not raised" do
      configure([{"local", "http://127.0.0.1:11434"}])

      assert Registry.global() == []
      assert [%{id: "local", reason: reason}] = Registry.global_refusals()
      assert reason != nil
    end

    test "an entry that is not a provider at all is refused, not raised" do
      configure(["not-a-provider"])

      assert Registry.global() == []
      assert [%{reason: :not_a_provider_entry}] = Registry.global_refusals()
    end
  end

  describe "the adapter's name" do
    test "a registered adapter id resolves" do
      configure([
        {"local", [kind: :self_hosted, adapter: @probe, base_url: "http://x", model: "m"]}
      ])

      assert [provider] = Registry.global()
      assert provider.adapter == @probe
      assert Registry.global_refusals() == []
    end

    test "a provider whose own id names no registered adapter is refused, not raised" do
      configure([{@uninterned, [kind: :self_hosted, base_url: "http://x", model: "m"]}])

      assert Registry.global() == []
      assert [%{reason: {:unknown_adapter, @uninterned}}] = Registry.global_refusals()
    end

    test "an adapter id that names no registered adapter is refused, not raised" do
      configure([
        {"local", [kind: :self_hosted, adapter: @uninterned, base_url: "http://x", model: "m"]}
      ])

      assert Registry.global() == []

      assert [%{id: "local", reason: {:unknown_adapter, @uninterned}}] =
               Registry.global_refusals()
    end

    test "a configured name never grows the atom table" do
      configure([
        {"local", [kind: :self_hosted, adapter: @uninterned, base_url: "http://x", model: "m"]}
      ])

      assert Registry.global() == []
      refute atom_exists?(@uninterned)
    end
  end

  describe "the credential's name" do
    @env "VERITAS_GLOBAL_PROVIDER_TEST_KEY"

    setup do
      System.put_env(@env, "s3cret")
      on_exit(fn -> System.delete_env(@env) end)
      :ok
    end

    test "credential_env resolves" do
      configure([
        {"hosted",
         [kind: :hosted, adapter: @probe, base_url: "https://x", model: "m", credential_env: @env]}
      ])

      assert [provider] = Registry.global()
      assert provider.credential_env == @env
      assert {:ok, "s3cret"} = Registry.resolve_credential(provider)
    end

    test "credential_ref resolves to the same reference" do
      configure([
        {"hosted",
         [kind: :hosted, adapter: @probe, base_url: "https://x", model: "m", credential_ref: @env]}
      ])

      assert [provider] = Registry.global()
      assert provider.credential_env == @env
      assert {:ok, "s3cret"} = Registry.resolve_credential(provider)
    end

    test "credential_ref resolves from a map configuration too" do
      configure([
        {"hosted",
         %{
           kind: :hosted,
           adapter: @probe,
           base_url: "https://x",
           model: "m",
           credential_ref: @env
         }}
      ])

      assert [provider] = Registry.global()
      assert provider.credential_env == @env
      assert {:ok, "s3cret"} = Registry.resolve_credential(provider)
    end
  end

  describe "the selection" do
    test "a refused global provider is named, not reported as an absence" do
      configure([
        {"local", [kind: :self_hosted, adapter: @uninterned, base_url: "http://x", model: "m"]}
      ])

      assert {:error, {:no_usable_provider, %{named: nil, refusals: [refusal]}}} =
               Registry.select("ws_global_test", [])

      assert refusal.id == "local"
    end

    test "a usable global provider is selected" do
      configure([
        {"local", [kind: :self_hosted, adapter: @probe, base_url: "http://x", model: "m"]}
      ])

      assert {:ok, provider, :global_default} = Registry.select("ws_global_test", [])
      assert provider.id == "local"
    end
  end

  defp atom_exists?(name) do
    String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
