defmodule Veritas.Plugin do
  @moduledoc """
  The plugin host: a Plugin is a guest, not a resident.

  This is the module that says what the plugin platform *is*, and the rest
  of the package is how it is kept true.

  ## What a Plugin is

  A **Plugin** is a separate OS process that speaks JSON-RPC 2.0 over a
  Unix domain socket (`docs/20` §Transport). It is not a BEAM process, not a
  module in this host, and not a dependency of it. It runs with an empty
  environment and no datastore credentials, and the only way it reaches
  anything is by asking the host.

  ## What that buys

  A Plugin can be written in Go, Python, Rust or Node with no dependency at
  all, and it can be replaced without the host being recompiled. The host
  keeps the authority and the Plugin keeps the code, and the boundary
  between them is a versioned protocol rather than an in-VM callback.

  ## The parts

    * `Veritas.Plugin.Manifest` — the manifest gate. Nothing is launched
      before the manifest is proven.
    * `Veritas.Plugin.Capability` — the closed vocabulary of scopes.
    * `Veritas.Plugin.Host` — the Port a Plugin reaches the host through,
      and `Veritas.Plugin.Host.Capability` — the one function every call
      passes through.
    * `Veritas.Plugin.Install` — the lifecycle: install, verify, start,
      stop, uninstall.
    * `Veritas.Plugin.Tool` — the tools Plugins contribute.
    * `Veritas.Plugin.Transport` — the seam the boundary is spoken over.
    * `Veritas.Plugin.Example` — the host's own example Plugin, a real
      separate process, so the description above is demonstrable.
  """

  alias Veritas.Core.{Policy, Principal}
  alias Veritas.Plugin.{Host, Install, Manifest, Tool}
  alias Veritas.Store.Error

  @doc """
  Installs a Plugin from its manifest.

  See `Veritas.Plugin.Install.install/2`.
  """
  @spec install(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  defdelegate install(manifest, opts \\ []), to: Install

  @doc """
  The installed Plugins.

  See `Veritas.Plugin.Install.list/0`.
  """
  @spec list() :: [map()]
  defdelegate list, to: Install

  @doc """
  Lists the installed plugins visible to a principal in one Workspace.

  Args:
    workspace (String.t()): The Workspace whose installs are requested.
    principal (Principal.t() | nil): The caller, checked through the host policy.

  Returns:
    {:ok, [map()]} with installation metadata, or {:error, Error.t()} for a
    denied request or an unavailable plugin host. Denials are audited.
  """
  @spec list(String.t(), Principal.t() | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def list(workspace, principal) do
    with :ok <- authorize_read(workspace, principal) do
      {:ok, Enum.filter(Install.list(), &(&1["workspace"] == workspace))}
    end
  catch
    :exit, _reason -> {:error, Error.new(:unavailable, "The plugin host is unavailable.")}
  end

  @doc """
  Calls a tool a Plugin registered.

  See `Veritas.Plugin.Host.call/4`.
  """
  @spec call(String.t(), atom() | String.t(), term(), map()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call(plugin_id, method, params, context), to: Host

  @doc """
  The tools the installed Plugins have registered.

  See `Veritas.Plugin.Tool.list/0`.
  """
  @spec tools() :: [map()]
  defdelegate tools(), to: Tool, as: :list

  @doc """
  Validates a manifest.

  See `Veritas.Plugin.Manifest.validate/1`.
  """
  @spec validate_manifest(map()) :: {:ok, map()} | {:error, String.t()}
  defdelegate validate_manifest(manifest), to: Manifest, as: :validate

  @doc """
  Checks a manifest's compatibility without installing or launching code.

  Args:
    workspace (String.t()): The caller's Workspace.
    manifest (term()): The decoded manifest to validate.
    principal (Principal.t() | nil): The caller, checked through the host policy.

  Returns:
    {:ok, map()} for a compatible manifest, or {:error, String.t() | Error.t()}
    for invalid input or a denied request. Denials are audited.
  """
  @spec validate_manifest(String.t(), term(), Principal.t() | nil) ::
          {:ok, map()} | {:error, String.t() | Error.t()}
  def validate_manifest(workspace, manifest, principal) do
    with :ok <- authorize_read(workspace, principal) do
      Manifest.validate(manifest)
    end
  end

  defp authorize_read(workspace, principal) do
    case Policy.authorize(principal, "plugin:read", %{workspace: workspace}) do
      :allow -> :ok
      {:deny, reason} -> {:error, Error.new(:permission_denied, reason)}
    end
  end
end
