defmodule OptimalEngine.TestSupport.KeyGrantsBackfill do
  @moduledoc """
  Runs the key grant backfill (migration 85) on a private database that holds
  only `api_keys`, as the upgrade runs it, so a test sees what the migration does
  to the rows it is given and to nothing else: not the other keys of the shared
  store, and not the SQL census, which traces the Store. Test support only.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations

  @version 85

  @typedoc "A key as the table holds it: `scopes` and `metadata` are the stored JSON text."
  @type row :: %{
          required(:id) => String.t(),
          required(:scopes) => String.t(),
          required(:metadata) => String.t(),
          optional(:revoked_at) => String.t() | nil
        }

  @doc "The migration, or a failed assertion when this Engine has none."
  @spec migration() :: Migrations.migration()
  def migration do
    case Enum.find(Migrations.all(), &(elem(&1, 0) == @version)) do
      nil -> ExUnit.Assertions.flunk("there is no migration #{@version}, the key grant backfill")
      migration -> migration
    end
  end

  @doc """
  Applies the migration to `rows` and returns the stored `metadata` of each key
  by id, with the log the runner wrote. With `again: true` the migration's
  statements are run a second time on the result, which must change nothing.
  """
  @spec run([row()], keyword()) :: %{metadata: %{String.t() => String.t()}, log: String.t()}
  def run(rows, opts \\ []) do
    {version, _description, statements} = migration = migration()

    {:ok, db} = Exqlite.Sqlite3.open(":memory:")

    try do
      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys = OFF")

      {30, _description, [{"api_keys", create} | _]} =
        Enum.find(Migrations.all(), &(elem(&1, 0) == 30))

      :ok = Exqlite.Sqlite3.execute(db, create)
      for row <- rows, do: insert(db, row)

      log =
        ExUnit.CaptureLog.capture_log(fn -> :ok = Migrations.run(db, [migration]) end)

      once = metadata(db)

      if opts[:again] do
        for {_label, sql} <- statements, do: :ok = Exqlite.Sqlite3.execute(db, sql)
        ExUnit.Assertions.assert(metadata(db) == once, "migration #{version} changed a row twice")
      end

      %{metadata: once, log: log}
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  @doc """
  The upgrade for one key of the shared store: the migration runs on a copy of
  its row and the result is written back, so no other key of the store is
  touched.
  """
  @spec apply_to_stored_key(String.t()) :: :ok
  def apply_to_stored_key(id) do
    {:ok, [[scopes, revoked_at, metadata]]} =
      Store.raw_query(
        "SELECT scopes, revoked_at, metadata FROM api_keys WHERE id = ?1",
        [id]
      )

    %{metadata: %{^id => migrated}} =
      run([%{id: id, scopes: scopes, revoked_at: revoked_at, metadata: metadata}])

    {:ok, _} = Store.raw_query("UPDATE api_keys SET metadata = ?2 WHERE id = ?1", [id, migrated])
    :ok
  end

  defp insert(db, row) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        """
        INSERT INTO api_keys (id, tenant_id, hashed_secret, prefix, name, scopes, revoked_at, metadata)
        VALUES (?1, 'default', 'hash', 'prefix00', ?1, ?2, ?3, ?4)
        """
      )

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, [row.id, row.scopes, row[:revoked_at], row.metadata])
      :done = Exqlite.Sqlite3.step(db, stmt)
    after
      Exqlite.Sqlite3.release(db, stmt)
    end
  end

  defp metadata(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT id, metadata FROM api_keys")

    try do
      stmt |> collect(db, []) |> Map.new()
    after
      Exqlite.Sqlite3.release(db, stmt)
    end
  end

  defp collect(stmt, db, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [id, metadata]} -> collect(stmt, db, [{id, metadata} | acc])
      :done -> acc
    end
  end
end
