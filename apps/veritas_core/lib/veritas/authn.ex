defmodule Veritas.Authn do
  @moduledoc """
  The authentication port.

  This is the seam that keeps the domain from knowing **what kind of
  credential** a request arrived with. The domain asks for a Principal; the
  host hands this port a credential — a local password today, an OIDC token
  tomorrow, an API token the day after — and gets back a Principal or a
  refusal. Nothing above this line can tell the difference, and nothing above
  this line should have to.

  That is the same discipline the data-access port applies (`docs/32`,
  `Veritas.Store`) and the agentic port applies (`docs/15`): **no Adapter
  type may cross into a domain context.** A domain module may not mention a
  password, a bearer token, a signed assertion or an `OIDC` subject. It asks
  `Veritas.Authn` for a Principal and gets one.

  ## What the port covers

    * `authenticate/2` — a credential becomes a Principal, or is refused.
    * `create_account/3` and `set_password/4` — the operator's path to a
      local account. An Adapter that has no local accounts refuses them with
      `:unsupported` rather than pretending.
    * `establish_session/3`, `resolve_session/3`, `rotate_session/3` and
      `revoke_session/3` — the session lifecycle.

  ## The shipped Adapter

  `Veritas.Authn.Local` is the local-accounts implementation: Argon2id
  password hashes (`docs/09` §3), a breached-password check at set-time, and
  server-side sessions.

  ## The corpus's federated identity is not here yet

  `docs/09` §3 and §4 specify OIDC, SAML, LDAP and SCIM in full, and
  `docs/16` ADR-017 makes Veritas OIDC-first with local accounts as the
  documented fallback. **None of the federated providers are implemented.**
  The port is shaped so that adding one is an Adapter and a configuration
  change rather than a change to the domain — but until an Adapter exists,
  a deployment has local accounts and nothing else, and the product says so
  rather than implying otherwise.
  """

  alias Veritas.Core.{Principal, Session}

  @typedoc "A Workspace identifier."
  @type workspace :: String.t()

  @typedoc "A credential, in whatever form the Adapter understands."
  @type credentials :: map()

  @typedoc "Why an authentication was refused."
  @type refusal ::
          :invalid_credentials
          | :account_disabled
          | :account_missing
          | :unsupported
          | term()

  @default_adapter Veritas.Authn.Local

  @doc """
  The Adapter currently installed.

  The identity provider is a **Default**: this behaviour is the contract, and
  the shipped Adapter is one implementation of it. A substitution is a
  configuration change, not a fork.
  """
  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:veritas_core, :authn) do
      {module, _options} when is_atom(module) -> module
      %{adapter: module} when is_atom(module) -> module
      module when is_atom(module) and not is_nil(module) -> module
      _ -> @default_adapter
    end
  end

  @doc """
  Points the system at a different Adapter.
  """
  @spec configure(module() | {module(), keyword()}) :: :ok
  def configure({module, options}) when is_atom(module) and is_list(options) do
    Application.put_env(:veritas_core, :authn, {module, options})
    :ok
  end

  def configure(module) when is_atom(module) do
    Application.put_env(:veritas_core, :authn, module)
    :ok
  end

  @doc "See `Veritas.Authn.authenticate/2`."
  @spec authenticate(workspace(), credentials()) ::
          {:ok, Principal.t()} | {:error, refusal()}
  def authenticate(workspace, credentials) do
    adapter().authenticate(workspace, credentials)
  end

  @doc "See `Veritas.Authn.create_account/3`."
  @spec create_account(workspace(), map(), keyword()) ::
          {:ok, Principal.t()} | {:error, refusal()}
  def create_account(workspace, attrs, opts \\ []) do
    adapter().create_account(workspace, attrs, opts)
  end

  @doc "See `Veritas.Authn.create_principal/3`."
  @spec create_principal(workspace(), map(), keyword()) ::
          {:ok, Principal.t()} | {:error, refusal()}
  def create_principal(workspace, attrs, opts \\ []) do
    adapter().create_principal(workspace, attrs, opts)
  end

  @doc "See `Veritas.Authn.set_password/4`."
  @spec set_password(workspace(), String.t(), String.t(), keyword()) ::
          {:ok, Principal.t()} | {:error, refusal()}
  def set_password(workspace, account_id, password, opts \\ []) do
    adapter().set_password(workspace, account_id, password, opts)
  end

  @doc "See `Veritas.Authn.establish_session/3`."
  @spec establish_session(workspace(), Principal.t(), keyword()) ::
          {:ok, Session.t()} | {:error, refusal()}
  def establish_session(workspace, principal, opts \\ []) do
    adapter().establish_session(workspace, principal, opts)
  end

  @doc "See `Veritas.Authn.resolve_session/3`."
  @spec resolve_session(workspace(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, refusal()}
  def resolve_session(workspace, token, opts \\ []) do
    adapter().resolve_session(workspace, token, opts)
  end

  @doc "See `Veritas.Authn.resolve_scope/3`."
  @spec resolve_scope(workspace(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, refusal()}
  def resolve_scope(workspace, token, opts \\ []) do
    adapter().resolve_scope(workspace, token, opts)
  end

  @doc "See `Veritas.Authn.rotate_session/3`."
  @spec rotate_session(workspace(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, refusal()}
  def rotate_session(workspace, token, opts \\ []) do
    adapter().rotate_session(workspace, token, opts)
  end

  @doc "See `Veritas.Authn.revoke_session/3`."
  @spec revoke_session(workspace(), String.t(), keyword()) :: :ok | {:error, refusal()}
  def revoke_session(workspace, token, opts \\ []) do
    adapter().revoke_session(workspace, token, opts)
  end

  @doc """
  The id of the account with an email address.

  A lookup, not an authority: it returns the account's **id** and nothing
  else — no Principal, no session, no credential. An operator knows the
  email; the store knows the id.
  """
  @spec account_id(workspace(), String.t()) :: {:ok, String.t()} | {:error, refusal()}
  def account_id(workspace, email) do
    adapter().account_id(workspace, email)
  end

  @doc """
  The accounts of a Workspace.

  An account is a person who may sign in: its identity, its roles and whether
  it is disabled. **No credential is ever returned** — the password hash is
  not in the result, so there is nothing for a screen, a log or an export to
  leak.
  """
  @spec list_accounts(workspace(), keyword()) :: {:ok, [map()]} | {:error, refusal()}
  def list_accounts(workspace, opts \\ []) do
    adapter().list_accounts(workspace, opts)
  end

  @doc """
  Changes an account's roles, or disables it.

  Two things are true of this and the second is why it is here rather than in
  the screen:

    * the change is written to the Audit Log, because a role is a permission
      and a permission that changed is an event;
    * the change takes effect on the **next request**, not on the next sign-in
      — the open sessions of the account are brought up to date in the same
      transaction, so a revoked role is gone from the very next request the
      account makes.

  Disabling is not deleting. The account stays, because the Audit Log refers
  to it, and a deleted identity cannot be referred to.
  """
  @spec update_account(workspace(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def update_account(workspace, account_id, attrs, opts \\ []) do
    adapter().update_account(workspace, account_id, attrs, opts)
  end

  # ── the behaviour ──────────────────────────────────────────────────────────

  @doc """
  Turns a credential into a Principal.

  A refused credential is a refusal with a reason, never an empty Principal.
  """
  @callback authenticate(workspace(), credentials()) ::
              {:ok, Principal.t()} | {:error, refusal()}

  @doc """
  Creates a local account.

  An Adapter with no local accounts refuses this with `:unsupported`.
  """
  @callback create_account(workspace(), map(), keyword()) ::
              {:ok, Principal.t()} | {:error, refusal()}

  @doc """
  Records a Principal for a person Veritas does **not** own.

  An external subject — somebody in the company's directory — maps to a
  Veritas Principal (`docs/09` §4's linkage). The Principal holds
  **Veritas's grants** over that person; the person holds the account, in the
  directory. So the record Veritas keeps carries **no password**: it cannot
  be signed into, and it is not a second account.

  It is the same row an account is — the corpus's Principal record — with the
  credential left out. An Adapter with no local accounts refuses this with
  `:unsupported`.
  """
  @callback create_principal(workspace(), map(), keyword()) ::
              {:ok, Principal.t()} | {:error, refusal()}

  @doc """
  Sets or resets the credential of an account.

  The corpus has no self-service reset: the operator resets on the Node, and
  the reset is written to the Audit Log.
  """
  @callback set_password(workspace(), String.t(), String.t(), keyword()) ::
              {:ok, Principal.t()} | {:error, refusal()}

  @doc """
  Issues a session for a Principal.
  """
  @callback establish_session(workspace(), Principal.t(), keyword()) ::
              {:ok, Session.t()} | {:error, refusal()}

  @doc """
  Resolves a session token into a live session.
  """
  @callback resolve_session(workspace(), String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, refusal()}

  @doc """
  Resolves a scope-bound token — the one the LiveView socket carries — into a
  live session.
  """
  @callback resolve_scope(workspace(), String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, refusal()}

  @doc """
  Rotates a session's token.
  """
  @callback rotate_session(workspace(), String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, refusal()}

  @doc """
  Ends a session.
  """
  @callback revoke_session(workspace(), String.t(), keyword()) :: :ok | {:error, refusal()}

  @doc """
  The id of the account with an email address.

  A lookup, not an authority.
  """
  @callback account_id(workspace(), String.t()) :: {:ok, String.t()} | {:error, refusal()}

  @doc """
  The accounts of a Workspace, without their credentials.
  """
  @callback list_accounts(workspace(), keyword()) :: {:ok, [map()]} | {:error, refusal()}

  @doc """
  Changes an account's roles, or disables it.
  """
  @callback update_account(workspace(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, refusal()}
end
