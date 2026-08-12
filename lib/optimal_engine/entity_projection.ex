defmodule OptimalEngine.EntityProjection do
  @moduledoc "Builds disposable point-in-time entity views from canonical truth and relationships."

  alias OptimalEngine.{EntityRegistry, RelationshipRegistry, Store}

  def build(entity_id, workspace_id, opts \\ []) do
    as_of = Keyword.get(opts, :as_of)

    with {:ok, entity} <- EntityRegistry.get(entity_id, workspace_id, entity_opts(as_of)),
         {:ok, relationships} <-
           RelationshipRegistry.list(entity_id, workspace_id, entity_opts(as_of)),
         {:ok, facts} <- facts(entity_id, workspace_id, as_of) do
      {:ok,
       %{
         entity: entity,
         facts: facts,
         relationships: relationships,
         as_of: as_of || "now",
         projection_policy: "rebuildable_from_canonical_truth"
       }}
    end
  end

  defp facts(entity_id, workspace_id, as_of) do
    temporal =
      if as_of,
        do:
          "AND datetime(transaction_time_start) <= datetime(?3) AND (transaction_time_end IS NULL OR datetime(transaction_time_end) > datetime(?3)) AND (valid_time_start IS NULL OR datetime(valid_time_start) <= datetime(?3)) AND (valid_time_end IS NULL OR datetime(valid_time_end) > datetime(?3))",
        else: "AND lifecycle_state='accepted' AND transaction_time_end IS NULL"

    params = if as_of, do: [workspace_id, entity_id, as_of], else: [workspace_id, entity_id]

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT id, fact_text, fact_type, lifecycle_state, verification_status, aggregate_confidence, valid_time_start, valid_time_end, transaction_time_start, transaction_time_end FROM facts WHERE workspace_id=?1 AND (subject_entity_id=?2 OR object_entity_id=?2) #{temporal} ORDER BY transaction_time_start DESC",
             params
           ) do
      {:ok,
       Enum.map(rows, fn [
                           id,
                           text,
                           type,
                           state,
                           verification,
                           confidence,
                           valid_from,
                           valid_to,
                           tx_from,
                           tx_to
                         ] ->
         %{
           id: id,
           fact_text: text,
           fact_type: type,
           lifecycle_state: state,
           verification_status: verification,
           confidence: confidence,
           valid_time_start: valid_from,
           valid_time_end: valid_to,
           transaction_time_start: tx_from,
           transaction_time_end: tx_to
         }
       end)}
    end
  end

  defp entity_opts(nil), do: []
  defp entity_opts(as_of), do: [as_of: as_of]
end
