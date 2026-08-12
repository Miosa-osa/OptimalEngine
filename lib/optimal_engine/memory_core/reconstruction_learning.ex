defmodule OptimalEngine.MemoryCore.ReconstructionLearning do
  @moduledoc """
  Path-conditioned learning and review-only consolidation for reconstruction.

  Outcomes credit the exact ordered association paths for one intent. Learning
  never rewrites evidence and consolidation never promotes a Fact.
  """

  alias OptimalEngine.MemoryCore.{ID, ScopeEnvelope, Store}
  alias OptimalEngine.Store, as: BaseStore

  @outcomes ~w[success partial failure]

  @doc "Records an authorized outcome against one Reconstruction Run."
  @spec record_outcome(String.t(), String.t(), ScopeEnvelope.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def record_outcome(run_id, outcome, scope, opts \\ [])

  def record_outcome(run_id, outcome, %ScopeEnvelope{} = scope, opts)
      when outcome in @outcomes do
    score = Keyword.get(opts, :score, default_score(outcome)) |> clamp()

    with {:ok, run} <- Store.get_reconstruction_run(run_id, scope.tenant_id, scope.workspace_id),
         :ok <- authorize_actor(run, scope),
         :ok <-
           Store.record_reconstruction_outcome(
             run,
             outcome,
             score,
             Keyword.get(opts, :notes),
             scope.actor
           ) do
      {:ok, %{run_id: run_id, outcome: outcome, score: score, learning_scope: "intent_path"}}
    end
  end

  def record_outcome(_run_id, _outcome, _scope, _opts), do: {:error, :invalid_outcome}

  @doc "Creates coherent review proposals from recurring successful path fingerprints."
  @spec propose_consolidation(ScopeEnvelope.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def propose_consolidation(%ScopeEnvelope{} = scope, opts \\ []) do
    minimum = Keyword.get(opts, :minimum_observations, 2)

    sql = """
    SELECT p.intent, p.association_ids, COUNT(*), AVG(p.outcome_credit),
           json_group_array(p.id)
    FROM memory_association_paths p
    JOIN memory_reconstruction_runs r ON r.id = p.run_id
    WHERE r.tenant_id = ?1 AND p.workspace_id = ?2 AND p.outcome_credit > 0
    GROUP BY p.intent, p.association_ids
    HAVING COUNT(*) >= ?3
    ORDER BY AVG(p.outcome_credit) DESC, COUNT(*) DESC
    LIMIT 50
    """

    with {:ok, rows} <- BaseStore.raw_query(sql, [scope.tenant_id, scope.workspace_id, minimum]) do
      proposals = Enum.map(rows, &proposal(scope, &1))

      Enum.reduce_while(proposals, {:ok, []}, fn proposal, {:ok, accepted} ->
        case insert_proposal(proposal) do
          :ok -> {:cont, {:ok, accepted ++ [proposal]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Measures reconstruction use, grounding, outcomes, and path learning for a workspace."
  @spec measure(ScopeEnvelope.t()) :: {:ok, map()} | {:error, term()}
  def measure(%ScopeEnvelope{} = scope) do
    sql = """
    SELECT COUNT(DISTINCT r.id), COALESCE(AVG(r.confidence), 0),
           COALESCE(AVG(json_array_length(r.citations)), 0), COUNT(DISTINCT p.id),
           COUNT(DISTINCT o.id),
           COALESCE(AVG(CASE o.outcome WHEN 'success' THEN 1.0 WHEN 'partial' THEN 0.5 WHEN 'failure' THEN 0.0 END), 0)
    FROM memory_reconstruction_runs r
    LEFT JOIN memory_association_paths p ON p.run_id = r.id
    LEFT JOIN memory_reconstruction_outcomes o ON o.run_id = r.id
    WHERE r.tenant_id = ?1 AND r.workspace_id = ?2
    """

    case BaseStore.raw_query(sql, [scope.tenant_id, scope.workspace_id]) do
      {:ok, [[runs, confidence, citations, paths, outcomes, outcome_score]]} ->
        {:ok,
         %{
           tenant_id: scope.tenant_id,
           workspace_id: scope.workspace_id,
           runs: runs,
           average_confidence: confidence,
           average_citations: citations,
           association_paths: paths,
           feedback_count: outcomes,
           outcome_score: outcome_score
         }}

      error ->
        error
    end
  end

  defp proposal(scope, [intent, association_ids, observations, credit, path_ids]) do
    members = Jason.decode!(association_ids)

    %{
      id:
        ID.content_id("consolidation", [
          scope.tenant_id,
          ":",
          scope.workspace_id,
          ":",
          intent,
          ":",
          association_ids
        ]),
      workspace_id: scope.workspace_id,
      proposal_type: "recurring_association_path",
      member_links: Enum.map(members, &%{type: "memory_association", id: &1}),
      rationale:
        "Connected association path repeatedly supported successful #{intent} reconstruction.",
      confidence: clamp(credit),
      status: "proposed",
      metadata: %{
        intent: intent,
        observations: observations,
        path_ids: Jason.decode!(path_ids),
        review_required: true
      }
    }
  end

  defp insert_proposal(proposal) do
    BaseStore.raw_execute(
      "INSERT OR IGNORE INTO memory_consolidation_proposals (id, workspace_id, proposal_type, member_links, rationale, confidence, status, metadata) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
      [
        proposal.id,
        proposal.workspace_id,
        proposal.proposal_type,
        Jason.encode!(proposal.member_links),
        proposal.rationale,
        proposal.confidence,
        proposal.status,
        Jason.encode!(proposal.metadata)
      ]
    )
  end

  defp authorize_actor(%{actor_id: nil}, _scope), do: :ok
  defp authorize_actor(%{actor_id: actor}, %{actor: actor}), do: :ok

  defp authorize_actor(_run, %{permissions: permissions}) do
    if "memory.reconstruction.review" in permissions, do: :ok, else: {:error, :forbidden}
  end

  defp default_score("success"), do: 1.0
  defp default_score("partial"), do: 0.5
  defp default_score("failure"), do: 1.0
  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
