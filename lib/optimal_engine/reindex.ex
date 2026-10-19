defmodule OptimalEngine.Reindex do
  @moduledoc """
  Durable reindex requests.

  Writers that change files in the engine root (BusinessOS mirrors markdown and
  then asks for a crawl) post `POST /api/reindex`.
  The request becomes a `reindex` job in `OptimalEngine.Jobs`, so it survives a
  restart, retries on failure, and dead-letters instead of disappearing.

  Repeated requests coalesce: while one reindex is queued or running, another
  request returns that job rather than enqueueing work that would immediately
  refuse to run.
  `OptimalEngine.Pipeline.Indexer.full_index/0` starts the crawl in its own task
  and answers `{:ok, :started}` at once; a job therefore completes when the
  crawl has started, and `Indexer.status/0` reports its progress.
  """

  require Logger

  alias OptimalEngine.Jobs

  @kind "reindex"

  @doc "The job kind used for reindex requests."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  Enqueue a reindex for a workspace, or return the one already active.

  Returns `{:ok, job, :queued}` for a new job and `{:ok, job, :already_running}`
  when a queued or running reindex already exists.
  """
  @spec enqueue(String.t(), keyword()) ::
          {:ok, Jobs.job(), :queued | :already_running} | {:error, term()}
  def enqueue(workspace_id, opts \\ []) when is_binary(workspace_id) do
    with {:ok, active} <- Jobs.active(workspace_id, @kind) do
      case active do
        nil ->
          case Jobs.enqueue(workspace_id, @kind, %{}, opts) do
            {:ok, job} -> {:ok, job, :queued}
            {:error, reason} -> {:error, reason}
          end

        job ->
          {:ok, job, :already_running}
      end
    end
  end

  @doc """
  Claim and run at most one queued reindex job.

  Pass `:lease_owner` so the caller can complete the same lease it claimed.
  Returns `{:ok, :idle}` when nothing is due, `{:ok, job}` when one ran, or
  `{:error, reason}`.
  """
  @spec drain(keyword()) :: {:ok, :idle | Jobs.job()} | {:error, term()}
  def drain(opts \\ []) do
    owner = Keyword.get(opts, :lease_owner, default_owner())

    claim_opts =
      opts
      |> Keyword.take([:workspace_id])
      |> Keyword.merge(kinds: [@kind], lease_owner: owner)

    with {:ok, job} <- Jobs.claim(claim_opts) do
      case job do
        nil -> {:ok, :idle}
        job -> run(job, owner, opts)
      end
    end
  end

  @doc """
  Perform one claimed job.

  `{:error, :already_running}` counts as success: another crawl is already
  doing the same work, and failing the job would only enqueue a retry that
  cannot start either.
  """
  @spec perform(Jobs.job()) :: :ok | {:error, term()}
  def perform(_job) do
    case index_fun().() do
      {:ok, :started} -> :ok
      {:error, :already_running} -> :ok
      {:ok, _other} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_index_result, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run(job, owner, _opts) do
    case perform(job) do
      :ok ->
        case Jobs.complete(job.id, owner) do
          {:ok, completed} -> {:ok, completed}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Reindex] job #{job.id} failed: #{inspect(reason)}")
        Jobs.fail(job.id, owner, inspect(reason))
    end
  end

  defp index_fun do
    Application.get_env(:optimal_engine, :reindex_fun, &OptimalEngine.index/0)
  end

  defp default_owner, do: "reindex-worker:#{node()}:#{System.pid()}"
end
