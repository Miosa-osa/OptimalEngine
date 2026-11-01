defmodule OptimalEngine.MixProject do
  use Mix.Project

  @version "0.3.13"

  # OPTIMAL_BUILD_FAILING_MIGRATION builds a test release of the upgrade
  # rollback drill whose last migration fails on purpose
  # (OptimalEngine.Store.FailingMigration), and its version says so: 1 for the
  # failing migration alone, 2 for a passing migration before it. No other build
  # sets it (scripts/build-failing-migration-release.sh, and
  # scripts/check_release_version.exs refuses it).
  @failing_migration_suffix (case System.get_env("OPTIMAL_BUILD_FAILING_MIGRATION") do
                               value when value in [nil, ""] ->
                                 ""

                               "1" ->
                                 "-failing-migration"

                               "2" ->
                                 "-passing-then-failing-migration"

                               other ->
                                 Mix.raise(
                                   "OPTIMAL_BUILD_FAILING_MIGRATION must be 1 or 2, not #{inspect(other)}"
                                 )
                             end)

  # `OptimalEngine.MemoryCore.SecurityLabels` reads metadata with `:json`, which
  # OTP 27 added. A build without it must not run: every metadata would read as
  # unlabelled.
  @otp_release System.otp_release()
  case Integer.parse(@otp_release) do
    {release, _rest} when release >= 27 ->
      :ok

    _other ->
      Mix.raise(
        "Optimal Engine needs Erlang/OTP 27 or later (it reads JSON with :json), not OTP #{@otp_release}"
      )
  end

  def project do
    [
      app: :optimal_engine,
      version: @version <> @failing_migration_suffix,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:mix]],
      description: description(),
      package: package(),
      escript: escript(),
      releases: releases()
    ]
  end

  # Local source-checkout CLI wrapper. It routes `./optimal <cmd>` to
  # `mix optimal.<cmd>` so native dependencies load from the normal Mix build.
  # It is not the production packaging format.
  defp escript do
    [
      main_module: OptimalEngine.CLI,
      name: "optimal",
      app: nil
    ]
  end

  # `MIX_ENV=prod mix release optimal` produces a supervised OTP runtime in
  # _build/prod/rel/optimal/. Use that shape for API/server deployment.
  # `bin/optimal maintenance <task>` (rel/env.sh.eex) runs the maintenance
  # tasks in a release. They report failures with Mix.raise, so Mix is loaded,
  # never started: no Mix project, archive or compiler is involved.
  defp releases do
    [
      optimal: [
        include_executables_for: [:unix],
        applications: [optimal_engine: :permanent, mix: :load]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :mnesia],
      mod: {OptimalEngine.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Storage & serialization
      {:exqlite, "~> 0.27"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:tz, "~> 0.28"},

      # Optional knowledge graph substrate
      {:rdf, "~> 3.0"},
      {:rocksdb, "~> 3.1"},

      # Signal and option validation
      {:nimble_options, "~> 1.1"},
      {:uuid, "~> 1.1"},

      # HTTP API
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.7"},

      # Parser backends
      {:nimble_csv, "~> 1.2"},
      {:floki, "~> 0.36"},

      # Observability
      {:telemetry, "~> 1.2"},

      # Auth
      {:bcrypt_elixir, "~> 3.1"},

      # Dev / test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      "optimal.index": ["run -e 'Mix.Tasks.Optimal.Index.run([])'"],
      "optimal.search": ["run -e 'Mix.Tasks.Optimal.Search.run(System.argv())'"],
      # Wipe the test SQLite store before every run so schema drift from
      # an older migration set can't leak into the current test process.
      test: [&wipe_test_store/1, "test"]
    ]
  end

  # The test store directory, inside this checkout (config/test.exs).
  defp test_store_dir, do: Path.expand("_build/test_store", __DIR__)

  defp wipe_test_store(_args) do
    db =
      Path.join(
        test_store_dir(),
        "optimal_engine_test_#{System.get_env("MIX_TEST_PARTITION", "0")}.db"
      )

    Enum.each(["", "-wal", "-shm"], &File.rm(db <> &1))
  end

  defp description do
    "Self-hosted second brain and operating engine for human and AI workspaces."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Miosa-osa/OptimalEngine"},
      files:
        ~w(bin lib priv config docs mix.exs README.md LICENSE AGENTS.md CLAUDE.md BOOT.md SYSTEM.md OPTIONS.md MISSION.md RESOURCES.md NOTES.md OPINIONS.md)
    ]
  end
end
