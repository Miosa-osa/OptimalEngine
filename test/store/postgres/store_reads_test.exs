defmodule OptimalEngine.Store.PostgresReadsTest do
  @moduledoc """
  The read side of the PostgreSQL store, against the embedded SQLite store:
  the same rows read back as the same contexts, signals, node listings and
  counts.

  The SQLite rows go through `OptimalEngine.Store` (the embedded store this
  build runs). The PostgreSQL rows are written with the statement the SQLite
  store uses, through the dialect, until the write path lands.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Context, Signal, Store}
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  @insert """
  INSERT INTO contexts (
    id, uri, type, path, title,
    l0_abstract, l1_overview, content,
    mode, genre, signal_type, format, structure,
    node, sn_ratio, entities,
    created_at, modified_at, valid_from, valid_until, supersedes,
    routed_to, metadata, workspace_id, tenant_id
  ) VALUES (
    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
    ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24,
    COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = ?24), 'default')
  )
  """

  @columns ~w(id uri type path title l0_abstract l1_overview content mode genre signal_type
              format structure node sn_ratio entities created_at modified_at valid_from
              valid_until supersedes routed_to metadata workspace_id)a

  setup_all do
    schema = PostgresStore.unique_schema()
    start_supervised!({PgStore, PostgresStore.options(schema)})
    on_exit(fn -> PostgresStore.drop_schema(schema) end)

    run = System.unique_integer([:positive])
    node = "pg-reads-#{run}"

    contexts = [
      context("pg-r-#{run}-1", node, :resource, ~U[2026-10-01 09:00:00Z], ["alice", "bob"]),
      context("pg-r-#{run}-2", node, :memory, ~U[2026-10-03 09:00:00Z], []),
      context("pg-r-#{run}-3", node, :resource, nil, ["carol"]),
      signal_context("pg-r-#{run}-4", node, ~U[2026-10-02 09:00:00Z])
    ]

    for ctx <- contexts do
      :ok = Store.insert_context(ctx)
      row = Context.to_row(ctx)
      {:ok, _} = PgStore.raw_query(@insert, Enum.map(@columns, &Map.fetch!(row, &1)))
    end

    %{contexts: contexts, node: node}
  end

  defp context(id, node, type, modified_at, entities) do
    %Context{
      id: id,
      uri: "optimal://nodes/#{node}/#{id}",
      type: type,
      path: "#{node}/#{id}.md",
      title: "Title #{id}",
      content: "Body of #{id}, with 'quotes' and unicode é.",
      l0_abstract: "abstract",
      l1_overview: "overview",
      node: node,
      sn_ratio: 0.75,
      entities: entities,
      created_at: ~U[2026-09-30 08:00:00Z],
      modified_at: modified_at,
      routed_to: [node, "elsewhere"],
      metadata: %{"source" => "test", "n" => 3},
      workspace_id: "default"
    }
  end

  defp signal_context(id, node, modified_at) do
    signal = %Signal{
      id: id,
      path: "#{node}/#{id}.md",
      title: "Signal #{id}",
      mode: :linguistic,
      genre: "decision-log",
      type: :decide,
      format: :markdown,
      structure: "adr",
      created_at: ~U[2026-09-30 08:00:00Z],
      modified_at: modified_at,
      node: node,
      sn_ratio: 0.9,
      entities: ["dave"],
      l0_summary: "summary",
      l1_description: "description",
      content: "signal body",
      routed_to: [node]
    }

    %{Context.from_signal(signal) | workspace_id: "default"}
  end

  test "a context reads back the same from both stores", %{contexts: contexts} do
    for %{id: id} <- contexts do
      assert {:ok, sqlite} = Store.get_context(id)
      assert {:ok, postgres} = PgStore.get_context(id)
      assert postgres == sqlite
    end

    assert {:error, :not_found} = PgStore.get_context("pg-r-missing")
  end

  test "a signal reads back the same from both stores", %{contexts: contexts} do
    id = List.last(contexts).id

    assert {:ok, %Signal{} = sqlite} = Store.get_signal(id)
    assert {:ok, ^sqlite} = PgStore.get_signal(id)
  end

  test "a node lists the same contexts in the same order", %{node: node} do
    {:ok, sqlite} = Store.get_by_node(node)
    {:ok, postgres} = PgStore.get_by_node(node)

    assert Enum.map(postgres, & &1.id) == Enum.map(sqlite, & &1.id)
    assert postgres == sqlite
    assert List.last(postgres).modified_at == nil

    {:ok, sqlite_resources} = Store.get_by_node(node, type: :resource)
    {:ok, postgres_resources} = PgStore.get_by_node(node, type: :resource)
    assert postgres_resources == sqlite_resources
    assert length(postgres_resources) == 2
  end

  test "stats count the same rows and report no cache" do
    assert {:ok, stats} = PgStore.stats()
    assert stats["total_contexts"] == 4
    assert stats["total_resources"] == 2
    assert stats["total_signals"] == 1
    assert stats["cache_size"] == 0

    assert Map.keys(stats) |> Enum.sort() ==
             Store.stats() |> elem(1) |> Map.keys() |> Enum.sort()
  end

  test "evict_cached has nothing to drop" do
    assert :ok = PgStore.evict_cached(["anything"])
  end

  test "the schema report lists what PostgreSQL did not get" do
    report = PgStore.schema_report()
    assert is_binary(report.fingerprint)
    assert Enum.any?(report.skipped, &(&1.name == "contexts_fts"))
  end
end
