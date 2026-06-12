defmodule OptimalEngine.MemoryCore.ClaimExtractor do
  @moduledoc """
  Source Package -> Claim extraction for the Truth Lifecycle.

  Extraction is intentionally conservative: it does not pretend extraction is
  truth. Source text becomes an unreviewed, pending Claim that only the
  `OptimalEngine.MemoryCore.FactPromoter` review boundary can turn into a
  Fact. Every extraction persists the Source Package, the Claim, a
  `supports` relationship edge, and a derivation ledger entry.
  """

  alias OptimalEngine.MemoryCore.{
    Claim,
    DerivationLedgerEntry,
    ID,
    RelationshipEdge,
    ScoringPolicy,
    SourcePackage,
    Store
  }

  @doc """
  Extract a single Claim from a Source Package.

  Callers may pass structured anchors (`:subject_anchor`, `:action_class`,
  `:object_anchor`) and explicit scores; otherwise the source text becomes an
  unreviewed assertion claim scored by `ScoringPolicy.claim_scores/2`.

  Returns `{:ok, %Claim{}}` with `status: "pending"`.
  """
  @spec extract_from_source(SourcePackage.t(), keyword()) :: {:ok, Claim.t()} | {:error, term()}
  def extract_from_source(%SourcePackage{} = source_package, opts \\ []) do
    claim_text = string_opt(opts, :claim_text, source_package.raw_text)
    now = timestamp()
    scores = ScoringPolicy.claim_scores(source_package, opts)

    claim =
      Claim.new(%{
        id:
          ID.content_id("cl", [
            source_package.tenant_id,
            ":",
            source_package.workspace_id,
            ":",
            source_package.id,
            ":",
            claim_text
          ]),
        tenant_id: source_package.tenant_id,
        workspace_id: source_package.workspace_id,
        source_package_id: source_package.id,
        signal_id: string_or_nil(Keyword.get(opts, :signal_id)),
        claim_text: claim_text,
        claim_type: string_opt(opts, :claim_type, "assertion"),
        subject_anchor: string_or_nil(Keyword.get(opts, :subject_anchor)),
        action_class: string_or_nil(Keyword.get(opts, :action_class)),
        object_anchor: string_or_nil(Keyword.get(opts, :object_anchor)),
        semantic_frame: Keyword.get(opts, :semantic_frame, %{}),
        source_span: Keyword.get(opts, :source_span, %{}),
        extraction_run_id: string_or_nil(Keyword.get(opts, :extraction_run_id)),
        evaluator_id:
          string_or_nil(
            Keyword.get(opts, :evaluator_id) || Keyword.get(opts, :extracted_by) ||
              Keyword.get(opts, :actor_id)
          ),
        aggregate_confidence: scores.confidence,
        aggregate_precision: scores.precision,
        raw_component_scores: scores.raw_component_scores,
        calibration_dataset_version: string_or_nil(scores.calibration_dataset_version),
        access_policy_id: source_package.access_policy_id,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        lifecycle_state: string_opt(opts, :lifecycle_state, "pending"),
        review_status: string_opt(opts, :review_status, "unreviewed"),
        valid_time_start: serialize_time(Keyword.get(opts, :valid_time_start)),
        valid_time_end: serialize_time(Keyword.get(opts, :valid_time_end)),
        transaction_time_start: now,
        transaction_time_end: nil,
        stale_after: serialize_time(Keyword.get(opts, :stale_after)),
        metadata: Keyword.get(opts, :metadata, %{})
      })

    source_ref = ref("source_package", source_package.id)
    claim_ref = ref("claim", claim.id)

    ledger =
      DerivationLedgerEntry.new(
        "memory_core.extract_claim",
        "source_package_to_claim",
        [source_ref],
        [claim_ref],
        tenant_id: source_package.tenant_id,
        workspace_id: source_package.workspace_id,
        source_package_links: [source_ref],
        evidence_links: [source_ref],
        actor_id: Keyword.get(opts, :actor_id),
        evaluator_id: claim.evaluator_id,
        parser_id: string_opt(opts, :parser_id, "optimal_engine.memory_core.claim_extractor"),
        confidence_delta: claim.aggregate_confidence,
        precision_delta: claim.aggregate_precision,
        scoring_policy_version: ScoringPolicy.version(),
        access_policy_id: source_package.access_policy_id,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        metadata: %{claim_type: claim.claim_type}
      )

    edge =
      RelationshipEdge.between(
        source_package,
        {"source_package", source_package.id},
        {"claim", claim.id},
        "supports",
        confidence: claim.aggregate_confidence,
        precision_score: claim.aggregate_precision,
        evidence_links: [source_ref]
      )

    with :ok <- Store.insert_source_package(source_package),
         :ok <- Store.insert_claim(claim),
         :ok <- Store.insert_relationship_edge(edge),
         :ok <- Store.insert_derivation_entry(ledger) do
      {:ok, claim}
    end
  end

  defp ref(type, id), do: DerivationLedgerEntry.object_ref(type, id)

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp serialize_time(nil), do: nil
  defp serialize_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize_time(value) when is_binary(value), do: value
  defp serialize_time(value), do: to_string(value)

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
