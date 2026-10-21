defmodule OptimalEngine.AtomicFile do
  @moduledoc """
  Writes a file so that a reader, or a restart after a crash, finds either the
  whole old text or the whole new text, never a torn one.

  The text goes to a hidden temporary file in the same folder, is flushed to
  disk, and is renamed over the target; the folder is then flushed too, so the
  rename itself survives a power loss. The indexer skips hidden files, so a
  temporary file left by a crash is never indexed.

    * `write/2` replaces the target (an update in place).
    * `create/2` refuses to replace anything: it answers `{:error, :eexist}`
      when the target exists, even if another process created it a moment ago.
  """

  @doc "Writes `content` to `path`, replacing what is there."
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, content) do
    with {:ok, tmp} <- stage(path, content) do
      case File.rename(tmp, path) do
        :ok -> sync_dir(Path.dirname(path))
        {:error, reason} -> discard(tmp, reason)
      end
    end
  end

  @doc "Writes `content` to `path` unless a file is already there (`{:error, :eexist}`)."
  @spec create(Path.t(), iodata()) :: :ok | {:error, term()}
  def create(path, content) do
    with {:ok, tmp} <- stage(path, content) do
      result =
        case File.ln(tmp, path) do
          :ok -> :ok
          {:error, :eexist} -> {:error, :eexist}
          # A folder that cannot hold hard links: check, then rename.
          {:error, _no_links} -> rename_unless_present(tmp, path)
        end

      _ = File.rm(tmp)

      case result do
        :ok -> sync_dir(Path.dirname(path))
        {:error, _} = error -> error
      end
    end
  end

  @doc "The SHA-256 of `content`, as lowercase hex."
  @spec sha256(iodata()) :: String.t()
  def sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # -- private ---------------------------------------------------------------

  defp stage(path, content) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- write_synced(tmp, content) do
      {:ok, tmp}
    else
      {:error, reason} -> discard(tmp, reason)
    end
  end

  defp write_synced(tmp, content) do
    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :exclusive]) do
      result =
        with :ok <- :file.write(fd, content),
             do: :file.sync(fd)

      closed = :file.close(fd)

      case {result, closed} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _} -> {:error, reason}
        {_, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp rename_unless_present(tmp, path) do
    if File.exists?(path), do: {:error, :eexist}, else: File.rename(tmp, path)
  end

  defp discard(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end

  # Flushes the folder so the rename is durable. Best effort: a platform that
  # cannot open a folder keeps the rename atomic, only not yet flushed.
  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:read, :directory]) do
      {:ok, fd} ->
        _ = :file.sync(fd)
        _ = :file.close(fd)
        :ok

      {:error, _} ->
        :ok
    end
  end
end
