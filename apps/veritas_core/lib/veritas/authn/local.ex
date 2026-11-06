defmodule Veritas.Authn.Local do
  @moduledoc """
  The local-accounts Adapter.

  `docs/09` §3: *"Local accounts are always present. They are the
  break-glass path and the home-lab default, never optional."* This is that
  path.

  ## The password hash

  Argon2id, with the corpus's floor of **`m=64 MiB, t=3, p=1`**.

  The `argon2_elixir` library expresses the memory cost as the **base-2
  logarithm of the cost in kibibytes**, so 64 MiB is `m_cost: 16` and not
  `m_cost: 65_536`. The distinction is not cosmetic: `m_cost: 65_536`
  computes `1 << 65_536`, which overflows to zero, and the C library refuses
  it with *"Memory cost is too small"*. The parameters below are therefore
  the library's, and the encoded hash they produce says
  `$argon2id$v=19$m=65536,t=3,p=1$` — which is the corpus's numbers.

  The floor is a floor. An operator may raise the cost; nothing may lower it
  below what the corpus fixes, because a deployment that quietly chose a
  weaker hash would be a deployment the corpus does not describe.

  ## The breached-password check

  At set-time, through `Veritas.Authn.Local.Breach`.

  ## The timing of a refusal

  An account that does not exist is refused in the same time as one whose
  password is wrong: the hash is verified against a dummy value either way.
  A sign-in that says *"no such account"* to one caller and *"wrong
  password"* to another is an account-enumeration oracle, and the Audit Log
  is where that difference belongs — not the response.
  """

  @behaviour Veritas.Authn

  alias Veritas.Authn.Local.Breach
  alias Veritas.Core.{Audit, Policy, Principal, Session, WorkspaceLock}
  alias Veritas.Store

  # The corpus's floor: `m=64 MiB, t=3, p=1`.
  #
  # `m_cost` is the base-2 logarithm of the memory cost in kibibytes, so 16
  # is 64 MiB. `t_cost` is the time cost (iterations) and `parallelism` is
  # the degree of parallelism.
  @floor_m_cost 16
  @floor_t_cost 3
  @floor_p_cost 1

  # A hash of a value nobody has, used to keep the timing of a refused
  # sign-in the same as the timing of a wrong password. It is a real
  # Argon2id hash at the corpus's parameters, so verifying against it costs
  # what verifying against a real password costs.
  @dummy_hash "$argon2id$v=19$m=65536,t=3,p=1$MVuvUN8Wbeejvb1BiAQf2A$0Z9RWM5KGrFvC9WQMjFJKiMp/qPSApIqjm/LRKZOfac"

  @impl Veritas.Authn
  def authenticate(workspace, credentials) when is_binary(workspace) and is_map(credentials) do
    email = normalise_email(credentials[:email] || credentials["email"])
    password = credentials[:password] || credentials["password"]

    cond do
      not is_binary(email) or email == "" ->
        refuse(workspace, "the sign-in named no account")

      not is_binary(password) or password == "" ->
        refuse(workspace, "the sign-in carried no credential")

      true ->
        do_authenticate(workspace, email, password)
    end
  end

  defp do_authenticate(workspace, email, password) do
    case find_account(workspace, email) do
      {:ok, nil} ->
        # Verify against a dummy hash so that the time taken to refuse an
        # unknown account is the time taken to refuse a wrong password.
        Argon2.verify_pass(password, @dummy_hash)
        refuse(workspace, "the sign-in named an account that does not exist")

      {:ok, account} ->
        verify(account, password, workspace)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify(account, password, workspace) do
    hash = account["password_hash"]

    cond do
      is_nil(hash) or hash == "" ->
        # An account with no password is an account that cannot be signed
        # into — it exists for the corpus's other purposes.
        Argon2.verify_pass(password, @dummy_hash)
        refuse(workspace, "the account carries no password")

      not Argon2.verify_pass(password, hash) ->
        refuse(workspace, "the credential was refused")

      account["disabled"] == true ->
        refuse(workspace, "the account is disabled")

      true ->
        {:ok,
         Principal.new(account["id"], workspace, account["roles"] || [],
           kind: kind_of(account),
           display_name: account["display_name"]
         )}
    end
  end

  @impl Veritas.Authn
  def create_account(workspace, attrs, opts \\ [])
      when is_binary(workspace) and is_map(attrs) do
    email = normalise_email(attrs[:email] || attrs["email"])
    password = attrs[:password] || attrs["password"]
    roles = attrs[:roles] || attrs["roles"] || []
    display_name = attrs[:display_name] || attrs["display_name"] || email
    id = attrs[:id] || attrs["id"] || account_id()

    with :ok <- validate_email(email),
         :ok <- validate_password(password),
         {:ok, hash} <- hash_password(password),
         :ok <- ensure_absent(workspace, email) do
      row = %{
        "id" => id,
        "email" => email,
        "display_name" => display_name,
        "disabled" => false,
        "roles" => Enum.map(roles, &role_string/1),
        "workspace" => workspace,
        "password_hash" => hash,
        "password_changed_at" => DateTime.utc_now()
      }

      result =
        WorkspaceLock.with_lock(workspace, fn ->
          Store.transaction(workspace, fn tx ->
            with {:ok, stored} <- Store.put(tx, :user, row),
                 {:ok, _sequence} <-
                   Audit.append(tx, workspace, %{
                     subject: stored["id"],
                     subject_table: "user",
                     from_state: nil,
                     to_state: "active",
                     actor: %{type: "operator", id: opts[:actor_id] || "local"},
                     reason: opts[:reason] || "the account was created",
                     correlation_id: opts[:correlation_id],
                     diff: %{
                       "account" => stored["id"],
                       "workspace" => workspace,
                       "profile" => Policy.profile_name()
                     }
                   }) do
              {:ok, stored}
            end
          end)
        end)

      case result do
        {:ok, stored} ->
          {:ok,
           Principal.new(stored["id"], workspace, stored["roles"] || [],
             kind: kind_of(stored),
             display_name: stored["display_name"]
           )}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl Veritas.Authn
  def create_principal(workspace, attrs, opts \\ [])
      when is_binary(workspace) and is_map(attrs) do
    email = normalise_email(attrs[:email] || attrs["email"])
    roles = attrs[:roles] || attrs["roles"] || []
    display_name = attrs[:display_name] || attrs["display_name"] || email
    id = attrs[:id] || attrs["id"] || account_id()

    with :ok <- validate_email(email),
         :ok <- ensure_absent(workspace, email) do
      # **No password hash.** The person holds the account, in the directory;
      # Veritas holds the grants. A row with no hash cannot be signed into,
      # and it is not a second account — it is the Principal the corpus's
      # linkage says an external subject maps to.
      row = %{
        "id" => id,
        "email" => email,
        "display_name" => display_name,
        "disabled" => false,
        "roles" => Enum.map(roles, &role_string/1),
        "workspace" => workspace,
        "password_hash" => nil,
        "password_changed_at" => nil
      }

      result =
        WorkspaceLock.with_lock(workspace, fn ->
          Store.transaction(workspace, fn tx ->
            with {:ok, stored} <- Store.put(tx, :user, row),
                 {:ok, _sequence} <-
                   Audit.append(tx, workspace, %{
                     subject: stored["id"],
                     subject_table: "user",
                     from_state: nil,
                     to_state: "active",
                     actor: %{type: "operator", id: opts[:actor_id] || "local"},
                     reason: opts[:reason] || "a principal was recorded for an external subject",
                     correlation_id: opts[:correlation_id],
                     diff:
                       %{
                         "account" => stored["id"],
                         "workspace" => workspace,
                         "external_subject" =>
                           attrs[:external_subject] || attrs["external_subject"],
                         "profile" => Policy.profile_name()
                       }
                       |> without_nils()
                   }) do
              {:ok, stored}
            end
          end)
        end)

      case result do
        {:ok, stored} ->
          {:ok,
           Principal.new(stored["id"], workspace, stored["roles"] || [],
             kind: kind_of(stored),
             display_name: stored["display_name"]
           )}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl Veritas.Authn
  def set_password(workspace, account_id, password, opts \\ [])
      when is_binary(workspace) and is_binary(account_id) and is_binary(password) do
    with :ok <- validate_password(password),
         {:ok, hash} <- hash_password(password),
         {:ok, account} <- fetch_account(workspace, account_id) do
      updated =
        Map.merge(account, %{
          "password_hash" => hash,
          "password_changed_at" => DateTime.utc_now()
        })

      result =
        WorkspaceLock.with_lock(workspace, fn ->
          Store.transaction(workspace, fn tx ->
            with {:ok, stored} <- Store.put(tx, :user, updated),
                 {:ok, _sequence} <-
                   Audit.append(tx, workspace, %{
                     subject: account_id,
                     subject_table: "user",
                     from_state: "active",
                     to_state: "active",
                     actor: %{type: "operator", id: opts[:actor_id] || "local"},
                     reason: opts[:reason] || "the password was set by the operator",
                     correlation_id: opts[:correlation_id],
                     diff: %{
                       "account" => account_id,
                       "workspace" => workspace,
                       "profile" => Policy.profile_name()
                     }
                   }) do
              {:ok, stored}
            end
          end)
        end)

      case result do
        {:ok, stored} ->
          # A password change ends the sessions that were issued under the
          # old credential. The corpus asks for a rotation on a privilege
          # change; ending them is the stronger form of the same rule.
          {:ok, _ended} =
            Session.revoke_all(workspace, account_id,
              reason: opts[:reason] || "the password was changed by the operator"
            )

          {:ok,
           Principal.new(stored["id"], workspace, stored["roles"] || [],
             kind: kind_of(stored),
             display_name: stored["display_name"]
           )}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl Veritas.Authn
  def establish_session(workspace, %Principal{} = principal, opts \\ []) do
    Session.start(principal, Keyword.put(opts, :workspace, workspace))
  end

  @impl Veritas.Authn
  def resolve_session(workspace, token, opts \\ []) do
    Session.resolve(token, workspace, opts)
  end

  @impl Veritas.Authn
  def resolve_scope(workspace, token, opts \\ []) do
    Session.resolve_scope(token, workspace, opts)
  end

  @impl Veritas.Authn
  def rotate_session(workspace, token, opts \\ []) do
    Session.rotate(token, workspace, opts)
  end

  @impl Veritas.Authn
  def revoke_session(workspace, token, opts \\ []) do
    Session.revoke(token, workspace, opts)
  end

  @impl Veritas.Authn
  def account_id(workspace, email) when is_binary(workspace) and is_binary(email) do
    case find_account(workspace, normalise_email(email)) do
      {:ok, nil} -> {:error, :account_missing}
      {:ok, account} -> {:ok, account["id"]}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Authn
  def list_accounts(workspace, opts \\ []) when is_binary(workspace) do
    limit = Keyword.get(opts, :limit, 200)

    case Store.transaction(workspace, fn tx ->
           Store.list(tx, :user, %{where: [], limit: limit})
         end) do
      {:ok, rows} -> {:ok, rows |> Enum.map(&public_account/1) |> Enum.sort_by(&account_email/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veritas.Authn
  def update_account(workspace, account_id, attrs, opts \\ [])
      when is_binary(workspace) and is_binary(account_id) and is_map(attrs) do
    with {:ok, account} <- fetch_account(workspace, account_id) do
      updated =
        account
        |> put_roles(attrs)
        |> put_disabled(attrs)

      result =
        WorkspaceLock.with_lock(workspace, fn ->
          Store.transaction(workspace, fn tx ->
            with {:ok, stored} <- Store.put(tx, :user, updated),
                 {:ok, _audit} <-
                   Audit.append(tx, workspace, %{
                     subject: account_id,
                     subject_table: "user",
                     from_state: account_state(account),
                     to_state: account_state(stored),
                     actor: %{type: "operator", id: opts[:actor_id] || "local"},
                     reason: opts[:reason] || "the account's roles were changed by the operator",
                     correlation_id: opts[:correlation_id],
                     diff: %{
                       "account" => account_id,
                       "roles" => stored["roles"],
                       "disabled" => stored["disabled"],
                       "profile" => Policy.profile_name()
                     }
                   }) do
              {:ok, stored}
            end
          end)
        end)

      case result do
        {:ok, stored} ->
          # A privilege change ends the sessions that were issued under the old
          # one, the same rule a password change follows. The change therefore
          # bites on the account's **next request**, not at its next sign-in.
          if privilege_changed?(account, stored) do
            {:ok, _ended} =
              Session.revoke_all(workspace, account_id,
                reason: opts[:reason] || "the account's privileges changed"
              )
          end

          {:ok, public_account(stored)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Hashes a password with Argon2id at the corpus's floor.

  The hash is the PHC string, so the parameters travel with it: a hash
  written under a stronger setting verifies under a weaker one, and the
  stored hash is therefore self-describing.
  """
  @spec hash_password(String.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_password(password) when is_binary(password) do
    {:ok, Argon2.hash_pwd_salt(password, argon2_options())}
  rescue
    error -> {:error, {:hash_failed, Exception.message(error)}}
  end

  @doc """
  Verifies a password against a stored Argon2id hash.
  """
  @spec verify_password(String.t(), String.t() | nil) :: boolean()
  def verify_password(password, hash) when is_binary(password) and is_binary(hash) do
    Argon2.verify_pass(password, hash)
  rescue
    _ -> false
  end

  def verify_password(_password, _hash), do: false

  @doc """
  The Argon2id parameters in force, as the encoded hash states them.
  """
  @spec parameters() :: %{
          t_cost: pos_integer(),
          m_cost: non_neg_integer(),
          parallelism: pos_integer()
        }
  def parameters do
    %{t_cost: @floor_t_cost, m_cost: @floor_m_cost, parallelism: @floor_p_cost}
  end

  # ── the accounts ───────────────────────────────────────────────────────────

  defp find_account(workspace, email) do
    case Store.transaction(workspace, fn tx ->
           Store.list(tx, :user, %{where: [email: email], limit: 1})
         end) do
      {:ok, [%{} = account | _]} -> {:ok, account}
      {:ok, _rows} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_account(workspace, account_id) do
    case Store.transaction(workspace, fn tx -> Store.fetch(tx, :user, account_id) end) do
      {:ok, nil} -> {:error, :account_missing}
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_absent(workspace, email) do
    case find_account(workspace, email) do
      {:ok, nil} -> :ok
      {:ok, _account} -> {:error, :account_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_email(nil), do: {:error, :invalid_email}
  defp validate_email(""), do: {:error, :invalid_email}

  defp validate_email(email) do
    if String.contains?(email, "@") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_password(nil), do: {:error, :password_required}
  defp validate_password(""), do: {:error, :password_required}

  defp validate_password(password) do
    case Breach.breached?(password) do
      {:ok, true} ->
        {:error, :password_breached}

      {:ok, false} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A refusal is recorded and then reported. The recorded reason is the
  # specific one; the reason the caller is told is the general one, so the
  # response cannot be used to find out which accounts exist.
  defp refuse(workspace, reason) do
    Session.record_refusal(workspace, reason)
    {:error, :invalid_credentials}
  end

  # ── the small helpers ──────────────────────────────────────────────────────

  # An account without its credential. The password hash is not in the result,
  # so nothing that renders an account can leak one.
  defp public_account(account) do
    Map.drop(account, ["password_hash", "password_changed_at"])
  end

  # A diff with a `nil` in it is not written with one.
  #
  # The store does not agree on a null field — one engine keeps it, one drops
  # it — so a diff that carried a null would hash a value the store cannot
  # reproduce, and the row would not verify when it was read back. A field
  # that is not set is simply not in the diff.
  defp without_nils(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp account_email(account), do: account["email"] || ""

  defp put_roles(account, attrs) do
    case attrs[:roles] || attrs["roles"] do
      nil -> account
      roles when is_list(roles) -> Map.put(account, "roles", Enum.map(roles, &role_string/1))
      _ -> account
    end
  end

  defp put_disabled(account, attrs) do
    case attrs[:disabled] || attrs["disabled"] do
      nil -> account
      disabled -> Map.put(account, "disabled", disabled == true or disabled == "true")
    end
  end

  defp account_state(account), do: if(account["disabled"] == true, do: "disabled", else: "active")

  defp privilege_changed?(account, updated) do
    account["roles"] != updated["roles"] or account["disabled"] != updated["disabled"]
  end

  defp normalise_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalise_email(_email), do: nil

  defp role_string(role) when is_binary(role) do
    case Principal.known_role(role) do
      nil -> role
      known -> Principal.role_name(known)
    end
  end

  defp role_string(role), do: to_string(role)

  defp kind_of(account) do
    case account["kind"] do
      "agentic" -> :agentic
      "service" -> :service
      "system" -> :system
      _ -> :human
    end
  end

  defp account_id do
    "u_" <> (12 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  # The floor is a floor: an operator may raise the cost, never lower it.
  defp argon2_options do
    configured = Application.get_env(:veritas_core, :argon2, [])

    t_cost = max(Keyword.get(configured, :t_cost, @floor_t_cost), @floor_t_cost)
    m_cost = max(Keyword.get(configured, :m_cost, @floor_m_cost), @floor_m_cost)
    parallelism = max(Keyword.get(configured, :parallelism, @floor_p_cost), @floor_p_cost)

    [t_cost: t_cost, m_cost: m_cost, parallelism: parallelism]
  end
end
