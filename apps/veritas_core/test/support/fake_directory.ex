defmodule Veritas.Core.Test.FakeDirectory do
  @moduledoc """
  A directory that is not a directory.

  The seam, exercised: this adapter speaks the same shapes as a real one —
  the same people, the same refusals, the same scopes — so the people screen
  and the port's contract can be tested without a Google service account and
  without a network.

  What it proves is the **seam**: that the screen reads a directory through
  the port, that the two populations are told apart, and that the grants are
  audited. It does not prove that Google answers.
  """
  @behaviour Veritas.Core.Directory

  @doc """
  The people this directory holds.

  Set them with `put_people/1`.
  """
  def people do
    Application.get_env(:veritas_core, :fake_directory_people, [])
  end

  @doc """
  Sets the people this directory holds.
  """
  def put_people(people) do
    Application.put_env(:veritas_core, :fake_directory_people, people)
  end

  @doc """
  The error the next call refuses with, if any.
  """
  def fail_with(reason) do
    Application.put_env(:veritas_core, :fake_directory_failure, reason)
  end

  @impl Veritas.Core.Directory
  def list(_opts) do
    case failure() do
      nil -> {:ok, people()}
      reason -> {:error, reason}
    end
  end

  @impl Veritas.Core.Directory
  def read(id, _opts) do
    case failure() do
      nil ->
        case Enum.find(people(), &(&1.id == id)) do
          nil -> {:error, :not_found}
          person -> {:ok, person}
        end

      reason ->
        {:error, reason}
    end
  end

  @impl Veritas.Core.Directory
  def create(attrs, _opts) do
    case failure() do
      nil ->
        person = %{
          id: attrs["id"] || "created-#{length(people())}",
          email: attrs["email"],
          name: attrs["name"],
          kind: :directory,
          provider: :fake
        }

        put_people(people() ++ [person])
        {:ok, person}

      reason ->
        {:error, reason}
    end
  end

  @impl Veritas.Core.Directory
  def required_scopes do
    ["https://www.googleapis.com/auth/admin.directory.user.readonly"]
  end

  defp failure do
    Application.get_env(:veritas_core, :fake_directory_failure)
  end
end
