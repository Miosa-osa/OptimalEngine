defmodule Mix.Tasks.Optimal.Topology do
  @shortdoc "Inspect workspace topology (nodes + members + skills)"

  @moduledoc """
  Prints a summary of the current workspace topology: nodes (by kind), top
  members, skill registry, and recent skill grants.

  ## Usage

      mix optimal.topology
      mix optimal.topology --tenant acme-corp
      mix optimal.topology --workspace default
      mix optimal.topology --nodes-only
      mix optimal.topology --skills-only
  """

  use Mix.Task

  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          tenant: :string,
          workspace: :string,
          nodes_only: :boolean,
          skills_only: :boolean
        ]
      )

    tenant_id = Keyword.get(opts, :tenant, Tenant.default_id())
    workspace_id = Keyword.get(opts, :workspace)
    nodes_only = Keyword.get(opts, :nodes_only, false)
    skills_only = Keyword.get(opts, :skills_only, false)

    IO.puts("")
    IO.puts("  Workspace topology")
    IO.puts("  tenant:    #{tenant_id}")
    IO.puts("  workspace: #{workspace_id || "(all)"}")
    IO.puts("  " <> String.duplicate("-", 60))

    if skills_only do
      print_skills(tenant_id)
    else
      print_nodes(tenant_id, workspace_id)
      unless nodes_only, do: print_skills(tenant_id)
    end

    IO.puts("")
  end

  defp print_nodes(tenant_id, workspace_id) do
    opts =
      [tenant_id: tenant_id]
      |> maybe_put(:workspace_id, workspace_id)

    case Topology.list_nodes(opts) do
      {:ok, []} ->
        IO.puts("  No nodes.")
        IO.puts("")

      {:ok, nodes} ->
        grouped = Enum.group_by(nodes, & &1.kind)

        IO.puts("  Nodes (#{length(nodes)} total)")
        IO.puts("")

        Enum.each(grouped, fn {kind, ns} ->
          IO.puts("    #{kind} (#{length(ns)}):")

          Enum.each(ns, fn n ->
            status_mark = if n.status == :active, do: "*", else: "-"
            parent = if n.parent_id, do: " <- #{n.parent_id}", else: ""
            IO.puts("      #{status_mark} #{n.slug}  [#{n.workspace_id} / #{n.style}]#{parent}")
          end)

          IO.puts("")
        end)

      _ ->
        IO.puts("  (nodes unavailable)")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_skills(tenant_id) do
    case Topology.list_skills(tenant_id: tenant_id) do
      {:ok, []} ->
        IO.puts("  No skills registered.")

      {:ok, skills} ->
        IO.puts("  Skills (#{length(skills)} total)")
        IO.puts("")

        Enum.each(skills, fn s ->
          kind_str = if s.kind, do: " [#{s.kind}]", else: ""
          IO.puts("    - #{s.name}#{kind_str}")
        end)

      _ ->
        IO.puts("  (skills unavailable)")
    end
  end
end
