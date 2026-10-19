defmodule OptimalEngine.Connectors.CadenceTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Connectors.Cadence

  @hour 60 * 60 * 1_000
  @day 24 * @hour
  @scheduler_default 12 * @hour

  describe "interval_ms/3" do
    test "a row's interval_ms wins over everything" do
      assert Cadence.interval_ms(%{"interval_ms" => 120_000}, "gmail", @scheduler_default) ==
               120_000
    end

    test "a named cadence and a duration are both understood" do
      assert Cadence.interval_ms(%{"cadence" => "hourly"}, "drive", @scheduler_default) == @hour
      assert Cadence.interval_ms(%{"cadence" => "daily"}, "gmail", @scheduler_default) == @day
      assert Cadence.interval_ms(%{"cadence" => "weekly"}, "gmail", @scheduler_default) == 7 * @day
      assert Cadence.interval_ms(%{"cadence" => "15m"}, "gmail", @scheduler_default) == 900_000
      assert Cadence.interval_ms(%{"cadence" => "6h"}, "gmail", @scheduler_default) == 6 * @hour
      assert Cadence.interval_ms(%{"cadence" => "2d"}, "gmail", @scheduler_default) == 2 * @day
    end

    test "interval_ms wins when a row sets both" do
      config = %{"interval_ms" => 300_000, "cadence" => "daily"}
      assert Cadence.interval_ms(config, "gmail", @scheduler_default) == 300_000
    end

    test "without a row cadence, mail pulls hourly and files daily" do
      assert Cadence.interval_ms(%{}, "gmail", @scheduler_default) == @hour
      assert Cadence.interval_ms(%{}, :slack, @scheduler_default) == @hour
      assert Cadence.interval_ms(%{}, "sources_folder", @scheduler_default) == @day
      assert Cadence.interval_ms(%{}, :drive, @scheduler_default) == @day
    end

    test "every other kind uses the scheduler's interval" do
      assert Cadence.interval_ms(%{}, "stripe", @scheduler_default) == @scheduler_default
      assert Cadence.interval_ms(%{}, "github", @scheduler_default) == @scheduler_default
    end
  end

  describe "describe/3" do
    test "names where the cadence came from" do
      assert %{interval_ms: 120_000, source: "config"} =
               Cadence.describe(%{"interval_ms" => 120_000}, "stripe", @scheduler_default)

      assert %{interval_ms: @hour, source: "kind"} =
               Cadence.describe(%{}, "gmail", @scheduler_default)

      assert %{interval_ms: @scheduler_default, source: "scheduler"} =
               Cadence.describe(%{}, "stripe", @scheduler_default)
    end
  end

  describe "validate/1" do
    test "accepts an absent cadence and the documented forms" do
      assert :ok = Cadence.validate(%{})
      assert :ok = Cadence.validate(%{"cadence" => "hourly"})
      assert :ok = Cadence.validate(%{"cadence" => "30m"})
      assert :ok = Cadence.validate(%{"interval_ms" => 60_000})
    end

    test "refuses a typo, a non-integer, and anything under one minute" do
      assert {:error, :invalid_cadence} = Cadence.validate(%{"cadence" => "hourlyy"})
      assert {:error, :invalid_cadence} = Cadence.validate(%{"cadence" => "0h"})
      assert {:error, :invalid_cadence} = Cadence.validate(%{"cadence" => "30s"})
      assert {:error, :invalid_cadence} = Cadence.validate(%{"interval_ms" => "soon"})
      assert {:error, :invalid_cadence} = Cadence.validate(%{"interval_ms" => 1_000})
      assert {:error, :invalid_cadence} = Cadence.validate(%{"interval_ms" => 90_000.5})
    end
  end

  describe "due?/3" do
    test "a connector that never ran is due" do
      assert Cadence.due?(nil, @hour, DateTime.utc_now())
    end

    test "a connector is due once its interval has passed since its last start" do
      now = ~U[2026-10-19 12:00:00Z]
      assert Cadence.due?(~U[2026-10-19 10:59:00Z], @hour, now)
      assert Cadence.due?(~U[2026-10-19 11:00:00Z], @hour, now)
      refute Cadence.due?(~U[2026-10-19 11:30:00Z], @hour, now)
    end
  end
end
