defmodule OptimalEngine.API.IntParam do
  @moduledoc """
  The one parser for an integer a request supplies: a query parameter, a body
  field or a header.

  SQLite binds a signed 64-bit integer. A larger one used to reach the Store's
  bind, which raises, and the Store GenServer died with every caller's in-flight
  call. A value outside `#{-9_223_372_036_854_775_808}..#{9_223_372_036_854_775_807}`
  is now refused with `OutOfRange`, which the router answers as
  `400 invalid_parameter`. Anything that is not an integer at all gives the
  caller's default, as each route's own parser did before.

  Options:

    * `:partial` - accept trailing text after the digits (`"12abc"` is `12`);
      the default needs the whole text to be the integer.
    * `:positive` - a value of zero or less gives the default.

  A value outside the 64-bit range is refused whatever the other options say.
  """

  defmodule OutOfRange do
    @moduledoc "An integer parameter outside the signed 64-bit range; answered as 400."
    defexception message: "an integer parameter is outside the signed 64-bit range",
                 plug_status: 400
  end

  @min -9_223_372_036_854_775_808
  @max 9_223_372_036_854_775_807

  @doc "The smallest integer a parameter may hold."
  @spec min() :: integer()
  def min, do: @min

  @doc "The largest integer a parameter may hold."
  @spec max() :: integer()
  def max, do: @max

  @doc """
  Parses `value`, or returns `default` when it holds no integer.

  Raises `OptimalEngine.API.IntParam.OutOfRange` for an integer outside 64 bits.
  """
  @spec parse(term(), default, keyword()) :: integer() | default when default: term()
  def parse(value, default, opts \\ []) do
    case to_integer(value, Keyword.get(opts, :partial, false)) do
      {:ok, n} -> accept(n, default, Keyword.get(opts, :positive, false))
      :error -> default
    end
  end

  defp to_integer(n, _partial) when is_integer(n), do: {:ok, n}

  defp to_integer(value, partial) when is_binary(value) or is_float(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> {:ok, n}
      {n, _rest} when partial -> {:ok, n}
      _ -> :error
    end
  end

  defp to_integer(_value, _partial), do: :error

  defp accept(n, _default, _positive) when n < @min or n > @max, do: raise(OutOfRange)
  defp accept(n, default, true) when n <= 0, do: default
  defp accept(n, _default, _positive), do: n
end
