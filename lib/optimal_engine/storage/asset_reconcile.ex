defmodule OptimalEngine.Storage.AssetReconcile do
  @moduledoc """
  Puts in the bucket the assets that were kept on the local disk while their
  object store was unconfigured or unreachable (`OptimalEngine.Storage.Assets`).

  Such an asset carries `storage_fallback_reason` in its metadata: that
  record is what is pending. A run reads the pending assets a batch at a time
  and, for each one whose workspace still selects S3 for assets:

    1. opens the local copy only if it is a regular file under the Engine's
       root (`Assets.confine_local/1`) and checks it against the asset's
       content hash;
    2. uploads it under the object key a direct write would have used;
    3. downloads the object back and compares its SHA-256 with the local copy;
    4. only then records the asset as placed: its `storage_path` becomes the
       object URI, its metadata names the object (`object_uri`, `object_key`,
       `object_checksum_sha256`, `object_size_bytes`) and `storage_placed_at`,
       and the fallback reason moves to `storage_fallback_resolved`.

  The local copy stays on disk. A run is idempotent: a placed asset is no
  longer pending, the same bytes uploaded again to the same key change
  nothing, and an asset whose object does not verify stays pending. The first
  transport error ends the run, so an object store that is still down is not
  asked once per asset. An asset whose workspace now keeps assets on the
  filesystem is resolved without an upload (`storage_fallback_resolved`
  records `backend_now_filesystem`). A workspace policy that cannot be read is
  not an answer: the asset stays pending.

  A stored path is data, and rows reach the table from a bundle import as well
  as from an upload. A row whose copy can never be placed is quarantined, not
  retried by every pass: its metadata gains `storage_placement_quarantined`
  (the reason: `outside_root`, `not_a_regular_file`, `local_copy_missing` or
  `local_copy_differs`) and `storage_placement_quarantined_at`, and the pass
  goes on to the next row. The fallback record stays; removing the two
  quarantine keys from the asset's metadata queues it again.

  The record of a row is a compare-and-swap on the `storage_path` and metadata
  the pass read, so a bundle import or a re-ingest that changes the row during
  the pass is not overwritten; the pass counts it as `superseded`.

  `gauges/0` are the metrics `optimal_engine_storage_assets_pending_placement`
  (assets waiting for a pass) and
  `optimal_engine_storage_assets_placement_quarantined` in `GET /api/metrics`
  (`gauges`) and in Prometheus. Counting them scans the assets table, so a
  scrape reads a count cached for a minute, dropped when an asset falls back to
  disk and refreshed by every pass.
  `OptimalEngine.Storage.AssetReconcile.Worker` runs a pass every ten minutes
  while any are pending and S3 is configured.
  """

  require Logger

  alias OptimalEngine.Storage.{Assets, S3}
  alias OptimalEngine.{Store, Workspace}

  @pending "json_extract(metadata, '$.storage_fallback_reason') IS NOT NULL"
  @not_quarantined "json_extract(metadata, '$.storage_placement_quarantined') IS NULL"
  @quarantined "json_extract(metadata, '$.storage_placement_quarantined') IS NOT NULL"
  @batch 100

  @pending_gauge "optimal_engine_storage_assets_pending_placement"
  @quarantined_gauge "optimal_engine_storage_assets_placement_quarantined"
  @help %{
    @pending_gauge =>
      "Assets kept on the local disk during an object store outage, waiting to be placed in the bucket",
    @quarantined_gauge =>
      "Assets kept on the local disk that a placement pass refused and will not retry until an operator requeues them"
  }

  @cache {__MODULE__, :counts}
  @cache_seconds 60

  @type counts :: %{pending: non_neg_integer(), quarantined: non_neg_integer()}

  @doc """
  How many assets are waiting to be put in their object store, in the Engine
  or (with `:workspace_id`) in one workspace. Quarantined assets are not
  waiting. This scans the assets table; the metrics read `counts/0`.
  """
  @spec pending_count(keyword()) :: non_neg_integer()
  def pending_count(opts \\ []) do
    case scan(opts) do
      {:ok, %{pending: pending}} -> pending
      {:error, _reason} -> 0
    end
  end

  @doc """
  The pending and quarantined counts of the whole Engine, from a cache at most
  a minute old. The cache is what keeps a metrics scrape from scanning the
  assets table.
  """
  @spec counts() :: {:ok, counts()} | {:error, term()}
  def counts do
    cache = cache()

    if :atomics.get(cache, 4) == :atomics.get(cache, 5) + 1 and
         System.monotonic_time(:second) - :atomics.get(cache, 3) < @cache_seconds do
      {:ok, %{pending: :atomics.get(cache, 1), quarantined: :atomics.get(cache, 2)}}
    else
      refresh_counts()
    end
  end

  @doc "Counts the whole Engine's assets now and caches the result for `counts/0`."
  @spec refresh_counts() :: {:ok, counts()} | {:error, term()}
  def refresh_counts do
    cache = cache()
    generation = :atomics.get(cache, 5)

    with {:ok, counts} <- scan([]) do
      :atomics.put(cache, 1, counts.pending)
      :atomics.put(cache, 2, counts.quarantined)
      :atomics.put(cache, 3, System.monotonic_time(:second))
      # Valid only if nothing invalidated the cache while the scan ran.
      :atomics.put(cache, 4, generation + 1)
      {:ok, counts}
    end
  end

  @doc """
  Drops the cached counts, for a writer that has just kept an asset on disk, so
  the next scrape counts it.
  """
  @spec invalidate_counts() :: :ok
  def invalidate_counts, do: :atomics.add(cache(), 5, 1)

  @doc """
  The gauges by Prometheus name, for `GET /api/metrics` and the Prometheus
  rendering; empty when the assets table cannot be counted.
  """
  @spec gauges() :: %{String.t() => non_neg_integer()}
  def gauges do
    case counts() do
      {:ok, %{pending: pending, quarantined: quarantined}} ->
        %{@pending_gauge => pending, @quarantined_gauge => quarantined}

      {:error, _reason} ->
        %{}
    end
  end

  @doc "What a gauge from `gauges/0` measures."
  @spec help(String.t()) :: String.t()
  def help(name), do: Map.fetch!(@help, name)

  @doc """
  Places up to `:limit` pending assets (100 by default), of one workspace with
  `:workspace_id`, the oldest first. Returns
  `{:ok, %{placed: n, resolved: n, failed: n, quarantined: n, superseded: n, pending: n}}`,
  or `{:error, :s3_not_configured}` without touching anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, :s3_not_configured}
  def run(opts \\ []) do
    if S3.configured?() do
      {where, params} = scope(opts, 2)

      {:ok, rows} =
        Store.raw_query(
          """
          SELECT id, tenant_id, workspace_id, storage_path, content_hash, metadata
          FROM assets WHERE #{@pending} AND #{@not_quarantined}#{where}
          ORDER BY created_at, id LIMIT ?1
          """,
          [Keyword.get(opts, :limit, @batch) | params]
        )

      counts =
        Enum.reduce_while(
          rows,
          %{placed: 0, resolved: 0, failed: 0, quarantined: 0, superseded: 0},
          fn row, counts ->
            case place_safely(row) do
              {:unreachable, _reason} -> {:halt, Map.update!(counts, :failed, &(&1 + 1))}
              {:failed, _reason} -> {:cont, Map.update!(counts, :failed, &(&1 + 1))}
              outcome -> {:cont, Map.update!(counts, outcome, &(&1 + 1))}
            end
          end
        )

      pending = pending_count(opts)
      refresh_counts()
      {:ok, Map.put(counts, :pending, pending)}
    else
      {:error, :s3_not_configured}
    end
  end

  # One row's trouble does not end the pass for the rows behind it.
  defp place_safely(row) do
    place(row)
  rescue
    error ->
      Logger.error("[AssetReconcile] an asset stays pending: #{Exception.message(error)}")
      {:failed, :exception}
  end

  defp place([id, tenant_id, workspace_id, storage_path, content_hash, metadata_json]) do
    row = %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      storage_path: storage_path,
      content_hash: content_hash || "",
      metadata_json: metadata_json,
      metadata: decode(metadata_json)
    }

    case Assets.resolve_backend(workspace_id: workspace_id) do
      {:ok, :s3} ->
        upload(row)

      {:ok, :filesystem} ->
        settle(row, storage_path, resolved(row.metadata, "backend_now_filesystem"), :resolved)

      {:error, reason} ->
        Logger.error(
          "[AssetReconcile] asset #{id} stays pending: its workspace storage policy could not be read: #{inspect(reason)}"
        )

        {:failed, reason}
    end
  end

  defp upload(row) do
    local = local_path(row)
    expected = String.replace_prefix(row.content_hash, "sha256:", "")

    key =
      Assets.object_key(%{
        tenant_id: row.tenant_id,
        workspace_id: slug(row.workspace_id),
        hash: row.content_hash,
        extension: Path.extname(local)
      })

    with {:ok, path} <- confine(local),
         {:ok, ^expected} <- local_sha256(path),
         {:ok, object} <- S3.put_file(key, path),
         :ok <- verify(key, expected) do
      placed =
        row.metadata
        |> resolved(row.metadata["storage_fallback_reason"])
        |> Map.merge(%{
          "storage_backend" => "s3",
          "object_uri" => object.uri,
          "object_key" => object.key,
          "object_checksum_sha256" => expected,
          "object_size_bytes" => object.size_bytes,
          "storage_placed_at" => now()
        })

      settle(row, object.uri, placed, :placed)
    else
      {:refused, reason} ->
        quarantine(row, reason)

      {:ok, _other} ->
        quarantine(row, "local_copy_differs")

      {:error, {:transport, _} = reason} ->
        {:unreachable, reason}

      {:error, reason} ->
        Logger.error("[AssetReconcile] asset #{row.id} stays pending: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  # Where the row says its local copy is. The metadata is JSON an importer can
  # write, so anything but a string is ignored.
  defp local_path(%{metadata: %{"local_path" => path}}) when is_binary(path), do: path
  defp local_path(row), do: row.storage_path

  # The local copy to open, or the reason this row can never be placed. Any
  # other trouble reaching the file may pass, so it is an error, not a refusal.
  defp confine(local) do
    case Assets.confine_local(local) do
      {:ok, path} ->
        {:ok, path}

      {:error, {:asset_outside_root, _}} ->
        {:refused, "outside_root"}

      {:error, {:asset_not_a_file, _}} ->
        {:refused, "not_a_regular_file"}

      {:error, {:asset_unreadable, _, reason}} when reason in [:enoent, :enotdir] ->
        {:refused, "local_copy_missing"}

      {:error, reason} ->
        {:error, {:local_copy_unreadable, reason}}
    end
  end

  # The object is read back and hashed before anything records it as placed.
  defp verify(key, expected) do
    tmp = Path.join(System.tmp_dir!(), "asset-reconcile-#{System.unique_integer([:positive])}")

    try do
      case S3.get_object_to_file(key, tmp) do
        {:ok, %{checksum_sha256: ^expected}} -> :ok
        {:ok, %{checksum_sha256: other}} -> {:error, {:object_differs, other}}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp)
    end
  end

  defp quarantine(row, reason) do
    marked =
      Map.merge(row.metadata, %{
        "storage_placement_quarantined" => reason,
        "storage_placement_quarantined_at" => now()
      })

    settle(row, row.storage_path, marked, :quarantined)
  end

  # Records the outcome in the row, if the row is still as the pass read it.
  defp settle(row, storage_path, metadata, outcome) do
    case swap(row, storage_path, metadata) do
      :changed ->
        log_settled(outcome, row, metadata)
        outcome

      :unchanged ->
        Logger.info("[AssetReconcile] asset #{row.id} changed during the pass, left as it is")
        :superseded

      {:error, reason} ->
        Logger.error(
          "[AssetReconcile] asset #{row.id} stays pending: its record could not be updated: #{inspect(reason)}"
        )

        {:failed, {:record_failed, reason}}
    end
  end

  defp log_settled(:placed, row, _metadata),
    do: Logger.info("[AssetReconcile] asset #{row.id} placed in the object store")

  defp log_settled(:quarantined, row, metadata) do
    Logger.error(
      "[AssetReconcile] asset #{row.id} quarantined, it is not retried: #{metadata["storage_placement_quarantined"]}"
    )
  end

  defp log_settled(:resolved, _row, _metadata), do: :ok

  # Compare-and-swap: the row is updated only while it holds the storage path
  # and metadata the pass read. A second pass, a bundle import or a re-ingest
  # that got there first leaves this update with nothing to change.
  defp swap(row, storage_path, metadata) do
    sql = """
    UPDATE assets SET storage_path = ?2, metadata = ?3
    WHERE id = ?1 AND storage_path = ?4 AND metadata = ?5
    RETURNING id
    """

    case Store.raw_query(sql, [
           row.id,
           storage_path,
           Jason.encode!(metadata),
           row.storage_path,
           row.metadata_json
         ]) do
      {:ok, [_row]} -> :changed
      {:ok, []} -> :unchanged
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolved(metadata, reason) do
    metadata
    |> Map.delete("storage_fallback_reason")
    |> Map.put("storage_fallback_resolved", reason)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp local_sha256(path) do
    {:ok,
     path
     |> File.stream!(1_048_576)
     |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
     |> :crypto.hash_final()
     |> Base.encode16(case: :lower)}
  rescue
    error -> {:error, {:local_copy_unreadable, Exception.message(error)}}
  end

  # One scan of the assets table: how many are waiting and how many are
  # quarantined, in the Engine or (with `:workspace_id`) in one workspace.
  defp scan(opts) do
    {where, params} = scope(opts, 1)

    sql = """
    SELECT COALESCE(SUM(CASE WHEN #{@quarantined} THEN 0 ELSE 1 END), 0),
           COALESCE(SUM(CASE WHEN #{@quarantined} THEN 1 ELSE 0 END), 0)
    FROM assets WHERE #{@pending}#{where}
    """

    case Store.raw_query(sql, params) do
      {:ok, [[pending, quarantined]]} -> {:ok, %{pending: pending, quarantined: quarantined}}
      {:ok, other} -> {:error, {:unexpected_count, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Five atomics in a persistent term, so that dropping or refreshing the
  # counts never rewrites the term: pending, quarantined, when they were
  # counted (monotonic seconds), the generation they were counted in plus one,
  # and the current generation. An invalidation bumps the generation, so the
  # counts of a scan that began before it never read as valid.
  defp cache do
    case :persistent_term.get(@cache, nil) do
      nil ->
        cache = :atomics.new(5, signed: true)
        :persistent_term.put(@cache, cache)
        cache

      cache ->
        cache
    end
  end

  defp scope(opts, index) do
    case Keyword.get(opts, :workspace_id) do
      nil -> {"", []}
      workspace_id -> {" AND workspace_id = ?#{index}", [workspace_id]}
    end
  end

  defp slug(workspace_id) do
    case Workspace.get(workspace_id) do
      {:ok, workspace} -> workspace.slug || workspace.id
      _ -> workspace_id
    end
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(_json), do: %{}
end
