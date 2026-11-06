defmodule Veritas.Plugin.Install do
  @moduledoc """
  The Plugin lifecycle: install, verify, start, stop, uninstall.

  The order is the corpus's (`docs/09` §6.1 and `docs/20` §Lifecycle):

      install → verify → start → call → stop → uninstall

  and every step refuses rather than guesses.

  ## Install

  `install/2` validates the manifest **first**. A manifest that does not
  validate is refused, and nothing is launched, because the manifest is
  what the host grants authority from and a Plugin that is never launched
  cannot be a Plugin that was trusted.

  The install then records the manifest, the capabilities the operator
  granted, and the **environment** the Plugin will be given. That
  environment is built from scratch and carries no datastore credential:
  `Veritas.Plugin.Environment` is where that is decided.

  ## Start

  `start/1` spawns the Plugin as a separate OS process, performs the
  handshake (`docs/20` §Transport), and then runs the health check the
  manifest declares. The status it returns is what the host believes:

    * `:running` — the handshake completed and the health check passed;
    * `:degraded` — the Plugin is answering on the socket, but its declared
      health endpoint did not answer. The Plugin is alive and quarantined
      from nothing; it is watched rather than trusted;
    * `:quarantined` — the process is gone or wedged.

  A degraded Plugin stays callable. `docs/20` §Transport makes the protocol
  the primary liveness signal and the HTTP endpoint supplementary, so a
  Plugin that answers on the socket is serving calls; what it has lost is
  the operator's assurance that it is well.

  This module is **Default**: the lifecycle is a policy the host applies,
  and a different host may hold its plugins elsewhere without changing the
  boundary.
  """

  require Logger

  alias Veritas.Plugin.{Environment, Example, Health, Manifest, Registry, Session}

  @start_timeout 20_000

  @doc """
  Installs a Plugin from its manifest.

  `opts` may name the capabilities the operator grants (`:granted_scopes`,
  a subset of what the manifest declares) and the Workspace the install
  belongs to (`:workspace`).

  Returns the install record as the operator sees it: the Plugin's id, its
  version, the capabilities granted, and the environment the Plugin will be
  given.
  """
  @spec install(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def install(manifest, opts \\ []) do
    with {:ok, manifest} <- Manifest.validate(manifest),
         {:ok, granted} <- resolve_grants(manifest, opts),
         {:ok, generation} <- next_generation(manifest["id"]),
         {:ok, manifest_path} <- write_manifest(manifest) do
      install = %{
        plugin_id: manifest["id"],
        version: manifest["version"],
        manifest: manifest,
        granted_scopes: granted,
        status: :installed,
        install_generation: generation,
        digest: digest(manifest_path),
        environment:
          Environment.build(%{
            plugin_id: manifest["id"],
            version: manifest["version"],
            namespace: namespace(manifest)
          }),
        workspace: Keyword.get(opts, :workspace, "default"),
        namespace: namespace(manifest),
        command: command(manifest),
        manifest_path: manifest_path,
        registrations: [],
        error: nil
      }

      Registry.put_install(install)

      {:ok, view(install)}
    end
  end

  @doc """
  The installed Plugins, as the operator sees them.

  Each entry carries the Plugin's id, its version, its **status** and the
  capabilities it holds.
  """
  @spec list() :: [map()]
  def list do
    Registry.list_installs()
    |> Enum.map(&view/1)
  end

  @doc """
  Verifies an installed Plugin.

  The manifest is read back from the store, validated again, checked
  against the digest that was recorded at install time, and the Plugin's
  command is resolved — so `verify/1` answers "is what is installed still
  what was installed, and can it be started?" rather than "is it there?".
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify(plugin_id) do
    with {:ok, install} <- Registry.fetch_install(plugin_id),
         {:ok, manifest} <- read_manifest(install),
         {:ok, _manifest} <- Manifest.validate(manifest),
         :ok <- check_digest(install, manifest),
         {:ok, executable} <- resolve_executable(install) do
      {:ok,
       %{
         "plugin_id" => install.plugin_id,
         "version" => install.version,
         "install_generation" => install.install_generation,
         "manifest_sha256" => install.digest,
         "command" => install.command,
         "executable" => executable
       }}
    else
      :error -> {:error, "the Plugin #{inspect(plugin_id)} is not installed"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts an installed Plugin.

  Returns the status the host believes the Plugin is in.
  """
  @spec start(String.t()) :: {:ok, Registry.status()} | {:error, String.t()}
  def start(plugin_id) do
    with {:ok, install} <- Registry.fetch_install(plugin_id),
         {:ok, executable} <- resolve_executable(install),
         {:ok, socket_dir} <- socket_dir(install),
         {:ok, argv} <- plugin_argv(install) do
      secret = generate_secret()

      case start_session(install, socket_dir, executable, argv, secret) do
        {:ok, pid} ->
          case Session.await_ready(pid, @start_timeout) do
            {:ok, pid} ->
              Registry.put_session(plugin_id, pid)
              status = health_status(install)
              Registry.update_status(plugin_id, status)
              {:ok, status}

            {:error, reason} ->
              Registry.update_status(plugin_id, :quarantined)
              {:error, reason}
          end

        {:error, reason} ->
          Registry.update_status(plugin_id, :quarantined)
          {:error, reason}
      end
    else
      :error -> {:error, "the Plugin #{inspect(plugin_id)} is not installed"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a running Plugin.

  The process is stopped and the socket is removed. The install and the
  grants remain, so the Plugin can be started again.
  """
  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(plugin_id) do
    case Registry.fetch_session(plugin_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Veritas.Plugin.SessionSupervisor, pid)
        Registry.remove_session(plugin_id)

      :error ->
        :ok
    end

    Registry.update_status(plugin_id, :stopped)
    :ok
  end

  @doc """
  Removes a Plugin.

  The process is stopped, the grants go with it, and the manifest is
  removed from the store. Uninstalling a Plugin that is not installed is
  not an error — it is the state the caller wanted.
  """
  @spec uninstall(String.t()) :: :ok | {:error, String.t()}
  def uninstall(plugin_id) do
    _ = stop(plugin_id)

    case Registry.fetch_install(plugin_id) do
      {:ok, install} -> remove_manifest(install)
      :error -> :ok
    end

    Registry.remove_install(plugin_id)
    :ok
  end

  # ── the install record ─────────────────────────────────────────────────────

  @doc false
  @spec view(map()) :: map()
  def view(install) do
    %{
      "plugin_id" => install.plugin_id,
      "name" => install.manifest["name"],
      "version" => install.version,
      "status" => install.status,
      "requested_scopes" => install.manifest["capabilities"],
      "granted_scopes" => install.granted_scopes,
      "environment" => install.environment,
      "workspace" => install.workspace,
      "namespace" => install.namespace,
      "install_generation" => install.install_generation,
      "manifest_sha256" => install.digest
    }
  end

  defp resolve_grants(manifest, opts) do
    declared = manifest["capabilities"]

    case Keyword.get(opts, :granted_scopes) do
      nil ->
        {:ok, declared}

      granted when is_list(granted) ->
        if Enum.all?(granted, &(&1 in declared)) do
          {:ok, granted}
        else
          {:error, "the granted capabilities include a scope the manifest did not declare"}
        end

      other ->
        {:error, "the granted capabilities must be a list, got #{inspect(other)}"}
    end
  end

  defp next_generation(plugin_id) do
    case Registry.fetch_install(plugin_id) do
      {:ok, install} -> {:ok, install.install_generation + 1}
      :error -> {:ok, 1}
    end
  end

  defp namespace(manifest) do
    manifest
    |> Map.get("data", %{})
    |> Map.get("namespace", "")
  end

  defp command(manifest) do
    manifest
    |> Map.get("entry_points", [])
    |> List.first()
    |> case do
      nil -> ""
      entry -> Map.get(entry, "command", "")
    end
  end

  # ── the store ──────────────────────────────────────────────────────────────

  defp store_dir do
    Application.get_env(
      :veritas_plugin,
      :store_dir,
      Path.join(System.tmp_dir!(), "veritas-plugin-store")
    )
  end

  # The manifest is written to the plugin's own directory in the store, and
  # the digest is taken over those bytes. The Plugin is given the path and
  # digests the file itself, so the host can tell whether the process that
  # connected is talking about the manifest the host installed.
  defp write_manifest(manifest) do
    directory = Path.join(store_dir(), hash(manifest["id"]))
    path = Path.join(directory, "manifest.json")

    with :ok <- File.mkdir_p(directory),
         {:ok, json} <- encode(manifest),
         :ok <- File.write(path, json) do
      {:ok, path}
    end
  end

  defp read_manifest(install) do
    case File.read(install.manifest_path) do
      {:ok, json} -> decode(json)
      {:error, reason} -> {:error, "the installed manifest could not be read: #{inspect(reason)}"}
    end
  end

  defp remove_manifest(install) do
    File.rm(install.manifest_path)
    :ok
  rescue
    _ -> :ok
  end

  defp check_digest(install, _manifest) do
    if digest(install.manifest_path) == install.digest do
      :ok
    else
      {:error, "the installed manifest does not match the digest that was recorded"}
    end
  end

  defp digest(path), do: digest_of_bytes(File.read!(path))

  defp digest_of_bytes(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  defp hash(value) do
    :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp encode(manifest) do
    {:ok, JSON.encode!(manifest)}
  rescue
    error -> {:error, "the manifest could not be encoded: #{Exception.message(error)}"}
  end

  defp decode(json) do
    {:ok, JSON.decode!(json)}
  rescue
    error -> {:error, "the installed manifest could not be read: #{Exception.message(error)}"}
  end

  # ── the process ────────────────────────────────────────────────────────────

  # The command is resolved on PATH. The host's own example is the one
  # exception, and only because the host shipped it: a missing command for
  # any other Plugin is a broken install, and starting something else would
  # hide it.
  defp resolve_executable(install) do
    case System.find_executable(install.command) do
      nil ->
        if install.command == Example.command() do
          {:ok, Example.launcher()}
        else
          {:error, "the Plugin's command #{inspect(install.command)} is not on PATH"}
        end

      path ->
        {:ok, path}
    end
  end

  # The arguments a Plugin's own launcher needs, before the two every
  # Plugin gets: where the socket is, and where its manifest is.
  defp plugin_argv(install) do
    if install.command == Example.command() do
      case Example.runtime() do
        {:ok, elixir, erl} -> {:ok, ["--elixir", elixir, "--erl", erl]}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  # The socket lives in a directory of its own, private to the host, and the
  # socket file itself is set to `0600`. Two layers for one property: only
  # the user running the host may reach a Plugin's socket.
  #
  # The path is short, because macOS caps a Unix socket path at 104 bytes
  # and a path that does not fit is a path nobody can connect to.
  #
  # The directory is per attempt; the socket inside it is named by the
  # session, so a session that is started again never asks for an address
  # that is already taken.
  defp socket_dir(install) do
    directory = Application.get_env(:veritas_plugin, :runtime_dir, System.tmp_dir!())

    serial = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    name =
      "veritas-pl-#{hash("#{install.plugin_id}:#{install.install_generation}")}-#{serial}"

    path =
      if String.length(Path.join(directory, name)) > 80 do
        Path.join("/tmp", name)
      else
        Path.join(directory, name)
      end

    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, "the runtime directory could not be prepared: #{inspect(reason)}"}
    end
  end

  defp start_session(install, socket_dir, executable, argv, secret) do
    options = [
      plugin_id: install.plugin_id,
      workspace: install.workspace,
      install_generation: install.install_generation,
      secret: secret,
      digest: install.digest,
      granted_scopes: install.granted_scopes,
      socket_dir: socket_dir,
      manifest_path: install.manifest_path,
      command: executable,
      argv: argv,
      environment: install.environment
    ]

    DynamicSupervisor.start_child(Veritas.Plugin.SessionSupervisor, {Session, options})
  end

  defp generate_secret do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # The health check the manifest declares. A Plugin that is answering on
  # the socket but whose health endpoint is dead is degraded, not dead.
  defp health_status(install) do
    health = Map.get(install.manifest, "health", %{})
    check = Map.get(health, "check", "")
    timeout = Map.get(health, "timeout_seconds", 5) * 1000

    case Health.check(check, timeout) do
      :ok ->
        :running

      {:error, reason} ->
        Logger.info(
          "[veritas.plugin] #{install.plugin_id} is degraded: its health check " <>
            "#{check} did not answer (#{inspect(reason)})"
        )

        :degraded
    end
  end
end
