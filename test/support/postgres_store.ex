defmodule OptimalEngine.Test.PostgresStore do
  @moduledoc false
  # The PostgreSQL database the `:postgres` tests use, named by
  # OPTIMAL_TEST_POSTGRES_URL. Without it those tests are excluded
  # (test/test_helper.exs). Every test module works in a schema of its own and
  # drops it when it finishes, so modules and checkouts never share tables.

  alias OptimalEngine.Store.Postgres.Connection

  @env "OPTIMAL_TEST_POSTGRES_URL"

  def env_name, do: @env

  def url, do: System.get_env(@env)

  def available?, do: url() not in [nil, ""]

  def unique_schema(prefix \\ "oe_test") do
    "#{prefix}_#{System.unique_integer([:positive])}_#{:rand.uniform(999_999)}"
  end

  @doc "Options for a store pool in `schema`."
  def options(schema, opts \\ []) do
    Keyword.merge([url: url(), schema: schema, pool_size: 4], opts)
  end

  @doc "Starts a pool in `schema` linked to the caller."
  def start_pool(schema, opts \\ []) do
    {:ok, pool} = Connection.start_link(options(schema, opts))
    pool
  end

  @doc "Drops `schema` and everything in it, on a connection of its own."
  def drop_schema(schema) do
    {:ok, config} = OptimalEngine.Storage.Postgres.config(url: url())

    options =
      config
      |> Map.take([:hostname, :port, :database, :username, :password, :ssl])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(options)

    try do
      Postgrex.query!(conn, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE), [])
    after
      GenServer.stop(conn)
    end

    :ok
  end
end
