defmodule OptimalEngine.Storage.BackupOrderTest do
  @moduledoc """
  "The newest backup" is decided by a timestamp kept to the second, and rows
  written in the same second are told apart by their insertion order: SQLite's
  rowid, and on PostgreSQL (which has none) the row's id, which is made in
  creation order (`OptimalEngine.Store.Catalog.ordered_id/1`). A random id there
  picked any of them: the storage audit, a restore's checksum or the offsite
  list could take an older backup for the newest.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Backup, Store}
  alias OptimalEngine.Store.Catalog

  @same_second "2099-01-01 00:00:00"

  setup do
    previous_dir = Application.get_env(:optimal_engine, :backup_dir)
    tmp = Path.join(System.tmp_dir!(), "backup-order-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_engine, :backup_dir, tmp)

    on_exit(fn ->
      {:ok, _} = Store.raw_query("DELETE FROM backup_records WHERE created_at = ?1", [@same_second])

      case previous_dir do
        nil -> Application.delete_env(:optimal_engine, :backup_dir)
        dir -> Application.put_env(:optimal_engine, :backup_dir, dir)
      end

      File.rm_rf(tmp)
    end)

    :ok
  end

  # `count` backups, one after another, then all stamped with the same second.
  defp backups_in_one_second(count) do
    infos =
      for i <- 1..count do
        {:ok, target} = Backup.resolve_target("order-#{i}.db")
        {:ok, info} = Backup.create(target)
        info
      end

    {:ok, _} =
      Store.raw_query(
        "UPDATE backup_records SET created_at = ?1, verified_at = ?1 WHERE id IN (SELECT value FROM json_each(?2))",
        [@same_second, Jason.encode!(Enum.map(infos, & &1.id))]
      )

    infos
  end

  test "of backups verified in the same second, the storage audit takes the last one made" do
    infos = backups_in_one_second(5)
    newest = List.last(infos)

    detail =
      OptimalEngine.StorageAudit.run().checks
      |> Enum.find(&(&1.name == "verified_backup"))
      |> Map.get(:detail)

    assert %{path: path, copies: ["local"]} = detail
    assert path == newest.target
  end

  test "ids are made in creation order, so a tie on the second goes to the newer row" do
    ids = for _ <- 1..500, do: Catalog.ordered_id("x_")
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)

    # On either store, a tie on the second ordered by id is the order the rows
    # were made in, as SQLite's rowid gives it.
    infos = backups_in_one_second(3)
    assert Enum.map(infos, & &1.id) == Enum.sort(Enum.map(infos, & &1.id))

    {:ok, rows} =
      Store.raw_query(
        "SELECT id FROM backup_records WHERE created_at = ?1 ORDER BY created_at DESC, id DESC",
        [@same_second]
      )

    assert List.flatten(rows) == infos |> Enum.map(& &1.id) |> Enum.reverse()
  end

  test "ids made by many processes at once still sort in the order they were made" do
    # A shared counter taken before and after each id: an id whose "after" is
    # below another's "before" was certainly made first.
    ticket = :atomics.new(1, [])

    made =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for _ <- 1..200 do
            before = :atomics.add_get(ticket, 1, 1)
            id = Catalog.ordered_id("p_")
            {before, id, :atomics.add_get(ticket, 1, 1)}
          end
        end)
      end)
      |> Enum.flat_map(&Task.await(&1, 30_000))

    ids = Enum.map(made, &elem(&1, 1))
    assert ids == Enum.uniq(ids)

    by_after = Enum.sort_by(made, &elem(&1, 2))

    for {_b, id, done} <- by_after,
        {before, later, _a} <- made,
        before > done do
      assert id < later, "#{id} was made before #{later} but sorts after it"
    end
  end

  test "the newest checksum in a SQLite catalog file is the last one made in its second" do
    path = Path.join(System.tmp_dir!(), "catalog-order-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> File.rm(path) end)
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "CREATE TABLE backup_records (id TEXT PRIMARY KEY, storage_uri TEXT, status TEXT, checksum_sha256 TEXT, created_at TEXT)"
      )

    # Ids that sort against the order they were made: only rowid tells them apart.
    for {id, sum} <- [{"z_first", "sum-1"}, {"m_second", "sum-2"}, {"a_third", "sum-3"}] do
      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "INSERT INTO backup_records VALUES ('#{id}', '/data/x.db', 'completed', '#{sum}', '#{@same_second}')"
        )
    end

    :ok = Exqlite.Sqlite3.close(db)
    assert Backup.catalog_checksum_in(path, "/data/x.db") == {:ok, "sum-3"}
  end
end
