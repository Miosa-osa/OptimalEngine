defmodule OptimalEngine.Authority.CanonicalJSON do
  @moduledoc """
  JSON Canonicalization Scheme (RFC 8785) for the values authority signs.

  Grants, policy packs, and evidence entries are hashed and signed over their
  canonical form, so two systems that hold the same value always compute the
  same bytes:

  * object members are sorted by the UTF-16 code units of their names;
  * no whitespace is emitted;
  * strings escape only `"`, `\\`, and control characters, using the short
    escapes (`\\b \\f \\n \\r \\t`) where they exist and lowercase `\\u00xx`
    otherwise; every other character is emitted as UTF-8;
  * integers are emitted exactly; finite floats use the shortest form that
    round-trips, which matches the ECMAScript serialization RFC 8785 relies
    on for every value authority produces. Non-finite numbers cannot occur in
    Elixir floats.

  Atom keys and atom values (other than `true`, `false`, and `nil`) are
  encoded as strings so Elixir maps and their decoded JSON form canonicalize
  identically.
  """

  @doc "Canonical JSON bytes for `value`."
  @spec encode(term()) :: binary()
  def encode(value), do: value |> encode_value() |> IO.iodata_to_binary()

  @doc "Lowercase hex SHA-256 of the canonical form of `value`."
  @spec hash(term()) :: String.t()
  def hash(value), do: :crypto.hash(:sha256, encode(value)) |> Base.encode16(case: :lower)

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: encode_float(value)
  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_atom(value), do: value |> Atom.to_string() |> encode_string()

  defp encode_value(%DateTime{} = value), do: value |> DateTime.to_iso8601() |> encode_string()

  defp encode_value(value) when is_struct(value),
    do: raise(ArgumentError, "cannot canonicalize struct #{inspect(value.__struct__)}")

  defp encode_value(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, member} -> {key_string(key), member} end)
      |> Enum.sort_by(fn {key, _member} -> utf16(key) end)
      |> Enum.map(fn {key, member} -> [encode_string(key), ?:, encode_value(member)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp encode_value(value) when is_list(value),
    do: [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]

  defp encode_value(value),
    do: raise(ArgumentError, "cannot canonicalize #{inspect(value)}")

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: raise(ArgumentError, "object keys must be strings, got #{inspect(key)}")

  defp utf16(key), do: :unicode.characters_to_binary(key, :utf8, {:utf16, :big})

  # Integral floats print without a fraction, as ECMAScript does (1.0 -> 1).
  defp encode_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e21 do
      value |> trunc() |> Integer.to_string()
    else
      value |> :erlang.float_to_binary([:short]) |> ecma_exponent()
    end
  end

  # Erlang writes "1.0e-7" and "1.0e-6"; ECMAScript writes "1e-7" but
  # "0.000001" (plain decimals from 1e-6 upward) and "1e+21".
  defp ecma_exponent(text) do
    case String.split(text, "e") do
      [mantissa, exponent] ->
        exponent = String.to_integer(exponent)
        {sign, mantissa} = split_sign(String.replace_suffix(mantissa, ".0", ""))

        if exponent in -6..-1 do
          digits = String.replace(mantissa, ".", "")
          sign <> "0." <> String.duplicate("0", -exponent - 1) <> digits
        else
          exponent_sign = if exponent < 0, do: "-", else: "+"
          sign <> mantissa <> "e" <> exponent_sign <> Integer.to_string(abs(exponent))
        end

      [plain] ->
        plain
    end
  end

  defp split_sign("-" <> rest), do: {"-", rest}
  defp split_sign(text), do: {"", text}

  defp encode_string(value) do
    [?", escape(value, []), ?"]
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<char, rest::binary>>, acc) when char < 0x20 do
    hex = char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    escape(rest, ["\\u" <> hex | acc])
  end

  defp escape(<<char::utf8, rest::binary>>, acc), do: escape(rest, [<<char::utf8>> | acc])

  defp escape(<<_invalid, _rest::binary>>, _acc),
    do: raise(ArgumentError, "strings must be valid UTF-8")
end
