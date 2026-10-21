defmodule OptimalEngine.Jobs do
  @moduledoc """
  Durable, workspace-scoped background jobs on the `jobs` and
  `dead_letter_jobs` tables.

  ## Lifecycle

      available --claim--> running --complete--> completed
                              |
                              +--fail (attempts left)--> available (run_at + backoff)
                              +--fail (exhausted)------> dead  (+ dead_letter_jobs row)

  Claiming is atomic: one Store transaction selects the next due job and
  leases it, so two workers never run the same job. A lease that expires
  (the worker died) makes the job claimable again; an expired lease on a job
  with no attempts left dead-letters it instead. Completing or failing a job
  requires the lease owner, so a worker whose lease was reclaimed cannot
  overwrite the new owner's result.

  Every job belongs to an active workspace, and its tenant is taken from the
  workspace row rather than from the caller.
  """

  alias OptimalEngine.Store

  @default_lease_seconds 300
  @default_max_attempts 5
  @max_backoff_seconds 3_600
  @max_error_bytes 2_000

  @job_columns """
  id, tenant_id, workspace_id, kind, payload, status, priority, run_at, attempts,
  max_attempts, lease_owner, lease_expires_at, idempotency_key, last_error,
  inserted_at, updated_at, completed_at
  """

  @dead_letter_columns """
  id, original_job_id, tenant_id, workspace_id, kind, payload, attempts,
  final_error, failed_at, replayed_at, metadata
  """

  @type job :: %{
          id: String.t(),
          tenant_id: String.t(),
          workspace_id: String.t(),
          kind: String.t(),
          payload: map(),
          status: String.t(),
          priority: integer(),
          run_at: String.t(),
          attempts: non_neg_integer(),
          max_attempts: pos_integer(),
          lease_owner: String.t() | nil,
          lease_expires_at: String.t() | nil,
          idempotency_key: String.t() | nil,
          last_error: String.t() | nil,
          inserted_at: String.t(),
          updated_at: String.t(),
          completed_at: String.t() | nil
        }

  @type outcome :: :completed | :retry | :dead

  @doc """
  Enqueue a job. Options: `:priority` (higher runs first), `:run_at`
  (`DateTime`), `:run_in` (seconds from now), `:max_attempts`, and
  `:idempotency_key` (re-enqueueing the same key in the same workspace
  returns the existing job).
  """
  @spec enqueue(String.t(), String.t(), map(), keyword()) :: {:ok, job()} | {:error, term()}
  def enqueue(workspace_id, kind, payload \\ %{}, opts \\ [])
      when is_binary(workspace_id) and is_binary(kind) and is_map(payload) do
    id = new_id("job_")
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with :ok <- validate_kind(kind),
         :ok <- validate_max_attempts(Keyword.get(opts, :max_attempts, @default_max_attempts)),
         {:ok, tenant_id} <- workspace_tenant(workspace_id),
         {sql, params} = insert_statement(id, tenant_id, workspace_id, kind, payload, opts),
         :ok <- Store.raw_execute(sql, params) do
      case idempotency_key do
        nil -> get(id, workspace_id)
        key -> get_by_idempotency_key(tenant_id, workspace_id, key)
      end
    end
  end

  @doc """
  Lease the next due job. Options: `:workspace_id` (default: any workspace),
  `:kinds`, `:lease_owner`, and `:lease_seconds`. Returns `{:ok, nil}` when
  nothing is due.
  """
  @spec claim(keyword()) :: {:ok, job() | nil} | {:error, term()}
  def claim(opts \\ []) do
    owner = Keyword.get_lazy(opts, :lease_owner, &default_owner/0)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    {scope_sql, scope_params} = scope_clause(opts)

    Store.transaction(fn txn ->
      with {:ok, _} <- dead_letter_expired_exhausted(txn, scope_sql, scope_params),
           {:ok, rows} <-
             Store.txn_query(
               txn,
               """
               SELECT id FROM jobs
               WHERE ((status = 'available' AND run_at <= datetime('now'))
                  OR (status = 'running' AND lease_expires_at <= datetime('now')))
                 #{scope_sql}
               ORDER BY priority DESC, run_at ASC, inserted_at ASC
               LIMIT 1
               """,
               scope_params
             ) do
        case rows do
          [] ->
            {:ok, nil}

          [[id]] ->
            with :ok <-
                   one_row(
                     Store.txn_execute(
                       txn,
                       """
                       UPDATE jobs SET status = 'running', attempts = attempts + 1,
                         lease_owner = ?2,
                         lease_expires_at = datetime('now', '+' || ?3 || ' seconds'),
                         updated_at = datetime('now')
                       WHERE id = ?1
                       """,
                       [id, owner, max(lease_seconds, 0)]
                     )
                   ) do
              txn_get(txn, id)
            end
        end
      end
    end)
  end

  @doc "Mark a leased job completed. Fails with `:lease_lost` for a non-owner."
  @spec complete(String.t(), String.t()) :: {:ok, job()} | {:error, term()}
  def complete(job_id, lease_owner) when is_binary(job_id) and is_binary(lease_owner) do
    Store.transaction(fn txn ->
      case Store.txn_execute(
             txn,
             """
             UPDATE jobs SET status = 'completed', completed_at = datetime('now'),
               lease_owner = NULL, lease_expires_at = NULL, updated_at = datetime('now')
             WHERE id = ?1 AND status = 'running' AND lease_owner = ?2
             """,
             [job_id, lease_owner]
           ) do
        {:ok, 1} -> txn_get(txn, job_id)
        {:ok, 0} -> {:error, :lease_lost}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Record a failed attempt. With attempts left the job returns to `available`
  after a backoff (`:retry_in` seconds, default exponential, capped at one
  hour); otherwise it is dead-lettered. `permanent: true` dead-letters it at
  once: the failure is one another attempt cannot fix (a refused input).
  """
  @spec fail(String.t(), String.t(), term(), keyword()) ::
          {:ok, %{job: job(), outcome: :retry | :dead}} | {:error, term()}
  def fail(job_id, lease_owner, error, opts \\ [])
      when is_binary(job_id) and is_binary(lease_owner) do
    message = error_message(error)

    Store.transaction(fn txn ->
      with {:ok, job} <- txn_get(txn, job_id),
           :ok <- owns_lease(job, lease_owner) do
        if job.attempts >= job.max_attempts or Keyword.get(opts, :permanent, false) do
          dead_letter(txn, job, message)
        else
          retry_in = Keyword.get_lazy(opts, :retry_in, fn -> backoff(job.attempts) end)
          schedule_retry(txn, job, message, retry_in)
        end
      end
    end)
  end

  @doc """
  Extend the lease of a running job by `seconds` from now. A long job calls
  this as it makes progress, so its lease never lapses while it is alive and
  a job whose worker died is still reclaimed promptly. Fails with
  `:lease_lost` for a non-owner.
  """
  @spec extend_lease(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def extend_lease(job_id, lease_owner, seconds)
      when is_binary(job_id) and is_binary(lease_owner) and is_integer(seconds) and seconds > 0 do
    result =
      Store.transaction(fn txn ->
        txn
        |> Store.txn_execute(
          """
          UPDATE jobs SET lease_expires_at = datetime('now', '+' || ?3 || ' seconds'),
            updated_at = datetime('now')
          WHERE id = ?1 AND status = 'running' AND lease_owner = ?2
          """,
          [job_id, lease_owner, seconds]
        )
        |> case do
          {:ok, 1} -> {:ok, :extended}
          {:ok, _} -> {:error, :lease_lost}
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, :extended} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Claim one due job and run `handler` on it. `:ok` or `{:ok, _}` completes
  the job; `{:error, reason}`, any other return, a raise, a throw, or an exit
  records a failed attempt. Accepts the `claim/1` options plus `:retry_in`.
  """
  @spec run_next((job() -> term()), keyword()) ::
          {:ok, %{job: job(), outcome: outcome()}} | :empty | {:error, term()}
  def run_next(handler, opts \\ []) when is_function(handler, 1) do
    owner = Keyword.get_lazy(opts, :lease_owner, &default_owner/0)

    case claim(Keyword.put(opts, :lease_owner, owner)) do
      {:ok, nil} ->
        :empty

      {:ok, job} ->
        case invoke(handler, job) do
          :ok ->
            with {:ok, done} <- complete(job.id, owner),
                 do: {:ok, %{job: done, outcome: :completed}}

          {:error, reason} ->
            fail(job.id, owner, reason, Keyword.take(opts, [:retry_in]))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, job()} | {:error, :not_found | term()}
  def get(job_id, workspace_id) when is_binary(job_id) and is_binary(workspace_id) do
    case Store.raw_query("SELECT #{@job_columns} FROM jobs WHERE id = ?1 AND workspace_id = ?2", [
           job_id,
           workspace_id
         ]) do
      {:ok, [row]} -> {:ok, job_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List a workspace's jobs, newest first. Options: `:status`, `:limit`."
  @spec list(String.t(), keyword()) :: {:ok, [job()]} | {:error, term()}
  def list(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

    {sql, params} =
      case Keyword.get(opts, :status) do
        nil ->
          {"SELECT #{@job_columns} FROM jobs WHERE workspace_id = ?1 ORDER BY inserted_at DESC, id LIMIT ?2",
           [workspace_id, limit]}

        status ->
          {"SELECT #{@job_columns} FROM jobs WHERE workspace_id = ?1 AND status = ?3 ORDER BY inserted_at DESC, id LIMIT ?2",
           [workspace_id, limit, to_string(status)]}
      end

    with {:ok, rows} <- Store.raw_query(sql, params), do: {:ok, Enum.map(rows, &job_from_row/1)}
  end

  @doc """
  The job a workspace enqueued with `idempotency_key`, in any state, or
  `{:error, :not_found}`. A caller checks it before accepting work it would
  otherwise discard as a duplicate.
  """
  @spec find_by_idempotency_key(String.t(), String.t()) :: {:ok, job()} | {:error, term()}
  def find_by_idempotency_key(workspace_id, key) when is_binary(workspace_id) and is_binary(key) do
    case Store.raw_query(
           "SELECT #{@job_columns} FROM jobs WHERE workspace_id = ?1 AND idempotency_key = ?2",
           [workspace_id, key]
         ) do
      {:ok, [row | _]} -> {:ok, job_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "How many jobs of a kind a workspace has queued or running."
  @spec count_active(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_active(workspace_id, kind) when is_binary(workspace_id) and is_binary(kind) do
    case Store.raw_query(
           "SELECT COUNT(*) FROM jobs WHERE workspace_id = ?1 AND kind = ?2 AND status IN ('available', 'running')",
           [workspace_id, kind]
         ) do
      {:ok, [[n]]} -> {:ok, n}
      {:ok, []} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Jobs of a kind across every workspace, newest first, for maintenance that
  spans workspaces (an importer sweeping its staging folders). Options:
  `:statuses` (default all) and `:limit` (default 10,000).
  """
  @spec list_kind(String.t(), keyword()) :: {:ok, [job()]} | {:error, term()}
  def list_kind(kind, opts \\ []) when is_binary(kind) do
    limit = opts |> Keyword.get(:limit, 10_000) |> max(1)
    statuses = Keyword.get(opts, :statuses, [])

    {status_sql, params} =
      case statuses do
        [] ->
          {"", [kind, limit]}

        list ->
          placeholders = Enum.map_join(1..length(list), ", ", &"?#{&1 + 2}")
          {" AND status IN (#{placeholders})", [kind, limit | Enum.map(list, &to_string/1)]}
      end

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT #{@job_columns} FROM jobs WHERE kind = ?1#{status_sql} ORDER BY inserted_at DESC LIMIT ?2",
             params
           ) do
      {:ok, Enum.map(rows, &job_from_row/1)}
    end
  end

  @doc """
  Return the workspace's queued or running job of a kind, if one exists.

  Callers use this to coalesce repeated requests onto one job: a save loop that
  asks for the same work ten times should not enqueue ten jobs that each refuse
  to run because the first one already is.
  """
  @spec active(String.t(), String.t()) :: {:ok, job() | nil} | {:error, term()}
  def active(workspace_id, kind) when is_binary(workspace_id) and is_binary(kind) do
    case Store.raw_query(
           """
           SELECT #{@job_columns} FROM jobs
           WHERE workspace_id = ?1 AND kind = ?2 AND status IN ('available', 'running')
           ORDER BY inserted_at ASC, id ASC
           LIMIT 1
           """,
           [workspace_id, kind]
         ) do
      {:ok, [row]} -> {:ok, job_from_row(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List a workspace's dead letters, newest first."
  @spec dead_letters(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def dead_letters(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT #{@dead_letter_columns} FROM dead_letter_jobs WHERE workspace_id = ?1 ORDER BY failed_at DESC, id LIMIT ?2",
             [workspace_id, limit]
           ) do
      {:ok, Enum.map(rows, &dead_letter_from_row/1)}
    end
  end

  @doc """
  Re-enqueue a dead-lettered job with a fresh attempt budget. A dead letter
  can be replayed once; the original job stays `dead` for audit.
  """
  @spec replay_dead_letter(String.t(), String.t(), keyword()) :: {:ok, job()} | {:error, term()}
  def replay_dead_letter(dead_letter_id, workspace_id, opts \\ [])
      when is_binary(dead_letter_id) and is_binary(workspace_id) do
    with :ok <- validate_max_attempts(Keyword.get(opts, :max_attempts, @default_max_attempts)),
         {:ok, letter} <- get_dead_letter(dead_letter_id, workspace_id) do
      job_id = new_id("job_")
      opts = Keyword.delete(opts, :idempotency_key)

      {sql, params} =
        insert_statement(job_id, letter.tenant_id, workspace_id, letter.kind, letter.payload, opts)

      # Marking the letter and enqueueing its replacement commit together, so
      # a dead letter is replayed exactly once.
      Store.transaction(fn txn ->
        with :ok <-
               txn
               |> Store.txn_execute(
                 "UPDATE dead_letter_jobs SET replayed_at = datetime('now') WHERE id = ?1 AND workspace_id = ?2 AND replayed_at IS NULL",
                 [dead_letter_id, workspace_id]
               )
               |> replay_claimed(),
             {:ok, _} <- Store.txn_execute(txn, sql, params) do
          txn_get(txn, job_id)
        end
      end)
    end
  end

  defp replay_claimed({:ok, 1}), do: :ok
  defp replay_claimed({:ok, 0}), do: {:error, :already_replayed}
  defp replay_claimed({:error, reason}), do: {:error, reason}

  # ─── private ─────────────────────────────────────────────────────────────

  defp invoke(handler, job) do
    case handler.(job) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp dead_letter_expired_exhausted(txn, scope_sql, scope_params) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             """
             SELECT id FROM jobs
             WHERE status = 'running' AND lease_expires_at <= datetime('now')
               AND attempts >= max_attempts #{scope_sql}
             """,
             scope_params
           ) do
      Enum.reduce_while(rows, {:ok, 0}, fn [id], {:ok, count} ->
        with {:ok, job} <- txn_get(txn, id),
             {:ok, _} <- dead_letter(txn, job, "lease expired after the final attempt") do
          {:cont, {:ok, count + 1}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp schedule_retry(txn, job, message, retry_in) do
    with :ok <-
           one_row(
             Store.txn_execute(
               txn,
               """
               UPDATE jobs SET status = 'available', last_error = ?2,
                 run_at = datetime('now', '+' || ?3 || ' seconds'),
                 lease_owner = NULL, lease_expires_at = NULL, updated_at = datetime('now')
               WHERE id = ?1
               """,
               [job.id, message, max(retry_in, 0)]
             )
           ),
         {:ok, updated} <- txn_get(txn, job.id) do
      {:ok, %{job: updated, outcome: :retry}}
    end
  end

  defp dead_letter(txn, job, message) do
    with {:ok, _} <-
           Store.txn_execute(
             txn,
             """
             INSERT INTO dead_letter_jobs (
               id, original_job_id, tenant_id, workspace_id, kind, payload, attempts,
               final_error, metadata
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             """,
             [
               new_id("dlq_"),
               job.id,
               job.tenant_id,
               job.workspace_id,
               job.kind,
               Jason.encode!(job.payload),
               job.attempts,
               message,
               Jason.encode!(%{priority: job.priority, max_attempts: job.max_attempts})
             ]
           ),
         :ok <-
           one_row(
             Store.txn_execute(
               txn,
               """
               UPDATE jobs SET status = 'dead', last_error = ?2, lease_owner = NULL,
                 lease_expires_at = NULL, updated_at = datetime('now')
               WHERE id = ?1
               """,
               [job.id, message]
             )
           ),
         {:ok, updated} <- txn_get(txn, job.id) do
      {:ok, %{job: updated, outcome: :dead}}
    end
  end

  defp one_row({:ok, 1}), do: :ok
  defp one_row({:ok, _}), do: {:error, :not_found}
  defp one_row({:error, reason}), do: {:error, reason}

  defp insert_statement(id, tenant_id, workspace_id, kind, payload, opts) do
    {run_at_sql, run_at_param} = run_at_clause(opts, 8)

    {"""
     INSERT INTO jobs (
       id, tenant_id, workspace_id, kind, payload, priority, max_attempts,
       run_at, idempotency_key
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, #{run_at_sql}, ?9)
     ON CONFLICT(tenant_id, workspace_id, idempotency_key) DO NOTHING
     """,
     [
       id,
       tenant_id,
       workspace_id,
       kind,
       Jason.encode!(payload),
       Keyword.get(opts, :priority, 0),
       Keyword.get(opts, :max_attempts, @default_max_attempts),
       run_at_param,
       Keyword.get(opts, :idempotency_key)
     ]}
  end

  defp owns_lease(%{status: "running", lease_owner: owner}, owner), do: :ok
  defp owns_lease(_job, _owner), do: {:error, :lease_lost}

  defp txn_get(txn, id) do
    case Store.txn_query(txn, "SELECT #{@job_columns} FROM jobs WHERE id = ?1", [id]) do
      {:ok, [row]} -> {:ok, job_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_by_idempotency_key(tenant_id, workspace_id, key) do
    case Store.raw_query(
           "SELECT #{@job_columns} FROM jobs WHERE tenant_id = ?1 AND workspace_id = ?2 AND idempotency_key = ?3",
           [tenant_id, workspace_id, key]
         ) do
      {:ok, [row]} -> {:ok, job_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_dead_letter(id, workspace_id) do
    case Store.raw_query(
           "SELECT #{@dead_letter_columns} FROM dead_letter_jobs WHERE id = ?1 AND workspace_id = ?2",
           [id, workspace_id]
         ) do
      {:ok, [row]} -> {:ok, dead_letter_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_tenant(workspace_id) do
    case Store.raw_query(
           "SELECT tenant_id FROM workspaces WHERE id = ?1 AND status = 'active'",
           [workspace_id]
         ) do
      {:ok, [[tenant_id]]} -> {:ok, tenant_id}
      {:ok, []} -> {:error, :workspace_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scope_clause(opts) do
    {workspace_sql, workspace_params} =
      case Keyword.get(opts, :workspace_id) do
        nil -> {"", []}
        workspace_id -> {"AND workspace_id = ?1", [workspace_id]}
      end

    case Keyword.get(opts, :kinds) do
      kinds when is_list(kinds) and kinds != [] ->
        offset = length(workspace_params)

        placeholders =
          kinds |> Enum.with_index(offset + 1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

        {"#{workspace_sql} AND kind IN (#{placeholders})",
         workspace_params ++ Enum.map(kinds, &to_string/1)}

      _ ->
        {workspace_sql, workspace_params}
    end
  end

  # Timestamps stay in SQLite's `YYYY-MM-DD HH:MM:SS` UTC form so text
  # comparisons against datetime('now') order correctly.
  defp run_at_clause(opts, index) do
    cond do
      match?(%DateTime{}, opts[:run_at]) ->
        {"?#{index}", opts[:run_at] |> DateTime.shift_zone!("Etc/UTC") |> sqlite_time()}

      is_integer(opts[:run_in]) ->
        {"datetime('now', '+' || ?#{index} || ' seconds')", max(opts[:run_in], 0)}

      true ->
        {"datetime('now', '+' || ?#{index} || ' seconds')", 0}
    end
  end

  defp sqlite_time(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  defp validate_kind(kind) do
    if String.trim(kind) == "", do: {:error, :kind_required}, else: :ok
  end

  defp validate_max_attempts(n) when is_integer(n) and n >= 1, do: :ok
  defp validate_max_attempts(_), do: {:error, :invalid_max_attempts}

  defp backoff(attempts), do: min(trunc(:math.pow(2, attempts)) * 5, @max_backoff_seconds)

  defp error_message(error) when is_binary(error), do: binary_part_safe(error)
  defp error_message(error), do: error |> inspect() |> binary_part_safe()

  defp binary_part_safe(text) when byte_size(text) <= @max_error_bytes, do: text
  defp binary_part_safe(text), do: String.slice(text, 0, @max_error_bytes)

  defp default_owner, do: "#{node()}:#{inspect(self())}"

  defp new_id(prefix), do: prefix <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  defp job_from_row([
         id,
         tenant_id,
         workspace_id,
         kind,
         payload,
         status,
         priority,
         run_at,
         attempts,
         max_attempts,
         lease_owner,
         lease_expires_at,
         idempotency_key,
         last_error,
         inserted_at,
         updated_at,
         completed_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      kind: kind,
      payload: decode_json(payload),
      status: status,
      priority: priority,
      run_at: run_at,
      attempts: attempts,
      max_attempts: max_attempts,
      lease_owner: lease_owner,
      lease_expires_at: lease_expires_at,
      idempotency_key: idempotency_key,
      last_error: last_error,
      inserted_at: inserted_at,
      updated_at: updated_at,
      completed_at: completed_at
    }
  end

  defp dead_letter_from_row([
         id,
         original_job_id,
         tenant_id,
         workspace_id,
         kind,
         payload,
         attempts,
         final_error,
         failed_at,
         replayed_at,
         metadata
       ]) do
    %{
      id: id,
      original_job_id: original_job_id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      kind: kind,
      payload: decode_json(payload),
      attempts: attempts,
      final_error: final_error,
      failed_at: failed_at,
      replayed_at: replayed_at,
      metadata: decode_json(metadata)
    }
  end

  defp decode_json(nil), do: %{}

  defp decode_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end
end
