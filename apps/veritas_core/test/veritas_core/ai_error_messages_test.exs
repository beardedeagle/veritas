defmodule Veritas.Core.AIErrorMessagesTest do
  use ExUnit.Case, async: true

  alias Veritas.Store.Error

  test "AI configuration failures give a useful message without exposing a credential reference" do
    assert Error.message(:no_model) =~ "Choose a model"
    assert Error.message(:unknown_adapter) =~ "adapter is not registered"

    message = Error.message({:environment_variable_not_set, "PRIVATE_PROVIDER_CREDENTIAL"})
    assert message =~ "administrator"
    refute message =~ "PRIVATE_PROVIDER_CREDENTIAL"
    refute message =~ "environment_variable_not_set"
  end
end
