defmodule Veritas.Plugin.Manifest do
  @moduledoc """
  The Plugin manifest: the only declaration a Plugin makes of its intent.

  A manifest is a map — parsed from YAML or JSON — whose fields are the
  table in `docs/08` §Plugin Manifest. It is the document the host grants
  authority from: the capabilities a Plugin asks for, the Host API it needs,
  the command that starts it, and the health contract the host uses to
  classify it.

  ## Validation is a hard gate

  A manifest that does not validate is refused **before anything is
  launched**. That order is the corpus's, not this module's: `docs/09` §6.1
  puts "validate manifest" before "spawn process", and `docs/20` §Capability
  Grants makes an unknown capability an *install-time* error.

  Two refusals carry the weight of the boundary:

    * **an incompatible `compatibility.host_api` range** — the Plugin speaks a
      Host API this host does not offer, so every call it makes would be
      against a vocabulary the host cannot honour;
    * **a `capabilities` entry outside the closed vocabulary** — an unknown
      scope is either a typo or an escalation attempt, and the host cannot
      tell the difference, so it refuses both.

  The vocabulary itself lives in `Veritas.Plugin.Capability`; the Host API
  range is read by `Veritas.Plugin.Semver`.

  ## The Host API version

  This host offers Host API **2.3.0**. The corpus's own example manifest
  declares `">= 2.3.0 and < 3.0.0"`, so a Plugin written against the
  corpus's example installs here unchanged.

  ## What is Fixed and what is Default

  The **gate** is Fixed: the corpus requires that nothing runs before the
  manifest is proven, and a host that skipped it would be a host that grants
  authority it never checked. The **field set** is Default: it is the corpus's
  table as of `docs/08`, and a host that reads a later amendment reads it
  here, in one place.

  ## A note on `vendor`

  `docs/08` lists `vendor` as required. The conformance manifest the plugin
  platform ships with does not carry it, so this host reads it as optional and
  does not refuse a manifest without it. Requiring it would refuse the
  corpus's own example.
  """

  alias Veritas.Plugin.{Capability, Semver}

  @api_version "veritas.plugin/v1"
  @host_api_version "2.3.0"

  @entry_point_types ~w(service job)
  @protocols ~w(jsonrpc)
  @dc_affinities ~w(local replicated bridged)

  @type t :: map()

  @doc "The manifest schema version this host reads."
  @spec api_version() :: String.t()
  def api_version, do: @api_version

  @doc """
  The Host API version this host offers.

  A manifest declares the range of Host API it needs; this is the version
  that range is checked against.
  """
  @spec host_api_version() :: String.t()
  def host_api_version, do: @host_api_version

  @doc """
  Validates a manifest.

  Returns the manifest unchanged when it is sound, so a caller can validate
  and use in one step. The refusal is a sentence naming what is wrong,
  because the refusal is read by a person installing a Plugin.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- validate_api_version(manifest),
         :ok <- validate_identity(manifest),
         :ok <- validate_compatibility(manifest),
         :ok <- validate_capabilities(manifest),
         :ok <- validate_configuration(manifest),
         :ok <- validate_permissions(manifest),
         :ok <- validate_data(manifest),
         :ok <- validate_entry_points(manifest),
         :ok <- validate_dc_affinity(manifest),
         :ok <- validate_health(manifest) do
      {:ok, manifest}
    end
  end

  def validate(other) do
    {:error, "the manifest must be a map of fields, got #{inspect(other)}"}
  end

  # ── the fields ─────────────────────────────────────────────────────────────

  defp validate_api_version(manifest) do
    case Map.fetch(manifest, "apiVersion") do
      {:ok, @api_version} ->
        :ok

      {:ok, other} ->
        {:error,
         "the manifest declares apiVersion #{inspect(other)}; this host reads #{@api_version}"}

      :error ->
        {:error, "the manifest has no apiVersion; it must declare #{@api_version}"}
    end
  end

  defp validate_identity(manifest) do
    with :ok <- require_string(manifest, "id"),
         :ok <- require_string(manifest, "name"),
         :ok <- require_string(manifest, "version") do
      case Semver.parse(manifest["version"]) do
        {:ok, _version} ->
          :ok

        :error ->
          {:error,
           "the manifest declares version #{inspect(manifest["version"])}, which is not a version " <>
             "this host can read"}
      end
    end
  end

  defp validate_compatibility(manifest) do
    with {:ok, compatibility} <- fetch_map(manifest, "compatibility"),
         {:ok, range} <- fetch_string(compatibility, "host_api") do
      cond do
        not Semver.valid_range?(range) ->
          {:error,
           "the manifest declares a host_api range #{inspect(range)} that this host cannot read"}

        not Semver.satisfies?(@host_api_version, range) ->
          {:error,
           "the manifest requires Host API #{inspect(range)}, which this host " <>
             "(#{@host_api_version}) does not satisfy"}

        true ->
          :ok
      end
    end
  end

  defp validate_capabilities(manifest) do
    case Map.fetch(manifest, "capabilities") do
      {:ok, scopes} when is_list(scopes) ->
        Enum.reduce_while(scopes, :ok, fn scope, :ok ->
          if is_binary(scope) and Capability.known?(scope) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "the manifest requests the capability #{inspect(scope)}, which is not in this " <>
                "host's capability vocabulary"}}
          end
        end)

      {:ok, other} ->
        {:error, "the manifest's capabilities must be a list of scopes, got #{inspect(other)}"}

      :error ->
        {:error, "the manifest has no capabilities; a Plugin declares the scopes it needs"}
    end
  end

  defp validate_configuration(manifest) do
    with {:ok, configuration} <- fetch_map(manifest, "configuration"),
         {:ok, schema} <- fetch_map(configuration, "schema") do
      _ = schema
      :ok
    end
  end

  defp validate_permissions(manifest) do
    with {:ok, permissions} <- fetch_map(manifest, "permissions"),
         {:ok, roles} <- fetch_list(permissions, "roles") do
      cond do
        not Enum.all?(roles, &is_binary/1) ->
          {:error, "the manifest's permissions.roles must be a list of role names"}

        not is_boolean(Map.get(permissions, "workspace_scoped")) ->
          {:error,
           "the manifest's permissions.workspace_scoped must be true or false, not " <>
             "#{inspect(Map.get(permissions, "workspace_scoped"))}"}

        true ->
          :ok
      end
    end
  end

  defp validate_data(manifest) do
    with {:ok, data} <- fetch_map(manifest, "data"),
         :ok <- require_string(data, "namespace") do
      case Map.fetch(data, "authority_dc") do
        {:ok, dc} when is_binary(dc) and dc != "" ->
          :ok

        {:ok, nil} ->
          :ok

        {:ok, other} ->
          {:error,
           "the manifest's data.authority_dc must be a Datacenter name, got #{inspect(other)}"}

        :error ->
          :ok
      end
    end
  end

  defp validate_entry_points(manifest) do
    with {:ok, entry_points} <- fetch_list(manifest, "entry_points") do
      if entry_points == [] do
        {:error, "the manifest has no entry_points; a Plugin is started by one"}
      else
        Enum.reduce_while(entry_points, :ok, fn entry, :ok ->
          case validate_entry_point(entry) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp validate_entry_point(entry) when is_map(entry) do
    with {:ok, type} <- fetch_string(entry, "type"),
         {:ok, command} <- fetch_string(entry, "command") do
      cond do
        type not in @entry_point_types ->
          {:error,
           "the manifest's entry point declares type #{inspect(type)}; this host runs " <>
             "#{Enum.join(@entry_point_types, " and ")} entry points"}

        command == "" ->
          {:error, "the manifest's entry point declares an empty command"}

        type == "service" and not valid_protocol?(entry) ->
          {:error,
           "the manifest's service entry point must declare protocol " <>
             "#{Enum.join(@protocols, " or ")}"}

        true ->
          :ok
      end
    end
  end

  defp validate_entry_point(other) do
    {:error, "the manifest's entry points must be maps, got #{inspect(other)}"}
  end

  defp valid_protocol?(entry) do
    case Map.fetch(entry, "protocol") do
      {:ok, protocol} -> protocol in @protocols
      :error -> false
    end
  end

  defp validate_dc_affinity(manifest) do
    case Map.fetch(manifest, "dc_affinity") do
      {:ok, affinity} when affinity in @dc_affinities ->
        :ok

      {:ok, other} ->
        {:error,
         "the manifest declares dc_affinity #{inspect(other)}; this host knows " <>
           "#{Enum.join(@dc_affinities, ", ")}"}

      :error ->
        {:error, "the manifest has no dc_affinity; a Plugin declares the Datacenters it runs in"}
    end
  end

  defp validate_health(manifest) do
    with {:ok, health} <- fetch_map(manifest, "health"),
         {:ok, check} <- fetch_string(health, "check") do
      cond do
        not valid_url?(check) ->
          {:error,
           "the manifest's health.check must be an http or https URL, got #{inspect(check)}"}

        not positive_integer?(Map.get(health, "interval_seconds")) ->
          {:error, "the manifest's health.interval_seconds must be a positive number of seconds"}

        not positive_integer?(Map.get(health, "timeout_seconds")) ->
          {:error, "the manifest's health.timeout_seconds must be a positive number of seconds"}

        not positive_integer?(Map.get(health, "degraded_after")) ->
          {:error, "the manifest's health.degraded_after must be a positive number of checks"}

        true ->
          :ok
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp require_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      {:ok, other} ->
        {:error, "the manifest's #{key} must be a non-empty string, got #{inspect(other)}"}

      :error ->
        {:error, "the manifest has no #{key}"}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, other} ->
        {:error, "the manifest's #{key} must be a map, got #{inspect(other)}"}

      :error ->
        {:error, "the manifest has no #{key}"}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) ->
        {:ok, value}

      {:ok, other} ->
        {:error, "the manifest's #{key} must be a list, got #{inspect(other)}"}

      :error ->
        {:error, "the manifest has no #{key}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, other} ->
        {:error, "the manifest's #{key} must be a string, got #{inspect(other)}"}

      :error ->
        {:error, "the manifest has no #{key}"}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_url?(check) do
    String.starts_with?(check, "http://") or String.starts_with?(check, "https://")
  end
end
