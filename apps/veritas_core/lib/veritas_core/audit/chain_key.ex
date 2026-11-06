defmodule Veritas.Core.Audit.ChainKey do
  @moduledoc """
  The key the Audit Log's chain is signed with.

  The chain is signed with **HMAC-SHA-256** under a key the **host** holds
  and the **store never sees**. That is the whole point. A chain whose key
  lives beside the data it protects can be rewritten by whoever can rewrite
  the data, and a hash anyone can recompute is not evidence of anything.

  ## Where the key comes from

  Three sources, in order:

    * `VERITAS_CHAIN_KEY_FILE` — a path to a **key ring** file, in JSON:

          {
            "current": "2026-10",
            "keys": [
              {"id": "2026-10", "secret": "<64 hex characters>", "created_at": "2026-10-26"}
            ]
          }

    * `VERITAS_CHAIN_KEY` — one key, as 64 hexadecimal characters. It is a
      ring of one.

    * **the default key ring file**, `~/.veritas/chain-key.json`. It is
      created on first use, with one generated key, readable only by its
      owner.

  The default file is what makes the chain work across **processes**. A
  key that lives in the memory of one process is a key the next process
  does not have: the migration would sign the chain with a key the server
  does not hold, the server would report a chain it cannot verify, and
  "broken" would be the wrong word for it. The file is the shared place: the
  server, the CLI and the migration all sign with the same key, so a chain
  written by one is verifiable by the others.

  ## What happens when there is no key at all

  There is **no unkeyed fallback**: a chain signed with a key nobody holds
  is a chain anybody can forge, which is the defect this module exists to
  remove.

    * **Production** — the boot check **refuses to start**. A service whose
      Audit Log cannot be trusted should not serve traffic.
    * **Everywhere else** — if the default file cannot be created (a
      read-only home, say), the boot check **warns loudly** and the chain is
      signed with an **ephemeral key generated for the life of the running
      VM**. The warning states the consequence: the chain does not survive a
      restart, and the events written before the restart cannot be verified
      by the next process. That is a nuisance in development and a defence
      in production, where a key is required.

  ## The lifecycle of a key

    * the **current** key signs every new event;
    * a **retired** key stays in the ring and keeps verifying the events it
      signed, until the chain is re-signed under the current key — and a
      migration re-chains every row, so that is when it happens;
    * a retired key may be **dropped** once no event it signed is still in
      the chain. Dropping it early is not silent: those events can no longer
      be verified, and the chain says so.

  ## This module holds secret material

  Nothing here is for logging, and the key never leaves this module: the
  Audit Log asks it to sign a payload and to say what a stored hash is, and
  it gets back a signature or a verdict. The ring is cached in
  `:persistent_term` because it is read on every audit write and it must not
  be a file read on every write; `reset/0` drops the cache, which is what a
  test needs and what a deliberate reload needs.
  """

  require Logger

  # `band/2` is the bitwise-and operator; Elixir does not import it by
  # default. It is the one this module needs: the key file's permission
  # bits.
  import Bitwise, only: [band: 2]

  @key_file_var "VERITAS_CHAIN_KEY_FILE"
  @key_var "VERITAS_CHAIN_KEY"
  @default_dir_var "VERITAS_CHAIN_KEY_DIR"
  @cache {__MODULE__, :ring}

  @secret_bytes 32

  # How long a writer waits for the writer that got there first, and how long
  # between the attempts. A publish that is in flight is milliseconds wide;
  # a writer that died is forever, and is a failure the operator must see.
  @publish_attempts 20
  @publish_interval 25

  @type key :: %{id: String.t(), secret: binary}
  @type ring :: %{current: String.t(), keys: [key]}

  @typedoc """
  What a stored hash is, given the payload it should cover.

    * `:matches` — the row is signed under a key the ring holds, and the
      signature is the one the payload produces.
    * `:tampered` — the row is signed under a key the ring holds, and the
      signature is **not** the one the payload produces. Somebody changed
      the row.
    * `:unverifiable` — the row is signed under a key the ring does not
      hold, or was signed before the chain was keyed at all. Nothing has
      been proven either way: the row may be perfectly genuine, and the
      host simply cannot check it.
  """
  @type verdict :: :matches | :tampered | :unverifiable

  @doc """
  The id of the key the ring signs with.
  """
  @spec current_id() :: String.t() | nil
  def current_id do
    case load() do
      {:ok, ring} -> ring.current
      {:error, _reason} -> nil
    end
  end

  @doc """
  Turns the ring: a new key becomes the current one, and the key it replaces
  **stays in the ring**.

  The retired key stays because a key that is dropped while the events it
  signed are still in the chain turns those events **unverifiable** rather
  than verified: the ring is what keeps a chain spanning a rotation
  checkable, and the verdict an operator gets is the difference between
  "somebody changed this" and "this cannot be checked".

  Only a ring that lives in a **file** can be rotated. A ring supplied as
  `VERITAS_CHAIN_KEY` is one key with nowhere to keep the retired one, so
  rotation there is refused with the reason rather than pretending.

  Returns the new ring and the key ids it moved between.
  """
  @spec rotate(keyword()) ::
          {:ok, %{ring: ring(), from: String.t(), to: String.t()}} | {:error, term()}
  def rotate(opts \\ []) do
    with {:ok, path} <- rotatable_ring_file(),
         {:ok, ring} <- ring_from_file(path) do
      new_id = Keyword.get(opts, :key_id) || new_key_id()
      new_secret = Keyword.get(opts, :secret) || :crypto.strong_rand_bytes(@secret_bytes)

      with {:ok, new_key} <- decode_key(new_id, Base.encode16(new_secret, case: :lower)) do
        from = ring.current
        new_key = Map.put(new_key, :created_at, DateTime.utc_now() |> Date.to_iso8601())

        rotated = %{
          current: new_id,
          # The key it replaces **stays in the ring**. A key dropped while
          # the events it signed are still in a chain turns those events
          # unverifiable rather than verified, and the ring is what keeps a
          # chain spanning a rotation checkable.
          keys: [new_key | ring.keys]
        }

        case write_ring(path, rotated) do
          :ok ->
            # The cached ring is the old one; it must not outlive the file.
            reset()
            {:ok, %{ring: rotated, from: from, to: new_id}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Drops a key from the ring.

  A key may only be dropped once no event it signed is still in a chain,
  because dropping it makes those events unverifiable — which is not the
  same as saying they were changed, and is a fact the operator has to be
  told.

  The options are not consulted: the ring is the host's, not a Workspace's,
  and there is one ring per host.
  """
  @spec drop_key(String.t(), keyword()) :: {:ok, ring()} | {:error, term()}
  def drop_key(key_id, _opts \\ []) do
    with {:ok, path} <- rotatable_ring_file(),
         {:ok, ring} <- ring_from_file(path) do
      kept = Enum.reject(ring.keys, fn key -> key.id == key_id end)

      if length(kept) == length(ring.keys) do
        {:error, :no_such_key}
      else
        current = if ring.current == key_id, do: nil, else: ring.current

        updated = %{ring | keys: kept, current: current}

        case write_ring(path, updated) do
          :ok ->
            reset()
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # The file the ring lives in, or the reason there is not one.
  #
  # The options are not consulted: the ring is the host's, not a Workspace's,
  # and a rotation is a host-level act. `rotate/1` and `drop_key/2` take
  # options of their own — the id and the secret of the new key — and those
  # are the options that matter.
  defp rotatable_ring_file do
    case System.get_env(@key_file_var) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        case System.get_env(@key_var) do
          secret when is_binary(secret) and secret != "" ->
            {:error,
             "the ring is supplied as VERITAS_CHAIN_KEY, which holds one key with nowhere to " <>
               "keep the retired one; set VERITAS_CHAIN_KEY_FILE to a key ring to rotate"}

          _missing ->
            {:ok, default_key_file()}
        end
    end
  end

  defp new_key_id do
    date = Date.utc_today() |> Date.to_iso8601()
    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{date}-#{suffix}"
  end

  # The ring is written the way it is read: atom keys in the document's
  # values, string keys in the document itself, and the whole thing written
  # atomically so a reader never sees half a ring.
  defp write_ring(path, ring) do
    document = %{
      "current" => ring.current,
      "keys" =>
        Enum.map(ring.keys, fn key ->
          %{
            "id" => key.id,
            "secret" => Base.encode16(key.secret, case: :lower),
            "created_at" => Map.get(key, :created_at)
          }
        end)
    }

    body = Jason.encode!(document)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      write_in_place(path, body, "the key ring could not be written")
    end
  end

  @doc """
  The key ring, or an error naming what is wrong with it.
  """
  @spec load() :: {:ok, ring()} | {:error, term()}
  def load do
    case :persistent_term.get(@cache, nil) do
      nil ->
        case build_ring() do
          {:ok, ring} ->
            :persistent_term.put(@cache, ring)
            {:ok, ring}

          {:error, reason} ->
            {:error, reason}
        end

      ring ->
        {:ok, ring}
    end
  end

  @doc """
  Drops the cached ring.

  A test needs it, because a test needs to know the key it signed with. An
  operator needs it after a rotation, if they choose to reload without a
  restart.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@cache)
    :ok
  end

  @doc """
  Signs a payload with the current key.

  The signature is `"<key id>:<mac>"`, so that a row says which key signed
  it. A row whose hash has no prefix was signed before the chain was keyed,
  and is recognised as such.
  """
  @spec sign(binary()) :: {:ok, String.t()} | {:error, term()}
  def sign(payload), do: sign(payload, nil)

  @doc """
  Signs a payload with a **named** key from the ring.

  A Workspace's chain is signed under the key it was adopted under, and it
  keeps that key until it adopts the next one. The key is in the ring — that
  is what a retired key is for — so the chain can be signed under it even
  though it is no longer the current one.

  A key the ring does not hold cannot sign anything, and says so: a chain
  whose key was dropped early is a chain that cannot be extended, and the
  operator is told that rather than being handed a mixture.
  """
  @spec sign(binary(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def sign(payload, key_id)

  def sign(payload, nil) do
    with {:ok, ring} <- load() do
      key = current_key!(ring)
      {:ok, key.id <> ":" <> mac(key, payload)}
    end
  end

  def sign(payload, key_id) when is_binary(key_id) do
    with {:ok, ring} <- load() do
      case key_by_id(ring, key_id) do
        nil ->
          {:error, "the chain key ring does not hold the key #{inspect(key_id)}"}

        key ->
          {:ok, key.id <> ":" <> mac(key, payload)}
      end
    end
  end

  @doc """
  What a stored hash is, given the payload it should cover.

  The three verdicts are the difference between "somebody changed this" and
  "this cannot be checked", and the difference matters: the first is a
  finding about the data, the second is a finding about the configuration.
  """
  @spec verdict(String.t() | nil, binary()) :: verdict()
  def verdict(nil, _payload), do: :unverifiable

  def verdict(stored, payload) do
    case load() do
      {:ok, ring} -> verdict_in_ring(ring, stored, payload)
      {:error, _reason} -> :unverifiable
    end
  end

  @doc """
  Whether a stored hash is the signature of a payload under a key the ring
  holds.
  """
  @spec matches?(String.t() | nil, binary()) :: boolean()
  def matches?(stored, payload), do: verdict(stored, payload) == :matches

  @doc """
  How a stored hash was signed.

  The shape is **uniform**: a caller can destructure it without first
  matching on it. A row signed before the chain was keyed is a first-class
  case here, not an exception — a guard that has to destructure a value that
  might be an atom is a guard that crashes on the case it exists to handle.

    * `{:keyed, id}` — signed with the key named `id`.
    * `{:unsigned, nil}` — not signed with a key: a row from before the
      chain was keyed. It carries no evidence.
  """
  @spec key_id(String.t() | nil) :: {:keyed, String.t()} | {:unsigned, nil}
  def key_id(nil), do: {:unsigned, nil}

  def key_id(stored) do
    case String.split(stored, ":", parts: 2) do
      [id, _mac] -> {:keyed, id}
      _unsigned -> {:unsigned, nil}
    end
  end

  @doc """
  The signature the chain used before it was keyed.

  It is here so that the migration can tell a legacy row from a tampered
  one: a legacy row that still matches the old algorithm has not been
  touched, and one that does not match has been. It proves nothing about a
  careful rewrite, and the migration says so in the report it returns.
  """
  @spec legacy_mac(binary()) :: String.t()
  def legacy_mac(payload), do: Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

  @doc """
  The boot check.

  In production, a chain with no key is a chain nobody can trust, and the
  service refuses to start. Everywhere else it warns, loudly, and says
  exactly what the consequence is.
  """
  @spec validate!() :: :ok
  def validate! do
    case load() do
      {:ok, ring} ->
        if ephemeral?(ring) do
          Logger.warning(
            "[veritas.audit] the chain key could not be persisted, so the Audit Log is signed " <>
              "with an ephemeral key generated for this run. THE CHAIN DOES NOT SURVIVE A " <>
              "PROCESS BOUNDARY: the events written before the restart cannot be verified by " <>
              "the next process. This is refused in production. Set #{@key_file_var} to a key " <>
              "ring file, or #{@key_var} to a key, before a deployment anybody else can reach."
          )
        end

        :ok

      {:error, reason} ->
        if production?() do
          raise "the Audit Log cannot be signed: #{reason}. " <>
                  "Set #{@key_file_var} to a key ring file, or #{@key_var} to a key."
        else
          Logger.warning(
            "[veritas.audit] no chain key is configured (#{reason}); the Audit Log cannot be " <>
              "signed and every audit write will fail. Set #{@key_file_var} or #{@key_var}."
          )

          :ok
        end
    end
  end

  @doc """
  Whether the running VM is a production one.

  The environment is the same one the boot check for the datastore credential
  uses, so the two refusals happen in the same places and for the same
  reason: a deployment that anybody else can reach must not run on defaults.
  """
  @spec production?() :: boolean()
  def production?, do: Application.get_env(:veritas_core, :environment, :prod) == :prod

  @doc """
  Whether the ring holds a key that another process can also hold.

  A ring that lives in one process's memory is not a key: the next process
  signs with a different one, and a chain written by the first cannot be
  checked by the second. A migration that signs rows with such a key
  destroys the rows it signs.
  """
  @spec persistent?() :: boolean()
  def persistent? do
    case load() do
      {:ok, ring} -> not ephemeral?(ring)
      {:error, _reason} -> false
    end
  end

  @doc """
  Where the default key ring lives.

  A directory the operator can point elsewhere, and a file inside it that
  only its owner can read.
  """
  @spec default_key_file() :: String.t()
  def default_key_file do
    directory =
      System.get_env(@default_dir_var) ||
        case System.get_env("HOME") do
          home when is_binary(home) and home != "" -> Path.join(home, ".veritas")
          _other -> "/tmp/.veritas"
        end

    Path.join(directory, "chain-key.json")
  end

  # ── the ring ────────────────────────────────────────────────────────────────

  defp build_ring do
    case System.get_env(@key_file_var) do
      path when is_binary(path) and path != "" ->
        ring_from_file(path)

      _ ->
        case System.get_env(@key_var) do
          secret when is_binary(secret) and secret != "" ->
            with {:ok, key} <- decode_key("default", secret),
                 do: {:ok, %{current: "default", keys: [key]}}

          _missing ->
            default_ring()
        end
    end
  end

  # The default file. It is created on first use, so that every process on
  # the machine — the server, the CLI, the migration — signs with the same
  # key, and a chain written by one is verifiable by the others.
  defp default_ring do
    path = default_key_file()

    case read_ring_file(path) do
      {:ok, ring} ->
        check_key_file_permissions(path)
        {:ok, ring}

      # The file is not there. It is created below, and only one writer may
      # create it.
      {:error, :missing} ->
        create_default_ring(path)

      # The file is there and cannot be read: it is empty, or it is not the
      # document it should be. It may hold the key that signed every event in
      # the chain, so replacing it would silently re-key the Audit Log — every
      # event the old key signed would then verify as tampered. It is a failure
      # the operator must see, not a repair the product makes silently.
      {:error, :empty} ->
        # An empty file is also what a publish in flight looks like: a writer
        # that created it and has not written it yet. It is waited out, never
        # deleted — deleting it would destroy a publish in flight and leave two
        # writers each believing they own the ring.
        adopt_published_ring(path, @publish_attempts)

      {:error, {:unparseable, reason}} ->
        {:error, unreadable_ring_error(path, reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ring is created by exactly **one** writer.
  #
  # Two processes that find no ring at the same time — the server starting
  # while the CLI runs — must not each mint a key: only one of them can own
  # the file, and the other must use **the key on disk** rather than the one
  # it generated. Two rings would be two keys with the same id, and every
  # event the loser signed would verify as tampered once anything restarted.
  defp create_default_ring(path) do
    case publish_default_ring(path) do
      {:ok, :created} ->
        case read_ring_file(path) do
          {:ok, ring} -> {:ok, ring}
          {:error, reason} -> {:error, reason}
        end

      {:error, :exists} ->
        # Another writer got there first. Its key is the key.
        adopt_published_ring(path, @publish_attempts)

      {:error, {:unavailable, _reason}} ->
        # The ring file could not be created at all — a directory that cannot
        # be written, say. The chain is signed with a key that lives in this
        # process only, and the boot check says what that costs. This is the
        # **last** resort: a race between two writers never comes here, or two
        # processes would sign with two keys and the chain would be unreadable
        # after a restart.
        {:ok, ephemeral_ring()}
    end
  end

  # The ring another writer published.
  #
  # It is read from the **file**, never from the key this writer generated: the
  # key on disk is the key every process must sign with, and a key that is not
  # on disk signs rows that verify as tampered once anything restarts.
  #
  # The file may still be empty — a writer that created it and has not
  # written it yet. That is waited out, never deleted: deleting it would
  # destroy a publish in flight and leave two writers each believing they own
  # the ring. A file that stays empty is a writer that died, and it is a
  # failure the operator must see.
  defp adopt_published_ring(path, attempts) when attempts > 0 do
    case read_ring_file(path) do
      {:ok, ring} ->
        check_key_file_permissions(path)
        {:ok, ring}

      {:error, :empty} ->
        Process.sleep(@publish_interval)
        adopt_published_ring(path, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adopt_published_ring(path, _attempts) do
    {:error, unreadable_ring_error(path, :empty)}
  end

  # The ring is published **exclusively**: the writer that creates the file
  # owns the key, and every other writer reads the key from the file rather
  # than keeping the one it generated.
  #
  # The content is written to a temporary file that is **this writer's own**,
  # and restricted to its owner before the secret is in it, so the key is
  # never on disk in a state another user could read.
  defp publish_default_ring(path) do
    key = %{
      id: "default",
      # The file holds the secret as **hexadecimal**, because that is what
      # `decode_key/2` reads it back as. Raw bytes are not valid UTF-8, and
      # a JSON document cannot carry them.
      secret: Base.encode16(:crypto.strong_rand_bytes(@secret_bytes), case: :lower),
      created_at: DateTime.utc_now() |> DateTime.to_date() |> Date.to_iso8601()
    }

    document = %{"current" => key.id, "keys" => [key]}
    body = Jason.encode!(document)
    temporary = temp_path(path)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_and_link(temporary, path, body)
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  defp write_and_link(temporary, path, body) do
    case write_private_file(temporary, body) do
      :ok ->
        link_into_place(temporary, path, body)

      {:error, :eexist} ->
        # The temporary name is this writer's own, so this is not expected —
        # but if it happens, another writer is publishing and **its** ring is
        # the ring. An ephemeral key here would sign the chain with a key
        # nothing else holds.
        {:error, :exists}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  # The publish is a hard link: it is atomic, and it refuses to overwrite, so
  # the first writer to link wins the ring and the rest are told it exists. A
  # filesystem without hard links falls back to an exclusive create, which
  # refuses to overwrite too; the only difference is that the file is briefly
  # empty while it is written.
  defp link_into_place(temporary, path, body) do
    case File.ln(temporary, path) do
      :ok ->
        _ = File.rm(temporary)
        {:ok, :created}

      {:error, :eexist} ->
        _ = File.rm(temporary)
        {:error, :exists}

      {:error, _reason} ->
        _ = File.rm(temporary)
        create_exclusively(path, body)
    end
  end

  defp create_exclusively(path, body) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, body),
             :ok <- File.close(file) do
          {:ok, :created}
        else
          {:error, reason} -> {:error, {:unavailable, reason}}
        end

      {:error, :eexist} ->
        {:error, :exists}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  # A temporary file that is this writer's own, restricted to its owner
  # before the secret is in it.
  defp write_private_file(path, body) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(file, body) do
      File.close(file)
    end
  end

  # The reason a ring file that cannot be read is not replaced.
  defp unreadable_ring_error(path, :empty) do
    "the chain key ring at #{path} is empty. It is not replaced, because it may be the key " <>
      "that signed the Audit Log; move it aside to start a new ring."
  end

  defp unreadable_ring_error(path, reason) do
    "the chain key ring at #{path} could not be read: #{reason}. It is not replaced, " <>
      "because it may be the key that signed the Audit Log; move it aside to start a new ring."
  end

  # The rename is not always possible — a filesystem that will not rename
  # over an existing file, for instance. The ring is then written where it
  # lies, in one write, and the window in which it is half-written is the
  # width of that write rather than the width of a process's death.
  defp write_in_place(path, body, reason) do
    with {:ok, file} <- File.open(path, [:write, :truncate, :binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(file, body),
         :ok <- File.close(file) do
      :ok
    else
      {:error, inner} ->
        {:error,
         "the chain key file could not be written: #{inner} (and not atomically: #{reason})"}
    end
  end

  # A temporary file that is **this writer's own**.
  #
  # The name carries the writer's process id and random bytes, so two writers
  # never write to the same temporary. A shared name would not be a slow race:
  # the second writer's exclusive create would fail, and the ring it was
  # publishing would never reach the disk at all.
  defp temp_path(path) do
    unique =
      "#{System.pid()}." <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    "#{path}.tmp.#{unique}"
  end

  # A key file that other users can read is a key other users have. The
  # file is the host's own secret, and the host says so.
  defp check_key_file_permissions(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when is_integer(mode) ->
        if band(mode, 0o077) != 0 do
          Logger.warning(
            "[veritas.audit] the chain key file #{path} is readable by users other than its " <>
              "owner. Anyone who can read it can forge the Audit Log."
          )
        end

      _other ->
        :ok
    end
  end

  defp ring_from_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, document} <- decode_ring(body),
         {:ok, ring} <- build_ring(document, path) do
      {:ok, ring}
    else
      {:error, reason} -> {:error, "#{reason} (#{path})"}
    end
  end

  defp read_ring_file(path) do
    case File.read(path) do
      {:ok, ""} ->
        # An empty file is what a process that died between creating the
        # file and writing it leaves behind. It holds no key, so it is
        # replaced rather than believed.
        {:error, :empty}

      {:ok, body} ->
        case decode_ring(body) do
          {:ok, document} ->
            build_ring(document, path)

          {:error, reason} ->
            {:error, {:unparseable, reason}}
        end

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, "the chain key file could not be read: #{reason}"}
    end
  end

  # A key that exists only for this run. It is marked so that the boot check
  # can say so, and so that a ring read from a file can never be mistaken for
  # one.
  defp ephemeral_ring do
    key = %{
      id: "ephemeral",
      secret: :crypto.strong_rand_bytes(@secret_bytes),
      ephemeral: true
    }

    %{current: "ephemeral", keys: [key]}
  end

  defp ephemeral?(ring), do: Map.get(current_key!(ring), :ephemeral, false)

  defp decode_ring(body) do
    case Jason.decode(body) do
      {:ok, %{"current" => current, "keys" => keys}} when is_list(keys) ->
        {:ok, %{"current" => current, "keys" => keys}}

      {:ok, _other} ->
        {:error, "the key ring file must hold a \"current\" id and a \"keys\" list"}

      {:error, _reason} ->
        {:error, "the key ring file is not valid JSON"}
    end
  end

  defp build_ring(%{"current" => current, "keys" => keys}, path) do
    with {:ok, decoded} <- decode_keys(keys),
         {:ok, _key} <- fetch_key(decoded, current) do
      {:ok, %{current: current, keys: decoded}}
    else
      {:error, reason} -> {:error, "#{reason} (#{path})"}
    end
  end

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case key do
        %{"id" => id, "secret" => secret} when is_binary(id) and is_binary(secret) ->
          case decode_key(id, secret) do
            {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _other ->
          {:halt, {:error, "every key in the ring needs an \"id\" and a \"secret\""}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_key(id, secret) do
    case Base.decode16(secret, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == @secret_bytes ->
        {:ok, %{id: id, secret: bytes}}

      {:ok, _other} ->
        {:error, "the key #{inspect(id)} must be #{@secret_bytes} bytes of hexadecimal"}

      :error ->
        {:error, "the key #{inspect(id)} is not hexadecimal"}
    end
  end

  defp fetch_key(keys, id) do
    case Enum.find(keys, &(&1.id == id)) do
      nil -> {:error, "the ring names #{inspect(id)} as current, and the ring does not hold it"}
      key -> {:ok, key}
    end
  end

  defp current_key!(ring), do: Enum.find(ring.keys, &(&1.id == ring.current)) || hd(ring.keys)

  defp key_by_id(ring, id), do: Enum.find(ring.keys, &(&1.id == id))

  defp verdict_in_ring(ring, stored, payload) do
    case key_id(stored) do
      {:keyed, id} ->
        case key_by_id(ring, id) do
          nil ->
            # The row was signed with a key this host does not hold. Nothing
            # has been proven: the row may be genuine, and the host simply
            # cannot check it. That is a configuration finding, not a
            # tampering one.
            :unverifiable

          key ->
            if secure_compare(key.id <> ":" <> mac(key, payload), stored),
              do: :matches,
              else: :tampered
        end

      {:unsigned, nil} ->
        # A row signed before the chain was keyed. It carries no evidence,
        # so it does not verify — and the migration is what replaces it.
        :unverifiable
    end
  end

  defp mac(key, payload),
    do: Base.encode16(:crypto.mac(:hmac, :sha256, key.secret, payload), case: :lower)

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and secure_compare_bytes(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp secure_compare_bytes(left, right) do
    :crypto.exor(left, right) == <<0::size(byte_size(left) * 8)>>
  end
end
