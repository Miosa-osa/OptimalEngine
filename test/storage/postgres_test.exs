defmodule OptimalEngine.Storage.PostgresTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.Postgres

  setup do
    previous = System.get_env(Postgres.env_name())
    System.delete_env(Postgres.env_name())

    on_exit(fn ->
      if previous do
        System.put_env(Postgres.env_name(), previous)
      else
        System.delete_env(Postgres.env_name())
      end
    end)

    :ok
  end

  test "reports not_configured without the environment variable" do
    refute Postgres.configured?()
    assert Postgres.health() == :not_configured
    assert {:error, :not_configured} = Postgres.config()
  end

  test "the URL is never part of the public description or the safe config" do
    System.put_env(
      Postgres.env_name(),
      "postgres://optimal:sup3r-secret@db.example.com:6543/optimal?sslmode=require"
    )

    assert {:ok, config} = Postgres.config()
    assert config.password == "sup3r-secret"
    assert config.hostname == "db.example.com"
    assert config.port == 6543
    assert config.database == "optimal"
    assert config.username == "optimal"
    assert config.ssl

    assert {:ok, safe} = Postgres.safe_config()
    refute Map.has_key?(safe, :password)
    refute inspect(Postgres.describe()) =~ "sup3r-secret"
    refute Jason.encode!(Postgres.describe()) =~ "sup3r-secret"
  end

  test "decodes a percent-encoded password and defaults the port" do
    System.put_env(Postgres.env_name(), "postgres://optimal:p%40ss%2Fword@db.example.com/optimal")

    assert {:ok, config} = Postgres.config()
    assert config.password == "p@ss/word"
    assert config.port == 5432
    refute config.ssl
  end

  test "rejects a URL that is not postgres" do
    System.put_env(Postgres.env_name(), "mysql://optimal:secret@db.example.com/optimal")

    assert {:error, :invalid_scheme} = Postgres.config()
    assert Postgres.health() == :invalid_config
  end

  test "rejects a URL without a database or a username" do
    System.put_env(Postgres.env_name(), "postgres://db.example.com")
    assert {:error, _reason} = Postgres.config()

    System.put_env(Postgres.env_name(), "postgres://db.example.com/optimal")
    assert {:error, :missing_username} = Postgres.config()
    assert Postgres.health() == :invalid_config
  end

  test "reports unreachable when nothing answers, never healthy on a configured URL" do
    System.put_env(Postgres.env_name(), "postgres://optimal:secret@127.0.0.1:1/optimal")

    assert Postgres.health(timeout: 250) == :unreachable
    refute Postgres.healthy?(timeout: 250)
  end

  test "the provider stays adapter_missing even when the probe would pass" do
    assert {:ok, provider} = OptimalEngine.Storage.Providers.get("postgres")
    refute provider.adapter_implemented
    assert provider.lifecycle_state == "adapter_missing"
    assert Postgres.describe().adapter_registered == false
    assert [%{feature: "full_text_search"} | _] = Postgres.describe().unavailable
  end

  if System.get_env("OPTIMAL_POSTGRES_TEST_URL") do
    @tag :postgres_live
    test "probes a reachable database with a real query" do
      System.put_env(Postgres.env_name(), System.fetch_env!("OPTIMAL_POSTGRES_TEST_URL"))

      assert Postgres.health(timeout: 5_000) == :healthy
      assert Postgres.healthy?(timeout: 5_000)
    end
  end
end
