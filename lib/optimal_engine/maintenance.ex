defmodule OptimalEngine.Maintenance do
  @moduledoc """
  Maintenance that runs as durable jobs (`OptimalEngine.Jobs`), so an Engine
  without Mix, such as a release, runs it through the API.

  | Kind | Work |
  | --- | --- |
  | `maintenance.chunk_embeddings` | embeds the workspace's chunks that have no embedding (`OptimalEngine.Embed.ChunkBackfill`) |
  | `maintenance.graph_backfill` | writes the relationship edges of the workspace's contexts and claims (`OptimalEngine.Graph.Backfill`) |
  | `maintenance.association_projection` | rebuilds the workspace's associative projection (`OptimalEngine.MemoryCore.AssociativeProjection`) once a recall finds it older than its sources |

  A job belongs to one workspace, and a workspace has at most one queued or
  running job of each kind: a request while one is active gets that job.
  One run does a bounded amount of work (500 chunks, or 1,000 contexts and
  claims; a projection job rebuilds the workspace's projection in one
  transaction) and never counts the whole scope. When more is left, the job
  completes and queues its continuation in the same Store transaction; the
  continuation resumes after the last row reached, so progress survives a
  restart. A failure retries with backoff and then dead-letters.

  An unavailable embedder is not a failure. The chunk job goes back in the
  queue with a growing delay (one minute, doubling, at most an hour) without
  spending an attempt, marking nothing failed. After 24 deferrals in a row it
  fails like any other attempt, so an embedder that never comes back ends in
  a dead letter that says so.

  The sweep (`sweep/1`) is the self-healing half: when the embedder is
  healthy it queues a low-priority chunk job for every workspace this Engine
  serves that has chunks with no embedding. `OptimalEngine.Maintenance.Worker`
  drains the jobs, runs the sweep, and prunes completed maintenance jobs.
  """

  require Logger

  alias OptimalEngine.Embed.ChunkBackfill
  alias OptimalEngine.Graph.Backfill, as: GraphBackfill
  alias OptimalEngine.{Jobs, Store}
  alias OptimalEngine.MemoryCore.{AssociativeProjection, ScopeEnvelope}

  @chunk_kind "maintenance.chunk_embeddings"
  @graph_kind "maintenance.graph_backfill"
  @projection_kind "maintenance.association_projection"
  @kinds [@chunk_kind, @graph_kind, @projection_kind]

  @chunk_batch 500
  @graph_batch 1_000
  @pause_ms 20
  @lease_seconds 900
  @sweep_priority -10
  @max_deferrals 24
  @first_deferral_s 60
  @max_deferral_s 3_600
  @keep_days 7

  @type kind :: :chunk_embeddings | :graph_backfill | :association_projection
  @type outcome :: :completed | :continued | :deferred | :retry | :dead

  @type sweep :: %{
          embedder: :healthy | :unavailable,
          queued: [String.t()],
          active: [String.t()],
          skipped: [String.t()]
        }

  @doc "The job kind for a maintenance operation."
  @spec kind(kind()) :: String.t()
  def kind(:chunk_embeddings), do: @chunk_kind
  def kind(:graph_backfill), do: @graph_kind
  def kind(:association_projection), do: @projection_kind

  @doc "Every maintenance job kind."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Queues a maintenance job in a workspace, or returns the one already queued
  or running there. Payload keys: `"limit"` (chunk jobs: the most chunks to
  embed, default all), `"claims"` (graph jobs: false skips the claim pass).
  Options are those of `OptimalEngine.Jobs.enqueue/4`.
  """
  @spec enqueue(kind(), String.t(), map(), keyword()) ::
          {:ok, Jobs.job(), :queued | :active} | {:error, term()}
  def enqueue(kind, workspace_id, payload \\ %{}, opts \\ []) do
    Jobs.enqueue_coalesced(workspace_id, kind(kind), payload, opts)
  end

  @doc """
  Queues a low-priority rebuild of the workspace's associative projection, or
  returns the one already queued or running there.
  """
  @spec queue_projection_rebuild(String.t()) ::
          {:ok, Jobs.job(), :queued | :active} | {:error, term()}
  def queue_projection_rebuild(workspace_id),
    do: enqueue(:association_projection, workspace_id, %{}, priority: @sweep_priority)

  @doc "The workspace's queued or running job of a kind, or nil."
  @spec active(kind(), String.t()) :: {:ok, Jobs.job() | nil} | {:error, term()}
  def active(kind, workspace_id), do: Jobs.active(workspace_id, kind(kind))

  @doc """
  Claims and runs at most one due maintenance job.

  Options: `:workspace_id` limits the claim to one workspace, `:lease_owner`
  names the worker, and `:embed`, `:healthy?`, `:batch` and `:pause_ms` are
  handed to the work (see `perform/2`). Returns `{:ok, :idle}` when nothing
  is due.
  """
  @spec drain(keyword()) ::
          {:ok, :idle | %{job: Jobs.job(), outcome: outcome()}} | {:error, term()}
  def drain(opts \\ []) do
    owner = Keyword.get_lazy(opts, :lease_owner, &default_owner/0)

    claim =
      opts
      |> Keyword.take([:workspace_id])
      |> Keyword.merge(kinds: @kinds, lease_owner: owner, lease_seconds: @lease_seconds)

    case Jobs.claim(claim) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, job} -> settle(job, owner, perform(job, opts))
      {:error, _} = error -> error
    end
  end

  @doc """
  Does one run of a claimed job.

  Returns `{:ok, result}` when the work is done, `{:continue, payload,
  result}` when more is left (the continuation's payload), `{:deferred,
  reason}` when the embedder is unavailable, or `{:error, reason}`.
  Options: `:embed` (see `OptimalEngine.Embed.ChunkBackfill`), `:healthy?`
  (a zero-argument function, default
  `OptimalEngine.Embed.ChunkBackfill.embedder_healthy?/0`, the patient
  maintenance probe), `:batch` (the most rows one run handles: 500 chunks or
  1,000 contexts and claims by default), and `:pause_ms` between pages
  (default 20).
  """
  @spec perform(Jobs.job(), keyword()) ::
          {:ok, map()} | {:continue, map(), map()} | {:deferred, term()} | {:error, term()}
  def perform(job, opts \\ []) do
    do_perform(job, opts)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Queues a low-priority chunk job for every workspace in scope that has
  chunks with no embedding, when the embedder is healthy.

  Options: `:healthy?` (as in `perform/2`), `:tenant_id` or `:workspace_id`
  to narrow the scan, and `:pause_ms` between the scan's windows. A workspace
  this Engine does not serve (`OptimalEngine.Scope.serves?/1`) is left out; one
  that is not registered and active cannot hold a job and is listed in
  `:skipped`. The sweep does not count the chunks it queues: a count reads the
  whole workspace, and `ChunkBackfill.status/1` (`GET
  /api/maintenance/embeddings?kind=chunks`) gives it on demand.
  """
  @spec sweep(keyword()) :: {:ok, sweep()} | {:error, term()}
  def sweep(opts \\ []) do
    healthy? = Keyword.get(opts, :healthy?, &ChunkBackfill.embedder_healthy?/0)
    empty = %{embedder: :healthy, queued: [], active: [], skipped: []}

    if healthy?.() do
      scan = Keyword.take(opts, [:tenant_id, :workspace_id, :pause_ms])

      with {:ok, workspaces} <- ChunkBackfill.pending_workspaces(scan) do
        result =
          workspaces
          |> Enum.filter(&OptimalEngine.Scope.serves?/1)
          |> Enum.reduce(empty, &queue/2)

        if result.queued != [] do
          Logger.info(
            "[Maintenance] sweep: chunks without an embedding in " <>
              "#{length(result.queued)} workspace(s); queued chunk embedding for " <>
              Enum.join(result.queued, ", ")
          )
        end

        {:ok, result}
      end
    else
      {:ok, %{empty | embedder: :unavailable}}
    end
  end

  defp queue(workspace_id, acc) do
    case enqueue(:chunk_embeddings, workspace_id, %{}, priority: @sweep_priority) do
      {:ok, _job, :queued} ->
        %{acc | queued: acc.queued ++ [workspace_id]}

      {:ok, _job, :active} ->
        %{acc | active: acc.active ++ [workspace_id]}

      {:error, :workspace_not_found} ->
        %{acc | skipped: acc.skipped ++ [workspace_id]}

      {:error, reason} ->
        Logger.warning("[Maintenance] sweep could not queue #{workspace_id}: #{inspect(reason)}")
        acc
    end
  end

  @doc """
  Deletes completed maintenance jobs older than `days` (default 7). Dead and
  queued jobs stay. Returns how many were deleted.
  """
  @spec prune(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(days \\ @keep_days) when is_integer(days) and days > 0 do
    # SQLite date arithmetic; a Postgres store uses now() - interval.
    sql = """
    DELETE FROM jobs
    WHERE kind IN (?1, ?2, ?3) AND status = 'completed'
      AND completed_at < datetime('now', '-' || ?4 || ' days')
    """

    Store.transaction(fn txn -> Store.txn_execute(txn, sql, @kinds ++ [days]) end)
  end

  # ── the work ────────────────────────────────────────────────────────────

  defp do_perform(%{kind: @chunk_kind, workspace_id: workspace_id, payload: payload}, opts) do
    healthy? = Keyword.get(opts, :healthy?, &ChunkBackfill.embedder_healthy?/0)
    batch = Keyword.get(opts, :batch, @chunk_batch)
    wanted = positive(payload["limit"])

    if healthy?.() do
      run_opts =
        [
          workspace_id: workspace_id,
          limit: min(wanted || batch, batch),
          after: payload["after"],
          count: false,
          pause_ms: Keyword.get(opts, :pause_ms, @pause_ms)
        ] ++ Keyword.take(opts, [:embed])

      case ChunkBackfill.run(run_opts) do
        {:ok, %{next: nil} = result} ->
          {:ok, result}

        {:ok, result} ->
          left = wanted && wanted - (result.embedded + result.failed)

          if left == nil or left > 0,
            do: {:continue, payload |> progress("after", result.next) |> put_limit(left), result},
            else: {:ok, result}

        {:error, {:embedder_unavailable, _}} = unavailable ->
          {:deferred, unavailable}

        {:error, _} = error ->
          error
      end
    else
      {:deferred, :embedder_unhealthy}
    end
  end

  defp do_perform(%{kind: @graph_kind, workspace_id: workspace_id, payload: payload}, opts) do
    run_opts = [
      workspace_id: workspace_id,
      claims: payload["claims"] != false,
      limit: Keyword.get(opts, :batch, @graph_batch),
      after: cursor(payload["after"]),
      carried: payload["after"] && carried(payload),
      count: false,
      pause_ms: Keyword.get(opts, :pause_ms, @pause_ms)
    ]

    case GraphBackfill.run(run_opts) do
      {:ok, %{next: nil} = result} ->
        {:ok, result}

      {:ok, %{next: {phase, id}} = result} ->
        resume = %{"phase" => to_string(phase), "id" => id}
        {:continue, payload |> carry(result) |> progress("after", resume), result}

      {:error, _} = error ->
        error
    end
  end

  defp do_perform(%{kind: @projection_kind} = job, _opts) do
    %{tenant_id: job.tenant_id, workspace_id: job.workspace_id, actor_id: "system:maintenance"}
    |> ScopeEnvelope.resolve()
    |> AssociativeProjection.rebuild()
  end

  defp do_perform(job, _opts), do: {:error, {:unknown_kind, job.kind}}

  defp settle(job, owner, {:ok, _result}) do
    with {:ok, done} <- Jobs.complete(job.id, owner),
         do: {:ok, %{job: done, outcome: :completed}}
  end

  defp settle(job, owner, {:continue, payload, _result}) do
    with {:ok, %{completed: done, next: next}} <-
           Jobs.complete_and_enqueue(job.id, owner, payload) do
      {:ok, %{job: done, outcome: :continued, next_job_id: next.id}}
    end
  end

  defp settle(job, owner, {:deferred, reason}) do
    deferrals = deferrals(job.payload)

    if deferrals < @max_deferrals do
      retry_in = min(@first_deferral_s * Integer.pow(2, deferrals), @max_deferral_s)

      Logger.info(
        "[Maintenance] #{job.kind} in #{job.workspace_id} deferred #{retry_in}s: " <>
          "#{inspect(reason)}"
      )

      payload = Map.put(job.payload, "deferrals", deferrals + 1)

      with {:ok, deferred} <-
             Jobs.defer(job.id, owner, "deferred: embedder unavailable", retry_in, payload: payload),
           do: {:ok, %{job: deferred, outcome: :deferred}}
    else
      settle(job, owner, {:error, {:embedder_unavailable_after_deferrals, deferrals, reason}})
    end
  end

  defp settle(job, owner, {:error, reason}) do
    Logger.warning("[Maintenance] #{job.kind} in #{job.workspace_id} failed: #{inspect(reason)}")

    Jobs.fail(job.id, owner, reason)
  end

  # ── payload helpers ─────────────────────────────────────────────────────

  # Progress resets the deferral count: the embedder answered.
  defp progress(payload, key, value), do: payload |> Map.put(key, value) |> Map.delete("deferrals")

  defp deferrals(%{"deferrals" => n}) when is_integer(n) and n >= 0, do: n
  defp deferrals(_payload), do: 0

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp put_limit(payload, nil), do: Map.delete(payload, "limit")
  defp put_limit(payload, n), do: Map.put(payload, "limit", n)

  defp cursor(%{"phase" => "claims", "id" => id}) when is_binary(id), do: {:claims, id}
  defp cursor(%{"phase" => "contexts", "id" => id}) when is_binary(id), do: {:contexts, id}
  defp cursor(_), do: nil

  # A graph job's slice passes on what it and the slices before it counted, so
  # the slice that reaches the end records the whole run (Graph.Backfill
  # `:carried`). Only a chain that began at the start carries counts: a
  # continuation an older Engine queued has none and is never recorded.
  defp carry(payload, result) do
    before =
      if payload["after"],
        do: carried(payload),
        else: %{contexts: 0, claims: 0, failed_edges: 0}

    case before do
      nil ->
        payload

      %{contexts: contexts, claims: claims, failed_edges: failed} ->
        Map.put(payload, "carried", %{
          "contexts" => contexts + result.contexts,
          "claims" => claims + result.claims,
          "failed_edges" => failed + result.failed_edges
        })
    end
  end

  defp carried(%{"carried" => %{"contexts" => c, "claims" => cl, "failed_edges" => f}})
       when is_integer(c) and is_integer(cl) and is_integer(f),
       do: %{contexts: c, claims: cl, failed_edges: f}

  defp carried(_payload), do: nil

  defp default_owner, do: "maintenance-worker:#{node()}:#{System.pid()}"
end
