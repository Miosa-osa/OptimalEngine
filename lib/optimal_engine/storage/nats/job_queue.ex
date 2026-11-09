defmodule OptimalEngine.Storage.NATS.JobQueue do
  @moduledoc """
  Background jobs dispatched through a JetStream work queue. On with `jobs`
  in `OPTIMAL_NATS_FLOWS`.

  The `jobs` table stays the record of every job: its lease, its attempts,
  its retries and dead letters (`OptimalEngine.Jobs`). What JetStream adds is
  the dispatch. Each job that is queued (`Jobs.enqueue/4` and its kin) is
  announced on stream `<NAMESPACE>_JOBS` at `<namespace>.jobs.<kind>` with
  the job's id as the message id, after the job's row is committed. The
  queue's durable consumer looks at the job each time its message is
  delivered:

    * finished (`completed`, `dead`) or gone: acknowledged, and the message
      leaves the queue;
    * due (`available` and its `run_at` passed, or `running` with its lease
      expired): the worker for its kind is woken at once, and the message
      comes back in a few seconds to see it finished;
    * not due yet (a retry's backoff, a lease still held): it comes back when
      the job will be due, at most an hour later.

  So the stream holds one message for every job not yet finished, a worker
  starts a job when it is queued rather than at its next poll, and a job
  outlives any restart: its row is committed before it is announced, and its
  message is acknowledged only when the row says it is finished.

  The workers keep polling the `jobs` table as they always have; that is the
  in-process path, and the one jobs take while NATS is down. Announcing never
  fails or delays an enqueue: it is a message to this process, which
  publishes in the background. A job queued while NATS is down is announced
  when the connection is back: the announcements that could not be sent are
  kept (the latest 10,000) and sent first, then every connection announces
  every job still queued or running (5,000 at most, oldest first), and a job
  announced twice inside the stream's duplicate window (an hour) is stored
  once. So a job queued during an outage does not wait behind every older
  unfinished job to be announced.

  What this does not cover: the kept announcements are in memory, so one the
  list evicted (past 10,000) or that an Engine restart lost, for a job that is
  not among the 5,000 oldest unfinished ones, is not announced until a later
  sweep reaches it; its worker still runs it at its next poll of the `jobs`
  table, as without NATS. An announcement the server refuses for good (larger
  than its `max_payload`, or refused by the stream) is dropped with a warning
  instead of kept, since it would fail the same way on every reconnect.

  Woken on their kind: `reindex` (`Reindex.Worker`), `import.*`
  (`Imports.Worker`), `analysis.*` (`Analyses.Worker`) and `maintenance.*`
  (`Maintenance.Worker`), each only while its own interval is above zero, so
  a worker an operator turned off stays off. Other kinds (bundle jobs,
  offsite backups) are announced and followed to completion, and run when
  their worker next polls.
  """

  @behaviour OptimalEngine.Storage.NATS.WorkQueue

  require Logger

  alias OptimalEngine.{Jobs, Store}
  alias OptimalEngine.Storage.NATS.{Protocol, WorkQueue}

  @recheck_ms 5_000
  @max_delay_ms 3_600_000
  @reconcile_limit 5_000

  # Kind prefix, worker, its interval setting and default, and the name a wake
  # registers under (one wake per worker at a time).
  @workers [
    {"reindex", OptimalEngine.Reindex.Worker, :reindex_interval_ms, 5_000,
     OptimalEngine.Storage.NATS.JobQueue.WakeReindex},
    {"import.", OptimalEngine.Imports.Worker, :imports_interval_ms, 2_000,
     OptimalEngine.Storage.NATS.JobQueue.WakeImports},
    {"analysis.", OptimalEngine.Analyses.Worker, :analyses_interval_ms, 300_000,
     OptimalEngine.Storage.NATS.JobQueue.WakeAnalyses},
    {"maintenance.", OptimalEngine.Maintenance.Worker, :maintenance_interval_ms, 10_000,
     OptimalEngine.Storage.NATS.JobQueue.WakeMaintenance}
  ]

  @doc false
  def child_spec(opts), do: WorkQueue.child_spec({__MODULE__, opts})

  @doc """
  Starts the queue (see `OptimalEngine.Storage.NATS.WorkQueue.start_link/2`).
  Options besides those: `:wake` (a map of job kind to a one-argument
  function, used instead of the built-in workers; tests), `:recheck_ms` (how
  soon the message of a woken job comes back, default 5 s).
  """
  def start_link(opts \\ []), do: WorkQueue.start_link(__MODULE__, opts)

  @doc """
  Announces a queued job. Returns at once and never fails: the job is in the
  `jobs` table already, and is announced again on the next connection if
  this one does not get through.
  """
  @spec announce(GenServer.server(), map()) :: :ok
  def announce(server \\ __MODULE__, job)

  def announce(server, %{id: id, kind: kind, status: status})
      when status in ["available", "running"],
      do:
        WorkQueue.publish_async(server, Protocol.token(kind), Jason.encode!(%{"job_id" => id}), id)

  def announce(_server, _job), do: :ok

  @doc "One pull now (tests, operators)."
  @spec drain_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def drain_now(server \\ __MODULE__), do: WorkQueue.drain_now(server)

  @doc "The queue's state and counts."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: WorkQueue.status(server)

  # ---------------------------------------------------------------------------
  # WorkQueue callbacks
  # ---------------------------------------------------------------------------

  @impl WorkQueue
  def flow, do: "jobs"

  @impl WorkQueue
  def stream_suffix, do: "JOBS"

  @impl WorkQueue
  def subject_root, do: "jobs"

  @impl WorkQueue
  def stream_options, do: %{duplicate_window_ms: 3_600_000}

  @impl WorkQueue
  def consumer, do: %{ack_wait_ms: 60_000, max_deliver: -1}

  # Every job still queued or running, announced again on a new connection.
  @impl WorkQueue
  def on_provisioned(server, _context) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT id, kind, status FROM jobs WHERE status IN ('available', 'running') ORDER BY inserted_at, id LIMIT ?1",
        [@reconcile_limit]
      )

    Enum.each(rows, fn [id, kind, _status] ->
      WorkQueue.publish(server, Protocol.token(kind), Jason.encode!(%{"job_id" => id}), id)
    end)
  rescue
    error -> Logger.warning("[NATS] job announce sweep failed: #{Exception.message(error)}")
  end

  @impl WorkQueue
  def handle_message(message, context) do
    %{"job_id" => id} = Jason.decode!(message.payload)

    case Jobs.fetch(id) do
      {:error, :not_found} ->
        :ack

      {:ok, %{status: status}} when status in ["completed", "dead"] ->
        :ack

      {:ok, job} ->
        now = NaiveDateTime.utc_now()

        case due_in(job, now) do
          0 ->
            wake(job.kind, context)
            {:retry, Map.get(context, :recheck_ms, @recheck_ms)}

          ms ->
            {:retry, min(ms, @max_delay_ms)}
        end

      {:error, reason} ->
        raise "job #{id} could not be read: #{inspect(reason)}"
    end
  end

  defp due_in(%{status: "available", run_at: run_at}, now), do: until(run_at, now)
  defp due_in(%{status: "running", lease_expires_at: expires}, now), do: until(expires, now)
  defp due_in(_job, _now), do: @recheck_ms

  defp until(nil, _now), do: 0

  defp until(at, now) do
    case NaiveDateTime.from_iso8601(at) do
      {:ok, at} -> max(NaiveDateTime.diff(at, now, :millisecond), 0)
      _ -> 0
    end
  end

  # One wake per worker at a time: a worker already draining finds the job.
  defp wake(kind, %{wake: wake}) when is_map(wake) do
    case Map.get(wake, kind) do
      nil -> :ok
      fun -> spawn(fn -> fun.(kind) end)
    end
  end

  defp wake(kind, _context) do
    with {_prefix, worker, key, default, name} <-
           Enum.find(@workers, fn {prefix, _, _, _, _} ->
             kind == prefix or String.starts_with?(kind, prefix)
           end),
         true <- Application.get_env(:optimal_engine, key, default) > 0,
         pid when is_pid(pid) <- Process.whereis(worker) do
      spawn(fn -> tick(worker, name) end)
    end

    :ok
  end

  # The registered name makes it one wake per worker at a time; a second one
  # finds the name taken and leaves it to the first.
  defp tick(worker, name) do
    Process.register(self(), name)
    worker.tick()
  rescue
    ArgumentError -> :ok
  catch
    _kind, _reason -> :ok
  end
end
