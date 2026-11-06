defmodule Veritas.Plugin.Capability do
  @moduledoc """
  The capability vocabulary — the closed set of scopes a Plugin may ask for.

  "Closed" is the whole point: a manifest requesting an unknown scope is
  rejected at install, because an unknown scope is either a typo or an
  escalation attempt, and both are errors (`docs/08` §Capabilities Requested).

  The scopes below are the table in `docs/08`, and nothing else. A scope is
  written `resource:verb` in a manifest and held as an atom (`:ci_read`)
  in the host, so that a call site reads as the scope it is checking.

  This is **Fixed** by the corpus: the vocabulary is the contract between the
  host and the people who write Plugins, and it cannot grow without a corpus
  amendment.
  """

  @vocabulary ~w(
    ci:read
    ci:write
    ticket:read
    ticket:write
    ticket:transition
    graph:query
    ui:extend
    graphql:extend
    ingest:publish
    schedule:register
    webhook:register
    agent:tool
    agent:invoke
    secret:read
    audit:read
    secret:provision
  )

  @type scope :: String.t()
  @type scope_atom :: atom()

  @doc "The closed vocabulary, as the corpus's table lists it."
  @spec vocabulary() :: [scope()]
  def vocabulary, do: @vocabulary

  @doc "Whether a scope is in the vocabulary."
  @spec known?(term()) :: boolean()
  def known?(scope) when is_binary(scope), do: scope in @vocabulary
  def known?(_scope), do: false

  @doc """
  The scope a scope atom names.

  `:ci_read` is `ci:read`. The atom is how the host holds a scope at a call
  site; the string is what a manifest declares.
  """
  @spec to_scope(scope_atom()) :: scope()
  def to_scope(scope) when is_atom(scope) do
    scope |> Atom.to_string() |> String.replace("_", ":")
  end

  @doc "The scope atom a scope string names."
  @spec from_scope(scope()) :: scope_atom()
  def from_scope(scope) when is_binary(scope) do
    String.to_atom(String.replace(scope, ":", "_"))
  end
end
