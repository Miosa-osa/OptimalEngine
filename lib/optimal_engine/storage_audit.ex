defmodule OptimalEngine.StorageAudit do
  @moduledoc "Deep, read-only health audit for every engine storage layer."

  alias OptimalEngine.{Backup, StorageCatalog, Store}
  alias OptimalEngine.Backup.Schedule
  alias OptimalEngine.Storage.{Assets, S3}
  alias OptimalEngine.Pipeline.Decomposer.RLM

  @scoped_tables ~w(contexts chunks chunk_embeddings memories claims facts memory_objects source_packages)

  @spec run() :: map()
  def run do
    checks = [
      check("sqlite_integrity", &sqlite_integrity/0),
      check("foreign_keys", &foreign_keys/0),
      check("migrations", &migrations/0),
      check("logical_stores", &logical_stores/0),
      check("fts_parity", &fts_parity/0),
      check("workspace_scope", &workspace_scope/0),
      check("vector_integrity", &vector_integrity/0),
      check("active_test_fixtures", &active_test_fixtures/0),
      check("asset_files", &asset_files/0),
      check("verified_backup", &verified_backup/0),
      check("offsite_backup_schedule", &offsite_backup_schedule/0),
      check("rlm_runtime", &rlm_runtime/0),
      check("cache", &cache/0)
    ]

    failures = Enum.reject(checks, & &1.ok)
    %{ok: failures == [], checks: checks, failures: length(failures)}
  end

  defp check(name, fun) do
    started_at = System.monotonic_time()

    try do
      case fun.() do
        {:ok, detail} ->
          %{name: name, ok: true, detail: detail, duration_ms: elapsed_ms(started_at)}

        {:error, detail} ->
          %{name: name, ok: false, detail: inspect(detail), duration_ms: elapsed_ms(started_at)}
      end
    rescue
      error ->
        %{
          name: name,
          ok: false,
          detail: Exception.message(error),
          duration_ms: elapsed_ms(started_at)
        }
    catch
      :exit, reason ->
        %{name: name, ok: false, detail: inspect(reason), duration_ms: elapsed_ms(started_at)}
    end
  end

  defp sqlite_integrity do
    db_path = Application.fetch_env!(:optimal_engine, :db_path)

    case Backup.verify(db_path) do
      {:ok, :ok} -> {:ok, "ok"}
      {:ok, issues} -> {:error, issues}
      other -> {:error, other}
    end
  end

  defp foreign_keys do
    case Store.raw_query("PRAGMA foreign_key_check", []) do
      {:ok, []} -> {:ok, "no violations"}
      {:ok, rows} -> {:error, %{violations: length(rows)}}
      other -> {:error, other}
    end
  end

  defp migrations do
    with {:ok, [[applied]]} <- Store.raw_query("SELECT MAX(version) FROM schema_migrations", []),
         expected <- OptimalEngine.Store.Migrations.all() |> List.last() |> elem(0),
         true <- applied == expected do
      {:ok, %{applied: applied, expected: expected}}
    else
      false -> {:error, :migration_drift}
      other -> {:error, other}
    end
  end

  defp logical_stores do
    stores = StorageCatalog.list()
    degraded = Enum.filter(stores, &(&1.status != "available"))
    if degraded == [], do: {:ok, %{available: length(stores)}}, else: {:error, degraded}
  end

  defp fts_parity do
    sql = """
    SELECT
      (SELECT COUNT(*) FROM contexts),
      (SELECT COUNT(*) FROM contexts_fts),
      (SELECT COUNT(DISTINCT id) FROM contexts_fts)
    """

    case Store.raw_query(sql, []) do
      {:ok, [[contexts, fts, distinct]]} when contexts == fts and fts == distinct ->
        {:ok, %{contexts: contexts, indexed: fts}}

      {:ok, [[contexts, fts, distinct]]} ->
        {:error, %{contexts: contexts, indexed: fts, distinct_ids: distinct}}

      other ->
        {:error, other}
    end
  end

  defp workspace_scope do
    parts =
      Enum.map_join(
        @scoped_tables,
        " + ",
        &"(SELECT COUNT(*) FROM #{&1} WHERE workspace_id = 'default')"
      )

    case scalar("SELECT #{parts}") do
      {:ok, 0} -> {:ok, "no legacy-default rows"}
      {:ok, count} -> {:error, %{legacy_default_rows: count}}
      other -> other
    end
  end

  defp vector_integrity do
    sql = """
    SELECT
      (SELECT COUNT(*) FROM vectors WHERE dimensions <= 0 OR length(embedding) != dimensions * 4),
      (SELECT COUNT(*) FROM chunk_embeddings WHERE dim <= 0 OR length(vector) != dim * 4),
      (SELECT COUNT(*) FROM vectors v LEFT JOIN contexts c ON c.id = v.context_id WHERE c.id IS NULL),
      (SELECT COUNT(*) FROM chunk_embeddings e LEFT JOIN chunks c ON c.id = e.chunk_id WHERE c.id IS NULL)
    """

    case Store.raw_query(sql, []) do
      {:ok, [[0, 0, 0, 0]]} -> {:ok, "dimensions and references valid"}
      {:ok, [counts]} -> {:error, %{bad_counts: counts}}
      other -> {:error, other}
    end
  end

  defp active_test_fixtures do
    sql = """
    SELECT
      (SELECT COUNT(*) FROM workspaces WHERE status = 'active' AND id GLOB 'exampleorg-*:secrets'),
      (SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL AND (
        path LIKE '/var/folders/%/optimal_%test_%'
        OR path LIKE '/tmp/optimal_%test_%'
        OR node = 'test'
        OR node LIKE 'node-a-%'
        OR node LIKE 'node-b-%'
      ))
    """

    case Store.raw_query(sql, []) do
      {:ok, [[0, 0]]} ->
        {:ok, "none active"}

      {:ok, [[workspaces, contexts]]} ->
        {:error, %{active_fixture_workspaces: workspaces, active_fixture_contexts: contexts}}

      other ->
        other
    end
  end

  # Assets are files on the local filesystem by default and objects in a bucket
  # when the workspace storage policy or the engine selects S3. Both are checked,
  # and an object that cannot be confirmed is a failure, not a pass.
  defp asset_files do
    case Store.raw_query("SELECT storage_path FROM assets", []) do
      {:ok, rows} ->
        rows
        |> Enum.map(&hd/1)
        |> Assets.inventory()

      other ->
        {:error, other}
    end
  end

  # The newest verified backup must exist somewhere. A local copy is the common
  # case; a backup whose local copy was removed after it was shipped offsite is
  # still a backup, so the object is confirmed before it is called missing.
  defp verified_backup do
    sql = """
    SELECT storage_uri, checksum_sha256, offsite, metadata
    FROM backup_records
    WHERE status = 'completed' AND integrity_status = 'verified'
    ORDER BY verified_at DESC, rowid DESC LIMIT 1
    """

    case Store.raw_query(sql, []) do
      {:ok, [[path, checksum, offsite, metadata]]} when is_binary(checksum) ->
        cond do
          String.length(checksum) != 64 ->
            {:error, :verified_backup_missing}

          File.regular?(path) ->
            {:ok, %{path: path, checksum: checksum, copies: ["local"]}}

          offsite == 1 ->
            offsite_backup(metadata, checksum)

          true ->
            {:error, :verified_backup_missing}
        end

      {:ok, []} ->
        {:error, :no_verified_backup}

      other ->
        {:error, other}
    end
  end

  # Scheduled offsite backups that are failing, stale, or cannot run are a
  # storage failure rather than a footnote. A schedule that is off passes.
  defp offsite_backup_schedule do
    status = Schedule.status()

    detail = %{
      state: status.state,
      enabled: status.enabled,
      interval_ms: status.interval_ms,
      last_success_at: status.last_success && status.last_success.shipped_at,
      last_error: status.last_job && status.last_job.last_error,
      dead_letters: status.dead_letters.count,
      problem: if(status.enabled, do: status.encryption.problem || status.object_store.problem)
    }

    if Schedule.failing_state?(status.state), do: {:error, detail}, else: {:ok, detail}
  end

  # An offsite-only backup is confirmed by asking the object store for it, so a
  # bucket that is unreachable or missing the object is reported, not assumed.
  defp offsite_backup(metadata, checksum) do
    with {:ok, decoded} <- decode_metadata(metadata),
         uri when is_binary(uri) <- decoded["offsite_uri"],
         {:ok, _bucket, key} <- S3.parse_uri(uri),
         {:ok, object} <- S3.head_object(key, max_retries: 0) do
      {:ok,
       %{
         path: nil,
         offsite_uri: uri,
         checksum: checksum,
         size_bytes: object.size_bytes,
         copies: ["offsite"]
       }}
    else
      nil -> {:error, :verified_backup_missing}
      _ -> {:error, :verified_backup_unreachable}
    end
  end

  defp decode_metadata(metadata) do
    case Jason.decode(metadata || "{}") do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_backup_metadata}
    end
  end

  defp rlm_runtime do
    case RLM.health() do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        if System.get_env("OPTIMAL_RLM_REQUIRED") == "true",
          do: {:error, reason},
          else: {:ok, %{available: false, optional: true, reason: inspect(reason)}}
    end
  end

  defp cache do
    case :ets.info(:optimal_engine_store_cache, :size) do
      :undefined -> {:error, :cache_unavailable}
      size -> {:ok, %{entries: size, file_cache: OptimalEngine.Store.FileCache.stats()}}
    end
  end

  defp scalar(sql) do
    case Store.raw_query(sql, []) do
      {:ok, [[value]]} -> {:ok, value}
      other -> {:error, other}
    end
  end

  defp elapsed_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end
