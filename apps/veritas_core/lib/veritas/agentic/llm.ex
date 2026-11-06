defmodule Veritas.Agentic.LLM do
  @moduledoc """
  The only LLM surface the domain may see.

  The Port is the seam that lets Veritas swap its model library without
  touching domain code (`docs/15`). It has **three callbacks** and returns
  **host-owned structs**; nothing framework-shaped appears in any signature.

  ## What crosses the boundary

  `complete/3` answers once, `stream/3` answers with the same `Response`
  shape, and `models/2` asks the provider what it has. The configuration is a
  **plain map** — never a framework config struct — and the raw provider
  payloads ride in the `raw` fields, which the domain never reads.

  ## What the Port does not do

  It does not retry, and it does not own the agent loop. Both are host
  concerns (`docs/15` §Agent Loop Ownership): every attempt must be an
  auditable row, and the approval gate lives in Veritas, not in a library.

  ## The two types the corpus names but does not define

  `opts` names `Veritas.Agentic.LLM.Cancel.t()` and
  `Veritas.Agentic.LLM.Event.t()`. **Neither struct is defined anywhere in
  the corpus** — `docs/39` §F7 raises it as a finding for the Architect, and
  `docs/39` is explicit that the console does not get to invent them. The
  types are named here exactly as `docs/15` writes them, so the Port is ready
  for the ruling; until then the adapters report `:unsupported` for
  streaming rather than inventing a delivery shape.
  """

  alias Veritas.Agentic.LLM.{Error, Model, Request, Response}

  @typedoc """
  The adapter's configuration.

  A plain map, never a framework config struct (`docs/15` §Port
  constraints).
  """
  @type config :: map()

  @typedoc """
  Per-call options.

  `:cancel` and `:on_event` name the two boundary structs `docs/15` refers
  to and does not define (`docs/39` §F7).
  """
  @type opts :: [
          timeout: pos_integer(),
          cancel: Veritas.Agentic.LLM.Cancel.t(),
          on_event: (Veritas.Agentic.LLM.Event.t() -> term())
        ]

  @doc """
  Answers a request, once.
  """
  @callback complete(Request.t(), config(), opts()) ::
              {:ok, Response.t()} | {:error, Error.t()}

  @doc """
  Answers a request, delivering the answer as it arrives.

  The delivery vehicle is `opts[:on_event]`, whose event type `docs/39` §F7
  leaves unspecified.
  """
  @callback stream(Request.t(), config(), opts()) ::
              {:ok, Response.t()} | {:error, Error.t()}

  @doc """
  The models the provider reports.
  """
  @callback models(config()) :: {:ok, [Model.t()]} | {:error, Error.t()}
end
