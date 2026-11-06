defmodule Veritas.Plugin.Semver do
  @moduledoc """
  Semantic versions and the ranges a manifest declares them in.

  A version is three numbers. A range is a set of comparators joined by "and"
  (or by whitespace) and groups of them separated by "||". The range syntax is
  the one npm-style manifests use, because a Plugin's manifest is written by
  people who already know it:

    * ">= 2.3.0 and < 3.0.0" — a range the corpus's own example uses
    * "^1.4.0" — at least 1.4.0, below 2.0.0
    * "~1.4.0" — at least 1.4.0, below 1.5.0
    * "1.4.0" or "= 1.4.0" — exactly that version
    * "1.4.x" or "1.x" — any patch or minor of that prefix
    * "*" — any version

  This is **Default** behaviour, substitutable behind `Veritas.Plugin.Semver`:
  a host that wants a different range grammar replaces this module and nothing
  else changes.
  """

  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Parses a version.

  A pre-release or build suffix is accepted and ignored: the corpus's
  compatibility line is about the host API, not about the plugin's own build.
  """
  @spec parse(String.t()) :: {:ok, version()} | :error
  def parse(version) when is_binary(version) do
    core =
      version
      |> String.trim()
      |> String.split(["-", "+"], parts: 2)
      |> List.first()

    case String.split(core, ".") do
      [major, minor, patch] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor),
             {patch, ""} <- Integer.parse(patch) do
          {:ok, {major, minor, patch}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse(_version), do: :error

  @doc """
  Whether a version satisfies a range.

  An unparseable version or range satisfies nothing: a compatibility check
  that cannot be evaluated must not pass.
  """
  @spec satisfies?(String.t(), String.t()) :: boolean()
  def satisfies?(version, range) when is_binary(version) and is_binary(range) do
    case parse(version) do
      {:ok, parsed} ->
        range
        |> String.split("||")
        |> Enum.any?(fn alternative ->
          alternative
          |> comparators()
          |> Enum.all?(&matches?(parsed, &1))
        end)

      :error ->
        false
    end
  end

  def satisfies?(_version, _range), do: false

  @doc """
  Whether a range is a range at all.

  A manifest that declares a compatibility line the host cannot read is
  refused, rather than being read as "compatible with everything".
  """
  @spec valid_range?(String.t()) :: boolean()
  def valid_range?(range) when is_binary(range) do
    range
    |> String.split("||")
    |> Enum.all?(fn alternative ->
      alternative
      |> comparators()
      |> Enum.any?()
      |> case do
        false -> false
        true -> Enum.all?(alternative |> comparators(), &readable?/1)
      end
    end)
  end

  def valid_range?(_range), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  defp readable?({_operator, bound}) do
    bound == "*" or match?({:ok, _}, parse(bound)) or wildcard?(bound)
  end

  defp wildcard?(bound) do
    bound
    |> String.split(".")
    |> Enum.any?(&(&1 in ["x", "X", "*"]))
  end

  defp comparators(alternative) do
    alternative
    |> String.replace(~r/\s+and\s+/, " ")
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
    |> join_operators([])
    |> to_comparators([])
  end

  # An operator and its bound may be written with a space between them —
  # ">= 2.3.0" is the corpus's own spelling — or without one, as in
  # ">=2.3.0". Both are read the same way, so the two are joined before
  # anything else looks at them.
  defp join_operators([], acc), do: Enum.reverse(acc)

  defp join_operators([operator, bound | rest], acc)
       when operator in ["<", "<=", ">", ">=", "=", "^", "~"] do
    join_operators(rest, [operator <> bound | acc])
  end

  defp join_operators([token | rest], acc), do: join_operators(rest, [token | acc])

  defp to_comparators([], acc), do: Enum.reverse(acc)

  defp to_comparators([">=" <> bound | rest], acc),
    do: to_comparators(rest, [{:gte, bound} | acc])

  defp to_comparators(["<=" <> bound | rest], acc),
    do: to_comparators(rest, [{:lte, bound} | acc])

  defp to_comparators([">" <> bound | rest], acc),
    do: to_comparators(rest, [{:gt, bound} | acc])

  defp to_comparators(["<" <> bound | rest], acc),
    do: to_comparators(rest, [{:lt, bound} | acc])

  defp to_comparators(["=" <> bound | rest], acc),
    do: to_comparators(rest, [{:eq, bound} | acc])

  defp to_comparators(["^" <> bound | rest], acc) do
    case parse(bound) do
      {:ok, {major, _minor, _patch}} ->
        to_comparators(rest, [{:lt, "#{major + 1}.0.0"} | [{:gte, bound} | acc]])

      :error ->
        to_comparators(rest, [{:eq, bound} | acc])
    end
  end

  defp to_comparators(["~" <> bound | rest], acc) do
    case parse(bound) do
      {:ok, {major, minor, _patch}} ->
        to_comparators(rest, [{:lt, "#{major}.#{minor + 1}.0"} | [{:gte, bound} | acc]])

      :error ->
        to_comparators(rest, [{:eq, bound} | acc])
    end
  end

  defp to_comparators([bound | rest], acc) when is_binary(bound) do
    to_comparators(rest, [{:eq, bound} | acc])
  end

  defp matches?(parsed, {:gte, bound}), do: compare(parsed, bound) >= 0
  defp matches?(parsed, {:lte, bound}), do: compare(parsed, bound) <= 0
  defp matches?(parsed, {:gt, bound}), do: compare(parsed, bound) > 0
  defp matches?(parsed, {:lt, bound}), do: compare(parsed, bound) < 0
  defp matches?(parsed, {:eq, bound}), do: compare(parsed, bound) == 0

  defp compare(parsed, bound) do
    case parse(bound) do
      {:ok, other} -> compare_tuples(parsed, other)
      :error -> -1
    end
  end

  defp compare_tuples(left, right) do
    cond do
      left > right -> 1
      left < right -> -1
      true -> 0
    end
  end
end
