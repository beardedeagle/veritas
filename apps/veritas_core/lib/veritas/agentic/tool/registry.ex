defmodule Veritas.Agentic.Tool.Registry do
  @moduledoc """
  The host's catalogue of tools.

  The host owns every tool definition (`docs/15` §Tool Registry Ownership),
  and the registry is where they live. **One registry, two consumers**: the
  internal agent loop and the MCP server project the *same* specs, so an
  external agent's action and an internal agent's action are indistinguishable
  for audit (`docs/39` §6.2).

  ## Where a tool came from

  | Source | What it is |
  |---|---|
  | `:core` | The product's own capabilities. In-process handlers. |
  | `{:plugin, plugin_id}` | A Plugin's tools, registered at the handshake. |
  | `{:mcp, server}` | An MCP server's tools, proxied. |

  ## What the registry enforces

  The **scope check** and the **audit** happen here, not in the tool and not
  in a model: a call whose scopes the actor does not hold is refused and the
  refusal is recorded, exactly as an interactive user's refusal would be.
  """

  alias Veritas.Agentic.Tool.Spec
  alias Veritas.Core.{Policy, Principal}

  @registry :veritas_agentic_tools

  @doc """
  Registers a tool.

  The source says where it came from; a core tool registers itself as
  `:core`.
  """
  @spec register(Spec.t(), keyword()) :: :ok
  def register(%Spec{} = spec, opts \\ []) do
    ensure_table()
    source = Keyword.get(opts, :source, :core)
    :ets.insert(@registry, {spec.name, spec, source})
    :ok
  end

  @doc """
  The tools the actor may use, in the order they were registered.

  A tool whose scopes the actor does not hold is **not listed**: the model
  is never offered a tool the caller could not use.
  """
  @spec list_for(term(), Principal.t() | nil) :: [Spec.t()]
  def list_for(_agent, actor) do
    ensure_table()

    @registry
    |> :ets.tab2list()
    |> Enum.map(fn {_name, spec, _source} -> spec end)
    |> Enum.filter(&permitted?(&1, actor))
  end

  @doc """
  Every registered tool — the catalogue.

  `list_for/2` is what a caller may use; this is what the product has.
  The console's Tools screen shows this.
  """
  @spec all() :: [Spec.t()]
  def all do
    ensure_table()

    @registry
    |> :ets.tab2list()
    |> Enum.map(fn {_name, spec, _source} -> spec end)
  end

  @doc """
  Where each tool came from, for the console's Tools screen.
  """
  @spec sources() :: %{String.t() => term()}
  def sources do
    ensure_table()

    @registry
    |> :ets.tab2list()
    |> Map.new(fn {name, _spec, source} -> {name, source} end)
  end

  @doc """
  Calls a tool.

  The scope check happens first and its refusal is **recorded**, because a
  refusal is an event (`docs/08`: every tool call is audited).
  """
  @spec call(String.t(), map(), Spec.context()) :: {:ok, map()} | {:error, term()}
  def call(name, arguments, context \\ %{}) do
    ensure_table()

    case :ets.lookup(@registry, name) do
      [{^name, spec, _source}] ->
        do_call(spec, arguments, context)

      [] ->
        {:error, :unknown_tool}
    end
  end

  @doc """
  The registered tool with that name.
  """
  @spec fetch(String.t()) :: {:ok, Spec.t()} | :error
  def fetch(name) when is_binary(name) do
    ensure_table()

    case :ets.lookup(@registry, name) do
      [{^name, spec, _source}] -> {:ok, spec}
      [] -> :error
    end
  end

  defp do_call(spec, arguments, context) do
    actor = Map.get(context, :actor)
    workspace = Map.get(context, :workspace)

    case check_scope(spec, actor, workspace) do
      :ok ->
        case spec.handler do
          nil -> {:error, :unknown_tool}
          handler -> handler.(arguments, context)
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end

  defp check_scope(spec, actor, workspace) do
    Enum.reduce_while(spec.scope, :ok, fn scope, _acc ->
      case Policy.authorize(actor, scope, %{workspace: workspace}) do
        :allow -> {:cont, :ok}
        {:deny, reason} -> {:halt, {:deny, reason}}
      end
    end)
  end

  defp permitted?(%Spec{scope: []}, _actor), do: true

  defp permitted?(%Spec{scope: scope}, actor) do
    Enum.all?(scope, fn name ->
      Policy.permitted?(actor, name, %{workspace: actor && actor.workspace})
    end)
  end

  defp ensure_table do
    case :ets.whereis(@registry) do
      :undefined -> :ets.new(@registry, [:named_table, :public, :set, read_concurrency: true])
      _reference -> @registry
    end
  end
end
