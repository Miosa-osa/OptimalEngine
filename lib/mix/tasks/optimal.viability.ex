defmodule Mix.Tasks.Optimal.Viability do
  @shortdoc "Viability: VSM systems, proxy metrics, variety ratio, audit, history, action chains"

  @moduledoc """
  Viability of a workspace or the org on the local Engine store.

  ## Usage

      mix optimal.viability report [--workspace default | --org]
      mix optimal.viability history [--workspace default | --org] [--days 30]
      mix optimal.viability snapshot [--workspace default | --org] [--days 30]
      mix optimal.viability audit [--workspace default] [--size 10]
      mix optimal.viability chain <correlation id, request id, or grant id>
      mix optimal.viability repair-cross-refs

  `repair-cross-refs` runs once after upgrading an Engine with existing data:
  it marks cross-reference copies of Signals so they count once.

  Output is JSON. The same views are on the HTTP API (`/api/viability`,
  `/api/viability/history`, `/api/viability/snapshot`,
  `/api/viability/audit/run`, `/api/agent-actions/:id`).
  """

  use Mix.Task

  alias OptimalEngine.Authority.ActionChain
  alias OptimalEngine.Viability
  alias OptimalEngine.Viability.Audit

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [tenant: :string, workspace: :string, org: :boolean, days: :integer, size: :integer],
        aliases: [t: :tenant, w: :workspace]
      )

    tenant = opts[:tenant] || "default"
    workspace = opts[:workspace] || "default"
    scope_key = if opts[:org], do: Viability.org(), else: workspace

    case rest do
      ["report" | _] ->
        if opts[:org],
          do: print(Viability.report(tenant, scope: :org)),
          else: print(Viability.report(tenant, workspace_ids: [workspace]))

      ["history" | _] ->
        print(Viability.history(tenant, scope_key, opts[:days] || 30))

      ["snapshot" | _] ->
        {:ok, written} = Viability.catch_up(tenant, scope_key, days: opts[:days] || 30)
        print(%{scope: scope_key, written: written})

      ["audit" | _] ->
        {:ok, result} = Audit.run(tenant, workspace, size: opts[:size] || 10)
        print(result)

      ["chain", id | _] ->
        case ActionChain.trace(tenant, id) do
          {:ok, chain} -> print(chain)
          {:error, :not_found} -> Mix.raise("no action chain for #{id}")
        end

      ["repair-cross-refs" | _] ->
        {:ok, result} = Viability.repair_cross_refs()
        print(result)

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp print(data), do: Mix.shell().info(Jason.encode!(data, pretty: true))
end
