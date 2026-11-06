defmodule Veritas.Core.ProviderRegistryCredentialTest do
  @moduledoc """
  The credential, as the provider registry holds it.

  The registry holds the **name of the environment variable** that holds the
  key, and the key is read from the environment when the provider is called.
  Nothing else is true: the key is never stored, never carried in a domain
  context, and never written to the Audit Log.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.Provider.Registry

  @env "VERITAS_TEST_PROVIDER_KEY"

  setup do
    on_exit(fn -> System.delete_env(@env) end)

    :ok
  end

  test "the key is read from the environment when the provider is called" do
    System.put_env(@env, "s3cret")

    assert {:ok, "s3cret"} =
             Registry.resolve_credential(%{kind: :hosted, credential_env: @env})
  end

  test "a provider that names no variable needs no key" do
    assert {:ok, nil} =
             Registry.resolve_credential(%{kind: :self_hosted, credential_env: nil})

    assert {:ok, nil} =
             Registry.resolve_credential(%{kind: :hosted, credential_env: ""})
  end

  test "a variable that is not set is refused, and the refusal names it" do
    assert {:error, {:environment_variable_not_set, @env}} =
             Registry.resolve_credential(%{kind: :hosted, credential_env: @env})
  end
end
