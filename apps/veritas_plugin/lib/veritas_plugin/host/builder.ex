defmodule Veritas.Plugin.Host.Builder do
  @moduledoc """
  The compile-time builder for a Host API.

  Plug's idiom is a builder that assembles a pipeline while the module is
  compiled, so the composition costs nothing at runtime and the shape of the
  pipeline is readable in the source rather than in a runtime data structure.
  This is that idea, at the plugin boundary: an operation is declared with
  `operation/2`, and the table of operations is produced **at compile time**,
  so the Host API the host offers is a literal inside the compiled module.

      defmodule Veritas.Plugin.Host.Operations do
        use Veritas.Plugin.Host.Builder

        operation "read_records",
          scope: {:by_param, "table", %{"ci" => :ci_read, "ticket" => :ticket_read}}

        operation "query_graph", scope: :graph_query
      end

  ## The operation spec

  `name` is the operation's name on the wire. A Plugin calls it as
  `"host." <> name`.

  `scope` says which capability the operation needs:

    * an atom — a fixed scope, such as `:graph_query`;
    * `{:by_param, key, mapping}` — the scope depends on a parameter, such
      as which table is being read. `mapping` is keyed by the **string** the
      parameter carries on the wire, because that is what a JSON frame holds.

  The scope spec must be a literal. A function would have to be evaluated on
  every call, and the whole point of the builder is that the table is settled
  before the host serves anything.

  This module is **Default**: the shape of a Host API is a choice, and a
  different host may declare a different one.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Veritas.Plugin.Host.Builder

      Module.register_attribute(__MODULE__, :host_operations, accumulate: true)

      @before_compile Veritas.Plugin.Host.Builder
    end
  end

  @doc """
  Declares one operation of the Host API.
  """
  defmacro operation(name, opts) do
    quote do
      @host_operations {unquote(name), unquote(opts)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    operations = env.module |> Module.get_attribute(:host_operations) |> Enum.reverse()

    quote do
      @doc """
      The operations of this Host API, fixed at compile time.
      """
      @spec __host_operations__() :: [{String.t(), keyword()}]
      def __host_operations__, do: unquote(Macro.escape(operations))
    end
  end
end
