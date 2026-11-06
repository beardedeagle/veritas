defmodule Veritas.Core.BootstrapToken do
  @moduledoc """
  The one-time bootstrap token, and where it lives.

  A bootstrap token is how the **first** account of a Workspace is created:
  there is no Principal to ask, because no account exists yet. The operator
  who owns the node is the authority, and the token is that authority made
  explicit.

  ## The token never reaches a terminal

  A token printed to a terminal is a token in the scrollback buffer, in the
  CI log — which is often archived and readable by anyone with access to the
  build — and on a screen nobody can unsee. A token passed as a command-line
  argument is a token every process on the machine can read while it runs.

  So the token is **written to a file** instead, at mode 0600 — readable only
  by its owner — and the command prints **the path**, never the token. The
  operator moves the token from that file into wherever they keep secrets: a
  password manager, a vault, a parameter store, a keychain.

  This is the same shape as the Audit Log's chain key, which already lives
  in a 0600 file and is never printed.

  ## The token's alphabet

  A token is 32 random bytes written as **hex**. The alphabet is not a
  detail: a token that can begin with `-` is a token that some shell, some
  option parser, or some person copying it into a command line will try to
  read as a flag. A base64url token begins with `-` one time in sixty-four,
  and a credential that is mistaken for an option is a credential that is
  refused — by this product or by whatever the operator was about to do with
  it. Hex cannot begin with `-`, and costs a few characters and no entropy:
  it is the same 256 bits, written out.

  ## The files, and why they are per Workspace

  Each Workspace has two files, named from the base path:

    * the **secret** file holds the token itself. It is the delivery: the
      operator reads it and moves it on. When they have, the file is empty
      and the token comes from somewhere else — the environment, standard
      input, or the prompt.
    * the **record** file holds only the token's **digest**. It is what a
      presented token is checked against, so a token that has been moved out
      of the secret file is still verifiable, and still single-use.

  Neither file ever holds another Workspace's data, and **one file per
  Workspace** is what makes that true at the filesystem level rather than by
  convention. A single host-wide file holding a map of Workspaces is a
  read-modify-write: two issuances at once read the same map, and one of
  them writes its entry over the other's. With one file per Workspace there
  is no shared file to lose an update in, and a file that is damaged is
  damaged for one Workspace alone.

  The record never holds the token, so the token's only copies are the
  operator's, the delivery file, and the process that is using it.

  ## The channels

  `Veritas.Authn` does not decide where a token comes from; the command line
  does, and it tries them in this order:

    1. the `VERITAS_BOOTSTRAP_TOKEN` environment variable, which is safe
       from the process list and is the one a pipeline uses;
    2. standard input, for a pipeline that pipes it;
    3. the secret file, which is where the token was written;
    4. a masked prompt, with the terminal's echo genuinely switched off.

  ## What a token guarantees

    * **It is single-use.** Consuming it removes it from the record, and a
      second attempt is refused.
    * **It is bound to one Workspace.** A token issued for one Workspace
      does not authorise another.
    * **It is verified against what is recorded**, in constant time, so a
      comparison cannot be measured.
  """

  @file_var "VERITAS_BOOTSTRAP_TOKEN_FILE"
  @default_record Path.join(["~", ".veritas", "bootstrap-token.json"])
  @secret_suffix ".secret"
  @record_suffix ".record"

  @doc """
  Issues a token for a Workspace and writes it to the secret file.

  Returns the **path**, not the token. The caller prints the path and
  nothing else.
  """
  @spec issue(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def issue(workspace, opts \\ []) when is_binary(workspace) do
    secret = secret_path(workspace, opts)
    token = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    entry = %{
      "digest" => digest(token),
      "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- write_record(workspace, entry, opts),
         :ok <- write_secret(secret, token) do
      {:ok, secret}
    end
  end

  @doc """
  The token the secret file holds.

  A lookup, not an authority: it reads what is there and returns it.
  """
  @spec read_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_token(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:error, :no_token_in_the_file}
          token -> {:ok, token}
        end

      {:error, :enoent} ->
        {:error, :no_token_in_the_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verifies a token for a Workspace and **consumes** it.

  The comparison is over the recorded digest, in constant time, and the
  lengths are compared first: the constant-time comparison refuses a
  mismatch of different lengths by raising, and a token of the wrong shape
  has to be refused, not crash the command.

  Consuming removes the Workspace's record, so a token works exactly once.

  The consumption is **atomic**: the token is claimed with an exclusive
  create, and only the caller that holds the claim spends it. Two callers
  that present the same token at the same time cannot both go on to spend
  it — without that, two accounts could be created from one token, and the
  second one would be created by a token that had already been spent.
  """
  @spec verify_and_consume(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify_and_consume(workspace, token, opts \\ [])
      when is_binary(workspace) and is_binary(token) do
    with {:ok, claim} <- claim(workspace, token, opts) do
      spend(claim, opts)
    end
  end

  @doc """
  Takes a token out of circulation **without** spending it.

  Exactly one caller can hold the claim. The claim is an **exclusive
  create**: the file it makes did not exist a moment earlier, and a second
  caller that tries to make it is refused. So a token that is presented
  twice at the same time is claimed once.

  A claim is finished in one of two ways:

    * `spend/2` — the work the token authorised happened. The record says
      the token is spent, and the delivery copy is emptied with it.
    * `release/2` — the work did not happen. The token is a token again, so
      that a refused account does not burn a one-time credential.

  The claim handle is what those two take. It is opaque to the caller.
  """
  @spec claim(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(workspace, token, opts \\ [])
      when is_binary(workspace) and is_binary(token) do
    with {:ok, entry} <- read_record(workspace, opts) do
      case entry do
        %{"digest" => recorded} when is_binary(recorded) ->
          if byte_size(recorded) == byte_size(digest(token)) and
               :crypto.hash_equals(recorded, digest(token)) do
            take_claim(workspace, recorded, entry, opts)
          else
            {:error, :bootstrap_token_refused}
          end

        _ ->
          {:error, :no_token_for_workspace}
      end
    end
  end

  @doc """
  Spends a claimed token.

  The record says the token is spent, and the **delivery copy** is emptied:
  there is no reason to leave a secret on disk once it has been used. Every
  copy the operator could have used is emptied — the file the token was
  delivered to, and the Workspace's own secret file.
  """
  @spec spend(map(), keyword()) :: :ok | {:error, term()}
  def spend(claim, opts \\ []) when is_map(claim) do
    workspace = Map.get(claim, :workspace)
    opts = Map.get(claim, :opts) || opts

    spent = %{
      "digest" => nil,
      "issued_at" => Map.get(claim, :issued_at),
      "spent_at" => DateTime.utc_now(),
      "attempt" => Map.get(claim, :attempt, 0)
    }

    with :ok <- write_record(workspace, spent, opts) do
      empty_delivery(workspace, opts)
    end
  end

  @doc """
  Releases a claimed token: the work it was claimed for did not happen, and
  the token is a token again.

  The claim moves to the **next attempt**, so the token can be claimed again
  without the file that holds the old claim being removed first. A token
  that was issued after this one was claimed is left alone: that one is the
  live one, and this token is spent either way.
  """
  @spec release(map(), keyword()) :: :ok | {:error, term()}
  def release(claim, opts \\ []) when is_map(claim) do
    workspace = Map.get(claim, :workspace)
    opts = Map.get(claim, :opts) || opts

    case read_record(workspace, opts) do
      {:ok, %{"digest" => digest} = entry} when is_binary(digest) ->
        if digest == Map.get(claim, :digest) do
          write_record(
            workspace,
            Map.merge(entry, %{"attempt" => Map.get(claim, :attempt, 0) + 1}),
            opts
          )
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  @doc """
  Removes a Workspace's record without using it.
  """
  @spec consume(String.t(), keyword()) :: :ok | {:error, term()}
  def consume(workspace, opts \\ []) when is_binary(workspace) do
    case read_record(workspace, opts) do
      {:ok, nil} ->
        :ok

      {:ok, _entry} ->
        write_record(workspace, %{"digest" => nil, "spent_at" => DateTime.utc_now()}, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The base path the Workspace's files are named from.

  The file itself is per Workspace: see `workspace_record_path/2` for the
  record and `secret_path/2` for the secret.
  """
  @spec record_path(keyword()) :: String.t()
  def record_path(opts \\ []) do
    Keyword.get(opts, :record) || default_record_path()
  end

  @doc """
  The file a Workspace's digest is recorded in.

  One file per Workspace, so that no two issuances share a file to lose an
  update in.
  """
  @spec workspace_record_path(String.t(), keyword()) :: String.t()
  def workspace_record_path(workspace, opts \\ []) when is_binary(workspace) do
    record_path(opts) <> "." <> workspace <> @record_suffix
  end

  @doc """
  The file the token is written to.

  It is per Workspace, so that one Workspace's token is not overwritten by
  another's, and so that a spent token's file can be emptied without
  touching the others.
  """
  @spec secret_path(String.t(), keyword()) :: String.t()
  def secret_path(workspace, opts \\ []) when is_binary(workspace) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) -> path
      _ -> default_record_path() <> "." <> workspace <> @secret_suffix
    end
  end

  @doc """
  The name of the environment variable that holds a token.
  """
  @spec token_env_var() :: String.t()
  def token_env_var, do: "VERITAS_BOOTSTRAP_TOKEN"

  @doc """
  The name of the environment variable that names the files.
  """
  @spec file_env_var() :: String.t()
  def file_env_var, do: @file_var

  @doc """
  The digest a token is recorded as.
  """
  @spec digest(String.t()) :: String.t()
  def digest(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  defp default_record_path do
    case System.get_env(@file_var) do
      path when is_binary(path) and path != "" -> path
      _ -> Path.expand(@default_record)
    end
  end

  # ── the files ──────────────────────────────────────────────────────────────

  # A Workspace's record, read from its own file.
  #
  # A file that cannot be read is an **error**, not an empty record. That
  # distinction is the whole point of the per-Workspace file: a record that
  # was damaged must not read as "this Workspace has no token", because that
  # silently turns a damaged file into a refused credential and sends the
  # operator looking in the wrong place.
  defp read_record(workspace, opts) do
    path = workspace_record_path(workspace, opts)

    case File.read(path) do
      {:ok, contents} ->
        decode_record(contents)

      {:error, :enoent} ->
        # No file of its own: an older build kept every Workspace's digest
        # in one file, so that is worth looking at before answering.
        case legacy_record(workspace, opts) do
          {:ok, entry} ->
            # Move it to the file it belongs in, so the migration happens
            # once and not on every read.
            _ = write_record(workspace, entry, opts)
            {:ok, entry}

          :error ->
            {:ok, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_record(contents) do
    case Jason.decode(contents) do
      {:ok, %{"digest" => digest} = entry} when is_binary(digest) ->
        {:ok, entry}

      {:ok, %{"digest" => nil}} ->
        # A spent record.
        {:ok, nil}

      {:ok, _other} ->
        {:ok, nil}

      {:error, _reason} ->
        {:error, :bootstrap_record_unreadable}
    end
  end

  # The record an older build wrote: one file, a map of Workspaces.
  defp legacy_record(workspace, opts) do
    path = record_path(opts)

    with {:ok, contents} <- File.read(path),
         {:ok, %{"workspaces" => workspaces}} when is_map(workspaces) <- Jason.decode(contents) do
      case Map.get(workspaces, workspace) do
        %{"digest" => digest} = entry when is_binary(digest) -> {:ok, entry}
        _other -> :error
      end
    else
      _other -> :error
    end
  end

  # The claim is a file that did not exist a moment ago.
  #
  # The **exclusive create** is what makes it a claim: the first caller to
  # create the file owns the token, and every other caller is refused. A
  # read-compare-write cannot do this — two callers can both read the same
  # digest, and both believe they are the first.
  defp take_claim(workspace, recorded, entry, opts) do
    attempt = Map.get(entry, "attempt", 0)
    path = claim_path(workspace, recorded, attempt, opts)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.open(path, [:write, :exclusive, :binary]) do
        {:ok, file} ->
          File.close(file)

          {:ok,
           %{
             workspace: workspace,
             digest: recorded,
             issued_at: Map.get(entry, "issued_at"),
             attempt: attempt,
             opts: opts
           }}

        {:error, :eexist} ->
          # Another caller holds the claim. The token is theirs, and this
          # caller has to be told so.
          {:error, :bootstrap_token_refused}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The file that holds the claim for one attempt of one token.
  #
  # The attempt is in the name, so that a released claim does not have to be
  # removed before the token can be claimed again: the next attempt has a
  # file of its own. The digest is in the name too, so that a token issued
  # later is never blocked by the claim on an earlier one.
  defp claim_path(workspace, recorded, attempt, opts) do
    workspace_record_path(workspace, opts) <>
      ".claimed." <> recorded <> "." <> Integer.to_string(attempt)
  end

  # Every copy of the token that is on disk is emptied: the file it was
  # delivered to, and the Workspace's own secret file. A token that is spent
  # and still readable is a token that can be presented again.
  defp empty_delivery(workspace, opts) do
    paths = Enum.uniq([secret_path(workspace, opts), secret_path(workspace, [])])

    Enum.reduce(paths, :ok, fn path, _acc ->
      case write_secret(path, "") do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # The record holds digests, never a token, and it is written with the
  # owner's permissions only. The write is atomic where the filesystem
  # allows it: a temporary file of its own, renamed into place, so a reader
  # never sees half a file. A filesystem that refuses the rename gets the
  # file written in place.
  defp write_record(workspace, entry, opts) do
    path = workspace_record_path(workspace, opts)

    contents =
      Jason.encode!(
        %{
          "workspace" => workspace,
          "digest" => Map.get(entry, "digest"),
          "issued_at" => Map.get(entry, "issued_at"),
          "spent_at" => Map.get(entry, "spent_at"),
          # Which claim the token is on. A token that was claimed for work
          # that did not happen is claimed again under the next number, so
          # that the claim is a claim on **this** attempt and not on the
          # token forever.
          "attempt" => Map.get(entry, "attempt", 0)
        },
        pretty: true
      )

    write_private(path, contents)
  end

  # The secret is the token itself, and it is the owner's alone.
  defp write_secret(path, token) do
    write_private(path, token)
  end

  # The file is the owner's alone, and so is the directory it is in.
  #
  # The order is the whole point: the directory is closed to other users
  # first, the file is restricted to its owner **before** the secret is in
  # it, and only then is the secret written. A file that another user can
  # read is a secret that another user has, whatever the file's own
  # permissions say — so the secret is never on disk in a state another user
  # could reach.
  defp write_private(path, contents) do
    with :ok <- private_directory(Path.dirname(path)) do
      write_private_file(path, contents)
    end
  end

  # A directory other users cannot enter. `File.mkdir_p/1` creates it with
  # the process's umask, which is not this product's to rely on, so the mode
  # is set afterwards.
  defp private_directory(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  # The file is written to a temporary of its own and published by a rename.
  #
  # The temporary is restricted to its owner **before** the secret is in it,
  # so there is no moment at which the secret is in a file another user can
  # read — not even for the width of a write.
  defp write_private_file(path, contents) do
    temporary = path <> ".tmp." <> random_suffix()

    with :ok <- write_restricted(temporary, contents, [:write, :exclusive]) do
      publish(temporary, path, contents)
    end
  end

  # The publish is a rename: it is atomic, and it keeps the file's
  # permissions. A filesystem that refuses the rename gets the file written
  # in place — restricted to its owner **before** the secret is in it, which
  # is the same rule the temporary follows.
  defp publish(temporary, path, contents) do
    case File.rename(temporary, path) do
      :ok ->
        # The rename brought the temporary's own permissions with it; this is
        # the belt to that braces, and it changes nothing that was open.
        File.chmod(path, 0o600)

      {:error, _reason} ->
        with :ok <- write_restricted(path, contents, [:write, :truncate]) do
          # The scratch is emptied before it is removed, so a filesystem that
          # refuses the removal does not leave a secret sitting in it.
          _ = write_restricted(temporary, "", [:write, :truncate])
          _ = File.rm(temporary)
          :ok
        end
    end
  end

  # Writes a file that only its owner can read.
  #
  # The file is created — or truncated — and **then** restricted, and the
  # contents are written after that. The order matters: a file that exists
  # with the process's umask holds nothing while it is being restricted, and
  # holds the secret only once it cannot be read by anybody else.
  defp write_restricted(path, contents, modes) do
    case File.open(path, modes ++ [:binary]) do
      {:ok, file} ->
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, contents),
             :ok <- File.close(file) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp random_suffix do
    6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
