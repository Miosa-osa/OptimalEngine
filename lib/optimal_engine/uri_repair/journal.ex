defmodule OptimalEngine.UriRepair.Journal do
  @moduledoc """
  The record of one run of `OptimalEngine.UriRepair`: an append-only JSON Lines
  file, and the backups of every file the run replaced.

      <root>/.system/uri-repair/<run id>/journal.jsonl
      <root>/.system/uri-repair/<run id>/backups/<sha256 of the old text>-<file name>

  Every entry carries the run id and a UTC time. Entries that touch a context
  name its id, workspace, old and new URI and path, and the SHA-256 of the old
  and the new text; an entry for a replaced file names its backup. An entry is
  flushed to disk before the step that follows it, so after a crash the journal
  says how far the run got. The folder is under `.system`, which the indexer
  skips.
  """

  alias OptimalEngine.AtomicFile

  @enforce_keys [:run_id, :dir, :path]
  defstruct [:run_id, :dir, :path]

  @type t :: %__MODULE__{run_id: String.t(), dir: Path.t(), path: Path.t()}

  @doc "Opens the journal of a new run under the Engine root."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    root = Keyword.get(opts, :root) || Application.get_env(:optimal_engine, :root_path, "")
    run_id = Keyword.get(opts, :run_id) || new_run_id()
    dir = Path.join([root, ".system", "uri-repair", run_id])
    path = Path.join(dir, "journal.jsonl")

    with :ok <- File.mkdir_p(Path.join(dir, "backups")),
         :ok <- touch(path) do
      {:ok, %__MODULE__{run_id: run_id, dir: dir, path: path}}
    end
  end

  @doc "Appends one entry and flushes it to disk."
  @spec append(t(), map()) :: :ok | {:error, term()}
  def append(%__MODULE__{} = journal, entry) when is_map(entry) do
    line =
      entry
      |> Map.put(:run_id, journal.run_id)
      |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    File.open(journal.path, [:append, :binary], fn io ->
      with :ok <- IO.binwrite(io, line <> "\n"), do: :file.sync(io)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Copies the file at `path` into the run's backups before it is replaced.
  Answers the backup path and the SHA-256 of the text it holds.
  """
  @spec backup(t(), Path.t()) :: {:ok, %{path: Path.t(), sha256: String.t()}} | {:error, term()}
  def backup(%__MODULE__{} = journal, path) do
    with {:ok, bytes} <- File.read(path) do
      sha = AtomicFile.sha256(bytes)
      target = Path.join([journal.dir, "backups", "#{sha}-#{Path.basename(path)}"])

      # The same text is the same backup; a second run copy is not an error.
      case AtomicFile.create(target, bytes) do
        result when result in [:ok, {:error, :eexist}] -> {:ok, %{path: target, sha256: sha}}
        {:error, _} = error -> error
      end
    end
  end

  defp touch(path) do
    case File.open(path, [:append, :binary]) do
      {:ok, io} -> File.close(io)
      {:error, _} = error -> error
    end
  end

  defp new_run_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    stamp <> "-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end
end
