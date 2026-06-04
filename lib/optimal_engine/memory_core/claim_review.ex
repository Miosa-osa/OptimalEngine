defmodule OptimalEngine.MemoryCore.ClaimReview do
  @moduledoc """
  Review boundary for pending Claims.

  Claims are not truth. This module is the controlled lifecycle boundary for
  accepting or rejecting them after evidence/policy review. Promotion creates a
  Fact and Memory Object through `KnowledgeLifecycle`; rejection only updates the
  Claim state.
  """

  alias OptimalEngine.MemoryCore.{KnowledgeLifecycle, Store}

  @spec pending(keyword()) :: {:ok, [map()]} | {:error, term()}
  def pending(opts \\ []) do
    opts
    |> Keyword.put(:review_status, "unreviewed")
    |> Keyword.put(:lifecycle_state, "pending")
    |> Store.list_claims()
  end

  @spec queue(keyword()) ::
          {:ok,
           %{
             tenant_id: String.t(),
             workspace_id: String.t(),
             count: non_neg_integer(),
             review_counts: map(),
             lifecycle_counts: map(),
             claims: [map()]
           }}
          | {:error, term()}
  def queue(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    with {:ok, claims} <-
           Store.list_claims(
             tenant_id: tenant_id,
             workspace_id: workspace_id,
             review_status: Keyword.get(opts, :review_status),
             lifecycle_state: Keyword.get(opts, :lifecycle_state),
             limit: Keyword.get(opts, :limit, 100)
           ) do
      {:ok,
       %{
         tenant_id: tenant_id,
         workspace_id: workspace_id,
         count: length(claims),
         review_counts: count_by(claims, :review_status),
         lifecycle_counts: count_by(claims, :lifecycle_state),
         claims: claims
       }}
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get(claim_id, opts \\ []), do: Store.get_claim(claim_id, opts)

  @spec reject(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reject(claim_id, opts \\ []) when is_binary(claim_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, claim} <-
           Store.get_claim(claim_id, tenant_id: tenant_id, workspace_id: workspace_id),
         :ok <-
           Store.update_claim_review(claim_id,
             tenant_id: tenant_id,
             workspace_id: workspace_id || claim.workspace_id,
             review_status: "rejected",
             lifecycle_state: "rejected",
             actor_id: Keyword.get(opts, :actor_id)
           ) do
      Store.get_claim(claim_id,
        tenant_id: tenant_id,
        workspace_id: workspace_id || claim.workspace_id
      )
    end
  end

  @spec promote(String.t(), keyword()) ::
          {:ok, %{claim: map(), fact: map(), memory_object: map()}} | {:error, term()}
  def promote(claim_id, opts \\ []) when is_binary(claim_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, claim} <-
           Store.get_claim(claim_id, tenant_id: tenant_id, workspace_id: workspace_id),
         :ok <- ensure_promotable(claim),
         {:ok, fact} <- KnowledgeLifecycle.promote_claim_to_fact(claim, fact_opts(opts)),
         {:ok, memory} <- KnowledgeLifecycle.build_memory_object(fact, memory_opts(opts)),
         :ok <-
           Store.update_claim_review(claim.id,
             tenant_id: claim.tenant_id,
             workspace_id: claim.workspace_id,
             review_status: "accepted",
             lifecycle_state: "accepted",
             actor_id: Keyword.get(opts, :actor_id)
           ),
         {:ok, reviewed_claim} <-
           Store.get_claim(claim.id, tenant_id: claim.tenant_id, workspace_id: claim.workspace_id) do
      {:ok, %{claim: reviewed_claim, fact: fact, memory_object: memory}}
    end
  end

  defp ensure_promotable(%{review_status: "rejected"}), do: {:error, :claim_rejected}
  defp ensure_promotable(%{lifecycle_state: "rejected"}), do: {:error, :claim_rejected}
  defp ensure_promotable(_claim), do: :ok

  defp count_by(claims, field) do
    claims
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp fact_opts(opts) do
    [
      actor_id: Keyword.get(opts, :actor_id),
      verifier_id: Keyword.get(opts, :verifier_id) || Keyword.get(opts, :actor_id),
      fact_text: Keyword.get(opts, :fact_text),
      fact_type: Keyword.get(opts, :fact_type),
      verification_status: Keyword.get(opts, :verification_status, "verified"),
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision),
      valid_time_start: Keyword.get(opts, :valid_time_start),
      valid_time_end: Keyword.get(opts, :valid_time_end),
      stale_after: Keyword.get(opts, :stale_after),
      metadata: Keyword.get(opts, :fact_metadata, %{})
    ]
    |> compact_nil()
  end

  defp memory_opts(opts) do
    [
      actor_id: Keyword.get(opts, :actor_id),
      summary: Keyword.get(opts, :summary),
      memory_type: Keyword.get(opts, :memory_type, "general"),
      salience: Keyword.get(opts, :salience),
      metadata: Keyword.get(opts, :memory_metadata, %{})
    ]
    |> compact_nil()
  end

  defp compact_nil(opts) do
    Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
  end
end
