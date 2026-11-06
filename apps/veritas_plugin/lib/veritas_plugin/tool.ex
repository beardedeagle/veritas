defmodule Veritas.Plugin.Tool do
  @moduledoc """
  The tools Plugins contribute, and the way the host calls them.

  A Plugin registers its tools at the handshake — the `ready` frame names
  them, and each one names the capabilities it needs. The host keeps those
  registrations in the registry, and this module is the surface the rest of
  the product uses to see them.

  ## The rule that matters

  A registration is a **claim**, not a grant. The Plugin says "this tool
  needs `ci:read`"; the host checks the Plugin's grant for `ci:read` on
  every call, through `Veritas.Plugin.Host.Capability.check/2`. A Plugin
  that claims a capability it was not granted is refused on the first call,
  not trusted because it asked nicely.

  This module is **Default**: the tool registry is one implementation of the
  idea that Plugins contribute surfaces. A different host may keep its
  surfaces elsewhere without changing the boundary.
  """

  alias Veritas.Plugin.{Host, Registry}

  @doc """
  Every tool the installed Plugins have registered.

  Each entry names the tool, the Plugin that contributed it, and the
  capabilities it needs.
  """
  @spec list() :: [map()]
  def list do
    Registry.list_installs()
    |> Enum.flat_map(fn install ->
      Enum.map(install.registrations, fn registration ->
        %{
          "name" => registration["name"],
          "plugin_id" => install.plugin_id,
          "required_scopes" => Map.get(registration, "required_scopes") || [],
          "description" => Map.get(registration, "description") || ""
        }
      end)
    end)
  end

  @doc """
  The registration of one tool, if a Plugin has made one.
  """
  @spec fetch(String.t(), String.t() | atom()) :: {:ok, map()} | :error
  def fetch(plugin_id, name) do
    wanted = to_string(name)

    case Registry.fetch_install(plugin_id) do
      {:ok, install} ->
        case Enum.find(install.registrations, &(&1["name"] == wanted)) do
          nil -> :error
          registration -> {:ok, registration}
        end

      :error ->
        :error
    end
  end

  @doc """
  Calls a tool a Plugin registered.

  The call goes through `Veritas.Plugin.Host.call/4`, so the grant is
  checked before the Plugin is spoken to.
  """
  @spec call(String.t(), String.t() | atom(), term(), map()) ::
          {:ok, term()} | {:error, term()}
  def call(plugin_id, name, params, context) do
    Host.call(plugin_id, name, params, context)
  end
end
