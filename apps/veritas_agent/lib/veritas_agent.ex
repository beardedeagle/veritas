defmodule Veritas.Agent do
  @moduledoc """
  The agent runtime.

  Provider adapters, the agent runner, and the approval gate live here
  (`docs/06`, `docs/15`). The agentic **Port** itself belongs to
  `Veritas.Core` so that no framework type can reach a domain context
  (INV-1) and so the port can be substituted without forking.

  This application is deliberately empty at v0.1: the approval machinery lands
  in v0.4, and the runner in v0.4 alongside it. The module exists now so the
  four-application layout (ADR-030) is real from the first commit and the
  supervision tree does not have to be reshaped later.
  """
end
