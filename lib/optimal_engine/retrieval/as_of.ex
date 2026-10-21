defmodule OptimalEngine.Retrieval.AsOf do
  @moduledoc """
  The instant a retrieval request measures time against.

  Freshness decay and the validity windows of governed recall depend on "now".
  A request reads the clock once, here, and carries the result, so every stage
  of it agrees on how old everything is. A caller that passes `:as_of` makes
  the request repeatable: two Engines holding the same data, asked at the same
  `:as_of`, rank the same way.

  `resolve/1` accepts:

    * `nil`, or a string that is blank after trimming - now
    * a `DateTime`
    * an ISO 8601 string; one without an offset is read as UTC

  An instant before 1970-01-01 or more than a year ahead of the clock is
  refused: a far-off instant only pushes the decay out of range, and no stored
  context is dated there. A refusal is `{:error, {:invalid_as_of, value}}`.
  """

  @earliest ~U[1970-01-01 00:00:00Z]
  @latest_ahead_seconds 366 * 24 * 3600

  @type error :: {:invalid_as_of, term()}

  @doc "The instant for a request: `value` if it is a valid `:as_of`, else the error."
  @spec resolve(term()) :: {:ok, DateTime.t()} | {:error, error()}
  def resolve(nil), do: {:ok, DateTime.utc_now()}
  def resolve(%DateTime{} = value), do: check(value, value)

  def resolve(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, DateTime.utc_now()}
      text -> parse(text, value)
    end
  end

  def resolve(value), do: {:error, {:invalid_as_of, value}}

  @doc """
  Resolves the `:as_of` option of `opts` and stores the instant back in it, so
  a function that calls others hands them one instant.
  """
  @spec put_resolved(keyword()) :: {:ok, keyword()} | {:error, error()}
  def put_resolved(opts) when is_list(opts) do
    with {:ok, as_of} <- resolve(Keyword.get(opts, :as_of)) do
      {:ok, Keyword.put(opts, :as_of, as_of)}
    end
  end

  @doc """
  Like `put_resolved/1`, but when no instant was asked for (`nil` or a blank
  string) it only drops the empty `:as_of` and stores no clock reading, so a
  caller that reads the clock when it must does not start storing one.
  """
  @spec put_if_given(keyword()) :: {:ok, keyword()} | {:error, error()}
  def put_if_given(opts) when is_list(opts) do
    case Keyword.get(opts, :as_of) do
      nil -> {:ok, Keyword.delete(opts, :as_of)}
      value when is_binary(value) -> put_given_text(opts, value)
      _value -> put_resolved(opts)
    end
  end

  @doc """
  The instant as SQLite's `datetime()` reads it, `YYYY-MM-DD HH:MM:SS` in UTC.

  Built from a `DateTime`, so it is safe to put in SQL text.
  """
  @spec sql_literal(DateTime.t()) :: String.t()
  def sql_literal(%DateTime{} = as_of) do
    as_of |> DateTime.to_unix() |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp put_given_text(opts, text) do
    if String.trim(text) == "",
      do: {:ok, Keyword.delete(opts, :as_of)},
      else: put_resolved(opts)
  end

  defp parse(text, original) do
    case DateTime.from_iso8601(text) do
      {:ok, instant, _offset} ->
        check(instant, original)

      {:error, :missing_offset} ->
        case DateTime.from_iso8601(text <> "Z") do
          {:ok, instant, _offset} -> check(instant, original)
          {:error, _} -> {:error, {:invalid_as_of, original}}
        end

      {:error, _} ->
        {:error, {:invalid_as_of, original}}
    end
  end

  defp check(instant, original) do
    latest = DateTime.add(DateTime.utc_now(), @latest_ahead_seconds, :second)

    if DateTime.compare(instant, @earliest) != :lt and DateTime.compare(instant, latest) != :gt,
      do: {:ok, instant},
      else: {:error, {:invalid_as_of, original}}
  end
end
