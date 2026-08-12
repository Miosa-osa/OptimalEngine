defmodule OptimalEngine.EntityQuality do
  @moduledoc "Reports identity quality without mutating canonical data."

  alias OptimalEngine.Store

  def run(workspace_id) do
    with {:ok, [[entities, duplicate_names]]} <-
           Store.raw_query(
             "SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT entity_kind || ':' || normalized_name) FROM canonical_entities WHERE workspace_id=?1 AND lifecycle_state='active'",
             [workspace_id]
           ),
         {:ok, [[unresolved, ambiguous]]} <-
           Store.raw_query(
             "SELECT SUM(CASE WHEN resolution_state='unresolved' THEN 1 ELSE 0 END), SUM(CASE WHEN resolution_state='ambiguous' THEN 1 ELSE 0 END) FROM entity_mentions WHERE workspace_id=?1",
             [workspace_id]
           ),
         {:ok, [[orphan_mentions]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM entity_mentions m LEFT JOIN canonical_entities e ON e.id=m.resolved_entity_id WHERE m.workspace_id=?1 AND m.resolved_entity_id IS NOT NULL AND e.id IS NULL",
             [workspace_id]
           ),
         {:ok, [[lineage]]} <-
           Store.raw_query("SELECT COUNT(*) FROM entity_lineage WHERE workspace_id=?1", [
             workspace_id
           ]) do
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
