defmodule Mix.Tasks.Optimal.Operate do
  @shortdoc "Operating layer: boot, today, brief, loops, protocol, topology import/export"

  @moduledoc """
  The operating layer on the local Engine store.

  ## Usage

      mix optimal.operate boot [--workspace default] [--timezone America/Chicago]
      mix optimal.operate today [--workspace default] [--cadence daily|weekly|monthly]
      mix optimal.operate brief [--workspace default]
      mix optimal.operate loops [--workspace default] [--state open|closed|dropped|all]
      mix optimal.operate extract [--workspace default] [--since 2026-01-01]
      mix optimal.operate protocol [--workspace default]
      mix optimal.operate topology-export [--out topology.yaml]
      mix optimal.operate topology-import <topology.yaml|json>
      mix optimal.operate seed-routing

  Output is JSON except `today` and `protocol`, which print the note or
  document text. All commands also exist on the HTTP API (`/api/boot`,
  `/api/rhythm/current`, `/api/brief`, `/api/loops`, `/api/protocol`,
  `/api/topology/*`, `/api/routing/*`).
  """

  use Mix.Task

  alias OptimalEngine.Operating.{Boot, Brief, Loops, Protocol, Rhythm}
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Topology.Portable

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          tenant: :string,
          workspace: :string,
          timezone: :string,
          cadence: :string,
          state: :string,
          since: :string,
          out: :string
        ],
        aliases: [t: :tenant, w: :workspace]
      )

    tenant = opts[:tenant] || "default"
    workspace = opts[:workspace] || "default"

    case rest do
      ["boot" | _] ->
        print(Boot.build(tenant, workspace, timezone: opts[:timezone]))

      ["today" | _] ->
        case Rhythm.current(tenant, workspace, opts[:cadence] || "daily", timezone: opts[:timezone]) do
          {:ok, note} -> Mix.shell().info(note.content)
          {:error, reason} -> Mix.raise("rhythm failed: #{reason}")
        end

      ["brief" | _] ->
        workspaces = if opts[:workspace], do: [workspace], else: nil
        print(Brief.build(tenant, workspace_ids: workspaces))

      ["loops" | _] ->
        print(Loops.list(tenant, workspace_ids: [workspace], state: opts[:state] || "open"))

      ["extract" | _] ->
        extract_opts = if opts[:since], do: [since: opts[:since]], else: []
        {:ok, found} = Loops.extract(tenant, workspace, extract_opts)
        {:ok, closed} = Loops.close_answered(tenant, workspace)
        print(%{detected: length(found), closed_by_reply: length(closed), loops: found})

      ["protocol" | _] ->
        {:ok, document} = Protocol.get(tenant, opts[:workspace])
        Mix.shell().info(document.content)

      ["topology-export" | _] ->
        json = Jason.encode!(Portable.export(tenant), pretty: true)

        case opts[:out] do
          nil -> Mix.shell().info(json)
          path -> File.write!(path, json) && Mix.shell().info("Wrote #{path}")
        end

      ["topology-import", path | _] ->
        content = File.read!(path)

        document =
          if String.ends_with?(path, ".json"),
            do: Jason.decode!(content),
            else: YamlElixir.read_from_string!(content)

        case Portable.import(tenant, document) do
          {:ok, summary} -> print(summary)
          {:error, reason} -> Mix.raise("import failed: #{inspect(reason)}")
        end

      ["seed-routing" | _] ->
        {:ok, count} = RuleStore.seed_from_routing_file(tenant)
        Mix.shell().info("Seeded #{count} routing rules from the routing rules file.")

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp print(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))
end
