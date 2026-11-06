defmodule Veritas.Plugin.Host.Capability do
  @moduledoc """
  The single enforcement point for every Plugin operation.

  `docs/20` §Capability Grants names this function and its position in the
  design: **there is exactly one**, and every Plugin operation — including
  one reached indirectly through a GraphQL extension or a registered agent
  tool — passes through it before any side effect.

  The rule it enforces is "re-validated": on **every** call the grant set is
  re-read and the required scope checked. Not at registration, not per
  session. So a grant that was revoked a second ago is refused now, and a
  grant that was given after the Plugin started is honoured now.

  The grant set is read from `Veritas.Plugin.Registry` on every call rather
  than cached in the session, which is what makes "re-read" true rather than
  "read once".

  A denial is **returned, not swallowed**: `{:error, :scope_denied}` is the
  answer, and a denied read is a detection signal, per `docs/09` §4.

  The scope may be given as an atom (`:ci_read`) or as the string a manifest
  writes (`"ci:read"`). Both name the same scope; the atom is how a call
  site reads, and the string is how a manifest declares.
  """

  alias Veritas.Plugin.{Capability, Registry}

  @type context :: %{
          required(:plugin_id) => String.t(),
          required(:workspace) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Whether the Plugin in this context holds this scope.

  Returns `:ok` or `{:error, :scope_denied}`.
  """
  @spec check(context(), atom() | String.t()) :: :ok | {:error, :scope_denied}
  def check(context, scope) do
    case grant(context) do
      {:ok, granted} ->
        if to_scope(scope) in granted do
          :ok
        else
          {:error, :scope_denied}
        end

      :error ->
        {:error, :scope_denied}
    end
  end

  @doc """
  Whether the Plugin holds every one of these scopes.
  """
  @spec check_all(context(), [atom() | String.t()]) :: :ok | {:error, :scope_denied}
  def check_all(context, scopes) when is_list(scopes) do
    Enum.reduce_while(scopes, :ok, fn scope, :ok ->
      case check(context, scope) do
        :ok -> {:cont, :ok}
        denial -> {:halt, denial}
      end
    end)
  end

  @doc """
  The scopes a Plugin currently holds, re-read from the registry.
  """
  @spec granted(context()) :: [String.t()]
  def granted(context) do
    case grant(context) do
      {:ok, granted} -> granted
      :error -> []
    end
  end

  # The grant, and the workspace it is granted in.
  #
  # A Plugin that is workspace-scoped holds its grant in one Workspace, and
  # a call that names another Workspace is refused — the Workspace is part
  # of the grant, not a detail of the call.
  defp grant(context) when is_map(context) do
    with plugin_id when is_binary(plugin_id) <- Map.get(context, :plugin_id),
         {:ok, install} <- Registry.fetch_install(plugin_id) do
      if workspace_matches?(context, install) do
        {:ok, install.granted_scopes}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp grant(_context), do: :error

  defp workspace_matches?(context, install) do
    if workspace_scoped?(install) do
      requested = Map.get(context, :workspace)
      is_nil(requested) or requested == install.workspace
    else
      true
    end
  end

  defp workspace_scoped?(install) do
    install.manifest
    |> Map.get("permissions", %{})
    |> Map.get("workspace_scoped") == true
  end

  defp to_scope(scope) when is_atom(scope), do: Capability.to_scope(scope)
  defp to_scope(scope) when is_binary(scope), do: scope
end
