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
  """

  use GenServer

  require Logger

  alias OptimalEngine.Knowledge.Hydration
  alias OptimalEngine.Knowledge.Store, as: KnowledgeStore

  @store_id "default"
  @hydration_delay_ms 10_000
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

    # Start the underlying Knowledge.Store registered under the default store_id.
    case KnowledgeStore.start_link(
           store_id: @store_id,
           backend: backend,
           backend_opts: backend_opts
         ) do
      {:ok, store_pid} ->
        # Hydrate asynchronously so supervision tree startup is not blocked.
        start_hydration(store_pid)
        {:ok, %{store_pid: store_pid}}

      {:error, {:already_started, store_pid}} ->
        start_hydration(store_pid)
        {:ok, %{store_pid: store_pid}}

      {:error, reason} ->
        Logger.warning("[DefaultStore] Could not start Knowledge.Store: #{inspect(reason)}")
        # Still start this GenServer so the supervisor tree doesn't fail — the
        # triple store is a secondary index and its absence is non-fatal.
        {:ok, %{store_pid: nil}}
    end
  end

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

  defp start_hydration(store_pid) do
    Task.start(fn ->
      Process.sleep(@hydration_delay_ms)
      hydrate(store_pid)
    end)
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

  defp hydrate(store_pid) do
    store_name = {:via, Registry, {OptimalEngine.Knowledge.Registry, @store_id}}

    target =
      if is_pid(store_pid) and Process.alive?(store_pid),
        do: store_pid,
        else: store_name

    {backend, backend_opts} = configured_backend()

    case Hydration.run(target, backend, backend_opts) do
      {:ok, %{loaded: count, after_edge_id: after_id}} ->
        Logger.info(
          "[DefaultStore] Triple store hydrated with #{count} edges from SQLite (after edge #{after_id})"
        )

      {:error, reason} ->
        Logger.warning("[DefaultStore] Triple store hydration failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("[DefaultStore] Triple store hydration exception: #{inspect(error)}")
  end
end
