defmodule OptimalEngine.Backup.Schedule do
  @moduledoc """
  Scheduled offsite backups as durable Engine jobs (`OptimalEngine.Jobs`).

  When `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` is set (0 or unset disables), the
  worker (`Backup.Schedule.Worker`) enqueues one `backup.offsite` job per
  interval slot, keyed by the slot so restarts and repeated ticks never add a
  second one, and drains the due jobs. Each job:

    1. takes a verified online backup into `OPTIMAL_BACKUP_DIR`. The backup
       runs `VACUUM INTO` on its own SQLite connection, so the single-writer
       Store is only touched to catalog the result;
    2. encrypts it with `OPTIMAL_BACKUP_KEY` and ships the ciphertext to the
       object store (`Backup.ship_offsite/2`), outside the Store process;
    3. prunes: keeps the newest `OPTIMAL_OFFSITE_BACKUP_KEEP` (default 14)
       scheduled offsite copies and the newest
       `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` (default 3) scheduled local files.

  A failed attempt retries after five minutes, and the retry ships the backup
  its job already took rather than taking another. After three attempts the
  job is dead-lettered. `status/1` reports the outcome; it is served by
  `GET /api/backup/offsite` and checked by the storage audit, so a broken
  bucket or a missing key is never silent.

  Pruning only touches copies the schedule made. A backup taken by hand is
  never deleted by the schedule.
  """

  require Logger

  alias OptimalEngine.{Backup, Jobs, Store, Workspace}
  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Storage.S3

  @kind "backup.offsite"
  @max_attempts 3
  @retry_in_seconds 300
  @lease_seconds 21_600
  @default_keep 14
  @default_keep_local 3
  @failing_states ~w(failing stale misconfigured)

  @doc "The job kind for a scheduled offsite backup."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "Milliseconds between scheduled backups; 0 means the schedule is off."
  @spec interval_ms(keyword()) :: non_neg_integer()
  def interval_ms(opts \\ []) do
    Keyword.get_lazy(opts, :interval_ms, fn ->
      Application.get_env(:optimal_engine, :offsite_backup_interval_ms, 0)
    end)
  end

  @doc "How many scheduled offsite copies are kept."
  @spec keep(keyword()) :: pos_integer()
  def keep(opts \\ []) do
    Keyword.get_lazy(opts, :keep, fn ->
      Application.get_env(:optimal_engine, :offsite_backup_keep, @default_keep)
    end)
  end

  @doc "How many scheduled local backup files are kept."
  @spec keep_local(keyword()) :: non_neg_integer()
  def keep_local(opts \\ []) do
    Keyword.get_lazy(opts, :keep_local, fn ->
      Application.get_env(:optimal_engine, :offsite_backup_keep_local, @default_keep_local)
    end)
  end

  @doc """
  Enqueue the backup for the current interval slot. Slots are fixed windows of
  the interval since the Unix epoch, so a daily interval runs once per UTC day
  however often the scheduler ticks or the engine restarts. Returns
  `:disabled` when the interval is 0.

  Options: `:now`, `:interval_ms`.
  """
  @spec schedule(keyword()) :: {:ok, Jobs.job()} | :disabled | {:error, term()}
  def schedule(opts \\ []) do
    interval = interval_ms(opts)

    if interval > 0 do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      slot = div(DateTime.to_unix(now, :millisecond), interval)

      Jobs.enqueue(
        Workspace.default_id(),
        @kind,
        %{"slot" => slot, "interval_ms" => interval},
        idempotency_key: "#{@kind}:#{interval}:#{slot}",
        max_attempts: @max_attempts
      )
    else
      :disabled
    end
  end

  @doc """
  Run due scheduled backups, at most `:limit` (default 5). A pass stops at the
  first failed attempt: when the bucket is down, the next job would fail the
  same way. Options: `:limit`, `:retry_in` (seconds), `:keep`, `:keep_local`.
  """
  @spec drain(keyword()) :: [map()]
  def drain(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    retry_in = Keyword.get(opts, :retry_in, @retry_in_seconds)

    Enum.reduce_while(1..limit, [], fn _, acc ->
      case Jobs.run_next(&handle(&1, opts),
             kinds: [@kind],
             retry_in: retry_in,
             lease_seconds: @lease_seconds
           ) do
        {:ok, %{job: job, outcome: :completed}} ->
          {:cont, [%{job_id: job.id, outcome: :completed} | acc]}

        {:ok, %{job: job, outcome: outcome}} ->
          {:halt, [%{job_id: job.id, outcome: outcome, error: job.last_error} | acc]}

        :empty ->
          {:halt, acc}

        {:error, reason} ->
          {:halt, [%{error: inspect(reason)} | acc]}
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Run one scheduled backup job: take (or reuse) its verified backup, ship it
  encrypted, and prune. Any failure is returned so the job retries and then
  dead-letters.
  """
  @spec handle(Jobs.job(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle(job, opts \\ []) do
    with :ok <- ready(),
         {:ok, backup} <- backup_for(job),
         {:ok, _shipped} <- ship(backup),
         {:ok, pruned} <- prune(opts) do
      Logger.info(
        "[Backup.Schedule] offsite backup #{backup.id} shipped; pruned #{length(pruned.offsite)} offsite and #{length(pruned.local)} local copies"
      )

      {:ok, %{backup_id: backup.id, pruned: pruned}}
    else
      {:error, reason} ->
        Logger.error("[Backup.Schedule] offsite backup failed: #{Backup.explain(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Prune scheduled copies: keep the newest `keep/1` offsite copies and the
  newest `keep_local/1` local files, delete the rest, and record what was
  removed in each catalog row. A backup left with no copy anywhere is marked
  `pruned`. Copies the schedule did not make are never considered.
  """
  @spec prune(keyword()) :: {:ok, %{offsite: [String.t()], local: [String.t()]}} | {:error, term()}
  def prune(opts \\ []) do
    with {:ok, rows} <- scheduled_rows() do
      drop_offsite = rows |> Enum.filter(& &1.offsite) |> Enum.drop(keep(opts)) |> ids()

      drop_local =
        rows |> Enum.filter(&File.regular?(&1.path)) |> Enum.drop(keep_local(opts)) |> ids()

      results =
        for row <- rows, row.id in drop_offsite or row.id in drop_local do
          prune_row(row, row.id in drop_offsite, row.id in drop_local)
        end

      case for({:error, failure} <- results, do: failure) do
        [] ->
          {:ok,
           %{
             offsite: for({:ok, %{id: id, offsite: true}} <- results, do: id),
             local: for({:ok, %{id: id, local: true}} <- results, do: id)
           }}

        failures ->
          {:error, {:prune_failed, failures}}
      end
    end
  end

  @doc """
  The schedule's state for operators: whether it is on, its settings, whether
  the backup key and object store are configured (the key id only, never the
  key), the latest job, the latest shipped backup, and dead letters.

  `state` is one of `disabled`, `misconfigured`, `pending`, `running`,
  `retrying`, `failing` (the latest job was dead-lettered), `stale` (no
  backup completed in two intervals), or `ok`.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    interval = interval_ms(opts)
    key = Envelope.backup_key()
    store = S3.config()
    last_job = latest_job()
    last_success = latest_success()

    %{
      enabled: interval > 0,
      interval_ms: interval,
      keep: keep(opts),
      keep_local: keep_local(opts),
      encryption: %{
        cipher: Envelope.cipher(),
        key_configured: match?({:ok, _}, key),
        key_id: key_id(key),
        problem: problem(key)
      },
      object_store: %{configured: match?({:ok, _}, store), problem: problem(store)},
      state: state(interval, key, store, last_job),
      last_job: last_job,
      last_success: last_success,
      dead_letters: dead_letters()
    }
  end

  @doc "True when a status `state` means scheduled backups are not being made."
  @spec failing_state?(String.t()) :: boolean()
  def failing_state?(state), do: state in @failing_states

  # ─── one run ─────────────────────────────────────────────────────────────

  # Refuse before taking a backup that could never be shipped.
  defp ready do
    with {:ok, _key} <- Envelope.backup_key(),
         {:ok, _config} <- S3.config(),
         do: :ok
  end

  # A retry ships the backup its job already took. A new backup is taken only
  # when the job has none, or its local file is gone before it was shipped.
  defp backup_for(job) do
    case Store.raw_query(
           """
           SELECT id, storage_uri, offsite, integrity_status FROM backup_records
           WHERE status = 'completed' AND json_extract(metadata, '$.schedule_job_id') = ?1
           ORDER BY created_at DESC, rowid DESC LIMIT 1
           """,
           [job.id]
         ) do
      {:ok, [[id, path, offsite, integrity]]} ->
        if offsite == 1 or File.regular?(path),
          do: verified(%{id: id, path: path, offsite: offsite == 1}, integrity),
          else: take_backup(job)

      {:ok, []} ->
        take_backup(job)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_backup(job) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = job.id |> String.replace_prefix("job_", "") |> String.slice(0, 8)

    metadata = %{
      "scheduled" => true,
      "schedule_job_id" => job.id,
      "schedule_slot" => job.payload["slot"]
    }

    with {:ok, target} <- Backup.resolve_target("scheduled-#{stamp}-#{suffix}.db"),
         {:ok, info} <- Backup.create(target, metadata: metadata) do
      verified(%{id: info.id, path: info.target, offsite: false}, info.integrity_status)
    end
  end

  defp verified(backup, "verified"), do: {:ok, backup}
  defp verified(backup, _integrity), do: {:error, {:backup_not_verified, backup.id}}

  defp ship(%{offsite: true}), do: {:ok, :already_shipped}
  defp ship(%{id: id}), do: Backup.ship_offsite(id)

  # ─── pruning ─────────────────────────────────────────────────────────────

  defp scheduled_rows do
    case Store.raw_query(
           """
           SELECT id, storage_uri, offsite, metadata FROM backup_records
           WHERE status = 'completed' AND json_extract(metadata, '$.scheduled') = 1
           ORDER BY created_at DESC, rowid DESC
           """,
           []
         ) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, path, offsite, metadata] ->
           %{id: id, path: path, offsite: offsite == 1, metadata: decode(metadata)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # The object is deleted before the row says so, and a failed delete leaves
  # the row offsite, so the catalog never claims less than the bucket holds.
  defp prune_row(row, drop_offsite?, drop_local?) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with :ok <- if(drop_offsite?, do: delete_object(row), else: :ok),
         :ok <- if(drop_local?, do: delete_local(row), else: :ok) do
      offsite = row.offsite and not drop_offsite?
      local = File.regular?(row.path)

      metadata =
        row.metadata
        |> then(&if drop_offsite?, do: Map.put(&1, "offsite_pruned_at", now), else: &1)
        |> then(&if drop_local?, do: Map.put(&1, "local_pruned_at", now), else: &1)

      status = if offsite or local, do: "completed", else: "pruned"

      case Store.raw_execute(
             "UPDATE backup_records SET offsite = ?1, status = ?2, metadata = ?3 WHERE id = ?4",
             [if(offsite, do: 1, else: 0), status, Jason.encode!(metadata), row.id]
           ) do
        :ok -> {:ok, %{id: row.id, offsite: drop_offsite?, local: drop_local?}}
        {:error, reason} -> {:error, %{id: row.id, reason: inspect(reason)}}
      end
    else
      {:error, reason} -> {:error, %{id: row.id, reason: inspect(reason)}}
    end
  end

  defp delete_object(%{metadata: %{"offsite_key" => key}}) when is_binary(key),
    do: S3.delete_object(key)

  defp delete_object(_row), do: :ok

  defp delete_local(%{path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:local_delete_failed, reason}}
    end
  end

  # ─── status ──────────────────────────────────────────────────────────────

  defp state(interval, _key, _store, _last_job) when interval <= 0, do: "disabled"
  defp state(_interval, {:error, _}, _store, _last_job), do: "misconfigured"
  defp state(_interval, _key, {:error, _}, _last_job), do: "misconfigured"
  defp state(_interval, _key, _store, nil), do: "pending"
  defp state(_interval, _key, _store, %{status: "dead"}), do: "failing"
  defp state(_interval, _key, _store, %{status: "running"}), do: "running"

  defp state(_interval, _key, _store, %{status: "available", last_error: error})
       when is_binary(error),
       do: "retrying"

  defp state(_interval, _key, _store, %{status: "available"}), do: "pending"

  defp state(interval, _key, _store, %{status: "completed", completed_at: completed_at}) do
    if older_than?(completed_at, 2 * interval), do: "stale", else: "ok"
  end

  defp state(_interval, _key, _store, %{status: status}), do: status

  defp older_than?(timestamp, ms) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, at} -> NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :millisecond) > ms
      _ -> false
    end
  end

  defp older_than?(_timestamp, _ms), do: false

  defp key_id({:ok, key}), do: Envelope.key_id(key)
  defp key_id({:error, _reason}), do: nil

  defp problem({:ok, _}), do: nil
  defp problem({:error, reason}), do: Backup.explain(reason)

  defp latest_job do
    case Store.raw_query(
           """
           SELECT id, status, attempts, max_attempts, last_error, run_at, completed_at, updated_at
           FROM jobs WHERE kind = ?1
           ORDER BY inserted_at DESC, rowid DESC LIMIT 1
           """,
           [@kind]
         ) do
      {:ok, [[id, status, attempts, max_attempts, error, run_at, completed_at, updated_at]]} ->
        %{
          id: id,
          status: status,
          attempts: attempts,
          max_attempts: max_attempts,
          last_error: error,
          run_at: run_at,
          completed_at: completed_at,
          updated_at: updated_at
        }

      _ ->
        nil
    end
  end

  defp latest_success do
    case Store.raw_query(
           """
           SELECT id, created_at, metadata FROM backup_records
           WHERE json_extract(metadata, '$.scheduled') = 1
             AND json_extract(metadata, '$.offsite_shipped_at') IS NOT NULL
           ORDER BY created_at DESC, rowid DESC LIMIT 1
           """,
           []
         ) do
      {:ok, [[id, created_at, metadata]]} ->
        metadata = decode(metadata)

        %{
          backup_id: id,
          created_at: created_at,
          shipped_at: metadata["offsite_shipped_at"],
          offsite_uri: metadata["offsite_uri"],
          key_id: metadata["offsite_key_id"]
        }

      _ ->
        nil
    end
  end

  defp dead_letters do
    case Store.raw_query(
           """
           SELECT id, final_error, failed_at,
                  (SELECT COUNT(*) FROM dead_letter_jobs
                   WHERE kind = ?1 AND replayed_at IS NULL)
           FROM dead_letter_jobs
           WHERE kind = ?1 AND replayed_at IS NULL
           ORDER BY failed_at DESC, rowid DESC LIMIT 1
           """,
           [@kind]
         ) do
      {:ok, [[id, error, failed_at, count]]} ->
        %{count: count, latest: %{id: id, final_error: error, failed_at: failed_at}}

      _ ->
        %{count: 0, latest: nil}
    end
  end

  defp decode(nil), do: %{}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end
