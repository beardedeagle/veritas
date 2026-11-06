defmodule Veritas.Web.PubSub do
  @moduledoc """
  The PubSub server for the Phoenix endpoint.

  In `phoenix_pubsub` 2.x the server is started as a supervised child with
  a name, and the endpoint's `pubsub_server:` names that process:

      # in the supervision tree
      Veritas.Web.PubSub

      # in the endpoint's configuration
      pubsub_server: Veritas.Web.PubSub

  The older `use Phoenix.PubSub, name: …` form does not exist in 2.x — the
  macro is gone — so the child spec is written out here. The name in
  `config/config.exs` must match this module exactly: a mismatch surfaces as
  `unknown registry: Veritas.Web.PubSub` at the first channel join, which is
  why the name is asserted at boot rather than left to a runtime failure.
  """

  @doc """
  The child spec for the PubSub server.

  The name is fixed: the endpoint is configured with it, and the LiveView and
  channel machinery subscribe through it.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Phoenix.PubSub.child_spec(Keyword.put_new(opts, :name, __MODULE__))
  end
end
