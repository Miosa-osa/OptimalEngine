defmodule OptimalEngine.Operating.Boot do
  @moduledoc """
  The session boot an agent or person reads before acting in a workspace:
  the actual day in the workspace's time zone, today's rhythm note, the
  fires (overdue and due-today loops), open loop counts, recent decisions,
  items gone stale, the operating protocol, and the org policy the workspace
  inherits from its tenant's org section (`OptimalEngine.OrgPolicy`).

  Everything comes from Engine data, so a fresh org gets a valid empty-state
  boot and an existing org gets its real state; nothing is read from local
  files.
  """

  alias OptimalEngine.Operating.{Brief, Loops, Protocol, Rhythm}
  alias OptimalEngine.{OrgPolicy, Store}

  @doc """
  Builds the boot for `workspace_id`. Options: `:timezone`, `:date` (tests),
  `:actor` (the reading principal, for authority decisions on org policy).
  """
  @spec build(String.t(), String.t(), keyword()) :: map()
  def build(tenant_id, workspace_id, opts \\ []) do
    timezone = opts[:timezone] || Rhythm.timezone(tenant_id, workspace_id)

    {date, timezone} =
      case opts[:date] do
        %Date{} = date -> {date, timezone}
        nil -> Rhythm.today(timezone)
      end

    today = Date.to_iso8601(date)
    loops = Loops.list(tenant_id, workspace_ids: [workspace_id], state: "open", limit: 1_000)

    fires =
      loops
      |> Enum.filter(&(&1.due_at && String.slice(&1.due_at, 0, 10) <= today))
      |> Enum.map(&Map.take(&1, [:id, :kind, :title, :due_at, :owner, :counterparty, :source_uri]))

    {:ok, rhythm} = Rhythm.current(tenant_id, workspace_id, "daily", timezone: timezone, date: date)
    {:ok, protocol} = Protocol.get(tenant_id, workspace_id, "protocol")
    brief = Brief.build(tenant_id, workspace_ids: [workspace_id], date: date, limit: 10)

    %{
      workspace_id: workspace_id,
      date: today,
      weekday: weekday(date),
      timezone: timezone,
      rhythm: %{period: rhythm.period, content: rhythm.content, generated: rhythm.generated},
      fires: fires,
      open_loops: %{total: length(loops), by_kind: Enum.frequencies_by(loops, & &1.kind)},
      recent_decisions: recent_decisions(tenant_id, workspace_id, date),
      stale: stale(tenant_id, workspace_id, date),
      brief: Map.take(brief, [:items, :counts]),
      protocol: %{source: protocol.source, hash: protocol.hash, content: protocol.content},
      org_policy: OrgPolicy.for_workspace(tenant_id, workspace_id, actor: opts[:actor])
    }
  end

  defp recent_decisions(tenant_id, workspace_id, date) do
    since = date |> Date.add(-7) |> Date.to_iso8601()

    case Store.raw_query(
           """
           SELECT id, title, decision, decided_by, decided_at FROM decisions
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND decided_at >= ?3
           ORDER BY decided_at DESC LIMIT 10
           """,
           [tenant_id, workspace_id, since]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, title, decision, by, at] ->
          %{id: id, title: title, decision: decision, decided_by: by, decided_at: at}
        end)

      _ ->
        []
    end
  end

  # Open loops untouched for 14 days and contexts whose validity has ended.
  defp stale(tenant_id, workspace_id, date) do
    cutoff = date |> Date.add(-14) |> Date.to_iso8601()
    today = Date.to_iso8601(date)

    loops =
      case Store.raw_query(
             "SELECT COUNT(*) FROM open_loops WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'open' AND updated_at < ?3",
             [tenant_id, workspace_id, cutoff]
           ) do
        {:ok, [[n]]} -> n
        _ -> 0
      end

    expired =
      case Store.raw_query(
             "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND valid_until IS NOT NULL AND valid_until < ?3 AND archived_at IS NULL",
             [tenant_id, workspace_id, today]
           ) do
        {:ok, [[n]]} -> n
        _ -> 0
      end

    %{loops_untouched_14_days: loops, contexts_past_valid_until: expired}
  end

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  defp weekday(date), do: Enum.at(@weekdays, Date.day_of_week(date) - 1)
end
