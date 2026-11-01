defmodule OptimalEngine.Knowledge.DefaultStore do
  @moduledoc """
  Starts and hydrates the singleton default Knowledge.Store.

  This GenServer starts a named `Knowledge.Store` (store_id = "default") under
  the Knowledge.Registry, then asynchronously loads all rows from the SQLite
  `graph_edges` table so the in-memory triple store mirrors durable state after a
  restart.

  The hydration is fire-and-forget: failures are logged but never crash the
  supervisor. New edges written after startup are fed synchronously via
  `Graph.maybe_feed_triple_store/4` (called from `Graph.create_edges_for_context`
  and `Graph.assert_edge`).

  Edges that leave or move by any other path (an erasure, a replicated delete,
  a move to another workspace, a rebuild) are recorded by triggers and applied
  here (`Knowledge.Mirror`): once the store is loaded, and then every 5
  seconds. `drain/0` applies them at once, for a caller that must not return
  while a removed edge is still in the store.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.Knowledge.Hydration
  alias OptimalEngine.Knowledge.Mirror
  alias OptimalEngine.Knowledge.Store, as: KnowledgeStore

  @store_id "default"
  @hydration_delay_ms 10_000
  @drain_interval_ms 5_000
  @drain_timeout_ms 120_000
  @backend_modules %{
    "ets" => OptimalEngine.Knowledge.Backend.ETS,
    "mnesia" => OptimalEngine.Knowledge.Backend.Mnesia,
    "rocksdb" => OptimalEngine.Knowledge.Backend.RocksDB
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {backend, backend_opts} = configured_backend()

    # Before the store opens: the triggers that record edge changes, and a
    # persistent store emptied when it cannot be trusted to hold only live
    # edges. A store already running has followed the changes all along.
    mirror =
      case Registry.lookup(OptimalEngine.Knowledge.Registry, @store_id) do
        [] ->
          Mirror.prepare(backend, backend_opts)

        _running ->
          _ = Mirror.install()
          :kept
      end

    hydration = %{backend: backend, backend_opts: backend_opts, mirror: mirror}

    # Start the underlying Knowledge.Store registered under the default store_id.
    case KnowledgeStore.start_link(
           store_id: @store_id,
           backend: backend,
           backend_opts: backend_opts
         ) do
      {:ok, store_pid} ->
        # Hydrate asynchronously so supervision tree startup is not blocked.
        start_hydration(store_pid, hydration)
        {:ok, %{store_pid: store_pid, hydrated: false}}

      {:error, {:already_started, store_pid}} ->
        start_hydration(store_pid, hydration)
        {:ok, %{store_pid: store_pid, hydrated: false}}

      {:error, reason} ->
        Logger.warning("[DefaultStore] Could not start Knowledge.Store: #{inspect(reason)}")
        # Still start this GenServer so the supervisor tree doesn't fail — the
        # triple store is a secondary index and its absence is non-fatal.
        {:ok, %{store_pid: nil, hydrated: false}}
    end
  end

  @doc """
  Applies the edge changes recorded so far to the default store and returns
  when they are applied. An Engine without a running default store keeps them
  for its next boot.
  """
  @spec drain() :: :ok | {:error, term()}
  def drain do
    if GenServer.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :drain, @drain_timeout_ms),
      else: :ok
  catch
    :exit, reason -> {:error, {:drain_failed, reason}}
  end

  # Until the load is done the changes are applied and kept, and applied again
  # once it is: a page loaded after a change could bring its triple back.
  @impl true
  def handle_call(:drain, _from, state),
    do: {:reply, drain_changes(state, keep: not state.hydrated), state}

  @impl true
  def handle_info(:hydrated, state) do
    _ = drain_changes(state, [])
    schedule_drain()
    {:noreply, %{state | hydrated: true}}
  end

  def handle_info(:drain, state) do
    _ = drain_changes(state, [])
    schedule_drain()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The backend module the default store runs on, decided the same way the store
  is started: RocksDB requested on a build without the `:rocksdb` library runs
  on ETS.
  """
  @spec backend() :: module()
  def backend, do: elem(resolve_backend(), 0)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp start_hydration(store_pid, hydration) do
    owner = self()

    Task.start(fn ->
      Process.sleep(@hydration_delay_ms)
      hydrate(owner, store_pid, hydration)
    end)
  end

  defp schedule_drain, do: Process.send_after(self(), :drain, @drain_interval_ms)

  defp drain_changes(%{store_pid: nil}, _opts), do: :ok

  defp drain_changes(%{store_pid: store_pid}, opts) do
    case Mirror.drain(store_pid, opts) do
      {:ok, _applied} ->
        :ok

      # A busy Store is expected now and then; the next drain applies them.
      {:error, {:store_unavailable, _}} = error ->
        Logger.debug("[DefaultStore] Store busy; graph edge changes wait for the next drain")
        error

      {:error, reason} = error ->
        Logger.warning("[DefaultStore] Could not apply graph edge changes: #{inspect(reason)}")
        error
    end
  end

  defp configured_backend do
    {backend, backend_opts, {level, message}} = resolve_backend()
    Logger.log(level, "[DefaultStore] " <> message)
    {backend, backend_opts}
  end

  defp resolve_backend do
    config = Application.get_env(:optimal_engine, :knowledge, [])

    requested =
      config
      |> Keyword.get(:backend, "ets")
      |> to_string()
      |> String.downcase()

    backend = Map.get(@backend_modules, requested, OptimalEngine.Knowledge.Backend.ETS)

    cond do
      requested == "rocksdb" and not Code.ensure_loaded?(:rocksdb) ->
        {OptimalEngine.Knowledge.Backend.ETS, [],
         {:warning,
          "OPTIMAL_KNOWLEDGE_BACKEND=rocksdb requested but :rocksdb is unavailable; falling back to ETS"}}

      requested == "rocksdb" ->
        path =
          Keyword.get(config, :rocksdb_path, Path.join(File.cwd!(), ".optimal/knowledge-rocksdb"))

        {backend, [path: path], {:info, "Knowledge backend: RocksDB at #{path}"}}

      requested == "mnesia" ->
        {backend, [copies: :ram_copies], {:info, "Knowledge backend: Mnesia"}}

      true ->
        {backend, [], {:info, "Knowledge backend: ETS"}}
    end
  end

  defp hydrate(owner, store_pid, %{backend: backend, backend_opts: backend_opts} = hydration) do
    store_name = {:via, Registry, {OptimalEngine.Knowledge.Registry, @store_id}}

    target =
      if is_pid(store_pid) and Process.alive?(store_pid),
        do: store_pid,
        else: store_name

    # The changes recorded before the load began are in the edges it reads.
    cut = Mirror.newest_change()

    case Hydration.run(target, backend, backend_opts) do
      {:ok, %{loaded: count, after_edge_id: after_id}} ->
        Logger.info(
          "[DefaultStore] Triple store hydrated with #{count} edges from SQLite (after edge #{after_id})"
        )

        # A store loaded in full from empty already holds the result of every
        # change before the cut, and a persistent one follows the rest.
        if hydration.mirror == :empty do
          _ = Mirror.discard_through(cut)
          if backend == Backend.RocksDB, do: Mirror.mark_following(backend_opts)
        end

      {:error, reason} ->
        Logger.warning("[DefaultStore] Triple store hydration failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("[DefaultStore] Triple store hydration exception: #{inspect(error)}")
  after
    send(owner, :hydrated)
  end
end
