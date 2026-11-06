defmodule Veritas.Agentic.Tool.Spec do
  @moduledoc """
  A tool, as the **host** holds it.

  The registry entry carries the policy; the port's `LLM.Tool` carries only
  what a model needs (`docs/15` §Tool Registry Ownership). Nothing here
  reaches a provider.

  ## The fields that are policy

    * `:scope` — the permission scopes the tool needs.
    * `:side_effect` — `:read`, `:write`, `:destructive` or `:external`.
    * `:approval` — `:never`, `:always`, or a condition the host decides
      from the arguments. **A read-only tool never asks** (`docs/39` §2.4).
    * `:timeout_ms` and `:idempotent` — the host's own bounds.

  ## The fields that are the tool

    * `:name`, `:description` and `:parameters` — the parameters are
      **host-canonical JSON Schema**, so the same tool appears in every
      adapter's request without rewriting.
    * `:handler` — an in-process host function. A **core capability** is a
      built-in tool, not a Plugin and not an adapter (`docs/39` §6.1).
  """

  alias Veritas.Agentic.LLM

  @typedoc "The side effect a tool has."
  @type side_effect :: :read | :write | :destructive | :external

  @typedoc "When a tool needs a human's approval."
  @type approval :: :never | :always | {:conditional, (map() -> boolean())}

  @typedoc "The context a handler is given."
  @type context :: %{
          optional(:workspace) => String.t(),
          optional(:actor) => Veritas.Core.Principal.t() | nil,
          optional(:agent) => term(),
          optional(:run_id) => String.t() | nil
        }

  @typedoc "One tool."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          scope: [String.t()],
          side_effect: side_effect(),
          approval: approval(),
          timeout_ms: pos_integer(),
          idempotent: boolean(),
          handler: (map(), context() -> {:ok, map()} | {:error, Veritas.Store.Error.t()}) | nil
        }

  defstruct name: "",
            description: "",
            parameters: %{"type" => "object", "properties" => %{}},
            scope: [],
            side_effect: :read,
            approval: :never,
            timeout_ms: 10_000,
            idempotent: true,
            handler: nil

  @doc """
  The only projection an adapter ever sees.

  The scope, the side-effect class, the approval policy, the timeout and
  the idempotency flag are **host-side** and never cross the boundary.
  """
  @spec llm_projection(t()) :: LLM.Tool.t()
  def llm_projection(%__MODULE__{} = spec) do
    %LLM.Tool{
      name: spec.name,
      description: spec.description,
      parameters: spec.parameters
    }
  end
end
