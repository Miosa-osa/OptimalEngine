defmodule OptimalEngine.Connectors.Cadence do
  @hourly_kinds ~w(gmail slack teams zoom fathom go_high_level)
  @daily_kinds ~w(sources_folder drive dropbox onedrive notion confluence)

  @moduledoc """
  How often a connector pulls.

  A connector row may set its own cadence in its `config`:

      "interval_ms": 3600000      milliseconds, at least one minute
      "cadence":     "hourly"     "hourly", "daily", "weekly", or "<n>m", "<n>h", "<n>d"

  `interval_ms` wins when a row sets both.
  Without either, the connector's kind decides:

    * message and meeting sources pull hourly: #{Enum.join(@hourly_kinds, ", ")}
    * file and document sources pull daily: #{Enum.join(@daily_kinds, ", ")}
    * every other kind pulls on the scheduler's `interval_ms` (daily unless configured)

  The shortest cadence is one minute, so a typo can never turn a connector
  into a tight loop against an outside API. A connector is due when its
  cadence has passed since its last run started, or when it has never run.
  """

  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  @named %{"hourly" => @hour, "daily" => @day, "weekly" => 7 * @day}
  @units %{"m" => @minute, "h" => @hour, "d" => @day}
  @duration ~r/\A\s*(\d+)\s*([mhd])\s*\z/

  @type described :: %{interval_ms: pos_integer(), source: String.t()}

  @doc "The shortest cadence a connector may have, in milliseconds."
  @spec minimum_ms() :: pos_integer()
  def minimum_ms, do: @minute

  @doc """
  The connector's pull interval in milliseconds. `default_ms` is the
  scheduler's interval, used for kinds without a default of their own.
  """
  @spec interval_ms(map(), String.t() | atom(), pos_integer()) :: pos_integer()
  def interval_ms(config, kind, default_ms), do: describe(config, kind, default_ms).interval_ms

  @doc """
  The interval and where it came from: `"config"` (the row), `"kind"` (the
  kind's default), or `"scheduler"` (the scheduler's interval).
  """
  @spec describe(map(), String.t() | atom(), pos_integer()) :: described()
  def describe(config, kind, default_ms) do
    case configured(config) do
      {:ok, ms} -> %{interval_ms: ms, source: "config"}
      _none_or_invalid -> kind_default(to_string(kind), default_ms)
    end
  end

  @doc "Refuses a cadence the scheduler could not honour."
  @spec validate(map()) :: :ok | {:error, :invalid_cadence}
  def validate(config) when is_map(config) do
    case configured(config) do
      {:error, _} = error -> error
      _ok_or_none -> :ok
    end
  end

  @doc "Whether a connector whose last run started at `last_started_at` is due at `now`."
  @spec due?(DateTime.t() | nil, pos_integer(), DateTime.t()) :: boolean()
  def due?(nil, _interval_ms, _now), do: true

  def due?(%DateTime{} = last_started_at, interval_ms, %DateTime{} = now) do
    DateTime.diff(now, last_started_at, :millisecond) >= interval_ms
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp kind_default(kind, _default_ms) when kind in @hourly_kinds,
    do: %{interval_ms: @hour, source: "kind"}

  defp kind_default(kind, _default_ms) when kind in @daily_kinds,
    do: %{interval_ms: @day, source: "kind"}

  defp kind_default(_kind, default_ms), do: %{interval_ms: default_ms, source: "scheduler"}

  defp configured(config) do
    cond do
      not is_nil(value(config, "interval_ms")) -> parse_interval(value(config, "interval_ms"))
      not is_nil(value(config, "cadence")) -> parse_cadence(value(config, "cadence"))
      true -> :none
    end
  end

  defp parse_interval(ms) when is_integer(ms) and ms >= @minute, do: {:ok, ms}
  defp parse_interval(_ms), do: {:error, :invalid_cadence}

  defp parse_cadence(name) when is_map_key(@named, name), do: {:ok, Map.fetch!(@named, name)}

  defp parse_cadence(text) when is_binary(text) do
    case Regex.run(@duration, text) do
      [_, count, unit] -> parse_interval(String.to_integer(count) * Map.fetch!(@units, unit))
      _ -> {:error, :invalid_cadence}
    end
  end

  defp parse_cadence(_cadence), do: {:error, :invalid_cadence}

  # Config arrives with string keys from the table and atom keys from a
  # caller building one by hand.
  defp value(map, "interval_ms"), do: Map.get(map, "interval_ms", Map.get(map, :interval_ms))
  defp value(map, "cadence"), do: Map.get(map, "cadence", Map.get(map, :cadence))
end
