defmodule OptimalEngine.Knowledge.Hydration do
  @moduledoc """
  Rebuilds the triple store from the durable `graph_edges` table.

  An in-memory backend (ETS, Mnesia RAM copies) starts empty, so every edge is
  loaded on every boot. A persistent backend (RocksDB) keeps what it already
  holds: after a full load it records the highest edge id it took in a marker
  file inside its own data directory, and the next boot loads only the edges
  after it. The marker lives and dies with the data it describes, so a wiped
  or replaced store directory loads in full again. A marker past the newest
  edge means the database went backwards (a restore), and the store is loaded
  in full rather than skipping edges.

  Edges written while the Engine runs reach the store as they are created;
  hydration is the catch-up for everything else.
  """

  alias OptimalEngine.Graph
  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.Store

  @marker "OPTIMAL_HYDRATED_THROUGH_EDGE_ID"

  @type result :: %{
          loaded: non_neg_integer(),
          after_edge_id: non_neg_integer(),
          through_edge_id: non_neg_integer()
        }

  @doc "Loads the edges `store` does not hold yet. See the moduledoc."
  @spec run(GenServer.server(), module(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(store, backend, backend_opts) do
    with {:ok, newest} <- newest_edge_id() do
      after_id = starting_point(backend, backend_opts, newest)

      with {:ok, loaded} <- Graph.hydrate_triple_store(store, after_id: after_id) do
        if persistent?(backend), do: write_marker(backend_opts, newest)
        {:ok, %{loaded: loaded, after_edge_id: after_id, through_edge_id: newest}}
      end
    end
  end

  @doc "Where a persistent store's marker is kept: inside its data directory."
  @spec marker_path(keyword()) :: String.t()
  def marker_path(backend_opts), do: Path.join(Keyword.fetch!(backend_opts, :path), @marker)

  defp persistent?(backend), do: backend == Backend.RocksDB

  defp starting_point(backend, backend_opts, newest) do
    with true <- persistent?(backend),
         {:ok, text} <- File.read(marker_path(backend_opts)),
         {marked, ""} <- text |> String.trim() |> Integer.parse(),
         true <- marked >= 0 and marked <= newest do
      marked
    else
      _full_load -> 0
    end
  end

  defp write_marker(backend_opts, newest) do
    path = marker_path(backend_opts)
    partial = path <> ".part"

    with :ok <- File.write(partial, Integer.to_string(newest)),
         do: File.rename(partial, path)
  end

  defp newest_edge_id do
    case Store.raw_query("SELECT COALESCE(MAX(id), 0) FROM graph_edges", []) do
      {:ok, [[newest]]} when is_integer(newest) -> {:ok, newest}
      {:ok, _other} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end
end
