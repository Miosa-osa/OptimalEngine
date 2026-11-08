defmodule OptimalEngine.Test.MigrationReplay do
  @moduledoc false
  # Runs a migration's statements again on the Engine's store, as a test of
  # what the migration does to rows. On PostgreSQL the schema is derived from
  # the migrations, so its schema statements (a table or index the derived
  # schema already has) are left out and every other statement runs.

  alias OptimalEngine.Store

  @schema_change {:unsupported, "schema change outside the migrations"}

  @doc "Each statement's result, `{label, result}`, schema statements on PostgreSQL left out."
  def run(statements) do
    postgres? = Store.selected?(OptimalEngine.Store.Postgres)

    Enum.flat_map(statements, fn {label, sql} ->
      case Store.raw_query(sql, []) do
        {:error, @schema_change} when postgres? -> []
        result -> [{label, result}]
      end
    end)
  end

  @doc "Runs the statements and fails on the first error."
  def run!(statements) do
    for {label, result} <- run(statements) do
      case result do
        {:ok, _} -> :ok
        {:error, reason} -> raise "#{label}: #{inspect(reason)}"
      end
    end

    :ok
  end
end
