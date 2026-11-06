defmodule Veritas.Core.Store.ConformanceCase do
  @moduledoc """
  The ExUnit case template for the store contract's conformance suite.

  A substitute Adapter author writes one module:

      defmodule MyAdapterConformanceTest do
        use Veritas.Core.Store.ConformanceCase, adapter: MyAdapter
      end

  and the contract's obligations are run against their Adapter: one test per
  obligation, each named by its `docs/32` number, each failing with the
  Adapter's own words.

  ## What the tests assert

    * an obligation the normative suite executes must **hold**;
    * an obligation it does not execute must be **registered** as not
      executable, with a reason. It is never silently passed.

  The obligations are executed by `Veritas.Store.Spec`, which is the normative
  implementation of `docs/32`; this template adds the reporting, the
  Workspace isolation and the cleanup.
  """
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use ExUnit.Case, async: false

      @adapter unquote(opts[:adapter])

      # A module tag has to be set after `use ExUnit.Case` and before the
      # tests are defined, which is exactly where the template defines them.
      unquote(
        case opts[:moduletag] do
          nil -> nil
          tag -> quote do: @moduletag(unquote(tag))
        end
      )

      setup_all do
        adapter = @adapter

        prepare_opts = unquote(Keyword.take(opts, [:workspace, :adapter_options]))

        case Veritas.Core.Store.Conformance.prepare(adapter, prepare_opts) do
          {:ok, ctx} ->
            # The cleanup is registered *before* the suite runs. A module that
            # fails while the Adapter is swapped would otherwise leave the
            # next module talking to the wrong datastore — a leak that looks
            # like a failure in somebody else's test.
            on_exit(fn -> Veritas.Core.Store.Conformance.cleanup(ctx) end)

            {results, _ok?} = Veritas.Core.Store.Conformance.run(ctx)

            {:ok, ctx: ctx, results: results}

          {:error, reason} ->
            raise "the conformance suite could not prepare #{inspect(adapter)}: " <>
                    inspect(reason)
        end
      end

      unquote(Veritas.Core.Store.ConformanceCase.test_definitions())
    end
  end

  @doc "The ExUnit test definitions, one per obligation of `docs/32`."
  @spec test_definitions() :: [Macro.t()]
  def test_definitions do
    for id <- Veritas.Core.Store.Conformance.contract_obligations() do
      quote do
        test "#{unquote(id)} — the contract obligation holds", %{results: results} do
          Veritas.Core.Store.ConformanceCase.assert_obligation(unquote(id), results)
        end
      end
    end
  end

  @doc """
  Asserts one obligation against a set of results.

  An obligation the normative suite executed must hold. An obligation it did
  not execute must be registered as not executable — a gap that is named, not
  one that passes in silence.
  """
  @spec assert_obligation(String.t(), [map()]) :: :ok
  def assert_obligation(id, results) do
    case Enum.find(results, fn result -> id in obligations_of(result.obligation) end) do
      nil ->
        registered =
          Enum.find(Veritas.Core.Store.Conformance.not_executable(), fn {oid, _reason} ->
            oid == id
          end)

        assert registered,
               "#{id} is neither executed by the contract suite nor registered as not executable"

        {^id, reason} = registered
        IO.puts(:stderr, "[conformance] #{id} is not executable: #{reason}")

        :ok

      result ->
        assert result.ok, "#{result.obligation} failed: #{result.detail}"
    end
  end

  @doc "The obligation ids named by a result."
  @spec obligations_of(String.t()) :: [String.t()]
  def obligations_of(name), do: Regex.scan(~r/O-\d+/, name) |> List.flatten()
end
