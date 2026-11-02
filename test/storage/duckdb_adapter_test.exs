defmodule OptimalEngine.Storage.DuckDBAdapterTest do
  @moduledoc """
  The DuckDB provider must report itself honestly: implemented, configured and
  healthy only when the executable answered a query against a writable analytics
  path, and proved only by a Parquet file written and read back.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{DuckDB, Providers}
  alias OptimalEngine.Storage.DuckDB.Adapter
  alias OptimalEngine.TestSupport.DuckDBFake

  setup do
    previous = System.get_env(DuckDB.env_name())
    System.delete_env(DuckDB.env_name())
    {_dir, restore} = DuckDBFake.install()

    analytics =
      Path.join(System.tmp_dir!(), "optimal-analytics-#{System.unique_integer([:positive])}")

    File.mkdir_p!(analytics)

    on_exit(fn ->
      restore.()
      File.rm_rf!(analytics)

      if previous,
        do: System.put_env(DuckDB.env_name(), previous),
        else: System.delete_env(DuckDB.env_name())
    end)

    %{analytics: analytics}
  end

  # `kill -0` succeeds while the process exists; the port's child reaper
  # collects it shortly after the kill.
  defp gone?(_pid, 0), do: false

  defp gone?(pid, tries) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(50)
        gone?(pid, tries - 1)

      _ ->
        true
    end
  end

  test "duckdb is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("duckdb")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.DuckDB.Adapter"
    assert provider.lifecycle_state == "not_configured"
  end

  test "without a path it is not configured; with a missing directory it is invalid", %{
    analytics: analytics
  } do
    assert DuckDB.health() == :not_configured
    assert {:error, :not_configured} = Adapter.probe()

    System.put_env(DuckDB.env_name(), Path.join(analytics, "missing"))
    assert DuckDB.health() == :invalid_config
    assert {:ok, provider} = Providers.get("duckdb", probe: true)
    assert provider.lifecycle_state == "unavailable"
  end

  test "an executable that answers against a writable path is available", %{analytics: analytics} do
    System.put_env(DuckDB.env_name(), analytics)
    assert DuckDB.health() == :healthy
    assert {:ok, provider} = Providers.get("duckdb", probe: true)
    assert provider.lifecycle_state == "available"
    assert %{executable_present: true} = Adapter.status()
  end

  test "the proof writes a Parquet file under the path, reads the row back and removes the file", %{
    analytics: analytics
  } do
    System.put_env(DuckDB.env_name(), analytics)

    assert {:ok, %{provider: "duckdb", wrote: 1, read_back: true, format: "parquet"}} =
             Adapter.probe()

    assert File.ls!(analytics) == []

    assert [%{provider: "duckdb", status: "pass"}] =
             Providers.proofs() |> Enum.filter(&(&1.provider == "duckdb"))
  end

  test "a query that hangs is killed at its timeout, not left running", %{analytics: analytics} do
    pidfile = Path.join(analytics, "hang.pid")
    System.put_env("DUCKDB_FAKE_PIDFILE", pidfile)
    on_exit(fn -> System.delete_env("DUCKDB_FAKE_PIDFILE") end)
    System.put_env(DuckDB.env_name(), analytics)

    {:ok, config} = DuckDB.config()
    assert {:error, :timeout} = DuckDB.query(config, "SELECT 'hang'", timeout: 1_000)

    pid = pidfile |> File.read!() |> String.trim()
    assert gone?(pid, 40), "the hung query's process #{pid} is still running"
    refute_received {_port, {:data, _}}
  end

  test "a path with a quote in it works and cannot end the statement", %{analytics: analytics} do
    quoted = Path.join(analytics, "o'brien")
    File.mkdir_p!(quoted)
    System.put_env(DuckDB.env_name(), quoted)

    assert {:ok, %{read_back: true}} = DuckDB.round_trip()
    assert File.ls!(quoted) == []
  end

  test "without the executable it is not installed, never healthy", %{analytics: analytics} do
    System.put_env(DuckDB.env_name(), analytics)
    previous = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")
    on_exit(fn -> System.put_env("PATH", previous) end)

    assert DuckDB.health() == :not_installed
    assert {:ok, provider} = Providers.get("duckdb", probe: true)
    assert provider.health == "not_installed"
    assert provider.lifecycle_state == "unavailable"
  end
end
