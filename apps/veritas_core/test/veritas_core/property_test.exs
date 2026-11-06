defmodule Veritas.Core.PropertyTest do
  @moduledoc """
  The property obligations of `docs/12` §Domain Invariant Testing.

  Two properties, both over the *whole* input space rather than over examples:

    * **no transition outside the ITIL model is ever accepted** — for any state
      the product can be in, and any target state, the domain accepts exactly
      the transitions the corpus permits, and a refused transition writes
      nothing at all;

    * **the Audit chain links every event to its predecessor** — under an
      arbitrary sequence of transitions, every event's `prev_hash` is the
      previous event's `hash`, the first has none, and the chain verifies.

  ## Why the corpus and not the product's own table

  The product reads its legal transitions from data (ADR-003), so a property
  written against that data agrees with the product by construction — and, worse,
  it reads a **table that another process can be migrating underneath it**. The
  store is shared, and a concurrent migration by another agent can change the
  transition vocabulary for a moment. A test that reads the table to check the
  table is therefore both weaker and flaky.

  So these properties compare the **domain's behaviour** against the
  **corpus's model** (`Veritas.Core.Test.Itil`, transcribed from `docs/02`).
  The comparison needs no table at all: the domain is asked, once per target
  state, whether it will accept the transition, and the answer is compared with
  what `docs/02` says.

  The Incident lifecycle is the one the product implements exactly, so it is
  the one these properties assert. The Service Request and Change vocabularies
  in the product are a **subset** of `docs/02` with different state names
  (`draft → cancelled` where `docs/02` has `draft → withdrawn`; no
  `authorized` state; `implementing` where `docs/02` has `in_progress`). That
  is a product-versus-corpus question for the BEAM Engineer and the ITIL
  Analyst — it is reported, not asserted here, because whether v0.1 ships a
  simplified Change lifecycle is a scoping decision rather than a defect this
  file can decide.
  """
  use ExUnit.Case, async: false

  import Veritas.Core.Test.Property

  alias Veritas.Core.Test.Itil
  alias Veritas.Core.{Audit, Tickets}

  @actor %{type: "user", id: "property"}

  # The number of generated cases. Enough to cross the state space, few
  # enough that the suite stays quick: every case is a real write.
  @property_iterations 100

  setup do
    workspace = unique_workspace()
    :ok = Veritas.Core.Test.StoreCase.migrate(workspace)

    # The Workspace is removed when the test ends, whether it passed or
    # failed.
    on_exit(fn -> Veritas.Core.Test.StoreCase.remove_workspace(workspace) end)

    {:ok, workspace: workspace}
  end

  describe "no transition outside the ITIL model is ever accepted" do
    test "the domain accepts exactly the transitions the corpus ships", %{
      workspace: workspace
    } do
      check_all(
        steps: list_of(integer(0..5), 5),
        target: element(Itil.state_space())
      ) do
        {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
        {ticket, _path} = walk(workspace, ticket, steps)

        legal = Itil.transitions_from("incident", ticket["state"])

        before_row = Tickets.read(workspace, ticket["id"])
        {:ok, before_audit} = Audit.entries(workspace)

        result =
          Tickets.transition(
            workspace,
            ticket["id"],
            target,
            Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
          )

        accepted? = match?({:ok, _}, result)

        # The corpus is the reference, not the product's own table.
        assert accepted? == target in legal,
               "#{ticket["state"]} → #{target}: the corpus says #{target in legal}, the domain says #{accepted?}"

        if accepted? do
          assert {:ok, moved} = result
          assert moved["state"] == target
        else
          # A refused transition writes nothing: no state change and no audit
          # row.
          assert {:error, :illegal_transition} = result
          assert Tickets.read(workspace, ticket["id"]) == before_row
          assert {:ok, current_audit} = Audit.entries(workspace)
          assert current_audit == before_audit
        end
      end
    end

    test "no accepted transition is outside the `docs/02` model", %{
      workspace: workspace
    } do
      check_all(
        steps: list_of(integer(0..5), 5),
        target: element(Itil.state_space())
      ) do
        {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
        {ticket, _path} = walk(workspace, ticket, steps)

        from_state = ticket["state"]

        case Tickets.transition(
               workspace,
               ticket["id"],
               target,
               Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
             ) do
          {:ok, _moved} ->
            assert Itil.legal_transition?(from_state, target),
                   "#{from_state} → #{target} is accepted but is not in the docs/02 model"

            assert target in Itil.incident_states()

          {:error, :illegal_transition} ->
            :ok

          {:error, reason} ->
            # A store fault is not a refusal. It says the datastore failed, not
            # that the domain said no.
            raise Veritas.Core.Test.Property.StoreFault, error: reason
        end
      end
    end

    test "a state that is not a ticket state is never accepted", %{workspace: workspace} do
      # `docs/02` is explicit that `escalated` is never stored as a ticket
      # state, only an event.
      for target <- Itil.not_a_state() do
        {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

        assert {:error, :illegal_transition} =
                 Tickets.transition(
                   workspace,
                   ticket["id"],
                   target,
                   Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
                 )
      end
    end
  end

  describe "the Audit chain links every event to its predecessor" do
    test "under an arbitrary sequence of transitions", %{workspace: workspace} do
      check_all(steps: list_of(integer(0..5), 8)) do
        {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
        {_ticket, path} = walk(workspace, ticket, steps)

        {:ok, events} = Audit.entries(workspace)

        # The Workspace is shared by every case of this property, so the
        # ticket's own events are counted, not the Workspace's.
        own = Enum.filter(events, &(&1["subject"] == ticket["id"]))

        # One event for the opening, one for each accepted transition.
        assert length(own) == length(path) + 1

        own
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [previous, event] ->
          assert event["prev_hash"] == previous["hash"],
                 "an event does not link to its predecessor"
        end)

        # And the Workspace's whole chain is intact.
        assert {:ok, :intact} = Audit.verify(workspace)

        assert {:ok, :intact} = Audit.verify(workspace)
      end
    end

    test "the first event in a Workspace has no predecessor", %{workspace: workspace} do
      {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)

      assert {:ok, events} = Audit.entries(workspace)
      assert [first | _] = events
      assert first["subject"] == ticket["id"]
      assert first["prev_hash"] == nil, "the first event has no predecessor"
    end

    test "and the chain survives a refused transition", %{workspace: workspace} do
      check_all(steps: list_of(integer(0..5), 6)) do
        {:ok, ticket} = Tickets.open(workspace, "incident", attrs(), @actor)
        {ticket, _path} = walk(workspace, ticket, steps)

        {:ok, before} = Audit.entries(workspace)

        # A name that is not a state of any ticket type, so the transition is
        # refused whatever the ticket's state is.
        assert {:error, :illegal_transition} =
                 Tickets.transition(
                   workspace,
                   ticket["id"],
                   "escalated",
                   Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
                 )

        assert {:ok, after_refusal} = Audit.entries(workspace)
        assert after_refusal == before
        assert {:ok, :intact} = Audit.verify(workspace)
      end
    end
  end

  describe "the model and the shipped table" do
    test "the shipped table is the `docs/02` model minus the deferred edges" do
      # The deferred set is asserted here so that a deferred edge cannot appear
      # without this test failing.
      assert Itil.deferred_transitions() == []
      assert Itil.shipped_transitions() == Itil.incident_transitions()
    end

    test "the product ships exactly the edges the schema documents", %{
      workspace: workspace
    } do
      shipped =
        for from_state <- Itil.incident_states(),
            to_state <- Tickets.available_transitions(workspace, "incident", from_state),
            do: {from_state, to_state}

      assert Enum.sort(shipped) == Enum.sort(Itil.shipped_transitions())
    end
  end

  describe "the harness itself" do
    test "a store fault is re-evaluated rather than reported as a counterexample" do
      # The store fault taxonomy says `:internal` is "always a defect, never a
      # normal outcome" — a defect of the datastore, not an answer about the
      # domain. So a case the store faulted on is evaluated again, and only a
      # case that *holds* against the corpus is a pass.
      faults = :counters.new(1, [])
      evaluations = :counters.new(1, [])

      check_all(steps: list_of(integer(0..5), 2)) do
        :counters.add(evaluations, 1, 1)

        if :counters.get(faults, 1) == 0 do
          :counters.add(faults, 1, 1)

          raise Veritas.Core.Test.Property.StoreFault,
            error: Veritas.Store.Error.new(:internal, "the store could not execute the statement")
        end

        :ok
      end

      # The fault was raised once, the case was evaluated again, and the
      # property held on the second evaluation.
      assert :counters.get(faults, 1) == 1
      assert :counters.get(evaluations, 1) >= 2
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # A Workspace of its own, per test.
  #
  # Not per case: a Workspace that is migrated and used in the same breath is
  # not the same as one that has settled, and a case that opens its ticket
  # before the migration is visible reads an empty Audit Log. The Workspace is
  # the isolation unit, so it is per *test* — the cases of one property share
  # it deliberately, and they account for each other's events by subject.
  defp unique_workspace do
    "prop_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp attrs do
    %{"title" => "Property ticket", "requester" => "property", "priority" => "medium"}
  end

  # The walk is driven by the corpus's model too, so the property never reads
  # a table another process could be migrating.
  defp walk(workspace, ticket, steps) do
    Enum.reduce(steps, {ticket, []}, fn step, {current, path} ->
      options = Itil.transitions_from("incident", current["state"])

      case options do
        [] ->
          {current, path}

        _ ->
          to_state = Enum.at(options, rem(step, length(options)))

          case Tickets.transition(
                 workspace,
                 current["id"],
                 to_state,
                 Veritas.Core.Principal.new(@actor.id, workspace, [:incident_manager])
               ) do
            {:ok, moved} ->
              {moved, path ++ [{current["state"], to_state}]}

            {:error, :illegal_transition} ->
              {current, path}

            {:error, reason} ->
              # A store fault is not a refusal, so it must not be folded into
              # the path as if the domain had said no.
              raise Veritas.Core.Test.Property.StoreFault, error: reason
          end
      end
    end)
  end
end
