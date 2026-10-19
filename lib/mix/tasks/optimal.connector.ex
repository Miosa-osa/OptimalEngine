defmodule Mix.Tasks.Optimal.Connector do
  @shortdoc "Register / list / run enterprise connectors"

  @moduledoc """
  Operate on enterprise connectors.

  ## Usage

      mix optimal.connector list                           - registered connectors with their status
      mix optimal.connector list --workspace <id>          - only one workspace's connectors
      mix optimal.connector adapters                       - every adapter the Engine ships
      mix optimal.connector register <id> --kind slack --config path/to/config.json --workspace <id>
      mix optimal.connector register <id> ... --disabled   - register without pulling yet
      mix optimal.connector run <id>                       - run one sync cycle into the connector's workspace
      mix optimal.connector run <id> --max-retries 3

  ## Options

    --kind         <atom>    adapter kind (required for `register`)
    --config       <path>    JSON file with the adapter's config (required for `register`);
                             credentials go under its "credentials" key and are sealed with CONNECTOR_KEY
    --workspace    <id>      workspace the connector's signals land in (required for `register`);
                             it must exist, belong to the tenant, and be active
    --tenant       <id>      tenant scope (default: default)
    --disabled               register the connector disabled
    --max-retries  <n>       runner retry cap for transient errors (default 5)

  `register` replaces the tenant's own row of the same id. `list` never prints
  credentials: it says whether they are stored, brokered, or absent.
  `list --adapters` is the same as `adapters`.
  """

  use Mix.Task

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{PullScheduler, Registry, Rows}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [
          kind: :string,
          config: :string,
          workspace: :string,
          tenant: :string,
          disabled: :boolean,
          adapters: :boolean,
          max_retries: :integer
        ]
      )

    case rest do
      ["list" | _] -> if parsed[:adapters], do: do_adapters(), else: do_list(parsed)
      ["adapters" | _] -> do_adapters()
      ["register", id | _] -> do_register(id, parsed)
      ["run", id | _] -> do_run(id, parsed)
      _ -> Mix.raise("Usage: mix optimal.connector list | adapters | register <id> | run <id>")
    end
  end

  defp do_adapters do
    summary = Registry.summary()
    IO.puts("Available adapters (#{length(summary)} total):\n")

    summary
    |> Enum.each(fn {kind, name, auth} ->
      IO.puts("  #{pad(kind)} #{pad(name, 22)} auth=#{auth}")
    end)
  end

  defp do_list(parsed) do
    tenant = Keyword.get(parsed, :tenant, "default")

    workspace_ids =
      case Keyword.get(parsed, :workspace) do
        nil -> :all
        workspace_id -> [workspace_id]
      end

    case Rows.list(tenant, workspace_ids: workspace_ids) do
      [] ->
        IO.puts("No connectors registered (tenant #{tenant}).")

      views ->
        IO.puts("Connectors (tenant #{tenant}, #{length(views)} total):\n")
        Enum.each(views, &print_view/1)
    end
  end

  defp print_view(view) do
    state = if view.enabled, do: "enabled", else: "disabled"
    state = if view.running, do: state <> ", running", else: state

    IO.puts("  #{view.id}")
    IO.puts("    kind:        #{view.kind}")
    IO.puts("    workspace:   #{view.workspace_id}")
    IO.puts("    state:       #{state}")
    IO.puts("    credentials: #{view.credentials}")

    IO.puts(
      "    cadence:     every #{format_ms(view.cadence.interval_ms)} (#{view.cadence.source})"
    )

    IO.puts("    last run:    #{format_run(view.last_run)}")
    IO.puts("    last error:  #{format_error(view.last_error)}")
    IO.puts("    signals:     #{view.signals_total} over #{view.runs} runs")
    IO.puts("")
  end

  defp do_register(id, parsed) do
    kind = Keyword.get(parsed, :kind) || Mix.raise("register needs --kind <kind>")
    path = Keyword.get(parsed, :config) || Mix.raise("register needs --config <path>")

    workspace =
      Keyword.get(parsed, :workspace) ||
        Mix.raise("register needs --workspace <id>: the workspace the connector's signals land in")

    tenant = Keyword.get(parsed, :tenant, "default")
    config = path |> File.read!() |> Jason.decode!()

    attrs = %{
      id: id,
      kind: kind,
      tenant_id: tenant,
      workspace_id: workspace,
      config: config,
      enabled: not Keyword.get(parsed, :disabled, false)
    }

    case Rows.register(attrs, mode: :upsert, actor: "operator:cli") do
      {:ok, view} ->
        state = if view.enabled, do: "enabled", else: "disabled"
        IO.puts("Registered connector #{view.id} (#{view.kind}) in #{view.workspace_id}, #{state}.")

      {:error, :connector_key_missing} ->
        Mix.raise("Connector credentials require CONNECTOR_KEY (hex-encoded 32 bytes).")

      {:error, reason} ->
        Mix.raise("Connector registration failed: #{inspect(reason)}")
    end
  end

  # A run from the command line drives the signals through intake, exactly
  # as a scheduled pull does, so the cursor never advances past signals that
  # were not ingested.
  defp do_run(id, parsed) do
    opts = [
      max_retries: Keyword.get(parsed, :max_retries, 5),
      signal_sink: PullScheduler.intake_sink()
    ]

    case Connectors.run(id, opts) do
      {:ok, result} ->
        IO.puts("Run complete: #{result.status}")
        IO.puts("  workspace:    #{result.workspace_id}")
        IO.puts("  signals:      #{result.signals}")
        IO.puts("  errors:       #{result.errors}")
        IO.puts("  cursor_before: #{inspect(result.cursor_before)}")
        IO.puts("  cursor_after:  #{inspect(result.cursor_after)}")
        if result.reason, do: IO.puts("  reason:       #{inspect(result.reason)}")

      {:error, :already_running} ->
        Mix.raise("Connector #{id} is already running.")

      {:error, reason} ->
        Mix.raise("Connector run failed: #{inspect(reason)}")
    end
  end

  defp format_run(nil), do: "never"

  defp format_run(run) do
    signals = if run.status == "success", do: ", #{run.signals} signals", else: ""
    "#{run.status} at #{run.started_at}#{signals}"
  end

  defp format_error(nil), do: "none"
  defp format_error(error), do: "#{error.error} at #{error.at}"

  defp format_ms(ms) when rem(ms, 86_400_000) == 0, do: "#{div(ms, 86_400_000)}d"
  defp format_ms(ms) when rem(ms, 3_600_000) == 0, do: "#{div(ms, 3_600_000)}h"
  defp format_ms(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp format_ms(ms), do: "#{ms}ms"

  defp pad(value, width \\ 14) do
    value
    |> to_string()
    |> String.pad_trailing(width)
  end
end
