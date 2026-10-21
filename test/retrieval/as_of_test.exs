defmodule OptimalEngine.Retrieval.AsOfTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Retrieval.AsOf

  describe "resolve/1" do
    test "reads the clock when no instant is asked for" do
      before = DateTime.utc_now()

      for blank <- [nil, "", "   ", "\n\t"] do
        assert {:ok, now} = AsOf.resolve(blank)
        assert DateTime.compare(now, before) != :lt
      end
    end

    test "takes a DateTime as it is" do
      assert {:ok, ~U[2026-10-20 12:00:00Z]} = AsOf.resolve(~U[2026-10-20 12:00:00Z])
    end

    test "takes an ISO 8601 string, with or without an offset, with whitespace around it" do
      expected = ~U[2026-10-20 12:00:00Z]

      for text <- [
            "2026-10-20T12:00:00Z",
            "  2026-10-20T12:00:00Z\n",
            "2026-10-20T14:00:00+02:00",
            "2026-10-20T12:00:00",
            "2026-10-20T07:00:00-05:00"
          ] do
        assert {:ok, ^expected} = AsOf.resolve(text)
      end
    end

    test "keeps fractional seconds" do
      assert {:ok, instant} = AsOf.resolve("2026-10-20T12:00:00.250Z")
      assert DateTime.to_unix(instant, :millisecond) == 1_792_497_600_250
    end

    test "refuses text that is not a timestamp" do
      for text <- ["yesterday", "2026-13-45T00:00:00Z", "2026-10-20 12:00", "12:00", "1e9"] do
        assert {:error, {:invalid_as_of, ^text}} = AsOf.resolve(text)
      end
    end

    test "refuses anything that is neither text nor a DateTime" do
      for value <- [42, 1.5, :now, %{}, [], {:ok, 1}] do
        assert {:error, {:invalid_as_of, ^value}} = AsOf.resolve(value)
      end
    end

    test "refuses an instant before 1970, which only pushes the decay out of range" do
      assert {:error, {:invalid_as_of, "1900-01-01T00:00:00Z"}} =
               AsOf.resolve("1900-01-01T00:00:00Z")

      assert {:error, {:invalid_as_of, "1969-12-31T23:59:59Z"}} =
               AsOf.resolve("1969-12-31T23:59:59Z")

      assert {:error, {:invalid_as_of, ~U[1900-01-01 00:00:00Z]}} =
               AsOf.resolve(~U[1900-01-01 00:00:00Z])

      assert {:ok, ~U[1970-01-01 00:00:00Z]} = AsOf.resolve("1970-01-01T00:00:00Z")
    end

    test "refuses an instant more than a year ahead, and accepts one a few months ahead" do
      far = DateTime.utc_now() |> DateTime.add(2 * 366 * 86_400, :second) |> DateTime.to_iso8601()
      assert {:error, {:invalid_as_of, ^far}} = AsOf.resolve(far)

      soon = DateTime.utc_now() |> DateTime.add(90 * 86_400, :second) |> DateTime.to_iso8601()
      assert {:ok, _instant} = AsOf.resolve(soon)
    end
  end

  describe "put_resolved/1" do
    test "stores the resolved instant back, replacing a string" do
      assert {:ok, opts} = AsOf.put_resolved(limit: 5, as_of: "2026-10-20T12:00:00Z")
      assert Keyword.get(opts, :as_of) == ~U[2026-10-20 12:00:00Z]
      assert Keyword.get(opts, :limit) == 5
    end

    test "stores the clock when none was asked for" do
      assert {:ok, opts} = AsOf.put_resolved(as_of: nil)
      assert %DateTime{} = Keyword.get(opts, :as_of)
      assert {:ok, opts} = AsOf.put_resolved([])
      assert %DateTime{} = Keyword.get(opts, :as_of)
    end

    test "passes the refusal on" do
      assert {:error, {:invalid_as_of, "nope"}} = AsOf.put_resolved(as_of: "nope")
    end
  end

  describe "put_if_given/1" do
    test "leaves the options alone when no instant was asked for" do
      assert {:ok, [limit: 5]} = AsOf.put_if_given(limit: 5)
      assert {:ok, [limit: 5]} = AsOf.put_if_given(limit: 5, as_of: nil)
      assert {:ok, [limit: 5]} = AsOf.put_if_given(limit: 5, as_of: "  ")
    end

    test "resolves one that was asked for, and refuses a bad one" do
      assert {:ok, opts} = AsOf.put_if_given(as_of: "2026-10-20T12:00:00Z")
      assert Keyword.get(opts, :as_of) == ~U[2026-10-20 12:00:00Z]
      assert {:error, {:invalid_as_of, "nope"}} = AsOf.put_if_given(as_of: "nope")
      assert {:error, {:invalid_as_of, 7}} = AsOf.put_if_given(as_of: 7)
    end
  end

  describe "sql_literal/1" do
    test "is the instant as SQLite's datetime() reads it, in UTC" do
      assert AsOf.sql_literal(~U[2026-10-20 12:00:05Z]) == "2026-10-20 12:00:05"
      assert AsOf.sql_literal(~U[2026-10-20 12:00:05.987654Z]) == "2026-10-20 12:00:05"
    end
  end
end
