defmodule Veritas.Core.Directory do
  @moduledoc """
  The directory of **the company's people**, and Veritas's grants over them.

  ## What this port is for

  The corpus's linkage is the shape of everything here: *an external subject
  maps to a Veritas Principal; a Principal maps to Role(s); a Principal in a
  Workspace has a Workspace membership.*

  So there are two populations, and they are not the same thing:

    * **local accounts** — Veritas's own. They hold a password, they sign in
      with it, and they are the break-glass path when nothing else answers.
      They live in `Veritas.Authn`.
    * **directory identities** — the company's own people, owned by the
      company's identity provider. Veritas does **not** own them and does not
      bundle an identity provider: it consumes one through this port, the
      same shape as the storage adapter and the model-provider adapters.

  Everything Veritas does with a directory identity is a **grant**, and grants
  live in Veritas. The directory owns the person; Veritas owns what the person
  may do here.

  ## What this port is not

  It is **not** the sign-in path. Signing in with the company's provider is
  OIDC, which is a different integration with different credentials, and
  `Veritas.Authn` is its seam. "Google OAuth" and "administering people in
  Google Workspace" are two different integrations, and this port is the
  second one.

  ## The scope an adapter wants

  An adapter says which access it needs, and the operator sees that before
  they grant it (`required_scopes/0`). The product must work with **no**
  directory at all: `configured?/0` is false, and the people screen says so in
  one plain line rather than showing an empty table pretending to be a
  directory.

  ## Configuration

  The adapter is chosen the way the provider registry is chosen — from the
  application configuration:

      config :veritas_core, :directory, {Veritas.Core.Directory.Google, key_path: "/etc/veritas/google.json", subject: "admin@example.com"}
  """
  @type person :: %{
          id: String.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          kind: :directory,
          provider: atom()
        }

  @type reason :: {:error, term()}

  @doc """
  Lists the directory's people.

  ## Options

    * `:limit` — the most people to return.
    * `:query` — a provider-side filter, where the provider has one.
  """
  @callback list(opts :: keyword()) :: {:ok, [person()]} | reason()

  @doc """
  Reads one person from the directory.
  """
  @callback read(id :: String.t(), opts :: keyword()) :: {:ok, person()} | reason()

  @doc """
  Creates a person in the directory, where the provider's admin API allows it.

  A provider that does not allow it **refuses** — `{:error, :not_supported}` —
  and does not pretend. Veritas does not create people in a directory it does
  not own; it grants them things.
  """
  @callback create(attrs :: map(), opts :: keyword()) :: {:ok, person()} | reason()

  @doc """
  The access this adapter needs, for the operator to grant.

  A scope is a claim about what the adapter will do with the directory's
  credentials. The operator sees it before granting it, and the product works
  without it.
  """
  @callback required_scopes() :: [String.t()]

  @doc """
  The adapter in force, or `:none` when no directory is configured.
  """
  @spec adapter() :: module() | :none
  def adapter do
    case Application.get_env(:veritas_core, :directory) do
      {module, _options} when is_atom(module) -> module
      nil -> :none
      module when is_atom(module) and module != :none -> module
      _ -> :none
    end
  end

  @doc """
  Whether a directory is configured at all.
  """
  @spec configured?() :: boolean()
  def configured?, do: adapter() != :none

  @doc """
  The options the adapter in force was configured with.
  """
  @spec adapter_options() :: keyword()
  def adapter_options do
    case Application.get_env(:veritas_core, :directory) do
      {_module, options} when is_list(options) -> options
      _ -> []
    end
  end

  @doc """
  Lists the directory's people, or says there is no directory.

  The refusal is a refusal and not an empty list: an empty list would say
  "this company has no people", which is a different and false statement.
  """
  @spec list(keyword()) :: {:ok, [person()]} | {:error, :no_directory}
  def list(opts \\ []) do
    case adapter() do
      :none -> {:error, :no_directory}
      module -> module.list(opts)
    end
  end

  @doc """
  Reads one person from the directory, or says there is no directory.
  """
  @spec read(String.t(), keyword()) :: {:ok, person()} | {:error, :no_directory}
  def read(id, opts \\ []) do
    case adapter() do
      :none -> {:error, :no_directory}
      module -> module.read(id, opts)
    end
  end

  @doc """
  Creates a person in the directory, or says there is no directory.
  """
  @spec create(map(), keyword()) :: {:ok, person()} | {:error, :no_directory}
  def create(attrs, opts \\ []) do
    case adapter() do
      :none -> {:error, :no_directory}
      module -> module.create(attrs, opts)
    end
  end

  @doc """
  The access the adapter in force needs, or an empty list.
  """
  @spec required_scopes() :: [String.t()]
  def required_scopes do
    case adapter() do
      :none -> []
      module -> module.required_scopes()
    end
  end
end
