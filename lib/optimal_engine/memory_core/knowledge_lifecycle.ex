defmodule OptimalEngine.MemoryCore.KnowledgeLifecycle do
  @moduledoc """
  Governed Source -> Claim -> Fact -> Memory Object lifecycle.

  This is intentionally conservative. It does not pretend extraction is truth.
  Source text first becomes an unreviewed Claim. A Claim can then be promoted
  into a Fact only through this lifecycle boundary, with evidence links,
  verification metadata, relationship edges, and derivation ledger entries.
  """

  alias OptimalEngine.MemoryCore.{DerivationLedgerEntry, ID, SourcePackage, Store}

  @doc """
  Extract a single Claim from a Source Package.

  The first implementation is deterministic and policy-oriented: callers may
  pass structured anchors, but if they do not, the source text becomes an
  unreviewed assertion claim rather than accepted truth.
  """
  @spec extract_claim(SourcePackage.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_claim(%SourcePackage{} = source_package, opts \\ []) do
    claim_text = string_opt(opts, :claim_text, source_package.raw_text)
    now = timestamp()

    claim = %{
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
      evaluator_id: string_or_nil(Keyword.get(opts, :evaluator_id)),
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence, 0.55),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, 0.55),
      raw_component_scores: Keyword.get(opts, :raw_component_scores, %{}),
      calibration_dataset_version: string_or_nil(Keyword.get(opts, :calibration_dataset_version)),
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
    }

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
        evaluator_id: Keyword.get(opts, :evaluator_id),
        parser_id: string_opt(opts, :parser_id, "optimal_engine.memory_core.knowledge_lifecycle"),
        confidence_delta: claim.aggregate_confidence,
        precision_delta: claim.aggregate_precision,
        access_policy_id: source_package.access_policy_id,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        metadata: %{claim_type: claim.claim_type}
      )

    edge =
      relationship_edge(
        source_package,
        "source_package",
        source_package.id,
        "claim",
        claim.id,
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

  @doc """
  Promote a Claim into a Fact.

  This does not delete or overwrite the Claim. The Fact points back to accepted
  Claim IDs and source evidence. Corrections/supersession will be a later
  lifecycle stage.
  """
  @spec promote_claim_to_fact(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def promote_claim_to_fact(claim, opts \\ []) when is_map(claim) do
    now = timestamp()
    fact_text = string_opt(opts, :fact_text, claim.claim_text)
    claim_ref = ref("claim", claim.id)
    source_ref = ref("source_package", claim.source_package_id)

    fact = %{
      id:
        ID.content_id("fact", [
          claim.tenant_id,
          ":",
          claim.workspace_id,
          ":",
          claim.id,
          ":",
          fact_text
        ]),
      tenant_id: claim.tenant_id,
      workspace_id: claim.workspace_id,
      fact_text: fact_text,
      fact_type: string_opt(opts, :fact_type, claim.claim_type || "assertion"),
      subject_anchor: string_or_nil(Keyword.get(opts, :subject_anchor) || claim.subject_anchor),
      action_class: string_or_nil(Keyword.get(opts, :action_class) || claim.action_class),
      object_anchor: string_or_nil(Keyword.get(opts, :object_anchor) || claim.object_anchor),
      scope: Keyword.get(opts, :scope, %{}),
      accepted_claim_ids: [claim.id],
      supporting_evidence_links: [source_ref, claim_ref],
      contradicting_evidence_links: Keyword.get(opts, :contradicting_evidence_links, []),
      verifier_id: string_or_nil(Keyword.get(opts, :verifier_id) || Keyword.get(opts, :actor_id)),
      verification_status: string_opt(opts, :verification_status, "verified"),
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence, claim.aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, claim.aggregate_precision),
      raw_component_scores: Keyword.get(opts, :raw_component_scores, %{}),
      access_policy_id: Map.get(claim, :access_policy_id),
      security_labels: Map.get(claim, :security_labels, []),
      partition_ids: Map.get(claim, :partition_ids, []),
      lifecycle_state: string_opt(opts, :lifecycle_state, "accepted"),
      contradiction_status: string_opt(opts, :contradiction_status, "none"),
      event_time: serialize_time(Keyword.get(opts, :event_time)),
      valid_time_start:
        serialize_time(Keyword.get(opts, :valid_time_start) || claim.valid_time_start),
      valid_time_end: serialize_time(Keyword.get(opts, :valid_time_end) || claim.valid_time_end),
      transaction_time_start: now,
      transaction_time_end: nil,
      verification_time: serialize_time(Keyword.get(opts, :verification_time)) || now,
      stale_after: serialize_time(Keyword.get(opts, :stale_after)),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    fact_ref = ref("fact", fact.id)

    ledger =
      DerivationLedgerEntry.new(
        "memory_core.promote_fact",
        "claim_to_fact",
        [claim_ref],
        [fact_ref],
        tenant_id: fact.tenant_id,
        workspace_id: fact.workspace_id,
        source_package_links: [source_ref],
        evidence_links: [source_ref, claim_ref],
        actor_id: Keyword.get(opts, :actor_id),
        evaluator_id: fact.verifier_id,
        confidence_delta: fact.aggregate_confidence - Map.get(claim, :aggregate_confidence, 0.5),
        precision_delta: fact.aggregate_precision - Map.get(claim, :aggregate_precision, 0.5),
        access_policy_id: fact.access_policy_id,
        security_labels: fact.security_labels,
        partition_ids: fact.partition_ids,
        metadata: %{verification_status: fact.verification_status}
      )

    edge =
      relationship_edge(claim, "claim", claim.id, "fact", fact.id, "supports",
        confidence: fact.aggregate_confidence,
        precision_score: fact.aggregate_precision,
        evidence_links: [source_ref, claim_ref]
      )

    with :ok <- Store.insert_fact(fact),
         :ok <- Store.insert_relationship_edge(edge),
         :ok <- Store.insert_derivation_entry(ledger) do
      {:ok, fact}
    end
  end

  @doc """
  Build a Memory Object around an accepted Fact.
  """
  @spec build_memory_object(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_memory_object(fact, opts \\ []) when is_map(fact) do
    now = timestamp()
    summary = string_opt(opts, :summary, fact.fact_text)
    fact_ref = ref("fact", fact.id)
    claim_refs = Enum.map(Map.get(fact, :accepted_claim_ids, []), &ref("claim", &1))
    source_refs = source_refs_from_fact(fact)

    memory = %{
      id:
        ID.content_id("memobj", [
          fact.tenant_id,
          ":",
          fact.workspace_id,
          ":",
          fact.id,
          ":",
          summary
        ]),
      tenant_id: fact.tenant_id,
      workspace_id: fact.workspace_id,
      memory_type: string_opt(opts, :memory_type, "general"),
      summary: summary,
      subject_anchor: string_or_nil(Keyword.get(opts, :subject_anchor) || fact.subject_anchor),
      action_class: string_or_nil(Keyword.get(opts, :action_class) || fact.action_class),
      semantic_frame: Keyword.get(opts, :semantic_frame, %{}),
      salience: Keyword.get(opts, :salience, 0.5),
      fact_links: [fact_ref],
      claim_links: claim_refs,
      source_package_links: source_refs,
      evidence_links: [fact_ref | claim_refs] ++ source_refs,
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence, fact.aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, fact.aggregate_precision),
      access_policy_id: Map.get(fact, :access_policy_id),
      security_labels: Map.get(fact, :security_labels, []),
      partition_ids: Map.get(fact, :partition_ids, []),
      lifecycle_state: string_opt(opts, :lifecycle_state, "current"),
      staleness_status: string_opt(opts, :staleness_status, "current"),
      supersession_status: string_opt(opts, :supersession_status, "none"),
      event_time: serialize_time(Keyword.get(opts, :event_time) || fact.event_time),
      valid_time_start:
        serialize_time(Keyword.get(opts, :valid_time_start) || fact.valid_time_start),
      valid_time_end: serialize_time(Keyword.get(opts, :valid_time_end) || fact.valid_time_end),
      transaction_time_start: now,
      transaction_time_end: nil,
      stale_after: serialize_time(Keyword.get(opts, :stale_after) || fact.stale_after),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    memory_ref = ref("memory_object", memory.id)

    ledger =
      DerivationLedgerEntry.new(
        "memory_core.build_memory_object",
        "fact_to_memory_object",
        [fact_ref],
        [memory_ref],
        tenant_id: memory.tenant_id,
        workspace_id: memory.workspace_id,
        source_package_links: source_refs,
        evidence_links: memory.evidence_links,
        actor_id: Keyword.get(opts, :actor_id),
        access_policy_id: memory.access_policy_id,
        security_labels: memory.security_labels,
        partition_ids: memory.partition_ids,
        metadata: %{memory_type: memory.memory_type}
      )

    edge =
      relationship_edge(fact, "fact", fact.id, "memory_object", memory.id, "supports",
        confidence: memory.aggregate_confidence,
        precision_score: memory.aggregate_precision,
        evidence_links: memory.evidence_links
      )

    with :ok <- Store.insert_memory_object(memory),
         :ok <- Store.insert_relationship_edge(edge),
         :ok <- Store.insert_derivation_entry(ledger) do
      {:ok, memory}
    end
  end

  @doc """
  Record that a newly accepted Fact supersedes an earlier current Fact.

  Supersession does not delete the old Fact. It closes the old current validity
  window, marks its lifecycle as superseded, and writes a typed Relationship Edge
  plus Derivation Ledger entry so retrieval and audit can explain the replacement.
  """
  @spec record_fact_supersession(map(), map(), keyword()) :: :ok | {:error, term()}
  def record_fact_supersession(new_fact, old_fact, opts \\ [])
      when is_map(new_fact) and is_map(old_fact) do
    new_ref = ref("fact", new_fact.id)
    old_ref = ref("fact", old_fact.id)

    edge =
      relationship_edge(new_fact, "fact", new_fact.id, "fact", old_fact.id, "supersedes",
        confidence: Map.get(new_fact, :aggregate_confidence, 0.5),
        precision_score: Map.get(new_fact, :aggregate_precision, 0.5),
        evidence_links: [new_ref, old_ref],
        metadata: %{
          supersession_reason: Keyword.get(opts, :reason, "reviewer accepted replacement fact")
        }
      )

    ledger =
      DerivationLedgerEntry.new(
        "memory_core.supersede_fact",
        "fact_supersession",
        [old_ref, new_ref],
        [new_ref],
        tenant_id: new_fact.tenant_id,
        workspace_id: new_fact.workspace_id,
        evidence_links: [old_ref, new_ref],
        actor_id: Keyword.get(opts, :actor_id),
        evaluator_id: Keyword.get(opts, :evaluator_id) || Keyword.get(opts, :actor_id),
        confidence_delta:
          Map.get(new_fact, :aggregate_confidence, 0.5) -
            Map.get(old_fact, :aggregate_confidence, 0.5),
        precision_delta:
          Map.get(new_fact, :aggregate_precision, 0.5) -
            Map.get(old_fact, :aggregate_precision, 0.5),
        access_policy_id: Map.get(new_fact, :access_policy_id),
        security_labels: Map.get(new_fact, :security_labels, []),
        partition_ids: Map.get(new_fact, :partition_ids, []),
        metadata: %{
          superseded_fact_id: old_fact.id,
          replacement_fact_id: new_fact.id,
          reason: Keyword.get(opts, :reason)
        }
      )

    with :ok <-
           Store.mark_fact_superseded(old_fact.id,
             tenant_id: old_fact.tenant_id,
             workspace_id: old_fact.workspace_id,
             valid_time_end: Keyword.get(opts, :valid_time_end)
           ),
         :ok <- Store.insert_relationship_edge(edge),
         :ok <- Store.insert_derivation_entry(ledger) do
      :ok
    end
  end

  defp relationship_edge(scope, from_type, from_id, to_type, to_id, relationship_type, opts) do
    %{
      id:
        ID.content_id("edge", [
          scope.workspace_id,
          ":",
          from_type,
          ":",
          from_id,
          ":",
          to_type,
          ":",
          to_id,
          ":",
          relationship_type
        ]),
      tenant_id: scope.tenant_id,
      workspace_id: scope.workspace_id,
      from_object_type: from_type,
      from_object_id: from_id,
      to_object_type: to_type,
      to_object_id: to_id,
      relationship_type: relationship_type,
      confidence: Keyword.get(opts, :confidence, 0.5),
      precision_score: Keyword.get(opts, :precision_score, 0.5),
      evidence_links: Keyword.get(opts, :evidence_links, []),
      access_policy_id: Map.get(scope, :access_policy_id),
      security_labels: Map.get(scope, :security_labels, []),
      partition_ids: Map.get(scope, :partition_ids, []),
      lifecycle_state: "current",
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp source_refs_from_fact(fact) do
    fact
    |> Map.get(:supporting_evidence_links, [])
    |> Enum.filter(fn
      %{type: "source_package"} -> true
      %{"type" => "source_package"} -> true
      _ -> false
    end)
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
