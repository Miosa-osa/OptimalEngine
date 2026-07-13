defmodule OptimalEngine.StorageCatalog do
  @moduledoc """
  Read-only inventory of the engine's logical stores and indexes.

  This is the agent-facing map of where data lives. It exposes capabilities,
  backing technologies, and aggregate counts without exposing stored content,
  credentials, or raw database access.
  """

  alias OptimalEngine.Store

  @stores [
    %{
      id: "relational",
      purpose: "Canonical topology, identity, evidence, truth, and governance",
      technology: "SQLite",
      tables:
        ~w(organizations workspaces nodes source_packages contexts claims facts memory_objects episodes events decomposition_runs)
    },
    %{
      id: "full_text",
      purpose: "Exact text and phrase retrieval",
      technology: "SQLite FTS5",
      tables: ~w(contexts_fts memories_fts source_packages_fts)
    },
    %{
      id: "vector",
      purpose: "Semantic similarity retrieval",
      technology: "SQLite BLOB embeddings with cosine search",
      tables: ~w(vectors chunk_embeddings)
    },
    %{
      id: "graph",
      purpose: "Relationship traversal and multi-hop reasoning",
      technology: "RocksDB projection with SQLite lineage",
      tables: ~w(edges relationship_edges node_relationships)
    },
    %{
      id: "assets",
      purpose: "Files, audio, video, OCR, transcripts, and visual extraction",
      technology: "Filesystem plus SQLite metadata",
      tables:
        ~w(assets asset_extractions asset_transcripts asset_ocr_spans asset_visual_observations)
    },
    %{
      id: "cache",
      purpose: "Hot context and retrieval acceleration",
      technology: "ETS and filesystem cache",
      tables: []
    },
    %{
      id: "jobs",
      purpose: "Durable background work, leases, retries, and dead letters",
      technology: "SQLite",
      tables: ~w(jobs dead_letter_jobs)
    },
    %{
      id: "metrics",
      purpose: "Live and historical operational measurements",
      technology: "Telemetry, Prometheus exposition, and SQLite history",
      tables: ~w(metric_samples)
    },
    %{
      id: "backups",
      purpose: "Backup inventory, verification, retention, and offsite status",
      technology: "SQLite catalog plus backup files",
      tables: ~w(backup_records)
    },
    %{
      id: "models",
      purpose: "Governed training examples, adaptation runs, and versioned model adapters",
      technology: "SQLite metadata plus trainer-neutral artifact storage",
      tables:
        ~w(training_examples training_runs model_adapters model_call_operations model_call_runs)
    },
    %{
      id: "secrets",
      purpose: "API authentication and encrypted connector credentials",
      technology: "bcrypt hashes and encrypted credential envelopes",
      tables: ~w(api_keys connectors)
    }
  ]

  @spec list() :: [map()]
  def list do
    Enum.map(@stores, fn store ->
      results = Map.new(store.tables, &{&1, count(&1)})

      counts =
        Map.new(results, fn
          {table, {:ok, count}} -> {table, count}
          {table, {:error, _reason}} -> {table, nil}
        end)

      store
      |> Map.put(:status, status(results))
      |> Map.put(:row_count, counts |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.sum())
      |> Map.put(:table_counts, counts)
    end)
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Enum.find(list(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp count(table) do
    case Store.raw_query("SELECT COUNT(*) FROM \"#{table}\"", []) do
      {:ok, [[count]]} when is_integer(count) -> {:ok, count}
      {:error, reason} -> {:error, reason}
      result -> {:error, {:unexpected_result, result}}
    end
  end

  defp status(results) do
    if Enum.all?(results, fn {_table, result} -> match?({:ok, _count}, result) end),
      do: "available",
      else: "degraded"
  end
end
