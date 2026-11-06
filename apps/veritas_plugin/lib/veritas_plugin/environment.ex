defmodule Veritas.Plugin.Environment do
  @moduledoc """
  The environment a Plugin process is given.

  `docs/20` §Data Access and `docs/09` ADR-009 put the rule in one line: a
  Plugin has **no store credentials**. It cannot reach the datastore, not
  because it is asked not to, but because nothing it was given can help it.

  Two mechanisms, and the second is the one that carries the weight:

    * the environment is **built**, not inherited. The Plugin is given the
      keys the host chooses and nothing else — not the host's environment
      minus the dangerous parts, which would keep every key nobody thought
      of;
    * every credential-shaped key is **scrubbed** anyway, so a key added to
      the built environment by mistake still does not reach the Plugin.

  The bootstrap secret does **not** travel here. `docs/20` §Transport is
  explicit that it travels on the Plugin's inherited stdin, never in argv
  and never in the environment, because an environment is inherited by every
  child the Plugin spawns and is readable by anything that can read the
  process's environment.

  This module is **Default**: an operator may add a key the host passes on
  (a proxy setting, a locale), and the scrub still applies to it.
  """

  # The shapes a credential takes. The list is deliberately broad: a false
  # positive costs a Plugin one environment variable, and a false negative
  # costs the datastore.
  @credential_markers ~w(
    surreal
    database_url
    db_password
    db_pass
    password
    passwd
    secret
    token
    api_key
    apikey
    credential
    cookie
    private_key
    session_key
  )

  @doc """
  The environment a Plugin with this install record is given.

  The keys are facts about the Plugin, not capabilities: what it is called,
  what version it is, which namespace it owns, and which Host API it is
  talking to.
  """
  @spec build(map()) :: map()
  def build(install) do
    %{
      "VERITAS_PLUGIN_ID" => Map.get(install, :plugin_id),
      "VERITAS_PLUGIN_VERSION" => Map.get(install, :version),
      "VERITAS_PLUGIN_NAMESPACE" => Map.get(install, :namespace),
      "VERITAS_HOST_API_VERSION" => Veritas.Plugin.Manifest.host_api_version(),
      "VERITAS_PLUGIN_PROTOCOL" => "veritas.plugin.v1"
    }
    |> scrub()
  end

  @doc """
  Removes every credential-shaped key.

  The check is on the *name*, in upper case, so `surreal_pass`, `SURREAL_URL`
  and `Veritas_Surreal_Password` are all caught.
  """
  @spec scrub(map()) :: map()
  def scrub(environment) when is_map(environment) do
    Map.reject(environment, fn {key, _value} -> credential_key?(key) end)
  end

  @doc """
  Whether a key looks like it carries a credential.
  """
  @spec credential_key?(term()) :: boolean()
  def credential_key?(key) do
    name = key |> to_string() |> String.upcase()

    Enum.any?(@credential_markers, fn marker -> String.contains?(name, marker) end)
  end
end
