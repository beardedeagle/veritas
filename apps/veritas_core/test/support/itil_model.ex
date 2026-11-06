defmodule Veritas.Core.Test.Itil do
  @moduledoc """
  The reference model, transcribed from `docs/02` §State machines.

  This is the corpus's own lifecycle tables, not the product's transition
  table. The difference matters: the product reads its legal transitions from
  data (ADR-003), so a test written against that data agrees with the
  product by construction and proves nothing. A test written against **this**
  model is a statement about the product and the corpus at the same time.

  ## The Incident lifecycle

      new          → acknowledged · cancelled
      acknowledged → in_progress · on_hold
      in_progress  → on_hold · resolved
      on_hold      → in_progress · resolved
      resolved     → closed · in_progress
      closed, cancelled → terminal

  The two edges that once needed the approval machinery — `acknowledged →
  on_hold` and `on_hold → resolved` — have landed, so the deferred set is
  empty. It is kept as a set rather than deleted, because it is the shape the
  corpus allows: a transition outside the model must never be accepted, and a
  transition inside it may be deferred — and the deferred set is asserted, so
  it cannot grow unnoticed.

  ## The other lifecycles

  The Service Request, Change, Problem and Vulnerability tables are here for
  the same reason. A ticket type whose product vocabulary has drifted from
  `docs/02` must be visible, not assumed.
  """

  @incident_states ~w(new acknowledged in_progress on_hold resolved closed cancelled)

  @incident_transitions [
    {"new", "acknowledged"},
    {"new", "cancelled"},
    {"acknowledged", "in_progress"},
    {"acknowledged", "on_hold"},
    {"in_progress", "on_hold"},
    {"in_progress", "resolved"},
    {"on_hold", "in_progress"},
    {"on_hold", "resolved"},
    {"resolved", "closed"},
    {"resolved", "in_progress"}
  ]

  # docs/02 §Service Request
  @service_request_transitions [
    {"submitted", "authorized"},
    {"submitted", "rejected"},
    {"submitted", "cancelled"},
    {"authorized", "scheduled"},
    {"authorized", "in_progress"},
    {"authorized", "cancelled"},
    {"authorized", "rejected"},
    {"scheduled", "in_progress"},
    {"scheduled", "cancelled"},
    {"in_progress", "completed"},
    {"in_progress", "cancelled"},
    {"completed", "closed"},
    {"completed", "in_progress"}
  ]

  # docs/02 §Change
  @change_transitions [
    {"draft", "submitted"},
    {"draft", "withdrawn"},
    {"submitted", "authorized"},
    {"submitted", "rejected"},
    {"submitted", "withdrawn"},
    {"authorized", "scheduled"},
    {"authorized", "in_progress"},
    {"authorized", "withdrawn"},
    {"scheduled", "in_progress"},
    {"scheduled", "authorized"},
    {"scheduled", "withdrawn"},
    {"in_progress", "implemented"},
    {"in_progress", "failed"},
    {"implemented", "review"},
    {"failed", "review"},
    {"review", "closed"},
    {"review", "implemented"}
  ]

  @deferred_transitions []

  @ticket_types ~w(service_request incident change problem vulnerability)

  @initial_states %{
    "service_request" => "submitted",
    "incident" => "new",
    "change" => "draft",
    "problem" => "new",
    "vulnerability" => "new"
  }

  @lifecycles %{
    "service_request" => @service_request_transitions,
    "incident" => @incident_transitions,
    "change" => @change_transitions
  }

  @doc "The Incident states, as `docs/02` defines them."
  def incident_states, do: @incident_states

  @doc "The Incident transitions `docs/02` defines."
  def incident_transitions, do: @incident_transitions

  @doc """
  The Incident transitions the product defers.

  These are legal in `docs/02` and absent from the shipped table. The set is
  empty: the shipped table is the whole `docs/02` Incident lifecycle.
  """
  def deferred_transitions, do: @deferred_transitions

  @doc "The ticket types the product knows."
  def ticket_types, do: @ticket_types

  @doc "The state a ticket of this type starts in, per `docs/02`."
  def initial_state(ticket_type), do: Map.fetch!(@initial_states, ticket_type)

  @doc """
  The corpus's transitions for a ticket type.

  Types the corpus models but this reference does not yet transcribe answer
  with an empty list, so a test over them is a test over nothing.
  """
  def transitions_for(ticket_type), do: Map.get(@lifecycles, ticket_type, [])

  @doc "The corpus's transitions out of a state, for a ticket type."
  def transitions_from(ticket_type, state) do
    for {from, to} <- transitions_for(ticket_type), from == state, do: to
  end

  @doc "The shipped table is the `docs/02` model minus the deferred edges."
  def shipped_transitions do
    @incident_transitions -- @deferred_transitions
  end

  @doc "Whether a transition is legal for an Incident, per `docs/02`."
  def legal_transition?(from_state, to_state) do
    {from_state, to_state} in @incident_transitions
  end

  @doc """
  The state space a property ranges over.

  Every state of every lifecycle the corpus models, plus names that are not
  states of any ticket type. `docs/02` is explicit that `escalated` is never
  stored as a ticket state, and a property that only tried legal targets
  would prove nothing.
  """
  @doc """
  The names that are not states of any ticket type.

  `docs/02` is explicit that `escalated` is never stored as a ticket state,
  only an event. A property that only tried legal targets would prove nothing.
  """
  def not_a_state do
    ~w(escalated authorised investigating triaging drafted proposed)
  end

  def state_space do
    @incident_states ++
      ~w(authorized rejected scheduled completed fulfilled triaged implemented
         failed review withdrawn drafted proposed triaging) ++
      ~w(escalated scheduled authorised triaged investigating)
  end
end
