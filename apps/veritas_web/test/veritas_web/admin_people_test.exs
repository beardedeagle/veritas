defmodule Veritas.Web.AdminPeopleTest do
  @moduledoc """
  The people screen: the company's directory beside Veritas's own accounts.

  The owner's claim under test is that the surface must not reference a
  mechanism this build does not contain, and that the people of the company
  must be manageable through it:

    * **with no directory**, the screen says so in one line, names what to
      configure, and the local accounts are still there and still editable;
    * **with a directory**, the company's people are listed beside the local
      accounts, each row saying which kind of person it is;
    * **a grant to somebody in the directory is written in Veritas** — the
      directory owns the person, Veritas owns the grants — and it is audited
      with the profile in force named;
    * **the access the adapter needs is visible** before the operator grants
      it.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Authn
  alias Veritas.Core.Audit
  alias Veritas.Core.Test.FakeDirectory

  @password "a-fine-passphrase-the-operator-chose-42"

  setup %{conn: conn, workspace: workspace} do
    Application.delete_env(:veritas_core, :directory)
    FakeDirectory.put_people([])

    on_exit(fn ->
      Application.delete_env(:veritas_core, :directory)
      FakeDirectory.put_people([])
    end)

    %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
    %{conn: signed_in, workspace: workspace}
  end

  describe "with no directory configured" do
    test "the screen says so, and the local accounts are still there", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _account} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, view, _static} = live(conn, ~p"/admin/people")
      html = render(view)

      # The honest empty state: what is missing, and what to configure.
      assert html =~ "No directory is configured"
      assert html =~ "config :veritas_core, :directory"

      # And the local accounts are here, saying which kind of person they are.
      assert html =~ "dana@example.test"
      assert html =~ "local account"
    end
  end

  describe "with a directory configured" do
    setup do
      FakeDirectory.put_people([
        %{id: "dir-1", email: "sam@example.com", name: "Sam", kind: :directory, provider: :fake}
      ])

      Application.put_env(:veritas_core, :directory, {FakeDirectory, []})

      :ok
    end

    test "the directory's people are listed beside the local accounts, each saying which kind it is",
         %{conn: conn, workspace: workspace} do
      {:ok, _account} =
        Authn.create_account(
          workspace,
          %{
            email: "dana@example.test",
            display_name: "Dana",
            roles: ["Service Desk Agent"],
            password: @password
          },
          actor_id: "test"
        )

      {:ok, view, _static} = live(conn, ~p"/admin/people")
      html = render(view)

      # Both populations, and each row says which it is.
      assert html =~ "sam@example.com"
      assert html =~ "directory identity"
      assert html =~ "dana@example.test"
      assert html =~ "local account"

      # And the access the adapter needs is visible before it is granted.
      assert html =~ "admin.directory.user.readonly"
    end

    test "a grant to somebody in the directory is written here, and audited with the profile",
         %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/admin/people")

      view
      |> form("#directory-roles-dir-1")
      |> render_submit(%{"role:Service Desk Agent" => "true"})

      # The Principal is in Veritas now — the directory owns the person, and
      # Veritas owns the grants.
      {:ok, accounts} = Authn.list_accounts(workspace)
      sam = Enum.find(accounts, &(&1["email"] == "sam@example.com"))

      assert sam, "the grant was not written: #{inspect(Enum.map(accounts, & &1["email"]))}"
      assert sam["roles"] == ["Service Desk Agent"]

      # And the Audit Log says who decided, and under which profile.
      {:ok, events} = Audit.entries(workspace)

      grant = Enum.find(events, &(&1["subject"] == sam["id"]))

      assert grant, "the grant was not audited"
      assert grant["subject_table"] == "user"
      assert grant["diff"]["profile"] == "home lab"
    end
  end
end
