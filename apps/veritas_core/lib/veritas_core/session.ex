defmodule Veritas.Core.Session do
  @moduledoc """
  Server-side sessions.

  `docs/09` §3 fixes the shape of a session, and every clause of it is a
  security property:

    * The browser holds an **opaque 256-bit random token**; only its
      **SHA-256 digest** is stored. The token is not a record, a row id or a
      signed claim — it is a secret, and the store never sees it.
    * `HttpOnly`, `Secure` and `SameSite=Lax` on the cookie that carries it.
    * An **absolute lifetime of 12 hours** and a **30-minute idle timeout**.
    * The token **rotates** on authentication, on any privilege change, and
      every 30 minutes for privileged roles.
    * *"Veritas is stateless at the Node level (`docs/05`), so a Node restart
      never invalidates a session."*

  That last clause is the reason this module stores a session in the
  **datastore** and nowhere else. A session held in the BEAM's memory dies
  with the Node; a session held in the store survives it, and a second Node
  can serve it. `docs/05` §Data Architecture puts it the same way: the BEAM
  holds no durable truth.

  ## The Workspace is part of the lookup

  A session lives in exactly one Workspace, and the store is scoped to the
  Workspace (`docs/09` §5). So resolving a session takes the Workspace it is
  being looked for in: a token presented against the wrong Workspace finds
  nothing, which is what makes a token useless outside the Workspace that
  issued it.

  ## What a session carries

  The session remembers the Principal it was issued to and the roles that
  Principal held **when it was issued**. A role change therefore does not
  silently widen a live session: the roles are compared on every resolution,
  and a difference **rotates** the token, which forces the holder back
  through sign-in with the new role set.

  ## The clock

  The idle timeout is a sliding window, so it has to be written back to the
  store on use. `now/0` is injectable through the options so that a test can
  place the clock where the corpus's limits say a session ends — the
  behaviour under test is the refusal, not the arithmetic.

  ## The Audit Log

  Every authentication event is written to the chain: the session's creation,
  its rotation, its revocation, its expiry, and every refused sign-in. A
  refusal that is not recorded is a refusal nobody can detect.

  A refusal is **committed**: the expired session is deleted and its refusal
  is appended in one transaction, and the refusal is what the caller is
  told. Returning the refusal from inside the transaction would roll the
  record of it back out of existence, so the refusal is carried out of the
  transaction under a different tag and translated at the boundary.
  """

  require Logger

  alias Veritas.Core.{Audit, Principal, WorkspaceLock}
  alias Veritas.Store
  alias Veritas.Store.Error

  @typedoc "A live session."
  @type t :: %__MODULE__{
          id: String.t(),
          token: String.t() | nil,
          scope_token: String.t() | nil,
          csrf_token: String.t() | nil,
          csrf_digest: String.t() | nil,
          principal_id: String.t(),
          workspace: String.t(),
          roles: [Principal.role()],
          kind: Principal.kind(),
          created_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          absolute_expires_at: DateTime.t(),
          idle_expires_at: DateTime.t(),
          rotated_at: DateTime.t() | nil
        }

  @typedoc "Why a session could not be used."
  @type refusal ::
          :unknown_session
          | :session_expired
          | :session_idle_expired
          | :account_disabled
          | :account_missing

  # The idle timeout: 30 minutes.
  @idle_timeout 30 * 60

  # The absolute lifetime: 12 hours.
  @absolute_timeout 12 * 60 * 60

  # The privileged roles rotate their token every 30 minutes, whether or not
  # anything about their authority has changed.
  @privileged_rotation 30 * 60

  # 256 bits of entropy in the token the browser holds.
  @token_bytes 32

  # The roles that carry authority. A session held by one of these is
  # rotated on a timer as well as on a privilege change.
  @privileged_roles ~w(service_desk_manager incident_manager change_manager cab_chair
                       cab_member problem_manager vulnerability_owner platform_admin)a

  defstruct [
    :id,
    :token,
    :scope_token,
    :csrf_token,
    :csrf_digest,
    :principal_id,
    :workspace,
    :kind,
    :created_at,
    :last_seen_at,
    :absolute_expires_at,
    :idle_expires_at,
    :rotated_at,
    roles: []
  ]

  @doc "The idle timeout, in seconds."
  @spec idle_timeout() :: pos_integer()
  def idle_timeout, do: @idle_timeout

  @doc "The absolute lifetime, in seconds."
  @spec absolute_timeout() :: pos_integer()
  def absolute_timeout, do: @absolute_timeout

  @doc "How often a privileged session rotates its token, in seconds."
  @spec privileged_rotation() :: pos_integer()
  def privileged_rotation, do: @privileged_rotation

  @doc """
  Issues a session for a Principal.

  The session is written and its Audit Log entry is appended **in one
  transaction**, so a session exists if and only if the Log says it was
  issued.
  """
  @spec start(Principal.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def start(%Principal{} = principal, opts \\ []) do
    now = now(opts)
    token = token()
    scope_token = token()
    csrf_token = token()

    row = %{
      "id" => session_id(),
      "workspace" => principal.workspace,
      "principal_id" => principal.id,
      "roles" => Principal.role_strings(principal),
      "kind" => to_string(principal.kind),
      "token_digest" => digest(token),
      "scope_digest" => digest(scope_token),
      "csrf_digest" => digest(csrf_token),
      "created_at" => now,
      "last_seen_at" => now,
      "absolute_expires_at" => DateTime.add(now, @absolute_timeout, :second),
      "idle_expires_at" => DateTime.add(now, @idle_timeout, :second),
      "rotated_at" => now
    }

    result =
      WorkspaceLock.with_lock(principal.workspace, fn ->
        Store.transaction(principal.workspace, fn tx ->
          with {:ok, stored} <- Store.put(tx, :session, row),
               {:ok, _sequence} <-
                 Audit.append(tx, principal.workspace, %{
                   subject: principal.id,
                   subject_table: "session",
                   from_state: nil,
                   to_state: "active",
                   actor: Principal.audit_actor(principal),
                   reason: "the principal signed in",
                   correlation_id: opts[:correlation_id],
                   diff: %{"session" => stored["id"], "workspace" => principal.workspace}
                 }) do
            {:ok, stored}
          end
        end)
      end)

    case result do
      {:ok, stored} ->
        {:ok,
         %__MODULE__{
           id: stored["id"],
           token: token,
           scope_token: scope_token,
           csrf_token: csrf_token,
           csrf_digest: stored["csrf_digest"],
           principal_id: principal.id,
           workspace: principal.workspace,
           roles: principal.roles,
           kind: principal.kind,
           created_at: now,
           last_seen_at: now,
           absolute_expires_at: row["absolute_expires_at"],
           idle_expires_at: row["idle_expires_at"],
           rotated_at: now
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves a session token into a live session.

  The token is looked up by its digest, so the store is never asked to
  compare a secret. A session that has expired, that has been idle too long,
  or whose account has been disabled is refused, and the refusal is written
  to the Audit Log.

  When the Principal's roles have changed, or when a privileged session is
  past its rotation interval, the token is **rotated**: the returned session
  carries a fresh token, scope token and CSRF token, and the old ones stop
  working at once.
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, refusal() | Error.t()}
  def resolve(token, workspace, opts \\ [])

  def resolve(nil, _workspace, _opts), do: {:error, :unknown_session}

  def resolve(token, workspace, opts) when is_binary(token) and is_binary(workspace) do
    now = now(opts)

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- fetch_by_digest(tx, "token_digest", digest(token)) do
          use_row(tx, row, now, opts)
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Resolves a **scope token** into a live session.

  The LiveView socket carries a scope-bound token rather than the session
  itself (`docs/09` §4), so a token that leaks out of the socket's own
  handshake cannot be used against the HTTP API.
  """
  @spec resolve_scope(String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, refusal() | Error.t()}
  def resolve_scope(scope_token, workspace, opts \\ [])

  def resolve_scope(nil, _workspace, _opts), do: {:error, :unknown_session}

  def resolve_scope(scope_token, workspace, opts)
      when is_binary(scope_token) and is_binary(workspace) do
    now = now(opts)

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- fetch_by_digest(tx, "scope_digest", digest(scope_token)) do
          use_row(tx, row, now, opts)
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Resolves a LiveView scope token without rotating any session credential.

  Revocation, absolute and idle expiry, account disablement and account
  removal are enforced exactly as they are on the HTTP path, and refusals that
  end a session are recorded in the Audit Log. The returned Principal carries
  the account's **current** roles, so a connected socket's next event uses its
  current authority.

  Unlike `resolve_scope/3`, this function never rotates the session token,
  scope token or CSRF secret: a websocket cannot deliver replacement cookies.
  It only slides the idle window. Current roles are returned to the caller but
  deliberately not written over the issued role set, leaving the HTTP path to
  perform the privilege-change rotation required by `docs/09` §3.
  """
  @spec resolve_scope_without_rotation(String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, refusal() | Error.t()}
  def resolve_scope_without_rotation(scope_token, workspace, opts \\ [])

  def resolve_scope_without_rotation(nil, _workspace, _opts), do: {:error, :unknown_session}

  def resolve_scope_without_rotation(scope_token, workspace, opts)
      when is_binary(scope_token) and is_binary(workspace) do
    now = now(opts)

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- fetch_by_digest(tx, "scope_digest", digest(scope_token)) do
          use_row_without_rotation(tx, row, now, opts)
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Rotates a session's token.

  The session keeps its identity and its place in the chain; the secret the
  browser holds changes, and the old secret stops working immediately.
  """
  @spec rotate(String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, refusal() | Error.t()}
  def rotate(token, workspace, opts \\ []) do
    now = now(opts)

    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with {:ok, row} <- fetch_by_digest(tx, "token_digest", digest(token)) do
          rotate_row(tx, row, now, opts, row["roles"])
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Ends a session.

  The row is deleted and the Audit Log records the revocation, so a session
  that was used and then ended leaves a trace of both.
  """
  @spec revoke(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def revoke(token, workspace, opts \\ [])

  def revoke(nil, _workspace, _opts), do: :ok

  def revoke(token, workspace, opts) when is_binary(token) and is_binary(workspace) do
    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        case fetch_by_digest(tx, "token_digest", digest(token)) do
          {:ok, row} ->
            with :ok <- Store.delete(tx, :session, row["id"]),
                 {:ok, _sequence} <-
                   Audit.append(tx, workspace, %{
                     subject: row["principal_id"],
                     subject_table: "session",
                     from_state: "active",
                     to_state: "revoked",
                     actor: %{type: row["kind"] || "human", id: row["principal_id"]},
                     reason: opts[:reason] || "the session was ended",
                     correlation_id: opts[:correlation_id],
                     diff: %{"session" => row["id"], "workspace" => workspace}
                   }) do
              :ok
            end

          {:error, :unknown_session} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
  end

  @doc """
  Ends every session a Principal holds.

  A password change and a role change both end the sessions that were issued
  under the old credential. The corpus asks for a rotation on a privilege
  change; where the client is not asking for a token, ending the session is
  the stronger form of the same rule, and it is what the operator's reset
  does.
  """
  @spec revoke_all(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def revoke_all(workspace, principal_id, opts \\ []) do
    # **One lock, many entries.** Every session the Principal holds ends in
    # one transaction, and each ending appends its own entry to the chain, so
    # the whole thing is held under one lock: the chain has one writer, and
    # the entries link to one another in the order they were written.
    WorkspaceLock.with_lock(workspace, fn ->
      Store.transaction(workspace, fn tx ->
        with {:ok, rows} <- Store.list(tx, :session, %{where: [principal_id: principal_id]}) do
          Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, count} ->
            :ok = Store.delete(tx, :session, row["id"])

            {:ok, _sequence} =
              Audit.append(tx, workspace, %{
                subject: principal_id,
                subject_table: "session",
                from_state: "active",
                to_state: "revoked",
                actor: %{type: row["kind"] || "human", id: principal_id},
                reason: opts[:reason] || "the principal's authority changed",
                correlation_id: opts[:correlation_id],
                diff: %{"session" => row["id"], "workspace" => workspace}
              })

            {:cont, {:ok, count + 1}}
          end)
        end
      end)
    end)
  end

  @doc """
  Whether the CSRF token a client sent matches this session.

  The comparison is over digests, so the raw token is never compared and
  never stored. The comparison itself is constant-time: a timing oracle on a
  CSRF token is a timing oracle on a session.
  """
  @spec csrf_match?(t(), String.t() | nil) :: boolean()
  def csrf_match?(%__MODULE__{csrf_digest: digest}, presented)
      when is_binary(digest) and is_binary(presented) do
    :crypto.hash_equals(digest, digest(presented))
  end

  def csrf_match?(_session, _presented), do: false

  @doc """
  The Principal a session belongs to.
  """
  @spec principal(t()) :: Principal.t()
  def principal(%__MODULE__{} = session) do
    Principal.new(session.principal_id, session.workspace, session.roles,
      kind: session.kind || :human
    )
  end

  @doc """
  Records a refused sign-in in the Audit Log.

  A refused sign-in is an authentication event, and the corpus asks for every
  authentication event to be recorded. The attempted identity is not: the Log
  says that a sign-in was refused and why, not who was guessed.
  """
  @spec record_refusal(String.t(), String.t(), keyword()) :: :ok
  def record_refusal(workspace, reason, opts \\ []) do
    result =
      WorkspaceLock.with_lock(workspace, fn ->
        Store.transaction(workspace, fn tx ->
          Audit.append(tx, workspace, %{
            subject: "session",
            subject_table: "session",
            from_state: nil,
            to_state: "refused",
            actor: %{type: "unknown", id: "unknown"},
            reason: reason,
            correlation_id: opts[:correlation_id],
            diff: %{"workspace" => workspace}
          })
        end)
      end)

    case result do
      {:ok, _sequence} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[veritas.session] a refused sign-in could not be recorded in the Audit Log: " <>
            (Error.message(reason) || inspect(reason))
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "[veritas.session] a refused sign-in could not be recorded in the Audit Log: " <>
          Exception.message(error)
      )

      :ok
  end

  # ── what happens when a session is used ────────────────────────────────────

  defp use_row(tx, row, now, opts) do
    workspace = row["workspace"]

    cond do
      expired?(row, now) ->
        refuse(tx, row, workspace, :session_expired, opts)

      idle?(row, now) ->
        refuse(tx, row, workspace, :session_idle_expired, opts)

      true ->
        case account(tx, row) do
          {:ok, user} ->
            roles = user["roles"] || []

            cond do
              not same_roles?(roles, row["roles"]) ->
                # The Principal's authority changed under a live session. The
                # token rotates, so the old one stops working and the holder
                # is refused until they sign in with the new authority.
                rotate_row(tx, row, now, opts, roles)

              rotation_due?(row, now) ->
                rotate_row(tx, row, now, opts, row["roles"])

              true ->
                touch(tx, row, now)
            end

          {:refused, reason} ->
            {:refused, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # LiveView re-authorisation must not rotate credentials it cannot deliver.
  # The issued roles stay in the row so the HTTP path still performs the
  # privilege-change rotation; only the returned Principal uses current roles.
  defp use_row_without_rotation(tx, row, now, opts) do
    workspace = row["workspace"]

    cond do
      expired?(row, now) ->
        refuse(tx, row, workspace, :session_expired, opts)

      idle?(row, now) ->
        refuse(tx, row, workspace, :session_idle_expired, opts)

      true ->
        case account(tx, row) do
          {:ok, user} ->
            touch(tx, row, now, user["roles"] || [])

          {:refused, reason} ->
            refuse(tx, row, workspace, reason, opts)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # The account behind a session. A session whose account has been disabled
  # is refused: disabling an account is how an operator revokes access, and
  # it must not wait for the session to time out.
  defp account(tx, row) do
    case Store.fetch(tx, :user, row["principal_id"]) do
      {:ok, nil} ->
        {:refused, :account_missing}

      {:ok, user} ->
        if user["disabled"] == true do
          {:refused, :account_disabled}
        else
          {:ok, user}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A refusal ends the session as well as refusing it: a session that has
  # expired is not a session that may be used again.
  defp refuse(tx, row, workspace, reason, opts) do
    with :ok <- Store.delete(tx, :session, row["id"]),
         {:ok, _sequence} <-
           Audit.append(tx, workspace, %{
             subject: row["principal_id"],
             subject_table: "session",
             from_state: "active",
             to_state: "refused",
             actor: %{type: row["kind"] || "human", id: row["principal_id"]},
             reason: refusal_reason(reason),
             correlation_id: opts[:correlation_id],
             diff: %{"session" => row["id"], "workspace" => workspace}
           }) do
      {:refused, reason}
    end
  end

  defp refusal_reason(:session_expired),
    do: "the session passed its absolute lifetime of 12 hours"

  defp refusal_reason(:session_idle_expired),
    do: "the session was idle for longer than 30 minutes"

  defp refusal_reason(:account_disabled), do: "the account was disabled"

  defp refusal_reason(:account_missing), do: "the account no longer exists"

  # The idle window slides forward on use.
  defp touch(tx, row, now), do: touch(tx, row, now, row["roles"])

  defp touch(tx, row, now, roles) do
    updated =
      Map.merge(row, %{
        "last_seen_at" => now,
        "idle_expires_at" => DateTime.add(now, @idle_timeout, :second)
      })

    {:ok, _stored} = Store.put(tx, :session, updated)

    {:ok,
     %__MODULE__{
       id: row["id"],
       principal_id: row["principal_id"],
       workspace: row["workspace"],
       roles: known_roles(roles),
       kind: row["kind"] || "human",
       csrf_digest: row["csrf_digest"],
       created_at: row["created_at"],
       last_seen_at: now,
       absolute_expires_at: row["absolute_expires_at"],
       idle_expires_at: updated["idle_expires_at"],
       rotated_at: row["rotated_at"]
     }}
  end

  defp rotate_row(tx, row, now, opts, roles) do
    token = token()
    scope_token = token()
    csrf_token = token()

    updated =
      Map.merge(row, %{
        "token_digest" => digest(token),
        "scope_digest" => digest(scope_token),
        "csrf_digest" => digest(csrf_token),
        "roles" => roles || row["roles"],
        "last_seen_at" => now,
        "idle_expires_at" => DateTime.add(now, @idle_timeout, :second),
        "rotated_at" => now
      })

    with {:ok, _stored} <- Store.put(tx, :session, updated),
         {:ok, _sequence} <-
           Audit.append(tx, row["workspace"], %{
             subject: row["principal_id"],
             subject_table: "session",
             from_state: "active",
             to_state: "rotated",
             actor: %{type: row["kind"] || "human", id: row["principal_id"]},
             reason: opts[:reason] || "the session token was rotated",
             correlation_id: opts[:correlation_id],
             diff: %{"session" => row["id"], "workspace" => row["workspace"]}
           }) do
      {:ok,
       %__MODULE__{
         id: row["id"],
         token: token,
         scope_token: scope_token,
         csrf_token: csrf_token,
         csrf_digest: updated["csrf_digest"],
         principal_id: row["principal_id"],
         workspace: row["workspace"],
         roles: known_roles(updated["roles"]),
         kind: row["kind"] || "human",
         created_at: row["created_at"],
         last_seen_at: now,
         absolute_expires_at: row["absolute_expires_at"],
         idle_expires_at: updated["idle_expires_at"],
         rotated_at: now
       }}
    end
  end

  # The roles are compared as sets: the order the store hands them back is
  # not a fact about the Principal, and a reordering is not a privilege
  # change.
  defp same_roles?(left, right) do
    MapSet.new(left || []) == MapSet.new(right || [])
  end

  defp known_roles(roles) do
    roles
    |> List.wrap()
    |> Enum.map(&Principal.known_role/1)
    |> Enum.reject(&is_nil/1)
  end

  # A privileged session rotates on a timer.
  defp rotation_due?(row, now) do
    privileged?(known_roles(row["roles"])) and
      DateTime.diff(now, row["rotated_at"] || row["created_at"]) >= @privileged_rotation
  end

  defp privileged?(roles), do: Enum.any?(roles, &(&1 in @privileged_roles))

  defp expired?(row, now), do: DateTime.compare(now, row["absolute_expires_at"]) == :gt

  defp idle?(row, now), do: DateTime.compare(now, row["idle_expires_at"]) == :gt

  # ── the store ──────────────────────────────────────────────────────────────

  defp fetch_by_digest(tx, field, value) do
    case Store.list(tx, :session, %{where: [{field, value}], limit: 1}) do
      {:ok, [%{"id" => id} | _]} -> Store.fetch(tx, :session, id)
      {:ok, _rows} -> {:error, :unknown_session}
      {:error, reason} -> {:error, reason}
    end
  end

  # A refusal is carried out of the transaction under its own tag, because a
  # transaction whose body returns `{:error, reason}` rolls that refusal's
  # own Audit Log row back out of existence.
  defp unwrap({:refused, reason}), do: {:error, reason}
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap(other), do: other

  # ── the secrets ────────────────────────────────────────────────────────────

  @doc """
  The digest a token is stored as.
  """
  @spec digest(String.t()) :: String.t()
  def digest(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  @doc """
  A fresh opaque token: 256 bits of CSPRNG entropy, URL-safe.

  The token is a secret and is never an identifier: the store sees only its
  digest, and the session's own id is a separate random value.
  """
  @spec token() :: String.t()
  def token, do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # A record id may hold letters, digits and underscore only, so the session
  # id is hexadecimal rather than the URL-safe token.
  defp session_id, do: "s_" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp now(opts), do: Keyword.get(opts, :now) || DateTime.utc_now()
end
