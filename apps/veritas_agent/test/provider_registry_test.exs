defmodule Veritas.Agent.ProviderRegistryTest do
  @moduledoc """
  The provider registry: what a stored provider looks like when it comes back,
  and where a credential comes from.

  The registry persists a provider and reads it back through a decoder, so
  every identifier it stores has to survive the round trip. A credential is
  held as a **reference** — the name of an environment variable — and is
  resolved when the provider is used, never stored.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider

  @credential_env "VERITAS_AGENT_REGISTRY_TEST_TOKEN"

  setup do
    on_exit(fn -> System.delete_env(@credential_env) end)
    :ok
  end

  defp provider(overrides) do
    Map.merge(
      %{
        id: "probe",
        kind: :hosted,
        adapter: :openai_compatible,
        base_url: "http://127.0.0.1:1/v1",
        model: "test-model",
        credential_env: @credential_env,
        capability_floor_acknowledged: false,
        capabilities: [:tools]
      },
      overrides
    )
  end

  describe "a stored provider" do
    test "comes back with an adapter the catalogue can fetch", %{} do
      # The registry persists the adapter identifier as a string and the
      # decoder handed it back unchanged, so the catalogue — which knew only
      # atoms — raised FunctionClauseError on the way to the adapter.
      workspace = "registry_test_#{System.unique_integer([:positive])}"

      assert {:ok, _stored} = Provider.Registry.put(workspace, provider(%{}))
      assert {:ok, [entry]} = Provider.Registry.list(workspace)

      assert {:ok, adapter} = AdapterRegistry.fetch(entry.adapter)

      assert adapter == Veritas.Agentic.LLM.Adapter.OpenAICompatible
    end
  end

  describe "a global provider" do
    test "keeps the reference to its credential", %{} do
      # The global tier hardcoded `credential_env: nil`, so a hosted provider
      # configured with a credential lost the reference and resolved to no
      # token at all.
      previous = Application.get_env(:veritas_core, :providers)

      Application.put_env(:veritas_core, :providers,
        hosted: [
          kind: :hosted,
          adapter: :openai_compatible,
          base_url: "http://127.0.0.1:1/v1",
          model: "test-model",
          credential_env: @credential_env,
          capabilities: [:tools]
        ]
      )

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:veritas_core, :providers)
          value -> Application.put_env(:veritas_core, :providers, value)
        end
      end)

      assert [global] = Provider.Registry.global()

      # The reference is the environment variable's name, and it survives.
      assert global.credential_env == @credential_env

      System.put_env(@credential_env, "the-token")

      assert {:ok, "the-token"} = Provider.Registry.resolve_credential(global)
    end

    test "resolves no credential when it names none", %{} do
      previous = Application.get_env(:veritas_core, :providers)

      Application.put_env(:veritas_core, :providers,
        self_hosted: [
          kind: :self_hosted,
          adapter: :ollama,
          base_url: "http://127.0.0.1:1",
          model: "llama3"
        ]
      )

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:veritas_core, :providers)
          value -> Application.put_env(:veritas_core, :providers, value)
        end
      end)

      assert [global] = Provider.Registry.global()

      assert {:ok, nil} = Provider.Registry.resolve_credential(global)
    end
  end
end
