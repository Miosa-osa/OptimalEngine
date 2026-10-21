defmodule OptimalEngine.Store.Postgres.AffinityTest do
  @moduledoc """
  The SQLite conversions the PostgreSQL store applies to parameters and
  results, without a database.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Store.Postgres.Affinity

  describe "text parameters" do
    test "take the values Exqlite binds as text, rendered the same way" do
      assert Affinity.to_text("plain") == "plain"
      assert Affinity.to_text(["io", "data"]) == "iodata"
      assert Affinity.to_text(42) == "42"
      assert Affinity.to_text(0.5) == "0.5"
      assert Affinity.to_text(:signal) == "signal"
      assert Affinity.to_text(true) == "true"
      assert Affinity.to_text(~D[2026-10-20]) == "2026-10-20"
      assert Affinity.to_text(~N[2026-10-20 08:30:00]) == "2026-10-20T08:30:00"
      assert Affinity.to_text(~U[2026-10-20 08:30:00Z]) == "2026-10-20T08:30:00"
      assert Affinity.to_text({:blob, <<"raw">>}) == "raw"
    end

    test "reject what Exqlite rejects" do
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_text(%{a: 1}) end

      not_utc =
        ~N[2026-10-20 08:30:00]
        |> DateTime.from_naive!("Etc/UTC")
        |> Map.put(:time_zone, "Europe/Paris")

      assert_raise DBConnection.EncodeError, fn -> Affinity.to_text(not_utc) end
    end
  end

  describe "integer parameters" do
    test "convert integral floats, integer text and booleans" do
      range = -100..100
      assert Affinity.to_integer(7, range) == 7
      assert Affinity.to_integer(3.0, range) == 3
      assert Affinity.to_integer(" 42 ", range) == 42
      assert Affinity.to_integer(true, range) == 1
      assert Affinity.to_integer(false, range) == 0
    end

    test "refuse a value SQLite would not store as an integer, or one out of range" do
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_integer(1.5, 0..10) end
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_integer("4x", 0..10) end
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_integer(11, 0..10) end
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_integer(nil, 0..10) end
    end
  end

  describe "float, bytes and boolean parameters" do
    test "convert numbers, numeric text and booleans to floats" do
      assert Affinity.to_float(2) == 2.0
      assert Affinity.to_float(0.25) == 0.25
      assert Affinity.to_float("1.5") == 1.5
      assert Affinity.to_float(true) == 1.0
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_float("high") end
    end

    test "take bytes as a binary, iodata or a {:blob, data} tuple" do
      assert Affinity.to_bytes({:blob, [<<0, 1>>, <<2>>]}) == <<0, 1, 2>>
      assert Affinity.to_bytes(<<0, 255>>) == <<0, 255>>
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_bytes(1) end
    end

    test "take booleans as booleans or 1 and 0" do
      assert Affinity.to_boolean(true)
      refute Affinity.to_boolean(0)
      assert_raise DBConnection.EncodeError, fn -> Affinity.to_boolean("yes") end
    end
  end

  describe "results" do
    test "an integral numeric is an integer and a fractional one a float" do
      assert Affinity.normalize(Decimal.new("12")) === 12
      assert Affinity.normalize(Decimal.new("1E+2")) === 100
      assert Affinity.normalize(Decimal.new("2.5000")) === 2.5
      assert Affinity.normalize(Decimal.new("3.0000")) === 3.0
    end

    test "every other value is returned unchanged" do
      assert Affinity.normalize_rows([["a", 1, nil, 0.5]]) == [["a", 1, nil, 0.5]]
      assert Affinity.normalize_rows(nil) == []
    end
  end
end
