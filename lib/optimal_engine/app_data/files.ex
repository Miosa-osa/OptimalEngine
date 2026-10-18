defmodule OptimalEngine.AppData.Files do
  @moduledoc """
  Files attached to app data records.

  Bytes are preserved through the Engine's governed asset store
  (`OptimalEngine.MemoryCore.AssetStore`): content addressed, recorded as
  an asset with a Source Package, scoped to the record's workspace. A
  `data_files` row links the asset to one record with its filename and
  content type. Deleting a file or its record removes the link; the asset
  itself stays in the asset store as preserved evidence.

  Uploads arrive as base64 inside the JSON request body (the API accepts
  JSON only), so one upload is bounded by the request size limit.
  Downloads stream from the asset's stored path and honor single byte
  ranges.
  """

  alias OptimalEngine.AppData.{Collections, Records, Schema, Scope, SQL}
  alias OptimalEngine.MemoryCore.AssetStore
  alias OptimalEngine.Store

  @max_bytes 6_000_000
  @max_files_per_record 100

  @doc "Largest decoded upload accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Attaches a file to a record. `attrs`: `filename`, `content_base64`,
  optional `content_type` and `metadata`.
  """
  @spec upload(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def upload(%Scope{} = scope, name, record_id, attrs) do
    with :ok <- Scope.allow(scope, name, "update"),
         :ok <- storable_workspace(scope.workspace_id),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, _} <- Records.fetch_visible(:store, scope, c, record_id),
         {:ok, filename} <- filename(attrs["filename"]),
         {:ok, bytes} <- decode(attrs["content_base64"]),
         {:ok, metadata} <- metadata(attrs["metadata"]),
         :ok <- below_file_limit(c, record_id),
         {:ok, tmp} <- write_tmp(bytes, filename) do
      try do
        content_type = attrs["content_type"] || "application/octet-stream"

        with {:ok, %{asset: asset}} <-
               AssetStore.store_file(tmp,
                 tenant_id: scope.tenant_id,
                 workspace_id: scope.workspace_id,
                 actor_id: scope.actor,
                 content_type: content_type,
                 source_type: "app_data_file",
                 source_system: "app_data",
                 source_uri: "optimal://#{scope.workspace_id}/data/#{name}/#{record_id}/files",
                 metadata: %{"filename" => filename, "collection" => name, "record_id" => record_id}
               ) do
          file = %{
            "id" => "file_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower),
            "record_id" => record_id,
            "asset_id" => asset.id,
            "filename" => filename,
            "content_type" => content_type,
            "size_bytes" => byte_size(bytes),
            "content_hash" =>
              "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
            "metadata" => metadata,
            "created_by" => scope.actor,
            "created_at" => Schema.now()
          }

          link(scope, c, file)
        end
      after
        File.rm(tmp)
      end
    end
  end

  # The record may have been deleted while the bytes were stored; link only
  # if it still exists, in one transaction.
  defp link(scope, c, file) do
    Store.transaction(fn txn ->
      with {:ok, _} <- Records.fetch_visible(txn, scope, c, file["record_id"]),
           {:ok, 1} <-
             SQL.exec(
               txn,
               "INSERT INTO data_files (id, tenant_id, workspace_id, collection_id, record_id, asset_id, filename, content_type, size_bytes, content_hash, metadata, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 file["id"],
                 scope.tenant_id,
                 scope.workspace_id,
                 c.id,
                 file["record_id"],
                 file["asset_id"],
                 file["filename"],
                 file["content_type"],
                 file["size_bytes"],
                 file["content_hash"],
                 Jason.encode!(file["metadata"]),
                 file["created_by"],
                 file["created_at"]
               ]
             ) do
        {:ok, Map.delete(file, "asset_id")}
      end
    end)
  end

  @doc "Files attached to a record."
  @spec list(Scope.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, name, record_id) do
    with :ok <- Scope.allow(scope, name, "read"),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, _} <- Records.fetch_visible(:store, scope, c, record_id),
         {:ok, rows} <-
           SQL.query(
             :store,
             "SELECT #{columns()} FROM data_files WHERE collection_id = ? AND record_id = ? ORDER BY created_at, id",
             [c.id, record_id]
           ) do
      {:ok, Enum.map(rows, &(to_file(&1) |> Map.delete("asset_id")))}
    end
  end

  @doc """
  Resolves a file for download: `{:ok, %{path:, size:, content_type:, filename:}}`.
  """
  @spec open(Scope.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(%Scope{} = scope, name, record_id, file_id) do
    with :ok <- Scope.allow(scope, name, "read"),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, _} <- Records.fetch_visible(:store, scope, c, record_id),
         {:ok, file} <- fetch(c, record_id, file_id),
         {:ok, asset} <-
           AssetStore.get(file["asset_id"],
             tenant_id: scope.tenant_id,
             workspace_id: scope.workspace_id
           ),
         path when is_binary(path) <- asset.storage_path,
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      {:ok,
       %{path: path, size: size, content_type: file["content_type"], filename: file["filename"]}}
    else
      {:error, :not_found} -> {:error, {:not_found, "file_not_found"}}
      {:error, :enoent} -> {:error, {:not_found, "file_bytes_missing"}}
      {:error, _} = error -> error
      _ -> {:error, {:not_found, "file_not_found"}}
    end
  end

  @doc "Detaches a file from a record."
  @spec delete(Scope.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, name, record_id, file_id) do
    with :ok <- Scope.allow(scope, name, "update"),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, _} <- Records.fetch_visible(:store, scope, c, record_id),
         {:ok, _file} <- fetch(c, record_id, file_id),
         :ok <-
           Store.raw_execute("DELETE FROM data_files WHERE id = ? AND collection_id = ?", [
             file_id,
             c.id
           ]) do
      :ok
    end
  end

  defp fetch(c, record_id, file_id) do
    case SQL.query(
           :store,
           "SELECT #{columns()} FROM data_files WHERE id = ? AND collection_id = ? AND record_id = ?",
           [file_id, c.id, record_id]
         ) do
      {:ok, [row]} -> {:ok, to_file(row)}
      {:ok, []} -> {:error, {:not_found, "file_not_found"}}
      error -> error
    end
  end

  defp below_file_limit(c, record_id) do
    case SQL.scalar(
           :store,
           "SELECT COUNT(*) FROM data_files WHERE collection_id = ? AND record_id = ?",
           [c.id, record_id]
         ) do
      {:ok, n} when n < @max_files_per_record ->
        :ok

      {:ok, _} ->
        {:error, {:validation, ["a record may hold at most #{@max_files_per_record} files"]}}

      error ->
        error
    end
  end

  # The asset store places bytes under a directory named for the workspace;
  # an id that could leave the store root is refused.
  defp storable_workspace(workspace_id) do
    if String.contains?(workspace_id, ["/", "\\", "..", "\0"]),
      do: {:error, {:validation, ["files need a workspace id without path separators"]}},
      else: :ok
  end

  defp filename(name) when is_binary(name) do
    base = Path.basename(name)

    if base != "" and String.length(base) <= 255 and String.valid?(base) and
         not String.contains?(base, ["\0", "\n", "\r"]),
       do: {:ok, base},
       else: {:error, {:validation, ["filename must be a plain file name"]}}
  end

  defp filename(_name), do: {:error, {:validation, ["filename is required"]}}

  defp decode(content) when is_binary(content) do
    case Base.decode64(content, ignore: :whitespace) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, {:validation, ["file larger than #{@max_bytes} bytes"]}}
      :error -> {:error, {:validation, ["content_base64 is not valid base64"]}}
    end
  end

  defp decode(_content), do: {:error, {:validation, ["content_base64 is required"]}}

  defp metadata(nil), do: {:ok, %{}}
  defp metadata(%{} = map) when not is_struct(map), do: {:ok, map}
  defp metadata(_value), do: {:error, {:validation, ["metadata must be an object"]}}

  defp write_tmp(bytes, filename) do
    ext = filename |> Path.extname() |> String.replace(~r/[^A-Za-z0-9.]/, "")

    path =
      Path.join(System.tmp_dir!(), "optimal-app-data-#{System.unique_integer([:positive])}#{ext}")

    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:storage, "temporary write failed: #{inspect(reason)}"}}
    end
  end

  defp columns,
    do:
      "id, record_id, asset_id, filename, content_type, size_bytes, content_hash, metadata, created_by, created_at"

  defp to_file([
         id,
         record_id,
         asset_id,
         filename,
         content_type,
         size,
         hash,
         metadata,
         created_by,
         created_at
       ]) do
    %{
      "id" => id,
      "record_id" => record_id,
      "asset_id" => asset_id,
      "filename" => filename,
      "content_type" => content_type,
      "size_bytes" => size,
      "content_hash" => hash,
      "metadata" => Jason.decode!(metadata),
      "created_by" => created_by,
      "created_at" => created_at
    }
  end
end
