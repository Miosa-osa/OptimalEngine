defmodule OptimalEngine.Store.FailingMigration do
  @moduledoc """
  A migration that fails on purpose, for the upgrade rollback drill (WO-39).

  An upgrade that boots a release whose migration fails must leave the store as
  it was, so the previous release can start on it again. This migration
  exercises that path: it creates a table, writes a row and changes existing
  data, and then fails. `OptimalEngine.Store.Migrations.run/2` runs each
  migration in one transaction, so none of it survives the failure, and the
  release never answers because its store cannot open.

  It exists only in a test release built with `OPTIMAL_BUILD_FAILING_MIGRATION=1`
  (`scripts/build-failing-migration-release.sh`). Three guards keep it out of
  every other build:

    * without the build flag, `migrations/1` is compiled to return nothing;
    * with the flag, the build's version must end in `-failing-migration`
      (`mix.exs` appends it), or compilation stops;
    * at run time the migration is offered only while the running
      application's version ends in `-failing-migration`.

  The flag is read at compile time, so a build that sets or clears it must
  compile with `--force`, as `deploy/Dockerfile.engine` and the build script do.
  """

  alias OptimalEngine.Store.Migrations

  @flag "OPTIMAL_BUILD_FAILING_MIGRATION"
  @suffix "-failing-migration"
  @enabled System.get_env(@flag) == "1"

  if @enabled do
    @build_version to_string(Mix.Project.config()[:version])

    unless String.ends_with?(@build_version, @suffix) do
      raise CompileError,
        description:
          "#{@flag}=1 builds a test release whose migration fails on purpose; " <>
            "its version must end in #{@suffix}, and #{@build_version} does not"
    end
  end

  @doc "The suffix a failing-migration test release carries in its version."
  @spec suffix() :: String.t()
  def suffix, do: @suffix

  @doc """
  What to append after `migrations` (the real ones): the failing migration in a
  failing-migration test release, nothing in any other build.
  """
  @spec migrations([Migrations.migration()]) :: [Migrations.migration()]
  if @enabled do
    def migrations(migrations), do: if(release?(), do: [migration(migrations)], else: [])
  else
    def migrations(_migrations), do: []
  end

  @doc """
  The failing migration, numbered after the last of `migrations`.

  It creates `failing_migration_probe`, writes a row to it, renames every
  tenant, and then inserts a NULL into a NOT NULL column, which fails.
  """
  @spec migration([Migrations.migration()]) :: Migrations.migration()
  def migration(migrations) do
    {last, _description, _statements} = List.last(migrations)

    {last + 1, "fails on purpose (failing-migration test release)",
     [
       {"failing_migration_probe",
        "CREATE TABLE failing_migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"},
       {"failing_migration_write",
        "INSERT INTO failing_migration_probe (note) VALUES ('written before the failure')"},
       {"failing_migration_update",
        "UPDATE tenants SET name = name || ' (changed by the failing migration)'"},
       {"failing_migration_fails", "INSERT INTO failing_migration_probe (note) VALUES (NULL)"}
     ]}
  end

  @doc "True when the running application is a failing-migration test release."
  @spec release?() :: boolean()
  def release?,
    do: String.ends_with?(OptimalEngine.Version.application_version(), @suffix)
end
