defmodule OptimalEngine.Portability.BundleJobs do
  @moduledoc """
  Workspace bundle export and import as durable jobs, so no caller holds a
  request open for the minutes a large workspace takes
  (`docs/guides/scope-and-portability.md`, "Bundle jobs").

  A job is a row of the `jobs` queue (`OptimalEngine.Jobs`), of kind
  `bundle.export` or `bundle.import`, with a folder of its own under
  `<backup dir>/bundle-jobs/<job id>/`. The folder holds `report.json` (phase,
  progress, error, result), the source URL of an import while it is needed,
  its download, and the `cancel` mark. `OptimalEngine.Portability.BundleWorker`
  runs one job at a time.

  The rules, from the contract the control plane builds against:

    * one queued or running bundle job per workspace, export and import
      together (`{:error, :bundle_job_active, job}` for a second);
    * an `Idempotency-Key` names one job of a kind in a workspace for good:
      the same request again gets that job back, another request under the
      key gets `{:error, :idempotency_key_reused, job}`;
    * an import names its target `workspace_id` and exactly one source: a
      `bundle` file in the caller's bundle folder, or a `source_url` on a host
      in `OPTIMAL_BUNDLE_URL_HOSTS` with the file's `sha256`;
    * a failed or cancelled job leaves no partial output: no partial export
      file, no download, and no rows in an import target that held nothing
      when the job started;
    * a job running when the Engine stops is not resumed: at the next boot its
      partial output is removed and it runs again from the start, at most
      three attempts in all, then fails with `engine_restarted`;
    * an export's bundle is kept for `OPTIMAL_BUNDLE_RETENTION_HOURS` (7 days)
      after it finishes, and job records for 30 days.
  """

  require Logger

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Imports.Fetch
  alias OptimalEngine.Jobs
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace

  @export "bundle.export"
  @import "bundle.import"
  @kinds [@export, @import]
  @max_attempts 3
  @retry_in_seconds 60
  @lease_seconds 600
  @heartbeat_ms 30_000
  @record_days 30
  @default_retention_hours 168
  @idempotency_key ~r/\A[\x21-\x7E]{1,128}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @retryable ~w(fetch_failed insufficient_storage store_busy engine_restarted)

  @type error :: {:error, atom(), String.t()} | {:error, atom(), Jobs.job()}

  @doc "The two job kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  # ── submitting ──────────────────────────────────────────────────────────

  @doc """
  Queues an export of `workspace_id`. Options: `:idempotency_key`. Returns
  `{:ok, view, :queued | :duplicate}` or an error with its code.
  """
  @spec submit_export(String.t(), String.t(), map(), keyword()) ::
          {:ok, map(), :queued | :duplicate} | error()
  def submit_export(tenant_id, workspace_id, params, opts \\ []) do
    request = %{"for_move" => params["for_move"] == true}

    with {:ok, key} <- idempotency_key(opts[:idempotency_key]),
         :ok <- own_workspace(tenant_id, workspace_id) do
      submit(tenant_id, workspace_id, @export, request, request, key, %{})
    end
  end

  @doc """
  Queues an import into `params["workspace_id"]`. Options:
  `:idempotency_key`, and `:operator` (the caller is the Engine operator, who
  alone may set `cross_tenant`). Returns `{:ok, view, :queued | :duplicate}`
  or an error with its code.
  """
  @spec submit_import(String.t(), map(), keyword()) ::
          {:ok, map(), :queued | :duplicate} | error()
  def submit_import(tenant_id, params, opts \\ []) do
    with {:ok, key} <- idempotency_key(opts[:idempotency_key]),
         {:ok, workspace_id} <- required_string(params, "workspace_id"),
         {:ok, mode} <- mode(params["mode"]),
         {:ok, cross_tenant} <- cross_tenant(params, opts[:operator] == true),
         :ok <- target_allowed(tenant_id, workspace_id, mode),
         {:ok, source, private} <- source(tenant_id, params, cross_tenant) do
      request = %{
        "mode" => mode,
        "organization_id" => params["organization_id"],
        "cross_tenant" => cross_tenant,
        "source" => source
      }

      submit(tenant_id, workspace_id, @import, request, request, key, private)
    end
  end

  defp submit(tenant_id, workspace_id, kind, request, fingerprinted, key, private) do
    fingerprint = fingerprint(kind, fingerprinted)
    stored_key = if key, do: kind <> ":" <> key

    payload = %{"request" => request, "fingerprint" => fingerprint, "key" => key}

    case Jobs.enqueue_exclusive(workspace_id, @kinds, kind, payload,
           tenant_id: tenant_id,
           idempotency_key: stored_key,
           max_attempts: @max_attempts,
           # The job's own files are written right after its row: the worker
           # waits a moment before it may claim it
           # (`config :optimal_engine, :bundle_job_start_delay_s`, 2 by default).
           run_in: Application.get_env(:optimal_engine, :bundle_job_start_delay_s, 2)
         ) do
      {:ok, job, :queued} ->
        File.mkdir_p!(job_dir(job.id))
        Enum.each(private, fn {name, value} -> write_private(job.id, name, value) end)
        write_report(job.id, %{"status" => "queued", "phase" => "queued"})
        {:ok, view(job), :queued}

      {:ok, job, :duplicate} ->
        if job.payload["fingerprint"] == fingerprint,
          do: {:ok, view(job), :duplicate},
          else: {:error, :idempotency_key_reused, job}

      {:ok, job, :active} ->
        {:error, :bundle_job_active, job}

      {:error, :workspace_not_found} ->
        {:error, :workspace_not_found, "workspace not found"}

      {:error, reason} ->
        {:error, :internal_error, inspect(reason)}
    end
  end

  # ── reading and cancelling ──────────────────────────────────────────────

  @doc "The job's status for its tenant, or `{:error, :not_found}`."
  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(tenant_id, job_id) do
    case own_job(tenant_id, job_id) do
      {:ok, job} -> {:ok, view(job)}
      error -> error
    end
  end

  @doc """
  The tenant's bundle jobs, newest first. Filters: `"workspace_id"`,
  `"status"` (as in the view), `"kind"` (`export` or `import`), `"limit"`
  (default 50, at most 500).
  """
  @spec list(String.t(), map()) :: [map()]
  def list(tenant_id, filters \\ %{}) do
    limit = filters |> Map.get("limit") |> to_int(50) |> max(1) |> min(500)

    kinds =
      case filters["kind"] do
        "export" -> [@export]
        "import" -> [@import]
        _ -> @kinds
      end

    kinds
    |> Enum.flat_map(fn kind ->
      case Jobs.list_kind(kind, limit: 10_000) do
        {:ok, jobs} -> jobs
        _ -> []
      end
    end)
    |> Enum.filter(&(&1.tenant_id == tenant_id))
    |> Enum.filter(&(filters["workspace_id"] in [nil, &1.workspace_id]))
    |> Enum.sort_by(&{&1.inserted_at, &1.id}, :desc)
    |> Enum.map(&view/1)
    |> Enum.filter(&(filters["status"] in [nil, &1.status]))
    |> Enum.take(limit)
  end

  @doc """
  Cancels a job. A queued one is cancelled at once (`{:ok, view, :cancelled}`);
  a running one is asked to stop at its next page or batch
  (`{:ok, view, :requested}`); a finished one answers
  `{:error, :job_finished, view}`, except a cancelled one, which answers as
  cancelled again.
  """
  @spec cancel(String.t(), String.t()) ::
          {:ok, map(), :cancelled | :requested}
          | {:error, :not_found}
          | {:error, :job_finished, map()}
  def cancel(tenant_id, job_id) do
    with {:ok, job} <- own_job(tenant_id, job_id) do
      current = view(job)

      cond do
        current.status == "cancelled" ->
          {:ok, current, :cancelled}

        current.status in ["succeeded", "failed"] ->
          {:error, :job_finished, current}

        job.status == "available" ->
          case Jobs.discard_queued(job.id) do
            {:ok, discarded} ->
              finish_report(job.id, %{"status" => "cancelled", "phase" => "done"})
              remove_private(job.id)
              {:ok, view(discarded), :cancelled}

            {:error, :not_queued} ->
              request_cancel(job)
          end

        true ->
          request_cancel(job)
      end
    end
  end

  defp request_cancel(job) do
    File.mkdir_p!(job_dir(job.id))
    File.write!(cancel_mark(job.id), "")
    {:ok, view(job), :requested}
  end

  # ── running ─────────────────────────────────────────────────────────────

  @doc """
  Claims the next due bundle job and runs it to its end in the calling
  process. `{:ok, :idle}` when nothing is due. The worker calls it; so do
  tests, with the worker turned off.
  """
  @spec drain(keyword()) :: {:ok, :idle | map()} | {:error, term()}
  def drain(opts \\ []) do
    owner = Keyword.get(opts, :lease_owner, "bundle:#{node()}:#{inspect(self())}")

    case Jobs.claim(kinds: @kinds, lease_owner: owner, lease_seconds: @lease_seconds) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, job} -> {:ok, run(job, owner)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Called once when the worker starts, before it claims anything: every
  bundle job still marked running was cut off when the Engine stopped. Its
  partial output is removed and it is made claimable again, recorded as
  `engine_restarted`; the claim counts the attempt and fails it once none are
  left. A job whose rows cannot all be taken back ends `failed` with
  `cleanup_incomplete` and `partial: true` instead, since running it again
  would meet what is left. It never raises: a job that cannot be cleaned up
  is released again at every boot, so a raise would crash the worker, and the
  Engine's supervisor with it, at every boot. Returns how many jobs were
  released.
  """
  @spec recover() :: non_neg_integer()
  def recover do
    case Jobs.release_running(@kinds, "engine_restarted") do
      {:ok, jobs} ->
        Enum.each(jobs, &recover_job/1)
        length(jobs)

      {:error, reason} ->
        Logger.error("[BundleJobs] could not release interrupted jobs: #{inspect(reason)}")
        0
    end
  end

  defp recover_job(job) do
    case clean_up(job, read_report(job.id)) do
      :ok ->
        update_report(job.id, %{
          "status" => "retrying",
          "error" => error_map(:engine_restarted, "the Engine stopped while the job ran")
        })

      :incomplete ->
        give_up(job)
    end
  rescue
    error ->
      Logger.error("[BundleJobs] could not recover job #{job.id}: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.error("[BundleJobs] could not recover job #{job.id}: #{kind} #{inspect(reason)}")
  end

  # What the job wrote could not all be removed, and another run would meet
  # what is left: the job ends here, and says so.
  defp give_up(job) do
    error =
      error_map(
        :cleanup_incomplete,
        "the Engine stopped while the job ran, and some of the rows it wrote could not be removed",
        true
      )

    finish_report(job.id, %{
      "status" => "failed",
      "phase" => "done",
      "error" => error,
      "partial" => true
    })

    remove_private(job.id)
    Jobs.fail(job.id, job.lease_owner, :cleanup_incomplete, permanent: true)
  end

  @doc """
  Removes export bundles past their retention, and job records and folders
  older than 30 days. Returns `{bundles, jobs}` removed.
  """
  @spec sweep() :: {non_neg_integer(), non_neg_integer()}
  def sweep do
    {:ok, exports} = Jobs.list_kind(@export, statuses: ["completed"], limit: 10_000)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_hours() * 3_600, :second)

    expired =
      for job <- exports,
          report = read_report(job.id),
          report["status"] == "succeeded",
          not Map.get(report["result"] || %{}, "expired", false),
          older?(report["finished_at"], cutoff) do
        with {:ok, path} <- WorkspaceBundle.bundle_path(job.tenant_id, report["result"]["bundle"]),
             do: File.rm(path)

        update_report(job.id, %{"result" => Map.put(report["result"], "expired", true)})
        job.id
      end

    # The cutoff is worked out here and bound in the form the column keeps
    # (`YYYY-MM-DD HH:MM:SS`, UTC), so the statement holds no date function.
    record_cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@record_days * 86_400, :second)
      |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id FROM jobs
        WHERE kind IN (SELECT value FROM json_each(?1)) AND status IN ('completed', 'dead')
          AND updated_at < ?2
        """,
        [Jason.encode!(@kinds), record_cutoff]
      )

    old = Enum.map(rows, fn [id] -> id end)
    Enum.each(old, &File.rm_rf(job_dir(&1)))

    if old != [] do
      Store.raw_query(
        "DELETE FROM jobs WHERE id IN (SELECT value FROM json_each(?1))",
        [Jason.encode!(old)]
      )
    end

    {length(expired), length(old)}
  end

  defp run(job, owner) do
    started = now()

    update_report(job.id, %{
      "status" => "running",
      "phase" => "starting",
      "started_at" => started,
      "error" => nil,
      # What an earlier attempt learned about its target is not this one's.
      "target_was_empty" => nil,
      "record_created" => nil,
      "unlogged" => nil,
      "progress" => empty_progress()
    })

    beat = %{job: job, owner: owner, at: System.monotonic_time(:millisecond)}
    Process.put({__MODULE__, :beat}, beat)

    outcome =
      try do
        case job.kind do
          @export -> run_export(job)
          @import -> run_import(job)
        end
      rescue
        error -> {:error, :internal_error, Exception.message(error)}
      end

    Process.delete({__MODULE__, :beat})
    finish(job, owner, outcome)
  end

  defp finish(job, owner, {:ok, result}) do
    finish_report(job.id, %{"status" => "succeeded", "phase" => "done", "result" => result})
    remove_private(job.id)
    File.rm(written_log(job.id))
    {:ok, _} = Jobs.complete(job.id, owner)
    fetched_view(job.id)
  end

  defp finish(job, owner, {:error, :cancelled}) do
    report = read_report(job.id)
    cleaned = clean_up(job, report)

    # A merge into a workspace that held rows is not rolled back, and rows that
    # could not be removed stay: it says so.
    finish_report(job.id, %{
      "status" => "cancelled",
      "phase" => "done",
      "partial" => partial?(job, report, cleaned)
    })

    remove_private(job.id)
    {:ok, _} = Jobs.complete(job.id, owner)
    fetched_view(job.id)
  end

  defp finish(job, owner, {:error, reason}),
    do: finish(job, owner, {:error, :internal_error, inspect(reason)})

  defp finish(job, owner, {:error, code, message}) do
    report = read_report(job.id)
    cleaned = clean_up(job, report)
    partial = partial?(job, report, cleaned)
    error = error_map(code, message, partial)

    # Rows left behind by a create would clash with another attempt.
    retry? =
      to_string(code) in @retryable and job.attempts < job.max_attempts and cleaned == :ok

    if retry? do
      update_report(job.id, %{"status" => "retrying", "phase" => "queued", "error" => error})
      Jobs.fail(job.id, owner, code, retry_in: @retry_in_seconds)
    else
      finish_report(job.id, %{
        "status" => "failed",
        "phase" => "done",
        "error" => error,
        "partial" => partial
      })

      remove_private(job.id)
      Jobs.fail(job.id, owner, code, permanent: true)
    end

    fetched_view(job.id)
  end

  defp fetched_view(job_id) do
    {:ok, job} = Jobs.fetch(job_id)
    view(job)
  end

  # ── export ──────────────────────────────────────────────────────────────

  defp run_export(job) do
    name = bundle_name(job.workspace_id)
    path = Path.join(WorkspaceBundle.bundle_dir(job.tenant_id), name)
    part = path <> ".part"
    update_report(job.id, %{"output" => part})

    case WorkspaceBundle.export(job.tenant_id, job.workspace_id, part, observe: observer(job)) do
      {:ok, manifest} ->
        :ok = File.rename(part, path)

        if job.payload["request"]["for_move"] == true,
          do:
            WorkspaceBundle.prepare_move(job.tenant_id, job.workspace_id, manifest["bundle_sha256"])

        %{size: size} = File.stat!(path)
        rows = manifest["tables"] |> Enum.map(& &1["rows"]) |> Enum.sum()
        progress(job.id, %{"bytes_done" => size, "bytes_total" => size, "rows_total" => rows})

        {:ok,
         %{
           "bundle" => name,
           "file_sha256" => file_sha256(path),
           "bundle_sha256" => manifest["bundle_sha256"],
           "size_bytes" => size,
           "tables" => length(manifest["tables"]),
           "rows" => rows,
           "files" => length(manifest["files"]),
           "ledger_sequence" => manifest["ledger_sequence"],
           "for_move" => job.payload["request"]["for_move"] == true,
           "download_path" => "/api/bundles/" <> name,
           "expires_at" =>
             DateTime.utc_now()
             |> DateTime.add(retention_hours() * 3_600, :second)
             |> DateTime.to_iso8601()
         }}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, :not_found} ->
        {:error, :workspace_not_found, "workspace not found"}

      {:error, :writes_in_progress} ->
        {:error, :store_busy, "the workspace kept receiving writes while the export started"}

      {:error, :insufficient_storage} ->
        {:error, :insufficient_storage, "the disk cannot hold this export and its working files"}

      {:error, reason} ->
        {:error, :internal_error, inspect(reason)}
    end
  end

  # The workspace, the time and 8 random bytes: a counter would let a name be
  # guessed from the one before it.
  defp bundle_name(workspace_id) do
    safe = workspace_id |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.slice(0, 80)
    random = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{safe}-#{System.os_time(:second)}-#{random}.tar.gz"
  end

  # ── import ──────────────────────────────────────────────────────────────

  defp run_import(job) do
    request = job.payload["request"]
    mode = if request["mode"] == "merge", do: :merge, else: :create

    # What the target was when the import began is the import's to say (an
    # event, once it has planned the target), not read here before a download
    # that may take long: a target that held nothing is emptied again of what
    # the import wrote if it does not finish.
    update_report(job.id, %{"mode" => request["mode"]})

    with {:ok, path, consume} <- import_source(job, request["source"]) do
      opts =
        [
          mode: mode,
          workspace_id: job.workspace_id,
          organization_id: request["organization_id"],
          cross_tenant: request["cross_tenant"] == true,
          consume: consume,
          observe: observer(job),
          written_log: written_log(job.id)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case WorkspaceBundle.import(path, job.tenant_id, opts) do
        {:ok, summary} -> {:ok, import_result(summary)}
        {:error, :cancelled} -> {:error, :cancelled}
        {:error, reason} -> import_error(note_unlogged(reason, job))
      end
    end
  end

  # A batch committed whose line the log could not take: the log is short of
  # what was written, so the cleanup that follows cannot be complete.
  defp note_unlogged({:import_failed, _table, {:written_log, _}} = reason, job) do
    update_report(job.id, %{"unlogged" => true})
    reason
  end

  defp note_unlogged(reason, _job), do: reason

  defp import_source(job, %{"kind" => "bundle", "name" => name}) do
    with {:ok, path} <- WorkspaceBundle.bundle_path(job.tenant_id, name),
         true <- File.regular?(path) || {:error, :bundle_not_found, "bundle not found"},
         %{size: size} <- File.stat!(path),
         :ok <- space_for(size) do
      {:ok, path, false}
    end
  end

  defp import_source(job, %{"kind" => "url", "sha256" => sha256}) do
    url = read_private(job.id, "source_url")
    dest = Path.join(job_dir(job.id), "source.tar.gz")
    update_report(job.id, %{"phase" => "fetching"})

    beat = fn bytes ->
      heartbeat()
      progress(job.id, %{"bytes_done" => bytes})
    end

    with url when is_binary(url) <- url || {:error, :fetch_failed, "the source URL is gone"},
         {:ok, bytes} <-
           fetch(url, dest, beat),
         :ok <- space_for(bytes),
         :ok <- digest(dest, sha256) do
      progress(job.id, %{"bytes_done" => bytes, "bytes_total" => bytes})
      {:ok, dest, true}
    end
  end

  defp fetch(url, dest, beat) do
    case Fetch.download(url, dest, max_bytes(), progress: beat, allowed_hosts: url_hosts()) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, :download_too_large} ->
        {:error, :fetch_too_large, "the bundle is larger than #{max_bytes()} bytes"}

      {:error, {:download_failed, code}} ->
        {:error, :fetch_failed, "the download failed: #{code}"}

      {:error, reason} ->
        {:error, :fetch_failed, "the download was refused: #{reason}"}
    end
  end

  defp digest(path, expected) do
    if file_sha256(path) == expected,
      do: :ok,
      else: {:error, :bundle_sha256_mismatch, "the file's SHA-256 is not the one given"}
  end

  defp import_result(summary) do
    rows = summary.rows

    %{
      "workspace_id" => summary.workspace_id,
      "mode" => to_string(summary.mode),
      "bundle_sha256" => summary.bundle_sha256,
      "source_workspace_id" => summary.source_workspace_id,
      "tables" => map_size(rows),
      "rows" => rows,
      "files" => summary.files,
      "ledger_sequence" => Map.get(summary, :ledger_sequence),
      "external_id" => summary.external_id,
      "imported_external_id" => summary.imported_external_id
    }
  end

  defp import_error(:bundle_from_another_tenant),
    do: {:error, :bundle_from_another_tenant, "the bundle was exported by another tenant"}

  defp import_error(:workspace_exists),
    do: {:error, :workspace_exists, "the target workspace already exists"}

  defp import_error(reason)
       when reason in [:table_checksum_mismatch, :file_checksum_mismatch, :invalid_bundle],
       do: {:error, :invalid_bundle, to_string(reason)}

  defp import_error({:import_failed, table, reason}),
    do: {:error, :internal_error, "writing #{table} failed: #{inspect(reason)}"}

  defp import_error({:incompatible_tables, _} = reason),
    do: {:error, :incompatible_bundle, inspect(reason)}

  defp import_error(reason), do: {:error, :invalid_bundle, inspect(reason)}

  # ── cleaning up ─────────────────────────────────────────────────────────

  # What a job leaves when it does not finish: an export's partial file, an
  # import's download, and the rows an import wrote into a target that held
  # nothing when it began (the workspace record too, when the import made it).
  # `:ok`, or `:incomplete` when some of that could not be removed. It never
  # raises (see `recover/0`).
  defp clean_up(job, report) do
    remove_leftovers(job, report)
  rescue
    error ->
      Logger.error("[BundleJobs] cleaning up job #{job.id} failed: #{Exception.message(error)}")
      :incomplete
  catch
    kind, reason ->
      Logger.error("[BundleJobs] cleaning up job #{job.id} failed: #{kind} #{inspect(reason)}")
      :incomplete
  end

  defp remove_leftovers(%{kind: @export}, report) do
    if is_binary(report["output"]), do: File.rm(report["output"])
    :ok
  end

  defp remove_leftovers(%{kind: @import} = job, report) do
    File.rm(Path.join(job_dir(job.id), "source.tar.gz"))

    # Only the rows the job wrote go (the import logged them as it wrote), so a
    # row another writer put in the target meanwhile stays, and so does the
    # workspace record if that leaves the workspace holding anything. What the
    # target was is what the import reported when it planned it.
    result =
      if report["target_was_empty"] == true do
        WorkspaceBundle.discard_written(written_log(job.id), job.tenant_id, job.workspace_id,
          record: report["record_created"] == true
        )
      else
        :ok
      end

    case result do
      :ok ->
        File.rm(written_log(job.id))
        :ok

      {:incomplete, why} ->
        # The log stays, to say what is left; the retention sweep removes it.
        Logger.error("[BundleJobs] job #{job.id} could not take back all it wrote: #{inspect(why)}")

        :incomplete
    end
  end

  defp partial?(%{kind: @import}, report, cleaned) do
    cleaned == :incomplete or report["unlogged"] == true or
      (report["target_was_empty"] == false and report["phase"] in ["writing", "files"])
  end

  defp partial?(_job, _report, _cleaned), do: false

  # ── progress, cancel, heartbeat ─────────────────────────────────────────

  defp observer(job) do
    fn event ->
      heartbeat()
      observe(job.id, event)

      if File.exists?(cancel_mark(job.id)), do: :cancel, else: :ok
    end
  end

  defp observe(job_id, {:phase, phase}), do: update_report(job_id, %{"phase" => to_string(phase)})

  defp observe(job_id, {:total, rows, files}),
    do: progress(job_id, %{"rows_total" => rows, "files_total" => files})

  defp observe(job_id, {:rows, table, n}) do
    report = read_report(job_id)
    current = report["progress"] || empty_progress()
    tables = Map.update(current["tables"] || %{}, table, n, &(&1 + n))

    progress(job_id, %{
      "rows_done" => (current["rows_done"] || 0) + n,
      "tables" => tables,
      "tables_done" => map_size(tables)
    })
  end

  defp observe(job_id, {:target, %{created: created, empty: empty}}),
    do: update_report(job_id, %{"record_created" => created, "target_was_empty" => empty})

  defp observe(_job_id, _event), do: :ok

  defp progress(job_id, changes) do
    report = read_report(job_id)

    update_report(job_id, %{
      "progress" => Map.merge(report["progress"] || empty_progress(), changes)
    })
  end

  defp empty_progress do
    %{
      "rows_done" => 0,
      "rows_total" => nil,
      "bytes_done" => 0,
      "bytes_total" => nil,
      "tables_done" => 0,
      "tables_total" => nil,
      "files_done" => 0,
      "files_total" => nil
    }
  end

  # Extends the running job's lease at most every 30 seconds.
  defp heartbeat do
    case Process.get({__MODULE__, :beat}) do
      %{job: job, owner: owner, at: at} = beat ->
        now = System.monotonic_time(:millisecond)

        if now - at >= @heartbeat_ms do
          Jobs.extend_lease(job.id, owner, @lease_seconds)
          Process.put({__MODULE__, :beat}, %{beat | at: now})
        end

      _ ->
        :ok
    end
  end

  # ── the view ────────────────────────────────────────────────────────────

  @doc false
  def view(job) do
    report = read_report(job.id)
    status = view_status(job, report)

    %{
      job_id: job.id,
      kind: job.kind,
      tenant_id: job.tenant_id,
      workspace_id: job.workspace_id,
      status: status,
      phase:
        if(status in ["succeeded", "failed", "cancelled"],
          do: "done",
          else: report["phase"] || "queued"
        ),
      progress: Map.drop(report["progress"] || empty_progress(), ["tables"]),
      attempt: job.attempts,
      max_attempts: job.max_attempts,
      idempotency_key: job.payload["key"],
      duplicate: false,
      cancel_requested: File.exists?(cancel_mark(job.id)),
      created_at: job.inserted_at,
      started_at: report["started_at"],
      updated_at: report["updated_at"] || job.updated_at,
      finished_at: report["finished_at"],
      partial: status in ["failed", "cancelled"] and report["partial"] == true,
      error: view_error(status, job, report),
      result: if(status == "succeeded", do: report["result"])
    }
  end

  defp view_status(%{status: "available", attempts: 0}, _report), do: "queued"
  defp view_status(%{status: "available"}, _report), do: "retrying"
  defp view_status(%{status: "running"}, _report), do: "running"
  defp view_status(%{status: "dead"}, _report), do: "failed"

  defp view_status(%{status: "completed"}, report),
    do: if(report["status"] == "cancelled", do: "cancelled", else: "succeeded")

  defp view_status(_job, _report), do: "queued"

  defp view_error("failed", job, report) do
    report["error"] ||
      error_map(:engine_restarted, job.last_error || "the job did not finish")
  end

  defp view_error("retrying", _job, report), do: report["error"]
  defp view_error(_status, _job, _report), do: nil

  defp error_map(code, message, partial \\ false) do
    code = to_string(code)
    base = %{"code" => code, "message" => message, "retryable" => code in @retryable}
    if partial, do: Map.put(base, "partial", true), else: base
  end

  # ── checks at submit ────────────────────────────────────────────────────

  defp idempotency_key(nil), do: {:ok, nil}

  defp idempotency_key(key) when is_binary(key) do
    if Regex.match?(@idempotency_key, key),
      do: {:ok, key},
      else:
        {:error, :invalid_idempotency_key,
         "Idempotency-Key must be 1 to 128 printable ASCII characters"}
  end

  defp idempotency_key(_key),
    do:
      {:error, :invalid_idempotency_key,
       "Idempotency-Key must be 1 to 128 printable ASCII characters"}

  defp required_string(params, field) do
    case params[field] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request, "#{field} is required"}
    end
  end

  defp mode(nil), do: {:ok, "create"}
  defp mode(mode) when mode in ["create", "merge"], do: {:ok, mode}
  defp mode(_mode), do: {:error, :invalid_request, "mode must be create or merge"}

  defp cross_tenant(params, operator?) do
    requested = params["cross_tenant"] in [true, "true"]

    cond do
      not requested -> {:ok, false}
      operator? -> {:ok, true}
      true -> {:error, :operator_only, "cross_tenant needs the Engine operator's key"}
    end
  end

  defp own_workspace(tenant_id, workspace_id) do
    case Workspace.get(workspace_id) do
      {:ok, %{tenant_id: ^tenant_id, status: status}} when status in [:active, "active"] -> :ok
      _ -> {:error, :workspace_not_found, "workspace not found"}
    end
  end

  defp target_allowed(tenant_id, workspace_id, "merge"), do: own_workspace(tenant_id, workspace_id)

  defp target_allowed(tenant_id, workspace_id, "create") do
    case Workspace.get(workspace_id) do
      {:ok, %{tenant_id: ^tenant_id}} ->
        {:error, :workspace_exists, "the target workspace already exists"}

      {:ok, _other} ->
        {:error, :workspace_not_found, "workspace not found"}

      {:error, :not_found} ->
        case String.split(workspace_id, ":", parts: 2) do
          [prefix, _slug] when prefix != tenant_id ->
            {:error, :workspace_not_found, "workspace not found"}

          _ ->
            :ok
        end
    end
  end

  # The import's source, as stored and fingerprinted, and what is kept out of
  # the job row (the full URL, whose query may carry a signature).
  defp source(tenant_id, %{"bundle" => name} = params, cross_tenant)
       when is_binary(name) and not is_map_key(params, "source_url") do
    with {:ok, path} <- bundle_file(tenant_id, name),
         :ok <- from_tenant(path, tenant_id, cross_tenant),
         %{size: size} = File.stat!(path),
         :ok <- size_allowed(size),
         :ok <- space_for(size) do
      {:ok, %{"kind" => "bundle", "name" => name}, %{}}
    end
  end

  defp source(_tenant_id, %{"source_url" => url} = params, _cross_tenant)
       when is_binary(url) and not is_map_key(params, "bundle") do
    sha256 = params["sha256"]
    hosts = url_hosts()

    cond do
      not (is_binary(sha256) and Regex.match?(@sha256, sha256)) ->
        {:error, :invalid_request,
         "sha256 (64 lowercase hexadecimal characters) is required with source_url"}

      hosts == [] ->
        {:error, :source_url_not_allowed,
         "this Engine takes no source_url (OPTIMAL_BUNDLE_URL_HOSTS is empty)"}

      Fetch.check(url, allowed_hosts: hosts) != :ok or URI.parse(url).scheme != "https" ->
        {:error, :source_url_not_allowed, "the source_url's host is not allowed"}

      true ->
        {:ok, %{"kind" => "url", "url" => Fetch.redact(url), "sha256" => sha256},
         %{"source_url" => url}}
    end
  end

  defp source(_tenant_id, _params, _cross_tenant),
    do: {:error, :invalid_request, "name exactly one of bundle and source_url"}

  defp bundle_file(tenant_id, name) do
    with {:ok, path} <- WorkspaceBundle.bundle_path(tenant_id, name),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :bundle_not_found, "bundle not found"}
    end
  end

  defp from_tenant(_path, _tenant_id, true), do: :ok

  defp from_tenant(path, tenant_id, false) do
    case WorkspaceBundle.source_tenant(path) do
      {:ok, ^tenant_id} -> :ok
      _ -> {:error, :bundle_not_found, "bundle not found"}
    end
  end

  defp size_allowed(size) do
    if size <= max_bytes(),
      do: :ok,
      else: {:error, :bundle_too_large, "the bundle is larger than #{max_bytes()} bytes"}
  end

  # The bundle, its unpacked tables, the rows they become, and the log of the
  # keys of the rows written (never more than the tables it is drawn from):
  # about four times its size beyond the file itself.
  defp space_for(size) do
    case WorkspaceBundle.free_bytes(WorkspaceBundle.backup_dir()) do
      free when is_integer(free) and free < size * 4 ->
        {:error, :insufficient_storage,
         "#{free} bytes are free and the import needs about #{size * 4} beyond the bundle"}

      _ ->
        :ok
    end
  end

  # ── storage of a job's own files ────────────────────────────────────────

  defp job_dir(job_id), do: Path.join([WorkspaceBundle.backup_dir(), "bundle-jobs", job_id])
  defp cancel_mark(job_id), do: Path.join(job_dir(job_id), "cancel")
  # What an import wrote, batch by batch, so that only that can be taken back.
  defp written_log(job_id), do: Path.join(job_dir(job_id), "written.jsonl")
  defp report_path(job_id), do: Path.join(job_dir(job_id), "report.json")

  defp read_report(job_id) do
    with {:ok, json} <- File.read(report_path(job_id)),
         {:ok, report} <- Jason.decode(json) do
      report
    else
      _ -> %{}
    end
  end

  defp write_report(job_id, report) do
    File.mkdir_p!(job_dir(job_id))
    tmp = report_path(job_id) <> ".tmp"
    File.write!(tmp, Jason.encode!(Map.put(report, "updated_at", now())))
    File.rename!(tmp, report_path(job_id))
  end

  defp update_report(job_id, changes),
    do: write_report(job_id, Map.merge(read_report(job_id), changes))

  defp finish_report(job_id, changes),
    do: update_report(job_id, Map.put(changes, "finished_at", now()))

  defp write_private(job_id, name, value) do
    path = Path.join(job_dir(job_id), name)
    File.write!(path, value)
    File.chmod!(path, 0o600)
  end

  defp read_private(job_id, name) do
    case File.read(Path.join(job_dir(job_id), name)) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp remove_private(job_id) do
    File.rm(Path.join(job_dir(job_id), "source_url"))
    File.rm(Path.join(job_dir(job_id), "source.tar.gz"))
    :ok
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp own_job(tenant_id, job_id) when is_binary(job_id) do
    case Jobs.fetch(job_id) do
      {:ok, %{kind: kind, tenant_id: ^tenant_id} = job} when kind in @kinds -> {:ok, job}
      _ -> {:error, :not_found}
    end
  end

  defp own_job(_tenant_id, _job_id), do: {:error, :not_found}

  defp fingerprint(kind, request),
    do: CanonicalJSON.hash(%{"kind" => kind, "request" => request})

  defp file_sha256(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp older?(iso, cutoff) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> DateTime.compare(at, cutoff) == :lt
      _ -> false
    end
  end

  defp older?(_iso, _cutoff), do: false

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  # OPTIMAL_BUNDLE_MAX_BYTES (config :optimal_engine, :bundle_max_bytes).
  defp max_bytes,
    do: Application.get_env(:optimal_engine, :bundle_max_bytes, 5 * 1024 * 1024 * 1024)

  # OPTIMAL_BUNDLE_URL_HOSTS (config :optimal_engine, :bundle_url_hosts).
  defp url_hosts, do: Application.get_env(:optimal_engine, :bundle_url_hosts, [])

  # OPTIMAL_BUNDLE_RETENTION_HOURS (config :optimal_engine, :bundle_retention_hours).
  defp retention_hours,
    do: Application.get_env(:optimal_engine, :bundle_retention_hours, @default_retention_hours)
end
