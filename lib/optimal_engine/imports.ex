defmodule OptimalEngine.Imports do
  @moduledoc """
  Import jobs.

  A Notion export arrives as an upload or as a URL, is staged under the
  Engine's imports folder (`<data dir>/imports/<import id>/`, or
  `config :optimal_engine, :imports_dir`), and runs as a durable
  `import.notion` job (`OptimalEngine.Jobs`): it survives a restart, a failed
  attempt is retried with backoff, and an archive that is refused fails at
  once. `OptimalEngine.Imports.Worker` drains the queue; the import itself is
  `OptimalEngine.Imports.Notion`.

  The staged folder holds the source (`source.zip`, or `source.url` for a
  URL, which never enters the job row, so a presigned URL is not readable
  through the job list) and `report.json`, the import's counts and error
  report, rewritten as it progresses. The source is deleted once the job
  completes or fails for good; the report is kept.

  Imports are workspace-scoped: a job writes only into its own workspace.
  """

  require Logger

  alias OptimalEngine.Imports.{Fetch, Notion}
  alias OptimalEngine.Jobs

  @notion "import.notion"
  @max_attempts 3
  @lease_seconds 600
  @default_max_bytes 1024 * 1024 * 1024
  @import_id ~r/\Aimp_[0-9a-f]{24}\z/

  @type staged :: %{id: String.t(), dir: Path.t(), source: Path.t()}

  @doc "The job kind of a Notion import."
  @spec notion_kind() :: String.t()
  def notion_kind, do: @notion

  @doc """
  The largest upload or download accepted, in bytes
  (`config :optimal_engine, :import_max_bytes`, env `OPTIMAL_IMPORT_MAX_BYTES`,
  default 1 GiB).
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes do
    case Application.get_env(:optimal_engine, :import_max_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_bytes
    end
  end

  @doc "The folder imports are staged in."
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:optimal_engine, :imports_dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _ ->
        Application.get_env(:optimal_engine, :db_path, ".optimal/index.db")
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("imports")
    end
  end

  @doc "Creates a staging folder for a new import."
  @spec stage() :: staged()
  def stage do
    id = "imp_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    folder = Path.join(dir(), id)
    File.mkdir_p!(folder)
    %{id: id, dir: folder, source: Path.join(folder, "source.zip")}
  end

  @doc "Removes a staging folder that will not become a job."
  @spec discard(staged()) :: :ok
  def discard(%{dir: folder}) do
    _ = File.rm_rf(folder)
    :ok
  end

  @doc """
  Enqueues a Notion import of a staged upload (`%{"kind" => "upload",
  "bytes" => n}`) or of a URL (`%{"kind" => "url", "url" => url}`).

  Options: `:actor_id`, and `:idempotency_key`: a repeated key returns the
  first job, `:duplicate`, and the new staging folder is discarded.
  Returns `{:ok, job, :queued | :duplicate}` or `{:error, reason}`.
  """
  @spec enqueue_notion(String.t(), staged(), map(), keyword()) ::
          {:ok, Jobs.job(), :queued | :duplicate} | {:error, term()}
  def enqueue_notion(workspace_id, staged, source, opts \\ []) do
    {url, source} = Map.pop(source, "url")
    source = if url, do: Map.put(source, "host", URI.parse(url).host), else: source
    if url, do: File.write!(Path.join(staged.dir, "source.url"), url)

    payload = %{"import_id" => staged.id, "source" => source, "actor_id" => opts[:actor_id]}

    key =
      case opts[:idempotency_key] do
        key when is_binary(key) and key != "" -> @notion <> ":" <> key
        _ -> nil
      end

    case Jobs.enqueue(workspace_id, @notion, payload,
           max_attempts: @max_attempts,
           idempotency_key: key
         ) do
      {:ok, %{payload: %{"import_id" => id}} = job} when id == staged.id ->
        {:ok, job, :queued}

      {:ok, job} ->
        discard(staged)
        {:ok, job, :duplicate}

      {:error, reason} ->
        discard(staged)
        {:error, reason}
    end
  end

  @doc """
  The status of a Notion import job in a workspace: the job's state plus the
  import's counts, progress and error report. `{:error, :not_found}` for an
  unknown id, a job of another workspace or another kind.
  """
  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def status(job_id, workspace_id) do
    case Jobs.get(job_id, workspace_id) do
      {:ok, %{kind: @notion} = job} -> {:ok, view(job, read_report(job.payload["import_id"]))}
      {:ok, _other_kind} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Claims and runs at most one queued Notion import. Options: `:workspace_id`,
  `:lease_owner`. Returns `{:ok, :idle}`, `{:ok, job}` (the job after the
  run), or `{:error, reason}`.
  """
  @spec drain(keyword()) :: {:ok, :idle | Jobs.job()} | {:error, term()}
  def drain(opts \\ []) do
    owner = Keyword.get_lazy(opts, :lease_owner, &default_owner/0)

    claim_opts =
      opts
      |> Keyword.take([:workspace_id])
      |> Keyword.merge(kinds: [@notion], lease_owner: owner, lease_seconds: @lease_seconds)

    case Jobs.claim(claim_opts) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, job} -> run(job, owner)
      {:error, reason} -> {:error, reason}
    end
  end

  # ── running one job ────────────────────────────────────────────────────

  defp run(job, owner) do
    id = job.payload["import_id"]
    started = now()
    previous = read_report(id)
    write_report(id, %{"started_at" => started})

    progress = fn report ->
      write_report(id, Map.put(report, "started_at", started))
      _ = Jobs.extend_lease(job.id, owner, @lease_seconds)
      :ok
    end

    result =
      try do
        with {:ok, folder} <- folder(id),
             {:ok, source} <- source_file(job, folder) do
          Notion.import_file(source, job.workspace_id,
            tenant_id: job.tenant_id,
            actor_id: job.payload["actor_id"] || "system:notion-import",
            work_dir: folder,
            limits: Application.get_env(:optimal_engine, :import_limits, %{}),
            progress: progress
          )
        end
      rescue
        error -> {:error, {:crashed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:crashed, "#{kind}: #{inspect(reason)}"}}
      end

    finish(job, owner, id, started, previous, result)
  end

  defp finish(job, owner, id, started, _previous, {:ok, report}) do
    write_report(id, Map.merge(report, %{"started_at" => started, "finished_at" => now()}))
    clean_source(id)

    case Jobs.complete(job.id, owner) do
      {:ok, done} -> {:ok, done}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(job, owner, id, started, previous, {:error, reason}) do
    {code, detail} = failure(reason)
    permanent = permanent?(reason)
    Logger.warning("[Imports] #{job.id} failed: #{code} #{detail}")

    # The counts so far: this attempt's progress, else the previous attempt's.
    report =
      previous
      |> Map.merge(read_report(id))
      |> Map.merge(%{
        "started_at" => started,
        "finished_at" => now(),
        "failure" => %{"code" => code, "detail" => detail}
      })

    write_report(id, report)
    message = if detail in [nil, ""], do: code, else: "#{code}: #{detail}"

    case Jobs.fail(job.id, owner, message, permanent: permanent) do
      {:ok, %{job: failed, outcome: outcome}} ->
        if outcome == :dead, do: clean_source(id)
        {:ok, failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A refused archive or URL will be refused again; anything else (a crash,
  # a download that broke off, a busy store) may succeed on another attempt.
  defp permanent?(reason) do
    Notion.fatal?(reason) or
      reason in [:invalid_source_url, :source_url_refused, :download_too_large, :source_missing]
  end

  defp failure({code, detail}) when is_atom(code), do: {Atom.to_string(code), detail_text(detail)}
  defp failure(code) when is_atom(code), do: {Atom.to_string(code), nil}
  defp failure(other), do: {"failed", inspect(other)}

  defp detail_text(detail) when is_binary(detail), do: detail
  defp detail_text(detail), do: inspect(detail)

  defp source_file(%{payload: %{"source" => %{"kind" => "url"}}}, folder) do
    path = Path.join(folder, "source.zip")

    with {:ok, url} <- read_source_url(folder),
         {:ok, _bytes} <- Fetch.download(url, path, max_bytes()) do
      {:ok, path}
    end
  end

  defp source_file(_job, folder) do
    path = Path.join(folder, "source.zip")
    if File.regular?(path), do: {:ok, path}, else: {:error, :source_missing}
  end

  defp read_source_url(folder) do
    case File.read(Path.join(folder, "source.url")) do
      {:ok, url} -> {:ok, String.trim(url)}
      {:error, _} -> {:error, :source_missing}
    end
  end

  defp clean_source(id) do
    with {:ok, folder} <- folder(id) do
      folder
      |> File.ls!()
      |> Enum.reject(&(&1 == "report.json"))
      |> Enum.each(&File.rm(Path.join(folder, &1)))
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── the report ─────────────────────────────────────────────────────────

  defp folder(id) when is_binary(id) do
    if Regex.match?(@import_id, id),
      do: {:ok, Path.join(dir(), id)},
      else: {:error, :source_missing}
  end

  defp folder(_id), do: {:error, :source_missing}

  defp write_report(id, report) do
    with {:ok, folder} <- folder(id) do
      File.mkdir_p!(folder)
      path = Path.join(folder, "report.json")
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(report))
      File.rename!(tmp, path)
    end

    :ok
  end

  defp read_report(id) do
    with {:ok, folder} <- folder(id),
         {:ok, data} <- File.read(Path.join(folder, "report.json")),
         {:ok, %{} = report} <- Jason.decode(data) do
      report
    else
      _ -> %{}
    end
  end

  @zero_counts Map.new(
                 ~w(entries parts pages databases rows assets skipped contexts unchanged
                    edges_child_of edges_links_to links_unresolved errors),
                 &{&1, 0}
               )

  defp view(job, report) do
    %{
      job_id: job.id,
      kind: job.kind,
      workspace_id: job.workspace_id,
      status: status_of(job),
      attempts: job.attempts,
      max_attempts: job.max_attempts,
      created_at: job.inserted_at,
      updated_at: job.updated_at,
      completed_at: job.completed_at,
      started_at: report["started_at"],
      finished_at: report["finished_at"],
      last_error: job.last_error,
      failure: report["failure"],
      source: job.payload["source"] || %{},
      counts: Map.merge(@zero_counts, report["counts"] || %{}),
      progress: report["progress"] || %{"done" => 0, "total" => 0},
      errors: report["errors"] || [],
      errors_truncated: report["errors_truncated"] == true,
      root_uris: report["root_uris"] || []
    }
  end

  defp status_of(%{status: "available", attempts: 0}), do: "queued"
  defp status_of(%{status: "available"}), do: "retrying"
  defp status_of(%{status: "running"}), do: "running"
  defp status_of(%{status: "completed"}), do: "completed"
  defp status_of(%{status: "dead"}), do: "failed"
  defp status_of(%{status: other}), do: other

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp default_owner, do: "imports:#{node()}:#{inspect(self())}"
end
