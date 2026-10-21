defmodule OptimalEngine.Store.FailingMigration do
  @moduledoc """
  Migrations that fail on purpose, for the upgrade rollback drill (WO-39).

  A release whose migration fails never answers, because its store cannot open.
  `OptimalEngine.Store.Migrations.run/2` runs each migration in one transaction,
  so the failed migration leaves no trace; migrations before it in the same boot
  stay applied. The two variants of the test release exercise both halves:

    * `OPTIMAL_BUILD_FAILING_MIGRATION=1`, version suffix `-failing-migration`:
      migration 9000001 creates a table, writes a row, changes the sentinel
      tenant's row, and then fails. The store keeps its migration counter,
      schema and data.
    * `OPTIMAL_BUILD_FAILING_MIGRATION=2`, version suffix
      `-passing-then-failing-migration`: migration 9000001 passes, then
      migration 9000002 fails. The passing migration stays applied, so the
      store is left between releases and only a backup taken before the boot
      restores it.

  The test migrations are numbered from a reserved base (`reserved_base/0`)
  that the real migrations never reach, so a test migration can never take a
  real migration's number. A store a passing test migration reached and no
  backup restored still opens with the previous release, which applies later
  real migrations as usual (the runner skips versions it has recorded, it does
  not compare numbers); its `max(version)` of 9000001 is then the migration
  drift `GET /api/stores/audit` reports.

  The sentinel tenant (`sentinel_tenant/0`) is a row a drill seeds so the
  failing migration has existing data to change; no other row is touched.

  Built only by `scripts/build-failing-migration-release.sh`. Three guards keep
  these migrations out of every other build:

    * without the build flag, `migrations/1` is compiled to return nothing;
    * with the flag, the build's version must be exactly `<x.y.z>` and the
      variant's suffix (`mix.exs` appends it), or compilation stops
      (`OptimalEngine.ReleaseIdentity.failing_build_problem/2`);
    * at run time they are offered only while the running application's
      version ends in `-failing-migration` (both suffixes do).

  `scripts/check_release_version.exs` and `deploy/miosa-template/build-release.sh`
  refuse to release either. The flag is read at compile time, so a build that
  sets or clears it compiles with `--force`, as `deploy/Dockerfile.engine` and
  the build script do.
  """

  alias OptimalEngine.Store.Migrations

  @flag "OPTIMAL_BUILD_FAILING_MIGRATION"
  @suffix "-failing-migration"
  @sentinel_tenant "failing-migration-sentinel"
  @reserved_base 9_000_000

  @variant (case System.get_env(@flag) do
              "1" -> :failing
              "2" -> :passing_then_failing
              _ -> nil
            end)

  if @variant do
    case OptimalEngine.ReleaseIdentity.failing_build_problem(
           System.get_env(@flag),
           to_string(Mix.Project.config()[:version])
         ) do
      nil -> :ok
      problem -> raise CompileError, description: problem
    end
  end

  @doc "The suffix every failing-migration test release carries at the end of its version."
  @spec suffix() :: String.t()
  def suffix, do: @suffix

  @doc "The tenant row a drill seeds for the failing migration to change."
  @spec sentinel_tenant() :: String.t()
  def sentinel_tenant, do: @sentinel_tenant

  @doc "The test migrations are numbered after this; every real migration is below it."
  @spec reserved_base() :: pos_integer()
  def reserved_base, do: @reserved_base

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

  @doc """
  The migrations of a variant, numbered from the reserved base. Raises when a
  real migration of `migrations` has reached it.
  """
  @spec variant(:failing | :passing_then_failing, [Migrations.migration()]) ::
          [Migrations.migration()]
  def variant(variant, migrations) do
    {last, _description, _statements} = List.last(migrations)

    if last >= @reserved_base do
      raise ArgumentError,
            "real migration #{last} has reached the failing-migration reserved base #{@reserved_base}"
    end

    case variant do
      :failing ->
        [failing_migration(@reserved_base + 1)]

      :passing_then_failing ->
        [passing_migration(@reserved_base + 1), failing_migration(@reserved_base + 2)]
    end
  end

  # It creates `failing_migration_probe`, writes a row to it, renames the
  # sentinel tenant, and then inserts a NULL into a NOT NULL column, which fails.
  defp failing_migration(version) do
    {version, "fails on purpose (failing-migration test release)",
     [
       {"failing_migration_probe",
        "CREATE TABLE failing_migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"},
       {"failing_migration_write",
        "INSERT INTO failing_migration_probe (note) VALUES ('written before the failure')"},
       {"failing_migration_update",
        "UPDATE tenants SET name = name || ' (changed by the failing migration)' WHERE id = '#{@sentinel_tenant}'"},
       {"failing_migration_fails", "INSERT INTO failing_migration_probe (note) VALUES (NULL)"}
     ]}
  end

  defp passing_migration(version) do
    {version, "passes on purpose before the failing one (failing-migration test release)",
     [
       {"passing_migration_probe",
        "CREATE TABLE passing_migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"},
       {"passing_migration_write",
        "INSERT INTO passing_migration_probe (note) VALUES ('applied before the failing migration')"}
     ]}
  end

  @doc "True when the running application is a failing-migration test release."
  @spec release?() :: boolean()
  def release?,
    do: String.ends_with?(OptimalEngine.Version.application_version(), @suffix)
end
