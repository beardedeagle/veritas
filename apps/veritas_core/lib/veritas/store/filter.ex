defmodule Veritas.Store.Filter do
  @moduledoc """
  The filter, the ordering and the limit, applied to a set of rows.

  A `Veritas.Store` filter is a closed set of predicates — `where`,
  `order_by`, `limit`, `offset` — and the contract says what they mean: the
  rows a Workspace's table holds, filtered and ordered, inside the Workspace
  scope (`docs/32` §The behaviour).

  Both Adapters have to answer that question the same way. The in-memory
  Adapter does the work in Elixir. The SurrealDB Adapter asks the engine to do
  it and then merges the transaction's own writes over the answer — and when
  the merge happened after the filter, the ordering and the limit, the
  Adapter's own rows came back unfiltered, unordered and unlimited while the
  other Adapter's did not.

  This module is the one place the rules live, so the two cannot drift again.

  It is also the one place the **merge** lives: the rows a transaction sees
  are the committed rows with the transaction's own writes over them, and a row
  the transaction has deleted does not exist. The two Adapters read the
  committed rows from different places — one asks the engine, the other keeps
  them in a process — but the answer they give about a transaction's own
  writes is the same answer.
  """

  @typedoc """
  The predicates a filter carries.

  A plain map, deliberately: the port's own `filter/0` type is the contract,
  and a module that both Adapters call must not depend on the port to describe
  its argument.
  """
  @type filter :: %{
          optional(:where) => [{atom() | String.t(), term()}],
          optional(:order_by) => [{atom() | String.t(), :asc | :desc}],
          optional(:limit) => pos_integer(),
          optional(:offset) => non_neg_integer()
        }

  @doc """
  The rows a transaction sees: the committed rows with the transaction's own
  writes **over** them.

  A row the transaction has written is the row that exists, for the rest of
  the transaction, whatever the engine holds. So the transaction's own version
  of a row is the one that survives the merge, and a row the transaction has
  written that the engine has never seen is in the answer too.

  A row the transaction has **deleted** does not exist. Not as the marker the
  delete leaves behind, and not as the committed row the delete removed: a
  delete in a transaction is a fact about the Workspace, and the Workspace
  does not hold the row any more.

  The order of the committed rows is kept, and the transaction's own rows that
  the engine has never seen come after them — so the answer is the same set of
  rows in the same order as it was before, with the transaction's own writes
  in it.
  """
  @spec merge([map()], [map()]) :: [map()]
  def merge(committed, overlay) do
    deleted =
      overlay
      |> Enum.filter(&deleted?/1)
      |> MapSet.new(& &1["id"])

    own =
      overlay
      |> Enum.reject(&deleted?/1)
      |> Map.new(&{&1["id"], &1})

    committed_ids = MapSet.new(committed, & &1["id"])

    committed_rows =
      committed
      |> Enum.reject(&MapSet.member?(deleted, &1["id"]))
      |> Enum.map(&Map.get(own, &1["id"], &1))

    own_rows =
      own
      |> Enum.reject(fn {id, _row} -> MapSet.member?(committed_ids, id) end)
      |> Enum.map(fn {_id, row} -> row end)

    committed_rows ++ own_rows
  end

  @doc """
  Whether a row is the marker a transaction's delete leaves behind.

  A delete cannot be written into the overlay as the absence of a row — the
  overlay is a map of rows — so it is written as a marker, and the marker says
  the row is gone.
  """
  @spec deleted?(map()) :: boolean()
  def deleted?(row), do: Map.get(row, "deleted") == true

  @doc """
  Applies a filter to rows: the predicates, then the ordering, then the page.

  The order matters. The predicates decide which rows are in the answer, the
  ordering decides which of them come first, and the page decides how many of
  them are returned — in that order, so a limit never truncates before the
  ordering has had its say.
  """
  @spec apply([map()], filter() | nil) :: [map()]
  def apply(rows, filter) do
    filter = filter || %{where: []}

    rows
    |> filter_rows(filter[:where] || [])
    |> sort_rows(filter[:order_by] || [])
    |> paginate(filter[:offset], filter[:limit])
  end

  @doc """
  The rows that satisfy every predicate.

  A predicate compares the row's value with the predicate's, on the row's
  **logical** value: a reference is compared as the bare id the port uses, so
  a predicate and a row mean the same thing whichever Adapter answered it.
  """
  @spec filter_rows([map()], [{atom() | String.t(), term()}]) :: [map()]
  def filter_rows(rows, where) do
    Enum.filter(rows, fn row ->
      Enum.all?(where, fn {field, value} ->
        Map.get(row, to_string(field)) == value
      end)
    end)
  end

  @doc """
  The rows in the order the filter asks for.

  A field the row does not carry sorts before a field it does, and two rows
  that compare equal keep the order they arrived in — a stable sort, so a
  traversal's result does not shuffle between two reads of the same data.
  """
  @spec sort_rows([map()], [{atom() | String.t(), :asc | :desc}]) :: [map()]
  def sort_rows(rows, []), do: rows

  def sort_rows(rows, order_by) do
    Enum.sort(rows, fn a, b ->
      Enum.all?(order_by, fn {field, direction} ->
        left = Map.get(a, to_string(field))
        right = Map.get(b, to_string(field))
        comparison = compare(left, right)
        if direction == :desc, do: comparison >= 0, else: comparison <= 0
      end)
    end)
  end

  @doc """
  The page of rows the filter asks for: the offset's rows dropped, the limit's
  rows taken.
  """
  @spec paginate([map()], non_neg_integer() | nil, pos_integer() | nil) :: [map()]
  def paginate(rows, nil, nil), do: rows
  def paginate(rows, offset, nil), do: Enum.drop(rows, offset || 0)
  def paginate(rows, offset, limit), do: rows |> Enum.drop(offset || 0) |> Enum.take(limit)

  # Two values, compared the way a sort compares them: missing before
  # present, then by value.
  defp compare(nil, nil), do: 0
  defp compare(nil, _), do: -1
  defp compare(_, nil), do: 1
  defp compare(left, right) when left < right, do: -1
  defp compare(left, right) when left > right, do: 1
  defp compare(_left, _right), do: 0
end
