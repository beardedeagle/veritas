defmodule Veritas.Agentic.LLM.AdapterRegistry do
  @moduledoc """
  The catalogue of adapter **implementations** that are compiled in.

  This is not the Provider registry. The catalogue says which adapter
  *code* exists — `ollama`, `openai_compatible`, `anthropic` — and the
  Provider registry says which provider *instances* a Workspace uses
  (`docs/39` §3.1). They are different things and are named apart.

  ## The catalogue is runtime data

  Nothing about the choice is compiled in: an adapter is registered by id,
  and the ids are resolved at call time. That is what makes swapping a
  provider a configuration change rather than a code change (`docs/15`
  §Configuration, B4).

  ## Where it lives

  An ETS table, created by the process that owns it. The host starts
  `veritas_core`; adapters bring their own dependencies and their own
  children, so the catalogue is **not** a supervision tree the Port requires
  (`docs/15` §Port constraints).

  ## What is registered

  The adapters themselves are registered by the application that owns them —
  `veritas_agent` registers the ones it ships — because a module in
  `veritas_core` may not name an adapter (`docs/15` §Compiler-enforced
  mechanism, rule 3: no non-adapter module may reference
  `Veritas.Agentic.LLM.Adapter.*`).
  """

  @table :veritas_agentic_adapters

  @doc """
  Registers an adapter under its id.

  Called by the application that owns the adapter. Registering the same id
  twice replaces the entry, so an operator may substitute an adapter without
  a restart.
  """
  @spec register(atom(), module()) :: :ok
  def register(id, adapter) when is_atom(id) and is_atom(adapter) do
    ensure_table()
    :ets.insert(@table, {id, adapter})
    :ok
  end

  @doc """
  The adapter registered under an id.

  The id may be an atom or the string it was persisted as — a stored
  identifier comes back from the store as a string, and an id that names no
  registered adapter is `:error` rather than an exception.
  """
  @spec fetch(atom() | String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_atom(id) and not is_nil(id) do
    ensure_table()

    case :ets.lookup(@table, id) do
      [{^id, adapter}] -> {:ok, adapter}
      [] -> :error
    end
  end

  def fetch(id) when is_binary(id) do
    case existing_atom(id) do
      {:ok, atom} -> fetch(atom)
      :error -> :error
    end
  end

  def fetch(_other), do: :error

  @doc """
  The id the catalogue knows, given a name.

  A name may be an atom or the string it was persisted or configured as. A
  **string** is matched against the *registered* ids, so nothing here grows
  the atom table from stored or configured data: a name the catalogue does
  not hold is a refusal, not a new atom.

  `String.to_atom/1` would make the atom table a function of whatever a
  configuration or a store row said, and `String.to_existing_atom/1` would
  raise on a name that is not interned yet. Neither is an answer.
  """
  @spec resolve_id(atom() | String.t()) :: {:ok, atom()} | {:error, term()}
  def resolve_id(id) when is_atom(id) and not is_nil(id) do
    ensure_table()

    if :ets.member(@table, id) do
      {:ok, id}
    else
      {:error, {:unknown_adapter, id}}
    end
  end

  def resolve_id(id) when is_binary(id) do
    ensure_table()

    case Enum.find(ids(), &(Atom.to_string(&1) == id)) do
      nil -> {:error, {:unknown_adapter, id}}
      atom -> {:ok, atom}
    end
  end

  def resolve_id(id), do: {:error, {:unknown_adapter, id}}

  @doc """
  The ids in the catalogue, sorted.
  """
  @spec ids() :: [atom()]
  def ids do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {id, _adapter} -> id end)
    |> Enum.sort()
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _reference -> @table
    end
  end

  # A stored identifier names an adapter the host already knows, so the atom
  # already exists. `String.to_atom/1` would grow the atom table from stored
  # data, which is why it is not used here.
  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end
end
