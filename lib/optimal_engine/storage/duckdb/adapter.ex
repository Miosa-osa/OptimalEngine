defmodule OptimalEngine.Storage.DuckDB.Adapter do
  @moduledoc """
  Storage provider adapter for DuckDB and Parquet.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `duckdb` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: the executable
  answered a query against a writable analytics path.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.DuckDB

  @capabilities ~w(analytics columnar lakehouse)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "duckdb"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "DuckDB and Parquet",
      kind: "embedded",
      role: "projection",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(query copy_parquet read_parquet),
      protocol: "the duckdb executable, one process per query, JSON rows",
      durability:
        "analytical projections under OPTIMAL_ANALYTICS_PATH, rebuilt from the canonical stores"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = DuckDB.configured?()

    health =
      cond do
        not configured -> :not_configured
        Keyword.get(opts, :probe, false) -> health(opts)
        true -> :unknown
      end

    %{
      id: id(),
      configured: configured,
      health: Atom.to_string(health),
      lifecycle_state: lifecycle_state(configured, health),
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      executable_present: System.find_executable(DuckDB.executable()) != nil
    }
  end

  @doc "Provider health from one query. Never raises."
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    case DuckDB.health(opts) do
      :healthy -> :healthy
      :not_configured -> :not_configured
      :not_installed -> :not_installed
      _ -> :unreachable
    end
  end

  @doc "The full proof: a Parquet file written under the analytics path and read back."
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if DuckDB.configured?() do
      with {:ok, evidence} <- DuckDB.round_trip(opts) do
        {:ok, Map.put(evidence, :provider, id())}
      end
    else
      {:error, :not_configured}
    end
  end

  defp lifecycle_state(false, _health), do: "not_configured"
  defp lifecycle_state(true, :healthy), do: "available"
  defp lifecycle_state(true, :unknown), do: "configured_unverified"
  defp lifecycle_state(true, _health), do: "unavailable"
end
