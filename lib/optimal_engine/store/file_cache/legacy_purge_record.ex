defmodule OptimalEngine.Store.FileCache.LegacyPurgeRecord do
  @moduledoc """
  The record that this Engine removed the unpartitioned embedding cache of
  earlier versions (`OptimalEngine.Store.FileCache.purge_legacy/0`).

  It is one small JSON file next to the database, written at the first boot of
  the release that partitions the cache (an Engine with an empty cache records
  zero files and zero bytes) and read by `GET /api/storage`
  (`embed_cache_legacy_purge`) and by the metrics. It belongs to this Engine and
  this release: it is not a table, so it is not replicated, not in a workspace
  bundle, and not in a backup of the database.

      %{ran_at: "2026-10-21T14:03:09Z", files: 1204, bytes: 9_877_216, engine_version: "0.3.5"}

  The location is `embed_cache_legacy_purge.json` in the database's directory;
  `config :optimal_engine, :embed_cache_legacy_purge_record, path` overrides it.
  """

  @file_name "embed_cache_legacy_purge.json"

  @type t :: %{
          ran_at: String.t(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          engine_version: String.t()
        }

  @files_gauge "optimal_engine_embed_cache_legacy_purge_files"
  @bytes_gauge "optimal_engine_embed_cache_legacy_purge_bytes"
  @help %{
    @files_gauge => "Files removed by the one-time purge of the unpartitioned embedding cache",
    @bytes_gauge => "Bytes removed by the one-time purge of the unpartitioned embedding cache"
  }

  @doc "Where the record is kept."
  @spec path() :: String.t()
  def path do
    case Application.get_env(:optimal_engine, :embed_cache_legacy_purge_record) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        :optimal_engine
        |> Application.get_env(:db_path, ".optimal/index.db")
        |> Path.expand()
        |> Path.dirname()
        |> Path.join(@file_name)
    end
  end

  @doc "The record, or `nil` when the purge has not run or the file is not a record."
  @spec read() :: t() | nil
  def read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"ran_at" => ran_at, "files" => files, "bytes" => bytes} = decoded} <-
           Jason.decode(body),
         true <- is_binary(ran_at) and is_integer(files) and files >= 0,
         true <- is_integer(bytes) and bytes >= 0,
         version when is_binary(version) <- Map.get(decoded, "engine_version") do
      %{ran_at: ran_at, files: files, bytes: bytes, engine_version: version}
    else
      _ -> nil
    end
  end

  @doc """
  Records that the purge ran now, in this version, and removed `files` files and
  `bytes` bytes. Written atomically (temporary file, then rename).
  """
  @spec write(non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def write(files, bytes)
      when is_integer(files) and files >= 0 and is_integer(bytes) and bytes >= 0 do
    record = %{
      ran_at: DateTime.utc_now() |> to_second() |> DateTime.to_iso8601(),
      files: files,
      bytes: bytes,
      engine_version: OptimalEngine.Version.application_version()
    }

    path = path()
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(record)),
         :ok <- File.rename(tmp, path) do
      {:ok, record}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc """
  The metrics the record sets, by Prometheus name; empty when nothing is
  recorded.
  """
  @spec gauges() :: %{String.t() => non_neg_integer()}
  def gauges do
    case read() do
      nil -> %{}
      %{files: files, bytes: bytes} -> %{@files_gauge => files, @bytes_gauge => bytes}
    end
  end

  @doc "What a gauge from `gauges/0` measures."
  @spec help(String.t()) :: String.t()
  def help(name), do: Map.fetch!(@help, name)

  defp to_second(%DateTime{} = now), do: %{now | microsecond: {0, 0}}
end
