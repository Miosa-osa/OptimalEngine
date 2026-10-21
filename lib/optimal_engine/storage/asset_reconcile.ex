defmodule OptimalEngine.Storage.AssetReconcile do
  @moduledoc """
  Puts in the bucket the assets that were kept on the local disk while their
  object store was unconfigured or unreachable (`OptimalEngine.Storage.Assets`).

  Such an asset carries `storage_fallback_reason` in its metadata: that
  record is what is pending. A run reads the pending assets a batch at a time
  and, for each one whose workspace still selects S3 for assets:

    1. checks the local copy against the asset's content hash;
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
  records `backend_now_filesystem`).

  `pending_count/0` is the gauge `optimal_engine_storage_assets_pending_placement`
  in `GET /api/metrics` (`gauges`) and in Prometheus.
  `OptimalEngine.Storage.AssetReconcile.Worker` runs a pass every ten minutes
  while any are pending and S3 is configured.
  """

  require Logger

  alias OptimalEngine.Storage.{Assets, S3}
  alias OptimalEngine.{Store, Workspace}

  @pending "json_extract(metadata, '$.storage_fallback_reason') IS NOT NULL"
  @batch 100

  @doc """
  How many assets are waiting to be put in their object store, in the Engine
  or (with `:workspace_id`) in one workspace.
  """
  @spec pending_count(keyword()) :: non_neg_integer()
  def pending_count(opts \\ []) do
    {where, params} = scope(opts, 1)

    case Store.raw_query("SELECT COUNT(*) FROM assets WHERE #{@pending}#{where}", params) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  @doc """
  Places up to `:limit` pending assets (100 by default), of one workspace with
  `:workspace_id`, the oldest first. Returns
  `{:ok, %{placed: n, resolved: n, failed: n, pending: n}}`, or
  `{:error, :s3_not_configured}` without touching anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, :s3_not_configured}
  def run(opts \\ []) do
    if S3.configured?() do
      {where, params} = scope(opts, 2)

      {:ok, rows} =
        Store.raw_query(
          """
          SELECT id, tenant_id, workspace_id, storage_path, content_hash, metadata
          FROM assets WHERE #{@pending}#{where} ORDER BY created_at, id LIMIT ?1
          """,
          [Keyword.get(opts, :limit, @batch) | params]
        )

      counts =
        Enum.reduce_while(rows, %{placed: 0, resolved: 0, failed: 0}, fn row, counts ->
          case place(row) do
            :placed -> {:cont, Map.update!(counts, :placed, &(&1 + 1))}
            :resolved -> {:cont, Map.update!(counts, :resolved, &(&1 + 1))}
            {:failed, _reason} -> {:cont, Map.update!(counts, :failed, &(&1 + 1))}
            {:unreachable, _reason} -> {:halt, Map.update!(counts, :failed, &(&1 + 1))}
          end
        end)

      {:ok, Map.put(counts, :pending, pending_count(opts))}
    else
      {:error, :s3_not_configured}
    end
  end

  defp place([id, tenant_id, workspace_id, storage_path, content_hash, metadata_json]) do
    metadata = decode(metadata_json)
    local = metadata["local_path"] || storage_path

    if Assets.selected_backend(workspace_id: workspace_id) == :s3 do
      upload(id, tenant_id, workspace_id, local, content_hash, metadata)
    else
      record(id, storage_path, resolved(metadata, "backend_now_filesystem"))
      :resolved
    end
  end

  defp upload(id, tenant_id, workspace_id, local, content_hash, metadata) do
    expected = String.replace_prefix(content_hash || "", "sha256:", "")

    key =
      Assets.object_key(%{
        tenant_id: tenant_id,
        workspace_id: slug(workspace_id),
        hash: content_hash,
        extension: Path.extname(local)
      })

    with {:ok, ^expected} <- local_sha256(local),
         {:ok, object} <- S3.put_file(key, local),
         :ok <- verify(key, expected) do
      placed =
        metadata
        |> resolved(metadata["storage_fallback_reason"])
        |> Map.merge(%{
          "storage_backend" => "s3",
          "object_uri" => object.uri,
          "object_key" => object.key,
          "object_checksum_sha256" => expected,
          "object_size_bytes" => object.size_bytes,
          "storage_placed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      record(id, object.uri, placed)
      Logger.info("[AssetReconcile] asset #{id} placed in the object store")
      :placed
    else
      {:ok, other} ->
        Logger.error(
          "[AssetReconcile] asset #{id} stays pending: its local copy hashes to #{other}, not #{expected}"
        )

        {:failed, :local_copy_differs}

      {:error, {:transport, _} = reason} ->
        {:unreachable, reason}

      {:error, reason} ->
        Logger.error("[AssetReconcile] asset #{id} stays pending: #{inspect(reason)}")
        {:failed, reason}
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

  # Only a row still pending is changed, so two runs never both record it.
  defp record(id, storage_path, metadata) do
    Store.raw_query(
      "UPDATE assets SET storage_path = ?2, metadata = ?3 WHERE id = ?1 AND #{@pending}",
      [id, storage_path, Jason.encode!(metadata)]
    )
  end

  defp resolved(metadata, reason) do
    metadata
    |> Map.delete("storage_fallback_reason")
    |> Map.put("storage_fallback_resolved", reason)
  end

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
