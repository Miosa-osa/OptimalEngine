defmodule OptimalEngine.Store.FailingMigration do
  @moduledoc """
  Migrations that fail on purpose, for the upgrade rollback drill (WO-39).

  A release whose migration fails never answers, because its store cannot open.
  `OptimalEngine.Store.Migrations.run/2` runs each migration in one transaction,
  so the failed migration leaves no trace; migrations before it in the same boot
  stay applied. The two variants of the test release exercise both halves:

    * `OPTIMAL_BUILD_FAILING_MIGRATION=1`, version suffix `-failing-migration`:
      one migration, numbered after the last real one, that creates a table,
      writes a row, changes the sentinel tenant's row, and then fails. The store
      keeps its migration counter, schema and data.
    * `OPTIMAL_BUILD_FAILING_MIGRATION=2`, version suffix
      `-passing-then-failing-migration`: a migration that passes, then the
      failing one. The passing migration stays applied, so the store is left
      between releases and only a backup taken before the boot restores it.

  The sentinel tenant (`sentinel_tenant/0`) is a row a drill seeds so the
  failing migration has existing data to change; no other row is touched.

  Built only by `scripts/build-failing-migration-release.sh`. Three guards keep
  these migrations out of every other build:

    * without the build flag, `migrations/1` is compiled to return nothing;
    * with the flag, the build's version must end in the variant's suffix
      (`mix.exs` appends it), or compilation stops;
    * at run time they are offered only while the running application's
      version ends in `-failing-migration` (both suffixes do).

  `scripts/check_release_version.exs` refuses to release either. The flag is
  read at compile time, so a build that sets or clears it compiles with
  `--force`, as `deploy/Dockerfile.engine` and the build script do.
  """

  alias OptimalEngine.Store.Migrations

  @flag "OPTIMAL_BUILD_FAILING_MIGRATION"
  @suffix "-failing-migration"
  @sentinel_tenant "failing-migration-sentinel"

  @variant (case System.get_env(@flag) do
              "1" -> :failing
              "2" -> :passing_then_failing
              _ -> nil
            end)

  if @variant do
    @build_version to_string(Mix.Project.config()[:version])
    @variant_suffix Map.fetch!(
                      %{
                        failing: "-failing-migration",
                        passing_then_failing: "-passing-then-failing-migration"
                      },
                      @variant
                    )

    unless String.ends_with?(@build_version, @variant_suffix) do
      raise CompileError,
        description:
          "#{@flag}=#{System.get_env(@flag)} builds a test release whose migration fails on purpose; " <>
            "its version must end in #{@variant_suffix}, and #{@build_version} does not"
    end
  end

  @doc "The suffix every failing-migration test release carries at the end of its version."
  @spec suffix() :: String.t()
  def suffix, do: @suffix

  @doc "The tenant row a drill seeds for the failing migration to change."
  @spec sentinel_tenant() :: String.t()
  def sentinel_tenant, do: @sentinel_tenant

  @doc """
  What to append after `migrations` (the real ones): the variant this test
  release was built as, or nothing in any other build.
  """
  @spec migrations([Migrations.migration()]) :: [Migrations.migration()]
  if @variant do
    def migrations(migrations),
      do: if(release?(), do: variant(@variant, migrations), else: [])
  else
    def migrations(_migrations), do: []
  end

  @doc "The migrations of a variant, numbered after the last of `migrations`."
  @spec variant(:failing | :passing_then_failing, [Migrations.migration()]) ::
          [Migrations.migration()]
  def variant(:failing, migrations), do: [migration(migrations)]

  def variant(:passing_then_failing, migrations) do
    passing = passing_migration(migrations)
    [passing, migration(migrations ++ [passing])]
  end

  @doc """
  The failing migration, numbered after the last of `migrations`.

  It creates `failing_migration_probe`, writes a row to it, renames the
  sentinel tenant, and then inserts a NULL into a NOT NULL column, which fails.
  """
  @spec migration([Migrations.migration()]) :: Migrations.migration()
  def migration(migrations) do
    {:next, "fails on purpose (failing-migration test release)",
     [
       {"failing_migration_probe",
        "CREATE TABLE failing_migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"},
       {"failing_migration_write",
        "INSERT INTO failing_migration_probe (note) VALUES ('written before the failure')"},
       {"failing_migration_update",
        "UPDATE tenants SET name = name || ' (changed by the failing migration)' WHERE id = '#{@sentinel_tenant}'"},
       {"failing_migration_fails", "INSERT INTO failing_migration_probe (note) VALUES (NULL)"}
     ]}
    |> renumber(migrations)
  end

  @doc "A migration that passes, numbered after the last of `migrations`."
  @spec passing_migration([Migrations.migration()]) :: Migrations.migration()
  def passing_migration(migrations) do
    {:next, "passes on purpose before the failing one (failing-migration test release)",
     [
       {"passing_migration_probe",
        "CREATE TABLE passing_migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"},
       {"passing_migration_write",
        "INSERT INTO passing_migration_probe (note) VALUES ('applied before the failing migration')"}
     ]}
    |> renumber(migrations)
  end

  @doc "True when the running application is a failing-migration test release."
  @spec release?() :: boolean()
  def release?,
    do: String.ends_with?(OptimalEngine.Version.application_version(), @suffix)

  defp renumber({:next, description, statements}, migrations) do
    {last, _description, _statements} = List.last(migrations)
    {last + 1, description, statements}
  end
end
