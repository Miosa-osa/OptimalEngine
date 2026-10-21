defmodule OptimalEngine.Store.FileCache.Maintenance do
  @moduledoc """
  Keeps the filesystem cache (`OptimalEngine.Store.FileCache`) within its
  rules.

    * At boot, before the API answers, it removes the unpartitioned layout
      earlier versions wrote: those entries held the embedded text in the clear
      and cannot be attributed to a workspace. The first boot of the release
      records the result on every Engine, even one with nothing to remove
      (`OptimalEngine.Store.FileCache.LegacyPurgeRecord`, served as
      `embed_cache_legacy_purge` by `GET /api/storage` and as two gauges), logs
      the file count and bytes, and emits the telemetry event
      `[:optimal_engine, :embed_cache, :legacy_purge]` with `%{files, bytes}`.
      A removal of files is also an audit event (`cache.legacy_purge`). Later
      boots find nothing and say nothing. Files of the old layout that appear
      again, after a rollback to an earlier version, are removed and recorded
      again.
    * Every six hours, and once at boot, it removes entries older than
      `cache_max_age_days`, and tries the removal of the old layout again if
      the boot attempt could not finish it:

          config :optimal_engine, :text_embedding, cache_max_age_days: 30

      The default is 30; `0` or `nil` keeps entries until their workspace is
      purged. A cache hit does not extend an entry's life.
    * `purge_workspace/3` is what workspace deletion, archiving and every
      erasure path call to remove a workspace's entries, and with them the
      other files that cannot outlive the workspace's data: its decomposition
      checkpoints and the local copies of its object-store assets
      (`OptimalEngine.Compliance.Artifacts`).

  Failures are logged and never crash the supervision tree.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Audit.Logger, as: Audit
  alias OptimalEngine.Compliance.Artifacts
  alias OptimalEngine.Store.FileCache
  alias OptimalEngine.Store.FileCache.LegacyPurgeRecord

  @interval_ms 6 * 60 * 60 * 1_000
  @default_max_age_days 30
  @day_seconds 86_400

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The configured retention in days, or `nil` when entries do not expire.
  """
  @spec max_age_days() :: pos_integer() | nil
  def max_age_days do
    config = Application.get_env(:optimal_engine, :text_embedding, [])

    case Keyword.get(config, :cache_max_age_days, @default_max_age_days) do
      days when is_integer(days) and days > 0 ->
        days

      off when off in [0, nil] ->
        nil

      other ->
        Logger.warning(
          "[FileCache] cache_max_age_days must be a whole number of days, got #{inspect(other)}; using #{@default_max_age_days}"
        )

        @default_max_age_days
    end
  end

  @doc """
  Remove the unpartitioned cache of earlier versions, and record it the first
  time. Returns what was removed; a second call finds nothing and returns zeros
  without a log line, an event or a new record.
  """
  @spec purge_legacy() :: {:ok, FileCache.removed()} | {:error, term()}
  def purge_legacy do
    case FileCache.purge_legacy() do
      {:ok, removed} ->
        if removed.files > 0 or is_nil(LegacyPurgeRecord.read()), do: announce(removed)
        {:ok, removed}

      {:error, reason} = error ->
        Logger.error(
          "[FileCache] could not remove the unpartitioned embedding cache: #{inspect(reason)}"
        )

        error
    end
  end

  # The record, the log line and the telemetry event of a purge that is news: the
  # first on this Engine, or one that found files again.
  defp announce(%{files: files, bytes: bytes} = removed) do
    version = OptimalEngine.Version.application_version()

    case LegacyPurgeRecord.write(files, bytes) do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[FileCache] could not record the purge of the unpartitioned embedding cache at #{LegacyPurgeRecord.path()}: #{inspect(reason)}"
        )
    end

    if files > 0 do
      Logger.info(
        "[FileCache] removed the unpartitioned embedding cache of earlier versions: " <>
          "#{files} files, #{bytes} bytes; it held the embedded text and cannot be attributed " <>
          "to a workspace, and entries are now kept per workspace (version #{version})"
      )

      record("cache.legacy_purge", "cache:legacy", removed)
    else
      Logger.info(
        "[FileCache] no unpartitioned embedding cache of earlier versions to remove: " <>
          "0 files, 0 bytes (version #{version})"
      )
    end

    :telemetry.execute(
      [:optimal_engine, :embed_cache, :legacy_purge],
      %{files: files, bytes: bytes},
      %{engine_version: version}
    )
  end

  @doc """
  Remove entries older than the configured retention. A no-op when entries do
  not expire.
  """
  @spec sweep() :: FileCache.removed()
  def sweep do
    case max_age_days() do
      nil ->
        %{files: 0, bytes: 0}

      days ->
        removed = FileCache.sweep(days * @day_seconds)

        if removed.files > 0 do
          Logger.info(
            "[FileCache] removed #{removed.files} entries older than #{days} days (#{removed.bytes} bytes)"
          )
        end

        removed
    end
  end

  @doc """
  Remove everything the cache holds for `workspace_id`: its embedding entries,
  its decomposition checkpoints and the local copies of its object-store assets.
  `reason` names the path that asked (`:archive`, `:erase`, `:retention`,
  `:move`, `:rename`, `:repair`, `:sync`) and goes in the log line. A failure is
  logged as an error and returned: the caller reports it rather than claim the
  workspace is clean. Both removals are tried; the first failure is the result.

  A caller that is about to delete the rows that point at the checkpoints (a
  workspace move) passes `plan: Compliance.Artifacts.plan(workspace_id)` taken
  before.

  A caller that deletes only some of a workspace's contexts (an erasure, a retention
  delete) passes `artifacts: false`: the files of the rows it deleted went with them
  (`Compliance.DerivedData`), and the checkpoints and copies of the contexts that stay,
  or of a decomposition under way, are not its to remove. The embedding entries cannot
  be told apart per context, so they go for the whole workspace.
  """
  @spec purge_workspace(String.t(), atom(), keyword()) ::
          {:ok, FileCache.removed()} | {:error, term()}
  def purge_workspace(workspace_id, reason, opts \\ [])
      when is_binary(workspace_id) and is_atom(reason) do
    cache = FileCache.purge_workspace(workspace_id)

    artifacts =
      if Keyword.get(opts, :artifacts, true),
        do: Artifacts.purge_workspace(workspace_id, Keyword.get(opts, :plan)),
        else: {:ok, %{files: 0, bytes: 0}}

    log_purge(combine(cache, artifacts), workspace_id, reason)
  end

  defp combine({:ok, a}, {:ok, b}), do: {:ok, %{files: a.files + b.files, bytes: a.bytes + b.bytes}}
  defp combine({:error, _} = error, _artifacts), do: error
  defp combine(_cache, {:error, _} = error), do: error

  defp log_purge(result, workspace_id, reason) do
    case result do
      {:ok, %{files: 0}} = none ->
        none

      {:ok, %{files: files, bytes: bytes}} = purged ->
        Logger.info(
          "[FileCache] purged the cache of workspace #{workspace_id} (#{reason}): #{files} files, #{bytes} bytes"
        )

        purged

      {:error, cause} = error ->
        Logger.error(
          "[FileCache] could not purge the cache of workspace #{workspace_id} (#{reason}): #{inspect(cause)}"
        )

        error
    end
  end

  @doc "`purge_workspace/3` for several workspaces; the first failure is returned after all are tried."
  @spec purge_workspaces([String.t()], atom(), keyword()) ::
          {:ok, FileCache.removed()} | {:error, term()}
  def purge_workspaces(workspace_ids, reason, opts \\ []) when is_list(workspace_ids) do
    workspace_ids
    |> Enum.uniq()
    |> Enum.map(&purge_workspace(&1, reason, opts))
    |> Enum.reduce({:ok, %{files: 0, bytes: 0}}, fn
      {:ok, removed}, {:ok, total} ->
        {:ok, %{files: total.files + removed.files, bytes: total.bytes + removed.bytes}}

      {:error, _} = error, {:ok, _total} ->
        error

      _result, {:error, _} = error ->
        error
    end)
  end

  @doc """
  A purge result as a map for a report: `%{files: n, bytes: n}`, or
  `%{error: reason}` when it failed. The error names the cause, not the path it
  happened at.
  """
  @spec summary({:ok, FileCache.removed()} | {:error, term()}) :: map()
  def summary({:ok, %{files: files, bytes: bytes}}), do: %{files: files, bytes: bytes}
  def summary({:error, cause}), do: %{error: inspect(reason(cause))}

  @doc """
  The cause of a failed purge without the path it names, for an answer or a
  report: an error code, or a kind of artifact and an error code. A shape this
  function does not know is `:purge_failed`. The log line keeps the full cause.
  """
  @spec reason(term()) :: term()
  def reason({:purge_failed, posix, _path}), do: posix
  def reason({:legacy_purge_failed, posix, _path}), do: posix
  def reason({:artifact_not_removed, kind, posix}), do: {kind, posix}
  def reason({:cache_key_unavailable, posix}), do: {:cache_key_unavailable, posix}
  def reason({:artifact_plan_unreadable, _cause}), do: :artifact_plan_unreadable
  def reason({:checkpoint_pointers_not_cleared, _cause}), do: :checkpoint_pointers_not_cleared
  def reason(posix) when is_atom(posix), do: posix
  # Anything else may carry a path or a row: the log has it, a report does not.
  def reason(_other), do: :purge_failed

  # The legacy purge runs here, not in `handle_continue/2`: this process starts before
  # the HTTP endpoint, so the record is there by the time the API answers.
  @impl true
  def init(opts) do
    ensure_key()

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      legacy_purged?: legacy_purged?(guarded(&purge_legacy/0))
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    guarded(&sweep/0)
    schedule(state)
    {:noreply, state}
  end

  # A purge of the old layout that failed at boot (a file it could not remove) is tried
  # again on every tick until it has gone through.
  @impl true
  def handle_info(:sweep, state) do
    ensure_key()
    legacy_purged? = state.legacy_purged? or legacy_purged?(guarded(&purge_legacy/0))
    guarded(&sweep/0)
    state = %{state | legacy_purged?: legacy_purged?}
    schedule(state)
    {:noreply, state}
  end

  # The cache cannot read or write an entry without its key. Without one every lookup is a
  # miss and every write fails quietly, so the operator is told here, once per tick.
  defp ensure_key do
    case guarded(&FileCache.ensure_key/0) do
      :ok ->
        :ok

      other ->
        Logger.error(
          "[FileCache] the cache key is unavailable (#{inspect(reason(other_cause(other)))}); " <>
            "embeddings are not cached until it can be created at #{FileCache.key_path()}"
        )

        :error
    end
  end

  defp other_cause({:error, cause}), do: cause
  defp other_cause(_), do: :cache_key_unavailable

  defp legacy_purged?({:ok, _removed}), do: true
  defp legacy_purged?(_failed), do: false

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval_ms)

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.error("[FileCache] maintenance failed: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.error("[FileCache] maintenance failed: #{inspect(reason)}")
      :error
  end

  # Best effort: the audit trail must not turn a finished removal into a failure.
  defp record(kind, target, removed) do
    Audit.log(kind,
      principal: "system:file-cache",
      target_uri: target,
      metadata: %{files: removed.files, bytes: removed.bytes}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
