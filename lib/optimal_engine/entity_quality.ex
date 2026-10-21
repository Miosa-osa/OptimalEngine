defmodule OptimalEngine.EntityQuality do
  @moduledoc """
  Reports identity quality without mutating canonical data.

  The report is the tenant's: two tenants can share a bare workspace id, so
  the entities, mentions and lineage it counts are the ones that belong to the
  tenant (a mention by `OptimalEngine.EntityResolution`, lineage through the
  entities it joins).
  """

  alias OptimalEngine.{EntityResolution, Store}

  @doc """
  The quality of a workspace's identities. Options: `:tenant_id` (default
  `"default"`): only that tenant's rows are counted.
  """
  def run(workspace_id, opts \\ []) do
    tenant = Keyword.get(opts, :tenant_id, "default")
    owned = EntityResolution.owned_mention_sql()
    # `?2` is the workspace and `?3` the tenant in every query, as in the
    # mention condition; `?1` is not used.
    params = [nil, workspace_id, tenant]

    with {:ok, [[entities, duplicate_names]]} <-
           Store.raw_query(
             "SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT entity_kind || ':' || normalized_name) FROM canonical_entities WHERE workspace_id=?2 AND tenant_id=?3 AND lifecycle_state='active'",
             params
           ),
         {:ok, [[unresolved, ambiguous]]} <-
           Store.raw_query(
             "SELECT SUM(CASE WHEN resolution_state='unresolved' THEN 1 ELSE 0 END), SUM(CASE WHEN resolution_state='ambiguous' THEN 1 ELSE 0 END) FROM entity_mentions WHERE workspace_id=?2 AND #{owned}",
             params
           ),
         {:ok, [[orphan_mentions]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM entity_mentions LEFT JOIN canonical_entities e ON e.id=entity_mentions.resolved_entity_id WHERE entity_mentions.workspace_id=?2 AND entity_mentions.resolved_entity_id IS NOT NULL AND e.id IS NULL AND #{owned}",
             params
           ),
         {:ok, [[lineage]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM entity_lineage l WHERE l.workspace_id=?2 AND EXISTS (SELECT 1 FROM canonical_entities e WHERE e.id IN (l.predecessor_entity_id, l.successor_entity_id) AND e.tenant_id=?3)",
             params
           ) do
      issues =
        (duplicate_names || 0) + (unresolved || 0) + (ambiguous || 0) + (orphan_mentions || 0)

      {:ok,
       %{
         workspace_id: workspace_id,
         status: if(issues == 0, do: "healthy", else: "review"),
         canonical_entities: entities || 0,
         duplicate_canonical_names: duplicate_names || 0,
         unresolved_mentions: unresolved || 0,
         ambiguous_mentions: ambiguous || 0,
         orphan_resolutions: orphan_mentions || 0,
         lineage_events: lineage || 0
       }}
    end
  end
end
