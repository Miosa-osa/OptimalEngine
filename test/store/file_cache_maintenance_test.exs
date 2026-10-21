defmodule OptimalEngine.Store.FileCacheMaintenanceTest do
  @moduledoc """
  The legacy cache layout is removed once at boot, entries expire by age, and
  retention is configured by `cache_max_age_days`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache
  alias OptimalEngine.Store.FileCache.{LegacyPurgeRecord, Maintenance}

  @scope {"default", "default:cache-maintenance-test"}
  @day 86_400

  @record_key :embed_cache_legacy_purge_record

  setup do
    saved =
      Map.new(
        [:cache_path, :text_embedding, @record_key],
        &{&1, Application.get_env(:optimal_engine, &1)}
      )

    dir = Path.join(System.tmp_dir!(), "cache-maintenance-#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_engine, :cache_path, dir)
    Application.delete_env(:optimal_engine, :text_embedding)

    # This test's own record, so the Engine's is neither read nor written.
    record = Path.join(System.tmp_dir!(), "purge-record-#{System.unique_integer([:positive])}.json")
    Application.put_env(:optimal_engine, @record_key, record)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
      File.rm(record)
    end)

    id = "purge-event-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:optimal_engine, :embed_cache, :legacy_purge],
        &__MODULE__.forward_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    %{dir: dir, record: record}
  end

  @doc false
  def forward_event(event, measurements, metadata, test),
    do: send(test, {:telemetry, event, measurements, metadata})

  describe "the legacy layout" do
    setup %{dir: dir} do
      # What earlier versions wrote: <cache>/embeddings/<xx>/<sha256>.bin, with the
      # embedded text in the clear inside the file.
      legacy = fn text ->
        key = "nomic-embed-text\0" <> text
        digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
        path = Path.join([dir, "embeddings", binary_part(digest, 0, 2), digest <> ".bin"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, :erlang.term_to_binary({1, key, [0.1, 0.2]}))
        path
      end

      %{legacy: legacy}
    end

    test "is removed once, with the file count and bytes logged, recorded and emitted", ctx do
      first = ctx.legacy.("old-marker first note")
      second = ctx.legacy.("old-marker second note")
      bytes = File.stat!(first).size + File.stat!(second).size
      before = purge_events()

      log =
        capture_log(fn ->
          assert {:ok, %{files: 2, bytes: ^bytes}} = Maintenance.purge_legacy()
        end)

      refute File.exists?(first)
      refute File.exists?(second)
      refute File.exists?(Path.join(ctx.dir, "embeddings"))
      assert log =~ "2 files, #{bytes} bytes"

      assert [[metadata]] = new_purge_events(before)
      assert %{"files" => 2, "bytes" => ^bytes} = Jason.decode!(metadata)

      version = OptimalEngine.Version.application_version()
      assert %{files: 2, bytes: ^bytes, engine_version: ^version, ran_at: ran_at} = recorded()
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(ran_at)
      assert String.ends_with?(ran_at, "Z")

      assert_received {:telemetry, [:optimal_engine, :embed_cache, :legacy_purge],
                       %{files: 2, bytes: ^bytes}, %{engine_version: ^version}}
    end

    test "a fresh Engine with an empty cache records zero files and zero bytes", ctx do
      assert recorded() == nil
      before = purge_events()

      log = capture_log(fn -> assert {:ok, %{files: 0, bytes: 0}} = Maintenance.purge_legacy() end)

      version = OptimalEngine.Version.application_version()
      assert %{files: 0, bytes: 0, engine_version: ^version, ran_at: _} = recorded()
      assert log =~ "0 files, 0 bytes"

      assert_received {:telemetry, [:optimal_engine, :embed_cache, :legacy_purge],
                       %{files: 0, bytes: 0}, _metadata}

      # Nothing was removed, so there is nothing to audit.
      assert new_purge_events(before) == []
      refute File.exists?(Path.join(ctx.dir, "embeddings"))
    end

    test "a second boot finds nothing, says nothing and keeps the record", ctx do
      ctx.legacy.("old-marker only note")
      capture_log(fn -> assert {:ok, %{files: 1}} = Maintenance.purge_legacy() end)
      first = recorded()
      assert_received {:telemetry, _event, %{files: 1}, _metadata}
      before = purge_events()

      log =
        capture_log(fn ->
          assert {:ok, %{files: 0, bytes: 0}} = Maintenance.purge_legacy()
        end)

      refute log =~ "FileCache"
      assert new_purge_events(before) == []
      assert recorded() == first
      refute_received {:telemetry, _event, _measurements, _metadata}
    end

    test "touches only files of the legacy shape", ctx do
      legacy = ctx.legacy.("old-marker note")
      stray = Path.join([ctx.dir, "embeddings", "notes.txt"])
      File.write!(stray, "not a cache entry")
      other = Path.join([ctx.dir, "decomposition", "run.json"])
      File.mkdir_p!(Path.dirname(other))
      File.write!(other, "{}")
      :ok = FileCache.put(@scope, "embeddings", "kept", [1.0])

      capture_log(fn -> assert {:ok, %{files: 1}} = Maintenance.purge_legacy() end)

      refute File.exists?(legacy)
      assert File.exists?(stray)
      assert File.exists?(other)
      assert {:ok, [1.0]} = FileCache.get(@scope, "embeddings", "kept")
    end

    test "starting the Engine's cache maintenance removes it before it answers", ctx do
      path = ctx.legacy.("old-marker booting note")
      before = purge_events()

      capture_log(fn ->
        start_supervised!({Maintenance, name: :cache_maintenance_boot_test})
      end)

      # Done when the process is up: the HTTP endpoint starts after it.
      refute File.exists?(path)
      assert %{files: 1} = recorded()
      assert length(new_purge_events(before)) == 1
      assert_received {:telemetry, _event, %{files: 1}, _metadata}
      stop_supervised!(Maintenance)

      # Booting again, as after a restart, keeps the record and does not run again.
      first = recorded()

      log =
        capture_log(fn ->
          start_supervised!({Maintenance, name: :cache_maintenance_reboot_test})
        end)

      refute log =~ "FileCache"
      assert recorded() == first
      assert length(new_purge_events(before)) == 1
      refute_received {:telemetry, _event, _measurements, _metadata}
    end

    test "files of the old layout that come back are removed and recorded again", ctx do
      capture_log(fn -> assert {:ok, %{files: 0}} = Maintenance.purge_legacy() end)
      assert %{files: 0} = recorded()
      assert_received {:telemetry, _event, %{files: 0}, _metadata}

      # A rollback to an earlier version writes the old layout again.
      path = ctx.legacy.("old-marker after a rollback")
      bytes = File.stat!(path).size

      capture_log(fn -> assert {:ok, %{files: 1, bytes: ^bytes}} = Maintenance.purge_legacy() end)

      refute File.exists?(path)
      assert %{files: 1, bytes: ^bytes} = recorded()
      assert_received {:telemetry, _event, %{files: 1, bytes: ^bytes}, _metadata}
    end

    test "a record that cannot be written is logged and does not fail the purge", ctx do
      ctx.legacy.("old-marker unrecordable")
      # The record's directory is a file.
      blocker = Path.join(System.tmp_dir!(), "purge-blocker-#{System.unique_integer([:positive])}")
      File.write!(blocker, "")
      on_exit(fn -> File.rm(blocker) end)
      Application.put_env(:optimal_engine, @record_key, Path.join(blocker, "record.json"))

      log = capture_log(fn -> assert {:ok, %{files: 1}} = Maintenance.purge_legacy() end)

      assert log =~ "could not record the purge"
      assert LegacyPurgeRecord.read() == nil
    end
  end

  describe "retention" do
    test "the default is 30 days; 0 or nil keeps entries; anything else is refused" do
      assert Maintenance.max_age_days() == 30

      put_retention(7)
      assert Maintenance.max_age_days() == 7

      for off <- [0, nil] do
        put_retention(off)
        assert Maintenance.max_age_days() == nil
      end

      put_retention("soon")

      log = capture_log(fn -> assert Maintenance.max_age_days() == 30 end)
      assert log =~ "cache_max_age_days must be a whole number of days"
    end

    test "the sweep removes entries older than the age and keeps fresh ones", %{dir: dir} do
      forgotten = {"default", "default:cache-maintenance-forgotten"}
      old = put_entry("old", age_days: 40, scope: forgotten)
      stale_tmp = old <> ".tmp-1"
      File.write!(stale_tmp, "left by a crashed write")
      age(stale_tmp, 40)
      put_entry("fresh", age_days: 2)

      assert %{files: 2, bytes: bytes} = FileCache.sweep(30 * @day)
      assert bytes > 0

      refute File.exists?(old)
      refute File.exists?(stale_tmp)
      assert {:ok, [1.0]} = FileCache.get(@scope, "tests", "fresh")
      assert :miss = FileCache.get(@scope, "tests", "old")

      # A workspace left with nothing leaves no directories behind.
      assert [_only_the_fresh_one] = Path.wildcard(Path.join(dir, "tenants/*/*"))
    end

    test "a hit does not extend an entry's life" do
      path = put_entry("read", age_days: 40)
      assert {:ok, [1.0]} = FileCache.get(@scope, "tests", "read")

      assert %{files: 1} = FileCache.sweep(30 * @day)
      refute File.exists?(path)
    end

    test "the configured retention decides what the sweep removes" do
      put_retention(7)
      ten = put_entry("ten-days", age_days: 10)
      three = put_entry("three-days", age_days: 3)

      log = capture_log(fn -> assert %{files: 1} = Maintenance.sweep() end)

      assert log =~ "older than 7 days"
      refute File.exists?(ten)
      assert File.exists?(three)
    end

    test "with retention off the sweep removes nothing" do
      put_retention(0)
      path = put_entry("ancient", age_days: 400)

      assert Maintenance.sweep() == %{files: 0, bytes: 0}
      assert File.exists?(path)
    end
  end

  describe "the cache path" do
    test "a sweep removes only what the cache wrote, whatever else shares the directory",
         %{dir: dir} do
      tenant = digest("a tenant")
      workspace = digest("a workspace")

      # A cache path that is also a workspace root: <root>/tenants/<tenant>/<slug>/...
      foreign = [
        Path.join([dir, "tenants", "acme", "sales", "nodes", "ab", "notes.md"]),
        Path.join([dir, "tenants", tenant, workspace, "embeddings", "ab", "notes.md"]),
        Path.join([dir, "tenants", tenant, workspace, "embeddings", "zz", digest("x") <> ".bin"]),
        Path.join([
          dir,
          "tenants",
          tenant,
          workspace,
          "Bad_Namespace",
          "ab",
          digest("y") <> ".bin"
        ]),
        Path.join([dir, "tenants", "acme", workspace, "embeddings", "ab", digest("z") <> ".bin"]),
        Path.join([
          dir,
          "tenants",
          tenant,
          workspace,
          "embeddings",
          "ab",
          digest("w") <> ".bin.old"
        ])
      ]

      for file <- foreign do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, "not a cache entry")
        age(file, 400)
      end

      owned = put_entry("owned", age_days: 400)

      assert %{files: 1} = FileCache.sweep(30 * @day)

      refute File.exists?(owned)
      for file <- foreign, do: assert(File.exists?(file), "the sweep removed #{file}")

      # Nor does a purge or a listing look at them.
      assert {:ok, %{files: 0}} = FileCache.purge_workspace("sales")
      assert FileCache.stats() == %{}
      for file <- foreign, do: assert(File.exists?(file), "a purge removed #{file}")
    end

    test "glob characters in it do not turn a purge, a sweep or a listing into a no-op",
         %{dir: dir} do
      root = Path.join(dir, "cache [a-z]* {x,y}? ~")
      Application.put_env(:optimal_engine, :cache_path, root)
      assert FileCache.root() == Path.expand(root)

      :ok = FileCache.put(@scope, "tests", "kept", [1.0])
      assert {:ok, [1.0]} = FileCache.get(@scope, "tests", "kept")
      assert %{"tests" => %{entries: 1}} = FileCache.stats()

      forgotten = {"default", "default:cache-maintenance-forgotten"}
      old = put_entry("old", age_days: 40, scope: forgotten)
      assert %{files: 1} = FileCache.sweep(30 * @day)
      refute File.exists?(old)
      assert {:ok, [1.0]} = FileCache.get(@scope, "tests", "kept")

      # The purge reports what it removed because it removed it.
      assert {:ok, %{files: 1}} = FileCache.purge_workspace(elem(@scope, 1))
      assert :miss = FileCache.get(@scope, "tests", "kept")
      refute File.exists?(entry_file(@scope, "tests", "kept"))

      legacy = Path.join([root, "embeddings", "ab", digest("legacy") <> ".bin"])
      File.mkdir_p!(Path.dirname(legacy))
      File.write!(legacy, "old layout")
      assert {:ok, %{files: 1}} = FileCache.purge_legacy()
      refute File.exists?(legacy)
    end
  end

  describe "a purge that fails" do
    setup do
      # File permissions do not bind the superuser, so the failures below cannot be made.
      {uid, 0} = System.cmd("id", ["-u"])
      if String.trim(uid) == "0", do: {:ok, skip: true}, else: {:ok, skip: false}
    end

    test "is tried again on the tick when it failed at boot", %{dir: dir, skip: skip} do
      unless skip do
        path = Path.join([dir, "embeddings", "ab", digest("stuck") <> ".bin"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "old layout")
        File.chmod!(Path.dirname(path), 0o500)
        on_exit(fn -> File.chmod(Path.dirname(path), 0o700) end)

        log =
          capture_log(fn ->
            pid = start_supervised!({Maintenance, name: :cache_maintenance_retry_test})

            # It could not remove the file, so nothing is recorded as done.
            assert File.exists?(path)
            assert LegacyPurgeRecord.read() == nil

            File.chmod!(Path.dirname(path), 0o700)
            send(pid, :sweep)
            :sys.get_state(pid)

            refute File.exists?(path)
            assert %{files: 1} = LegacyPurgeRecord.read()
          end)

        assert log =~ "could not remove the unpartitioned embedding cache"
      end
    end

    test "reports its cause without the path it failed at", %{dir: dir, skip: skip} do
      unless skip do
        :ok = FileCache.put(@scope, "tests", "stuck", [1.0])
        shard = entry_file(@scope, "tests", "stuck") |> Path.dirname()
        File.chmod!(shard, 0o500)
        on_exit(fn -> File.chmod(shard, 0o700) end)

        {result, _log} = with_log(fn -> Maintenance.purge_workspace(elem(@scope, 1), :erase) end)

        assert {:error, {:purge_failed, :eacces, path}} = result
        assert String.starts_with?(path, dir)
        assert Maintenance.reason({:purge_failed, :eacces, path}) == :eacces
        assert %{error: ":eacces"} = Maintenance.summary(result)
      end
    end
  end

  test "purging a workspace says how much it removed" do
    :ok = FileCache.put(@scope, "embeddings", "a", [1.0])
    :ok = FileCache.put(@scope, "embeddings", "b", [1.0])

    log =
      capture_log(fn ->
        assert {:ok, %{files: 2, bytes: bytes}} =
                 Maintenance.purge_workspace(elem(@scope, 1), :archive)

        send(self(), {:bytes, bytes})
      end)

    assert_received {:bytes, bytes}

    assert log =~
             "purged the cache of workspace #{elem(@scope, 1)} (archive): 2 files, #{bytes} bytes"

    assert Maintenance.summary({:ok, %{files: 2, bytes: bytes}}) == %{files: 2, bytes: bytes}
    assert %{error: ":boom"} = Maintenance.summary({:error, :boom})
  end

  defp recorded, do: LegacyPurgeRecord.read()

  defp put_retention(days) do
    Application.put_env(:optimal_engine, :text_embedding, cache_max_age_days: days)
  end

  # A cache entry whose file was last written `age_days` ago.
  defp put_entry(key, opts) do
    scope = Keyword.get(opts, :scope, @scope)
    age_days = Keyword.fetch!(opts, :age_days)
    :ok = FileCache.put(scope, "tests", key, [1.0])
    path = entry_file(scope, "tests", key)
    age(path, age_days)
    path
  end

  # Where the cache keeps an entry: derived from the layout, not found by a glob, so it
  # also works under a cache path with glob characters in it.
  defp entry_file({tenant, workspace}, namespace, key) do
    digest = digest(key)

    Path.join([
      FileCache.root(),
      "tenants",
      digest(tenant),
      digest(workspace),
      namespace,
      binary_part(digest, 0, 2),
      digest <> ".bin"
    ])
  end

  defp age(path, days) do
    mtime = :calendar.system_time_to_universal_time(System.os_time(:second) - days * @day, :second)
    File.touch!(path, mtime)
  end

  defp digest(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  defp purge_events do
    {:ok, [[n]]} =
      Store.raw_query("SELECT COUNT(*) FROM events WHERE kind = 'cache.legacy_purge'", [])

    n
  end

  # Metadata of the purge events written since `before` events existed.
  defp new_purge_events(before) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT metadata FROM events WHERE kind = 'cache.legacy_purge' ORDER BY id LIMIT -1 OFFSET ?1",
        [before]
      )

    rows
  end
end
