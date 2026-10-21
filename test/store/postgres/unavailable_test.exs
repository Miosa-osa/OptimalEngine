defmodule OptimalEngine.Store.Postgres.UnavailableTest do
  @moduledoc """
  What the PostgreSQL store does not do yet is listed, reported by the
  provider inventory, and refused: a database that holds data of such a
  feature does not get a running store.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.Postgres, as: Provider
  alias OptimalEngine.Store.Postgres.{Connection, Schema}
  alias OptimalEngine.Test.PostgresStore

  @features ~w(replication app_data_collections full_text_search sqlite_json_functions
               date_time_arithmetic sqlite_catalog rowid sqlite_functions replace_writes
               runtime_schema_and_transactions)

  # Where the PostgreSQL store and its dialect refuse a statement or a feature.
  @refusing ~w(lib/optimal_engine/store/dialect.ex lib/optimal_engine/store/postgres/connection.ex
               lib/optimal_engine/store/postgres.ex lib/optimal_engine/sync.ex
               lib/optimal_engine/app_data/collections.ex lib/optimal_engine/retrieval/search.ex)

  test "the inventory lists every feature that is not on PostgreSQL, with how it is refused" do
    unavailable = Provider.unavailable()

    assert Enum.map(unavailable, & &1.feature) == @features

    for item <- unavailable do
      assert is_binary(item.reason) and item.reason != ""
      assert item.refused_as != []
    end

    assert {:ok, provider} = OptimalEngine.Storage.Providers.get("postgres")
    assert Enum.map(provider.unavailable, & &1.feature) == @features
  end

  test "every name the inventory refuses with is a refusal the dialect or the store makes" do
    dialect = MapSet.new(OptimalEngine.Store.Dialect.refusals(), &elem(&1, 0))
    sources = Enum.map_join(@refusing, &File.read!/1)

    unknown =
      for %{refused_as: names} <- Provider.unavailable(),
          name <- names,
          not MapSet.member?(dialect, name),
          not String.contains?(sources, ~s({:unsupported, "#{name})),
          do: name

    assert unknown == []
  end

  test "every refusal the dialect makes by name is in the inventory" do
    listed =
      for %{refused_as: names} <- Provider.unavailable(),
          name <- names,
          into: MapSet.new(),
          do: name

    missing =
      for {name, _reason} <- OptimalEngine.Store.Dialect.refusals(),
          not MapSet.member?(listed, name),
          do: name

    assert missing == []
  end

  describe "a store whose database holds data of a feature it cannot run" do
    @describetag :postgres

    setup do
      schema = PostgresStore.unique_schema()
      pool = PostgresStore.start_pool(schema)
      {:ok, _} = Schema.sync(pool, schema: schema)
      on_exit(fn -> PostgresStore.drop_schema(schema) end)
      %{schema: schema, pool: pool}
    end

    test "starts when there is none", %{schema: schema} do
      assert {:ok, store} = start_store(schema)
      GenServer.stop(store)
      released()
    end

    test "does not start with replication enabled", %{schema: schema, pool: pool} do
      {:ok, _} =
        Connection.query(
          pool,
          "INSERT INTO sync_workspaces (tenant_id, workspace_id, enabled_by) VALUES ('default', 'default', 'test')"
        )

      assert {:error, {:postgres_store_failed, {:unsupported_in_use, ["replication"]}}} =
               start_store(schema)

      released()
    end

    test "does not start with an app data collection", %{schema: schema, pool: pool} do
      {:ok, plan} = Schema.derive()
      table = Enum.find(plan.tables, &(&1.name == "data_collections"))

      required =
        for column <- table.columns,
            (column.not_null or column.name in table.primary_key) and is_nil(column.default) and
              not column.identity,
            into: %{} do
          {column.name, if(column.type == "BIGINT", do: 1, else: "#{column.name}-1")}
        end

      row =
        Map.merge(required, %{
          "tenant_id" => "default",
          "workspace_id" => "default",
          "schema" => "{}"
        })

      names = Map.keys(row)
      marks = Enum.map_join(1..length(names), ", ", &"?#{&1}")

      {:ok, _} =
        Connection.query(
          pool,
          "INSERT INTO data_collections (#{Enum.join(names, ", ")}) VALUES (#{marks})",
          Enum.map(names, &Map.fetch!(row, &1))
        )

      assert {:error, {:postgres_store_failed, {:unsupported_in_use, ["app_data_collections"]}}} =
               start_store(schema)

      released()
    end
  end

  # Not linked, so a store that refuses to start does not take the test down.
  defp start_store(schema),
    do: GenServer.start(OptimalEngine.Store.Postgres, PostgresStore.options(schema))

  # The store's pool is named; the next test waits until it is gone.
  defp released do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Process.whereis(OptimalEngine.Store.Postgres.Pool),
        do: {:cont, Process.sleep(20)},
        else: {:halt, :ok}
    end)
  end
end
