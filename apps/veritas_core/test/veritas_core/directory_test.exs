defmodule Veritas.Core.DirectoryTest do
  @moduledoc """
  The directory port, and the one adapter's own facts.

  Two claims under test:

    * **with no directory, the port refuses** — it does not return an empty
      list, because an empty list says "this company has no people", which is
      a different and false statement;
    * **the Google adapter's request shapes and its mapping are facts that can
      be checked without a network** — the URL it lists from, the scopes it
      needs, and the person its JSON carries.

  ## What is not tested here

  **The calls to Google.** They need a service account with domain-wide
  delegation, and this build has none. The adapter is written to the API and
  has never been run against it; the corpus's rule applies — no capability is
  claimed before it has been measured.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Directory
  alias Veritas.Core.Directory.Google

  setup do
    previous = Application.get_env(:veritas_core, :directory)
    Application.delete_env(:veritas_core, :directory)

    on_exit(fn ->
      if previous do
        Application.put_env(:veritas_core, :directory, previous)
      else
        Application.delete_env(:veritas_core, :directory)
      end
    end)

    :ok
  end

  describe "with no directory configured" do
    test "the port refuses, and says there is no directory" do
      refute Directory.configured?()

      assert {:error, :no_directory} = Directory.list()
      assert {:error, :no_directory} = Directory.read("someone")
      assert {:error, :no_directory} = Directory.create(%{"email" => "a@example.test"})

      # And no scopes, because there is no adapter to want them.
      assert Directory.required_scopes() == []
    end

    test "the refusal is not an empty list" do
      # An empty list says "this company has no people". The refusal says
      # "there is no directory here", which is true.
      refute match?({:ok, []}, Directory.list())
    end
  end

  describe "the Google adapter" do
    test "it asks for the scopes an operator must grant" do
      scopes = Google.required_scopes()

      # The read scope lists people; the write scope creates them.
      assert "https://www.googleapis.com/auth/admin.directory.user.readonly" in scopes
      assert "https://www.googleapis.com/auth/admin.directory.user" in scopes
    end

    test "it lists from the directory's own users endpoint" do
      url = Google.list_url(customer: "my_customer", limit: 25)

      assert url =~ "admin.googleapis.com/admin/directory/v1/users"
      assert url =~ "customer=my_customer"
      assert url =~ "maxResults=25"
    end

    test "it maps the API's own JSON onto a person" do
      person =
        Google.person(%{
          "id" => "1234",
          "primaryEmail" => "sam@example.com",
          "name" => %{"fullName" => "Sam Example"}
        })

      assert person.id == "1234"
      assert person.email == "sam@example.com"
      assert person.name == "Sam Example"
      assert person.kind == :directory
      assert person.provider == :google
    end

    test "a person with no id falls back to their email, because that is how they are known" do
      person = Google.person(%{"primaryEmail" => "sam@example.com"})

      assert person.id == "sam@example.com"
      assert person.email == "sam@example.com"
    end
  end
end
