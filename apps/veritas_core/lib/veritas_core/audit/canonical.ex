defmodule Veritas.Core.Audit.Canonical do
  @moduledoc """
  A canonical encoding of a value.

  The Audit Log's chain signs the content of an event, and an event's `diff`
  is a map. A map has no order that can be relied on: a small map is ordered
  by the term order of its keys, a large one by a hash order, and neither is
  promised to be the same across BEAM versions, across processes, or between
  a value that was written and the same value read back from the store. A
  signature over an unordered encoding is a signature that changes when
  nothing did — and a chain that reports a break nobody caused is a chain
  nobody trusts.

  So the value is encoded here, once, in one order:

    * the keys of a map are sorted by **their own encoded form**, so the order
      does not depend on the map's type or on the BEAM's hash function;
    * every scalar carries its type, so an integer `1` and a string `"1"` do
      not encode the same;
    * a string is length-prefixed and escaped, so no value can be mistaken
      for the end of another.

  The encoding is therefore a property of this module rather than of the
  term it encodes, and it is stable across BEAM versions and across
  processes. `Veritas.Core.Audit` signs with it, and the migration re-signs
  with it, so a row written by one version verifies under the next.
  """

  @type t :: term()

  @doc """
  The canonical encoding of a value.

  Two values that are `==` encode identically. Two values that are not `==`
  do not: the encoding is injective, so a changed value always changes the
  signature.
  """
  @spec encode(t()) :: binary()
  def encode(value), do: encode_value(value)

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "btrue"
  defp encode_value(false), do: "bfalse"
  defp encode_value(value) when is_integer(value), do: "i" <> Integer.to_string(value)

  defp encode_value(value) when is_float(value),
    do: "f" <> :erlang.float_to_binary(value, [:short])

  defp encode_value(value) when is_bitstring(value), do: "s" <> encode_binary(value)
  defp encode_value(value) when is_atom(value), do: "a" <> Atom.to_string(value)

  defp encode_value(%DateTime{} = value), do: "t" <> encode_binary(canonical_datetime(value))

  defp encode_value(%NaiveDateTime{} = value),
    do: "t" <> encode_binary(canonical_naive_datetime(value))

  defp encode_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"

  defp encode_value(value) when is_tuple(value),
    do: "(" <> Enum.map_join(Tuple.to_list(value), ",", &encode_value/1) <> ")"

  defp encode_value(value) when is_map(value) do
    inner =
      value
      |> Map.keys()
      |> Enum.sort_by(&encode_value/1)
      |> Enum.map_join(",", fn key ->
        encode_value(key) <> ":" <> encode_value(Map.get(value, key))
      end)

    "{" <> inner <> "}"
  end

  # A datetime is canonicalised to UTC with a **fixed** six-digit fraction.
  #
  # The precision the struct carries is a property of the *text* it was
  # parsed from, not of the instant: a store that trims trailing zeros from
  # the fraction hands back ".082" where it was given ".082000", and
  # `DateTime.from_iso8601/1` then produces a datetime whose precision field
  # says three digits. An encoding that depended on that field would give the
  # same instant two different encodings, and a row would fail to verify for
  # no reason at all. Converting through the epoch makes the encoding a
  # function of the instant and nothing else.
  defp canonical_datetime(value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  # A naive datetime has no zone, so it is read as UTC for the purposes of the
  # encoding — a fixed interpretation, which is all a canonical form needs.
  defp canonical_naive_datetime(value) do
    value
    |> NaiveDateTime.to_date()
    |> then(fn date -> DateTime.new!(date, value.time, "Etc/UTC") end)
    |> canonical_datetime()
  end

  # A binary is length-prefixed and escaped, so that a value can never be
  # mistaken for the end of the value before it, and so that a binary
  # containing a separator cannot forge a boundary.
  defp encode_binary(value) do
    bytes = :erlang.iolist_to_binary(value)

    escaped =
      bytes
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte ->
        cond do
          byte == ?\\ -> "\\\\"
          byte == ?" -> "\\\""
          byte < 32 -> "\\x" <> Base.encode16(<<byte>>, case: :upper)
          true -> <<byte>>
        end
      end)

    Integer.to_string(byte_size(bytes)) <> ":" <> escaped
  end
end
