defmodule Veritas.Core.Test.Property do
  @moduledoc """
  A small, seeded property harness.

  The domain's state machines are finite and enumerable, so the interesting
  question is not "does this example work" but "does this hold for every
  input". That needs a generator and a reproducible seed, which is all this
  module is.

  It exists because the project has no property-testing dependency, and adding
  one is a change to `apps/veritas_core/mix.exs` — the BEAM Engineer's file.
  This harness is deliberately small and deliberately in the test tree, so the
  suite runs today with no new dependency. If the project later takes on
  `stream_data`, this module is the seam to delete: the shape of a property
  (`check all(...) do ... end`) is deliberately the same.

  ## Seeding and reproducibility

  A property runs against a fixed seed, so a failure is reproducible: the
  failure message carries the seed and the generated values. Change the seed
  with `@property_seed` and the number of cases with `@property_iterations`,
  both set before the property is declared:

      @property_seed {17, 42, 99}
      @property_iterations 500
  """

  defmodule StoreFault do
    @moduledoc """
    A store fault: the store refused or failed a statement.

    It is **not** evidence about the domain's behaviour. A domain refusal is
    `{:error, :illegal_transition}` — a rule saying no. A store fault is the
    datastore failing to do what it was asked, which says nothing about whether
    the domain would have behaved correctly.

    The harness tells the two apart, so a store fault is never reported as a
    property that failed. See `docs/12` §Flakiness and Quarantine Policy.
    """

    defexception [:error]

    @impl true
    def message(%{error: error}) do
      "the store failed: " <> describe(error)
    end

    defp describe(error) do
      detail =
        try do
          Veritas.Store.Error.message(error)
        rescue
          _ -> nil
        end

      detail || inspect(error)
    end
  end

  defmodule Gen do
    @moduledoc "A seeded generator. The state is threaded explicitly, never hidden."

    defstruct [:state]

    @doc "A generator with a given seed."
    def new(seed), do: %Gen{state: :rand.seed_s(:exsss, seed)}

    @doc "Picks one element of a list."
    def pick(%Gen{} = g, []), do: {nil, g}

    def pick(%Gen{} = g, list) do
      {index, state} = :rand.uniform_s(length(list), g.state)
      {Enum.at(list, index - 1), %Gen{g | state: state}}
    end

    @doc "An integer in a range, inclusive."
    def int(%Gen{} = g, range) do
      min = range.first
      max = range.last
      {value, state} = :rand.uniform_s(max - min + 1, g.state)
      {min + value - 1, %Gen{g | state: state}}
    end

    @doc "A list of up to `max` values from a generator function."
    def list_of(%Gen{} = g, fun, max) do
      {count, g} = int(g, 0..max)

      Enum.reduce(1..count//1, {[], g}, fn _index, {acc, g} ->
        {value, g} = fun.(g)
        {[value | acc], g}
      end)
      |> then(fn {acc, g} -> {Enum.reverse(acc), g} end)
    end
  end

  @default_seed {2026, 10, 25}
  @default_iterations 200

  @doc """
  Picks one element of a list.

      check all(state <- Gen.element(States.all())) do
        ...
      end
  """
  def element(list), do: fn g -> Gen.pick(g, list) end

  @doc "An integer in a range, inclusive."
  def integer(range), do: fn g -> Gen.int(g, range) end

  @doc "A list of up to `max` values."
  def list_of(fun, max), do: fn g -> Gen.list_of(g, fun, max) end

  @doc """
  Runs the body against many generated cases.

      check_all(
        type: Gen.element(Tickets.ticket_types()),
        to_state: Gen.element(States.all())
      ) do
        ...
      end

  Each generator is a keyword entry whose value is a generator function. The
  body must be true for every generated case. A failure names the seed and
  the values that produced it, so the case can be replayed.

  The keyword form is used rather than the `x <- generator` form because
  Elixir expands a bare `x <- gen` as an operator expression and rejects it
  as an undefined variable before any macro can see it. The names in the
  keyword list are bound in the body, so the body reads the same either way.
  """
  defmacro check_all(generators, do: body) do
    gens = for {key, expr} <- generators, do: {key_name(key), expr}

    names = Enum.map(gens, fn {name, _expr} -> name end)
    vars = Enum.map(names, fn name -> Macro.var(name, nil) end)
    pattern = {:%{}, [], Enum.zip(names, vars)}
    assertion = {:fn, [], [{:->, [], [[pattern], [do: body]]}]}

    seed =
      Module.get_attribute(__CALLER__.module, :property_seed) || @default_seed

    iterations =
      Module.get_attribute(__CALLER__.module, :property_iterations) || @default_iterations

    quote do
      Veritas.Core.Test.Property.check_all(
        unquote(Macro.escape(seed)),
        unquote(iterations),
        unquote(names),
        unquote(Enum.map(gens, fn {_name, expr} -> expr end)),
        unquote(assertion)
      )
    end
  end

  defp key_name({name, _meta, _context}) when is_atom(name), do: name
  defp key_name(name) when is_atom(name), do: name

  @doc "Runs the assertion function against `iterations` generated cases."
  def check_all(seed, iterations, names, generators, assertion_fun) do
    gen = Gen.new(seed)

    Enum.reduce(1..iterations, gen, fn iteration, g ->
      {values, g} = Enum.map_reduce(generators, g, fn generator, g -> generator.(g) end)
      values = Map.new(Enum.zip(names, values))

      # Isolation, not a retry. The store this suite migrated is the store the
      # case is evaluated against: a test that starts a store of its own
      # publishes into the application environment, and the Adapter reads that
      # environment on every request. The property is still asserted on every
      # case.
      Veritas.Core.Test.StoreCase.pin_store_configuration()

      case evaluate(assertion_fun, values, 1) do
        :ok ->
          g

        {:store_fault, error, attempts} ->
          ExUnit.Assertions.flunk("""
          the store failed on iteration #{iteration} of #{iterations}, #{attempts} times over.

          The case could not be evaluated, so this is a fault of the store and
          not a counterexample. The fault is registered in the quarantine
          registry, with its owner and its expiry.

          seed: #{inspect(seed)}
          generated: #{inspect(values)}

          #{Exception.message(error)}
          """)

        {:violation, error} ->
          ExUnit.Assertions.flunk("""
          property failed on iteration #{iteration} of #{iterations}.

          seed: #{inspect(seed)}
          generated: #{inspect(values)}

          #{Exception.message(error)}
          """)
      end
    end)

    :ok
  end

  # How many times a case is evaluated when the store faults. A store fault is
  # an environment failure, not an answer about the domain, so the case is
  # evaluated again — an engine panic must not masquerade as a counterexample.
  # The bound keeps a broken store from hiding behind an endless retry: three
  # faults over, the test fails and says so.
  @store_fault_attempts 3

  # A case either holds or it does not. A store fault is neither: it is the
  # datastore failing to do what it was asked, which says nothing about whether
  # the domain would have behaved correctly.
  defp evaluate(assertion_fun, values, attempt) do
    assertion_fun.(values)
    :ok
  rescue
    error ->
      cond do
        store_fault?(error) and attempt < @store_fault_attempts ->
          # The re-evaluation is a re-evaluation, not a cover-up: the fault is
          # printed, so a run that passed over an engine panic says so.
          IO.puts(
            :stderr,
            "[property] the store faulted on a case; the case is evaluated again " <>
              "(attempt #{attempt + 1} of #{@store_fault_attempts}): " <>
              Exception.message(error)
          )

          evaluate(assertion_fun, values, attempt + 1)

        store_fault?(error) ->
          {:store_fault, error, attempt}

        true ->
          {:violation, error}
      end
  end

  # A store fault arrives either as the harness's own exception or as a match
  # against `{:ok, _}` that found the store's error instead.
  defp store_fault?(%StoreFault{}), do: true

  defp store_fault?(%MatchError{term: {:error, %Veritas.Store.Error{}}}), do: true

  defp store_fault?(_other), do: false
end
