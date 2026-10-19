defmodule Mix.Tasks.Optimal.Postgres.Check do
  @shortdoc "Check the PostgreSQL provider connection without exposing credentials"
  @moduledoc """
  Reports how the PostgreSQL provider is configured and whether it answers a
  real query.

  This is the operator check for stage 1 of
  `docs/guides/postgres-provider.md`. The engine does not yet store relational
  data in PostgreSQL, so a healthy probe means the connection works, not that
  the provider is usable.

  Usage:

      mix optimal.postgres.check
      mix optimal.postgres.check --json
      mix optimal.postgres.check --timeout 5000

  Exit status is 0 when the database is healthy or not configured, and 1 when
  it is configured but unreachable or malformed.
  """

  use Mix.Task

  alias OptimalEngine.Storage.Postgres

  @default_timeout 2_000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [json: :boolean, timeout: :integer])

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    health = Postgres.health(timeout: timeout)

    if Keyword.get(opts, :json, false) do
      print_json(health, timeout)
    else
      print_text(health, timeout)
    end

    if health in [:unreachable, :invalid_config] do
      exit({:shutdown, 1})
    end
  end

  defp print_text(health, timeout) do
    Mix.shell().info("postgres provider (stage 1: connection probe only)")
    Mix.shell().info("  health: #{health}")
    Mix.shell().info("  adapter_registered: false")

    case Postgres.safe_config() do
      {:ok, config} ->
        Mix.shell().info("  host: #{config.hostname}")
        Mix.shell().info("  port: #{config.port}")
        Mix.shell().info("  database: #{config.database}")
        Mix.shell().info("  username: #{config.username}")
        Mix.shell().info("  ssl: #{config.ssl}")
        Mix.shell().info("  timeout_ms: #{timeout}")

      {:error, :not_configured} ->
        Mix.shell().info("  #{Postgres.env_name()} is not set")

      {:error, reason} ->
        Mix.shell().info("  #{Postgres.env_name()} is invalid: #{inspect(reason)}")
    end
  end

  defp print_json(health, timeout) do
    payload =
      case Postgres.safe_config() do
        {:ok, config} ->
          %{
            provider: "postgres",
            stage: 1,
            adapter_registered: false,
            health: Atom.to_string(health),
            configured: true,
            timeout_ms: timeout,
            connection: %{
              host: config.hostname,
              port: config.port,
              database: config.database,
              username: config.username,
              ssl: config.ssl
            }
          }

        {:error, reason} ->
          %{
            provider: "postgres",
            stage: 1,
            adapter_registered: false,
            health: Atom.to_string(health),
            configured: false,
            timeout_ms: timeout,
            reason: Atom.to_string(reason)
          }
      end

    Mix.shell().info(Jason.encode!(payload))
  end
end
