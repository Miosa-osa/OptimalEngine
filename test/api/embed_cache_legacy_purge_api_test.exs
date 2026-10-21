defmodule OptimalEngine.API.EmbedCacheLegacyPurgeApiTest do
  @moduledoc """
  The one-time removal of the unpartitioned embedding cache is readable by machine:
  `embed_cache_legacy_purge` in `GET /api/storage`, and two gauges in `GET /api/metrics`
  and `GET /api/metrics/prometheus`.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Store.FileCache.LegacyPurgeRecord

  @record_key :embed_cache_legacy_purge_record
  @files "optimal_engine_embed_cache_legacy_purge_files"
  @bytes "optimal_engine_embed_cache_legacy_purge_bytes"

  setup do
    saved = Application.get_env(:optimal_engine, @record_key)
    record = Path.join(System.tmp_dir!(), "purge-api-#{System.unique_integer([:positive])}.json")
    Application.put_env(:optimal_engine, @record_key, record)

    on_exit(fn ->
      case saved do
        nil -> Application.delete_env(:optimal_engine, @record_key)
        value -> Application.put_env(:optimal_engine, @record_key, value)
      end

      File.rm(record)
    end)

    %{record: record}
  end

  describe "GET /api/storage" do
    test "says null when the purge has never run on this Engine" do
      body = get_json("/api/storage")

      assert Map.has_key?(body, "embed_cache_legacy_purge")
      assert body["embed_cache_legacy_purge"] == nil
    end

    test "carries the record, and the usage it always carried" do
      {:ok, written} = LegacyPurgeRecord.write(1204, 9_877_216)
      body = get_json("/api/storage")

      assert body["embed_cache_legacy_purge"] == %{
               "ran_at" => written.ran_at,
               "files" => 1204,
               "bytes" => 9_877_216,
               "engine_version" => OptimalEngine.Version.application_version()
             }

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(written.ran_at)
      assert is_map(body["profile"]) and is_list(body["gauges"]) and Map.has_key?(body, "boot_ms")
    end

    test "an Engine that had nothing to remove reports zero files and zero bytes" do
      {:ok, _} = LegacyPurgeRecord.write(0, 0)

      assert %{"files" => 0, "bytes" => 0} = get_json("/api/storage")["embed_cache_legacy_purge"]
    end

    test "a file that is not a record reads as never run", %{record: record} do
      for body <- ["", "not json", ~s({"files": 3}), ~s({"ran_at": "x", "files": -1, "bytes": 0})] do
        File.write!(record, body)
        assert get_json("/api/storage")["embed_cache_legacy_purge"] == nil
      end
    end
  end

  describe "GET /api/metrics" do
    test "has no purge gauges until the purge is recorded" do
      assert get_json("/api/metrics")["gauges"] == %{}
      refute prometheus() =~ @files
    end

    test "sets the two gauges from the record" do
      {:ok, _} = LegacyPurgeRecord.write(7, 4096)

      assert get_json("/api/metrics")["gauges"] == %{@files => 7, @bytes => 4096}

      body = prometheus()
      assert body =~ "# TYPE #{@files} gauge"
      assert body =~ "# TYPE #{@bytes} gauge"
      assert body =~ "\n#{@files} 7\n"
      assert body =~ "\n#{@bytes} 4096\n"
    end

    test "the existing metrics are still there" do
      {:ok, _} = LegacyPurgeRecord.write(1, 1)
      body = get_json("/api/metrics")

      for key <- ~w(counters histograms uptime_ms sizing connectors) do
        assert Map.has_key?(body, key), "missing #{key}"
      end
    end
  end

  test "the record is Engine-local: one file, not a table" do
    {:ok, _} = LegacyPurgeRecord.write(2, 20)

    assert Path.basename(LegacyPurgeRecord.path()) =~ ".json"
    assert File.regular?(LegacyPurgeRecord.path())
    assert Task.async(&LegacyPurgeRecord.read/0) |> Task.await() == LegacyPurgeRecord.read()
  end

  defp get_json(path) do
    conn = conn(:get, path) |> Router.call(Router.init([]))
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp prometheus do
    conn = conn(:get, "/api/metrics/prometheus") |> Router.call(Router.init([]))
    assert conn.status == 200
    conn.resp_body
  end
end
