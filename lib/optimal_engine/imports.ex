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
  URL) and `report.json`, the import's counts and error report, rewritten as
  it progresses. The source is deleted once the job completes or fails for
  good; the report is kept.

  A source URL may be a presigned URL whose query string is a credential. It
  is written only to `source.url` (owner-only permissions) and deleted as soon
  as the download completes. The job row, the report, the status, errors and
  logs carry only `OptimalEngine.Imports.Fetch.redact/1`, `scheme://host/path`.

  The staging folder is owner-only (0700) and every file in it (the source
  zip, the URL, unpacked part zips and CSVs) is 0600. At most
  `max_outstanding/0` imports per workspace are queued or running at once.
  `sweep/1` (run when `OptimalEngine.Imports.Worker` starts) removes the
  sources of imports that ended long ago, however they ended, and folders no
  job refers to.

  An idempotency key names one import per workspace for good: a request that
  repeats it gets the first job back, whatever state it is in, and its body is
  not read. A new import needs a new key.

  Imports are workspace-scoped: a job writes only into its own workspace.
  """

  require Logger

  alias OptimalEngine.Imports.{Fetch, Notion}
  alias OptimalEngine.Jobs

  @notion "import.notion"
  @max_attempts 3
  @lease_seconds 600
  @default_max_bytes 1024 * 1024 * 1024
  @default_max_outstanding 2
  @sweep_age_seconds 86_400
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

  @doc """
  How many imports a workspace may have queued or running at once
  (`config :optimal_engine, :import_max_outstanding`, default 2).
  """
  @spec max_outstanding() :: pos_integer()
  def max_outstanding do
    case Application.get_env(:optimal_engine, :import_max_outstanding) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_outstanding
    end
  end

  @doc """
  The import a workspace already started with `idempotency_key`, if any, so
  a repeated request is answered before its body is read.
  """
  @spec existing(String.t(), String.t() | nil) :: {:ok, Jobs.job()} | :none
  def existing(_workspace_id, key) when key in [nil, ""], do: :none

  def existing(workspace_id, key) do
    case Jobs.find_by_idempotency_key(workspace_id, @notion <> ":" <> key) do
      {:ok, %{kind: @notion} = job} -> {:ok, job}
      _ -> :none
    end
  end

  @doc """
  `:ok` when the workspace may start another import, or
  `{:error, :too_many_imports}` when `max_outstanding/0` are already queued or
  running.
  """
  @spec admit(String.t()) :: :ok | {:error, :too_many_imports}
  def admit(workspace_id) do
    case Jobs.count_active(workspace_id, @notion) do
      {:ok, n} -> if n >= max_outstanding(), do: {:error, :too_many_imports}, else: :ok
      {:error, _} -> :ok
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
    File.chmod!(folder, 0o700)
    %{id: id, dir: folder, source: Path.join(folder, "source.zip")}
  end

  @doc """
  Removes what old imports leave behind: the sources of imports that are not
  queued or running and are older than `max_age_seconds` (default one day),
  however they ended, including jobs dead-lettered when a lease ran out, and
  staging folders no job refers to. Reports are kept. Returns how many folders
  were cleaned.
  """
  @spec sweep(non_neg_integer()) :: non_neg_integer()
  def sweep(max_age_seconds \\ @sweep_age_seconds) do
    with {:ok, jobs} <- Jobs.list_kind(@notion),
         {:ok, names} <- File.ls(dir()) do
      active =
        for %{status: status, payload: %{"import_id" => id}} <- jobs,
            status in ["available", "running"],
            into: MapSet.new(),
            do: id

      known = MapSet.new(jobs, & &1.payload["import_id"])
      cutoff = System.os_time(:second) - max_age_seconds

      Enum.count(names, fn name ->
        folder = Path.join(dir(), name)

        cond do
          not Regex.match?(@import_id, name) or MapSet.member?(active, name) -> false
          not older_than?(folder, cutoff) -> false
          MapSet.member?(known, name) -> leftovers?(folder) and clean_source(name) == :ok
          true -> match?({:ok, _}, File.rm_rf(folder))
        end
      end)
    else
      _ -> 0
    end
  end

  defp leftovers?(folder) do
    case File.ls(folder) do
      {:ok, names} -> Enum.any?(names, &(&1 != "report.json"))
      _ -> false
    end
  end

  defp older_than?(folder, cutoff) do
    case File.stat(folder, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
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
  Returns `{:ok, job, :queued | :duplicate}` or `{:error, reason}`, with
  `{:error, :too_many_imports}` when the workspace already has
  `max_outstanding/0` imports queued or running. The count and the insert run
  under one lock per workspace, so two requests at once cannot both take the
  last place.
  """
  @spec enqueue_notion(String.t(), staged(), map(), keyword()) ::
          {:ok, Jobs.job(), :queued | :duplicate} | {:error, term()}
  def enqueue_notion(workspace_id, staged, source, opts \\ []) do
    {url, source} = Map.pop(source, "url")

    source =
      if url do
        path = Path.join(staged.dir, "source.url")
        File.write!(path, url)
        File.chmod!(path, 0o600)
        Map.put(source, "url", Fetch.redact(url))
      else
        source
      end

    payload = %{"import_id" => staged.id, "source" => source, "actor_id" => opts[:actor_id]}

    key =
      case opts[:idempotency_key] do
        key when is_binary(key) and key != "" -> @notion <> ":" <> key
        _ -> nil
      end

    result =
      :global.trans(
        {{__MODULE__, workspace_id}, self()},
        fn ->
          with :none <- existing(workspace_id, opts[:idempotency_key]),
               :ok <- admit(workspace_id) do
            Jobs.enqueue(workspace_id, @notion, payload,
              max_attempts: @max_attempts,
              idempotency_key: key
            )
          end
        end,
        [node()]
      )

    case result do
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

    # A long download or import keeps its lease, so another worker never
    # starts it a second time while this one is alive.
    heartbeat = fn -> _ = Jobs.extend_lease(job.id, owner, @lease_seconds) end

    progress = fn report ->
      write_report(id, Map.put(report, "started_at", started))
      heartbeat.()
      :ok
    end

    # A crash is reported by its kind only: an exception message or an exit
    # term can carry the request, and with it a presigned URL.
    result =
      try do
        with {:ok, folder} <- folder(id),
             {:ok, source} <- source_file(job, folder, heartbeat) do
          Notion.import_file(source, job.workspace_id,
            tenant_id: job.tenant_id,
            actor_id: job.payload["actor_id"] || "system:notion-import",
            work_dir: folder,
            limits: Application.get_env(:optimal_engine, :import_limits, %{}),
            progress: progress,
            heartbeat: heartbeat
          )
        end
      rescue
        error -> {:error, {:crashed, inspect(error.__struct__)}}
      catch
        kind, _reason -> {:error, {:crashed, Atom.to_string(kind)}}
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
      reason in [
        :invalid_source_url,
        :source_url_refused,
        :redirect_refused,
        :too_many_redirects,
        :download_too_large,
        :source_missing
      ]
  end

  # Every detail is scrubbed of URL query strings before it is logged or
  # stored, whatever produced it.
  defp failure({code, detail}) when is_atom(code), do: {Atom.to_string(code), detail_text(detail)}
  defp failure(code) when is_atom(code), do: {Atom.to_string(code), nil}
  defp failure(other), do: {"failed", detail_text(other)}

  defp detail_text(detail) when is_binary(detail), do: Fetch.scrub(detail)
  defp detail_text(detail), do: detail |> inspect() |> Fetch.scrub()

  # A URL source is downloaded once: the URL file is deleted when the zip is
  # complete, and a later attempt (the import itself failed) reuses the zip.
  defp source_file(%{payload: %{"source" => %{"kind" => "url"}}}, folder, heartbeat) do
    path = Path.join(folder, "source.zip")
    url_file = Path.join(folder, "source.url")

    case File.read(url_file) do
      {:ok, url} ->
        opts = [progress: fn _bytes -> heartbeat.() end]

        with {:ok, _bytes} <- Fetch.download(String.trim(url), path, max_bytes(), opts) do
          File.rm(url_file)
          {:ok, path}
        end

      {:error, _} ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :source_missing}
    end
  end

  defp source_file(_job, folder, _heartbeat) do
    path = Path.join(folder, "source.zip")
    if File.regular?(path), do: {:ok, path}, else: {:error, :source_missing}
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
      File.chmod!(tmp, 0o600)
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
