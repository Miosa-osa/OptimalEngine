defmodule OptimalEngine.Sync.Lineage do
  @moduledoc """
  Where each replicated table gets its data class from.

  A replicated row stays on its Engine when its class is above the peer's
  `max_class`. Few tables carry a `security_labels` column, but many hold
  text or vectors copied from a row that does: a memory is the text of a
  source package, a chunk is a slice of a document, an embedding is a vector
  of either. This module names, for every table `OptimalEngine.Sync.Capture`
  replicates, what the row's class is made of:

    * its own labels: a `security_labels` column, the `security_labels` key
      of a `metadata` column, or a `classification_level` column;
    * the rows it derives from, found through its link columns (`refs`):
      a row is as classified as the most classified row it points at;
    * `special` lookups for rows that are pointed at rather than pointing
      (a document is linked from the derivation ledger entry that produced
      it, not the other way round).

  Table kinds:

    * `:labelled` has its own labels and may also point at its sources;
    * `:derived` has no labels of its own and takes its class from its
      sources;
    * `:aggregate` is computed over the workspace with no per-row lineage; it
      stays home while the workspace holds anything above the gate;
    * `:structural` holds configuration, ids or numbers, no content copied
      from another row.

  `OptimalEngine.Sync.Gate` reads this map. A table missing from it is held
  back, and a test fails until it is classified here.
  """

  alias OptimalEngine.MemoryCore.SecurityLabels

  @typedoc """
  A link column:

    * `{:id, column, table}` the id of a row of `table`;
    * `{:typed, type_column, id_column}` an id and the type naming its table;
    * `{:links, column}` a JSON list of ids or `%{"type", "id"}` objects;
    * `{:json_ids, column, table}` a JSON list of ids of `table`;
    * `{:json_map, column, %{key => table}}` a JSON object with ids under keys;
    * `{:meta_id, key, table}` an id under `key` of the row's `metadata`;
    * `{:uris, column}` the ids inside the `optimal://` addresses in a text
      column.
  """
  @type ref_def ::
          {:id, String.t(), String.t()}
          | {:typed, String.t(), String.t()}
          | {:links, String.t()}
          | {:json_ids, String.t(), String.t()}
          | {:json_map, String.t(), %{String.t() => String.t()}}
          | {:meta_id, String.t(), String.t()}
          | {:uris, String.t()}

  @type t :: %{
          kind: :labelled | :derived | :aggregate | :structural,
          key: String.t() | nil,
          table: String.t(),
          labels: boolean(),
          partitions: boolean(),
          meta: String.t() | nil,
          class: String.t() | nil,
          refs: [ref_def()],
          extra: [String.t()],
          special: [atom()]
        }

  @type ref :: {:row, String.t(), String.t()} | {:any, String.t()} | :overflow

  @uri_refs 1_000

  # -- the map --------------------------------------------------------------------

  @source_links [{:links, "source_package_links"}, {:links, "evidence_links"}]
  @entities [
    {:id, "subject_entity_id", "canonical_entities"},
    {:id, "object_entity_id", "canonical_entities"}
  ]
  @asset_parents [{:id, "asset_id", "assets"}, {:id, "source_package_id", "source_packages"}]
  @asset_children @asset_parents ++
                    [
                      {:id, "adapter_run_id", "asset_adapter_runs"},
                      {:id, "extraction_id", "asset_extractions"}
                    ]
  @chunk_parent [{:id, "chunk_id", "chunks"}]
  @context_parent [{:id, "context_id", "contexts"}]

  @specs %{
    # Rows with their own labels.
    #
    # A source package or claim raised by a fact conflict (`Sync`) names the
    # fact in its metadata, so it is held as long as the fact is.
    "source_packages" => {:labelled, [{:meta_id, "fact_id", "facts"}], meta: "metadata"},
    "claims" =>
      {:labelled,
       [
         {:id, "source_package_id", "source_packages"},
         {:id, "signal_id", "contexts"},
         {:meta_id, "fact_id", "facts"}
       ] ++ @entities, meta: "metadata"},
    "facts" =>
      {:labelled,
       [
         {:json_ids, "accepted_claim_ids", "claims"},
         {:links, "supporting_evidence_links"},
         {:links, "contradicting_evidence_links"}
       ] ++ @entities},
    "memory_objects" =>
      {:labelled, [{:links, "fact_links"}, {:links, "claim_links"}] ++ @source_links},
    "memory_detail_objects" =>
      {:labelled, [{:typed, "parent_object_type", "parent_object_id"}] ++ @source_links},
    "relationship_edges" =>
      {:labelled,
       [
         {:typed, "from_object_type", "from_object_id"},
         {:typed, "to_object_type", "to_object_id"},
         {:links, "evidence_links"}
       ]},
    "derivation_ledger" =>
      {:labelled,
       [
         {:links, "input_object_links"},
         {:links, "source_package_links"},
         {:links, "evidence_links"}
       ]},
    "episodes" =>
      {:labelled,
       [
         {:json_map, "provenance",
          %{
            "source_package_id" => "source_packages",
            "claim_id" => "claims",
            "claim_ids" => "claims",
            "signal_id" => "contexts",
            "context_id" => "contexts"
          }}
       ]},
    "workflow_traces" =>
      {:labelled,
       [
         {:links, "episode_links"},
         {:links, "step_links"},
         {:links, "input_links"},
         {:links, "source_package_links"},
         {:links, "evidence_links"}
       ]},
    "generalized_workflows" =>
      {:labelled,
       [
         {:links, "workflow_trace_links"},
         {:links, "supporting_episode_links"},
         {:links, "contradicting_trace_links"},
         {:links, "step_pattern_links"}
       ]},
    "procedural_memory_objects" =>
      {:labelled,
       [
         {:links, "generalized_workflow_links"},
         {:links, "step_links"},
         {:links, "validation_links"},
         {:links, "evidence_links"}
       ]},
    "skill_packages" =>
      {:labelled,
       [
         {:links, "procedural_memory_links"},
         {:links, "workflow_links"},
         {:links, "validation_links"},
         {:links, "evidence_links"}
       ]},
    "active_memory_pools" =>
      {:labelled,
       [
         {:links, "loaded_context_links"},
         {:links, "context_package_links"},
         {:links, "promotion_candidate_links"}
       ] ++ @source_links},
    "context_packages" =>
      {:labelled,
       [
         {:links, "memory_links"},
         {:links, "fact_links"},
         {:links, "workflow_links"},
         {:links, "skill_package_links"},
         {:links, "returned_object_links"},
         {:id, "active_memory_pool_id", "active_memory_pools"}
       ] ++ @source_links},
    "memory_associations" =>
      {:labelled,
       [
         {:typed, "from_object_type", "from_object_id"},
         {:typed, "to_object_type", "to_object_id"}
       ] ++ @source_links},
    "model_call_operations" => {:labelled, []},
    "model_call_runs" =>
      {:labelled,
       [
         {:id, "model_call_operation_id", "model_call_operations"},
         {:id, "active_memory_pool_id", "active_memory_pools"},
         {:links, "source_package_links"},
         {:links, "observation_links"}
       ]},
    "mcp_tool_definitions" => {:labelled, []},
    "tool_call_runs" =>
      {:labelled,
       [
         {:id, "mcp_tool_definition_id", "mcp_tool_definitions"},
         {:id, "active_memory_pool_id", "active_memory_pools"},
         {:links, "source_package_links"},
         {:links, "observation_links"}
       ]},
    "canonical_entities" => {:labelled, [], partitions: false, special: [:entity_sources]},
    "assets" => {:labelled, [{:id, "source_package_id", "source_packages"}]},
    "asset_adapter_runs" => {:labelled, @asset_parents},
    "asset_extractions" =>
      {:labelled, @asset_parents ++ [{:id, "adapter_run_id", "asset_adapter_runs"}]},
    "asset_transcripts" => {:labelled, @asset_children},
    "asset_ocr_spans" => {:labelled, @asset_children},
    "asset_visual_observations" => {:labelled, @asset_children},
    "asset_embedding_refs" => {:labelled, @asset_children},

    # Memories. The versioned memory has no label column: a labelled memory
    # carries its labels in `metadata`, and points at the source package and
    # claim it was staged from. A source package of a memory written through
    # `Memory.create/1` points at the memory instead (`:memory_sources`). A
    # version is as classified as every version behind it (`:memory_chain`,
    # which reads `parent_memory_id` and `root_memory_id` itself, one read per
    # version, and does not recurse).
    "memories" =>
      {:derived,
       [
         {:meta_id, "memory_core_source_package_id", "source_packages"},
         {:meta_id, "memory_core_pending_claim_id", "claims"},
         {:id, "source_chunk_id", "chunks"},
         {:uris, "citation_uri"}
       ],
       meta: "metadata",
       extra: ["parent_memory_id", "root_memory_id"],
       special: [:memory_sources, :memory_chain]},
    "memory_embeddings" => {:derived, [{:id, "memory_id", "memories"}], key: nil},
    "memory_relations" =>
      {:derived, [{:id, "source_memory_id", "memories"}, {:id, "target_memory_id", "memories"}]},

    # Documents. A context points at its source package (new rows) or is
    # pointed at by the derivation ledger entry that produced it (older rows);
    # chunks, vectors and what is read off them follow the context.
    "contexts" =>
      {:derived, [{:meta_id, "source_package_id", "source_packages"}],
       meta: "metadata", special: [:context_sources]},
    "chunks" =>
      {:derived, [{:id, "signal_id", "contexts"}, {:id, "parent_id", "chunks"}],
       class: "classification_level"},
    "chunk_embeddings" => {:derived, @chunk_parent, key: nil},
    "vectors" => {:derived, @context_parent, key: "context_id"},
    "classifications" => {:derived, @chunk_parent},
    "intents" => {:derived, @chunk_parent},
    "cluster_members" => {:derived, @chunk_parent},
    "clusters" => {:derived, [], special: [:cluster_members]},
    "citations" => {:derived, @chunk_parent},
    "wiki_pages" => {:derived, [], key: nil, special: [:wiki_page]},
    "edges" =>
      {:derived, [{:id, "source_id", "contexts"}, {:id, "target_id", "contexts"}], special: [:edge]},
    "entities" => {:derived, @context_parent},
    "decisions" => {:derived, @context_parent},
    "signal_events" => {:derived, @context_parent},
    "open_loops" => {:derived, [{:id, "source_context_id", "contexts"}, {:uris, "source_uri"}]},
    "observations" => {:derived, [{:id, "source", "contexts"}]},
    "data_files" => {:derived, [{:id, "asset_id", "assets"}]},

    # The entity spine.
    "entity_mentions" =>
      {:derived,
       [
         {:id, "source_package_id", "source_packages"},
         {:id, "context_id", "contexts"},
         {:id, "resolved_entity_id", "canonical_entities"}
       ]},
    "entity_aliases" =>
      {:derived,
       [{:id, "source_package_id", "source_packages"}, {:id, "entity_id", "canonical_entities"}]},
    "entity_identifiers" =>
      {:derived,
       [{:id, "source_package_id", "source_packages"}, {:id, "entity_id", "canonical_entities"}]},
    "resolution_decisions" =>
      {:derived,
       [{:id, "mention_id", "entity_mentions"}, {:id, "selected_entity_id", "canonical_entities"}]},
    "entity_lineage" =>
      {:derived,
       [
         {:id, "predecessor_entity_id", "canonical_entities"},
         {:id, "successor_entity_id", "canonical_entities"}
       ]},

    # Work done on a source.
    "training_examples" => {:derived, [{:id, "source_package_id", "source_packages"}]},
    "decomposition_runs" => {:derived, [{:id, "source_package_id", "source_packages"}]},
    "evaluation_cases" =>
      {:derived,
       [{:id, "context_package_id", "context_packages"}, {:links, "retrieved_object_links"}]},
    "memory_reconstruction_runs" =>
      {:derived,
       [
         {:id, "context_package_id", "context_packages"},
         {:links, "evidence"},
         {:links, "citations"}
       ]},
    "memory_reconstruction_outcomes" => {:derived, [{:id, "run_id", "memory_reconstruction_runs"}]},
    "memory_association_paths" =>
      {:derived,
       [
         {:id, "run_id", "memory_reconstruction_runs"},
         {:json_ids, "association_ids", "memory_associations"},
         {:links, "evidence_links"}
       ]},
    "memory_path_feedback" => {:derived, [{:typed, "object_type", "object_id"}], key: nil},
    "memory_consolidation_proposals" => {:derived, [{:links, "member_links"}]},
    "export_records" => {:derived, [{:typed, "source_object_type", "source_object_id"}]},
    "projection_revisions" =>
      {:derived, [{:id, "export_record_id", "export_records"}, {:links, "source_object_links"}]},
    "link_health_records" =>
      {:derived,
       [
         {:id, "export_record_id", "export_records"},
         {:id, "projection_revision_id", "projection_revisions"}
       ]},

    # Computed over the workspace, with no row to point at: reports and
    # dashboards that quote claims, titles and loops, notes rendered from the
    # open loops, and the summaries of conversations.
    "analysis_reports" => {:aggregate, []},
    "data_quality_snapshots" => {:aggregate, []},
    "rhythm_notes" => {:aggregate, [], key: nil},
    "sessions" => {:aggregate, []},

    # Configuration, ids and numbers.
    "architectures" => {:structural, []},
    "connectors" => {:structural, []},
    "data_changes" => {:structural, []},
    "data_collections" => {:structural, []},
    "data_schema_migrations" => {:structural, []},
    "dead_letter_jobs" => {:structural, []},
    "evaluation_runs" => {:structural, []},
    "jobs" => {:structural, []},
    "memory_path_priors" => {:structural, []},
    "model_adapters" => {:structural, []},
    "node_members" => {:structural, []},
    "node_relationships" => {:structural, []},
    "node_types" => {:structural, []},
    "nodes" => {:structural, []},
    "optimality_assessments" => {:structural, []},
    "principal_skills" => {:structural, []},
    "rhythm_templates" => {:structural, []},
    "routing_rules" => {:structural, []},
    "skills" => {:structural, []},
    "storage_provider_configs" => {:structural, []},
    "surfacing_subscriptions" => {:structural, []},
    "topology_change_requests" => {:structural, []},
    "training_runs" => {:structural, []},
    "workspace_members" => {:structural, []},
    "workspace_storage_policies" => {:structural, []}
  }

  @tables Map.new(@specs, fn
            {table, {kind, refs}} -> {table, {kind, refs, []}}
            {table, {kind, refs, opts}} -> {table, {kind, refs, opts}}
          end)

  # Rows that carry a class of their own (or stand for one): a link to a row
  # of these that no longer exists cannot be read, so it is not trusted.
  @labelled for {table, {:labelled, _, _}} <- @tables, do: table
  @anchors ["memories" | @labelled]

  # Where a link without a type is looked for, in this order.
  @any_tables ~w(source_packages claims facts memory_objects memories episodes memory_detail_objects
                 relationship_edges context_packages workflow_traces generalized_workflows
                 procedural_memory_objects skill_packages active_memory_pools memory_associations
                 derivation_ledger assets asset_extractions asset_adapter_runs canonical_entities
                 contexts chunks)

  @types %{
    "source_package" => "source_packages",
    "claim" => "claims",
    "fact" => "facts",
    "memory_object" => "memory_objects",
    "memory_detail_object" => "memory_detail_objects",
    "relationship_edge" => "relationship_edges",
    "edge" => "relationship_edges",
    "episode" => "episodes",
    "memory" => "memories",
    "durable_memory" => "memories",
    "versioned_memory" => "memories",
    "signal" => "contexts",
    "context" => "contexts",
    "chunk" => "chunks",
    "asset" => "assets",
    "asset_adapter_run" => "asset_adapter_runs",
    "asset_extraction" => "asset_extractions",
    "workflow_trace" => "workflow_traces",
    "generalized_workflow" => "generalized_workflows",
    "procedural_memory_object" => "procedural_memory_objects",
    "procedural_memory" => "procedural_memory_objects",
    "skill_package" => "skill_packages",
    "context_package" => "context_packages",
    "active_memory_pool" => "active_memory_pools",
    "memory_association" => "memory_associations",
    "association" => "memory_associations",
    "derivation_ledger" => "derivation_ledger",
    "ledger" => "derivation_ledger",
    "entity" => "canonical_entities",
    "canonical_entity" => "canonical_entities",
    "export_record" => "export_records",
    "projection_revision" => "projection_revisions",
    "reconstruction_run" => "memory_reconstruction_runs"
  }

  # -- reading the map -------------------------------------------------------------

  @doc "The tables the map classifies."
  @spec tables() :: [String.t()]
  def tables, do: @tables |> Map.keys() |> Enum.sort()

  @doc "How a table's class is made up, or nil for a table the map does not know."
  @spec spec(String.t()) :: t() | nil
  def spec(table) do
    case Map.get(@tables, table) do
      nil ->
        nil

      {kind, refs, opts} ->
        %{
          kind: kind,
          table: table,
          key: Keyword.get(opts, :key, if(kind == :structural, do: nil, else: "id")),
          labels: kind == :labelled,
          partitions: Keyword.get(opts, :partitions, kind == :labelled),
          meta: Keyword.get(opts, :meta),
          class: Keyword.get(opts, :class),
          refs: refs,
          extra: Keyword.get(opts, :extra, []),
          special: Keyword.get(opts, :special, [])
        }
    end
  end

  @doc "True for tables whose rows carry a class that a missing row cannot restate."
  @spec anchor?(String.t()) :: boolean()
  def anchor?(table), do: table in @anchors

  @doc "The tables searched for a link that names no type."
  @spec any_tables() :: [String.t()]
  def any_tables, do: @any_tables

  @doc "The table a link type names, or nil."
  @spec table_for_type(term()) :: String.t() | nil
  def table_for_type(type) when is_binary(type),
    do: Map.get(@types, type |> String.trim() |> String.downcase())

  def table_for_type(type) when is_atom(type) and not is_nil(type),
    do: table_for_type(Atom.to_string(type))

  def table_for_type(_type), do: nil

  @doc "Every column of `table` the map reads: what is loaded to classify a row that is pointed at."
  @spec columns(t()) :: [String.t()]
  def columns(spec) do
    ref_columns =
      Enum.flat_map(spec.refs, fn
        {:id, column, _table} -> [column]
        {:typed, type_column, id_column} -> [type_column, id_column]
        {:links, column} -> [column]
        {:json_ids, column, _table} -> [column]
        {:json_map, column, _mapping} -> [column]
        {:uris, column} -> [column]
        {:meta_id, _key, _table} -> []
      end)

    ([spec.key] ++
       [
         if(spec.labels, do: "security_labels"),
         if(spec.partitions, do: "partition_ids"),
         spec.meta,
         spec.class
       ] ++ spec.extra ++ ref_columns)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # -- reading a row ----------------------------------------------------------------

  @doc """
  What a row carries itself, as the tokens a reader's grants are compared
  with (`OptimalEngine.MemoryCore.SecurityLabels`): its labels column, its
  partitions, the labels and partitions in its metadata and its
  classification level. Nil when it carries none. A value that cannot be read
  is the `unresolved` token.
  """
  @spec own_tokens(t(), map()) :: MapSet.t(SecurityLabels.token()) | nil
  def own_tokens(spec, row) do
    tokens =
      Enum.flat_map(
        [
          spec.labels && SecurityLabels.tokens(row["security_labels"]),
          spec.partitions && SecurityLabels.partition_tokens(row["partition_ids"]),
          spec.meta && SecurityLabels.metadata_tokens(row[spec.meta]),
          spec.class && class_tokens(row[spec.class])
        ],
        &(&1 || [])
      )

    if tokens == [], do: nil, else: MapSet.new(tokens)
  end

  @doc """
  The class a row carries itself: the highest class among `own_tokens/2`. Nil
  when it names none. An unreadable value ranks restricted.
  """
  @spec own_rank(t(), map()) :: SecurityLabels.rank() | nil
  def own_rank(spec, row), do: spec |> own_tokens(row) |> SecurityLabels.token_rank()

  # A classification level: `internal` is the column's default and says
  # nothing; a level this Engine does not know cannot be read.
  defp class_tokens(value) when value in [nil, ""], do: []

  defp class_tokens(value) do
    case SecurityLabels.class_rank(value) do
      nil -> [SecurityLabels.unresolved()]
      rank when rank > 1 -> [{:label, value |> to_string() |> String.trim() |> String.downcase()}]
      _internal_or_lower -> []
    end
  end

  @doc "The rows a row points at, through the link columns of its table."
  @spec refs(t(), map()) :: [ref()]
  def refs(spec, row), do: Enum.flat_map(spec.refs, &extract(&1, row, spec))

  @doc "The rows a free-form value (a JSON list or object of links) points at."
  @spec link_refs(term()) :: [ref()]
  def link_refs(value), do: value |> decode() |> links()

  @doc """
  The rows named by the `optimal://` addresses in a text (a wiki page body, a
  citation): every id-shaped piece of each address, whichever of `/`, `#` or
  `?` separates it. More than 1,000 pieces cannot be followed and come back
  as `:overflow`, which the gate does not trust.
  """
  @spec uri_refs(term()) :: [ref()]
  def uri_refs(text) when is_binary(text) do
    refs =
      ~r|optimal://[^\s)}\]>"']+|
      |> Regex.scan(text)
      |> Enum.flat_map(fn [uri] ->
        uri
        |> String.replace_prefix("optimal://", "")
        |> String.split(~r/[^A-Za-z0-9_\-:.]+/, trim: true)
      end)
      |> Enum.uniq()
      |> Enum.flat_map(&any/1)

    if length(refs) > @uri_refs, do: [:overflow], else: refs
  end

  def uri_refs(_text), do: []

  @doc "The row a bare id points at, if it can be an Engine id."
  @spec id_refs(term()) :: [ref()]
  def id_refs(id) when is_binary(id), do: any(id)
  def id_refs(_id), do: []

  defp extract({:id, column, table}, row, _spec), do: scalar(row[column], table)

  defp extract({:typed, type_column, id_column}, row, _spec) do
    case {table_for_type(row[type_column]), row[id_column]} do
      {nil, _id} -> []
      {table, id} -> scalar(id, table)
    end
  end

  defp extract({:links, column}, row, _spec), do: link_refs(row[column])

  defp extract({:json_ids, column, table}, row, _spec) do
    case decode(row[column]) do
      ids when is_list(ids) -> Enum.flat_map(ids, &scalar(&1, table))
      _other -> []
    end
  end

  defp extract({:json_map, column, mapping}, row, _spec) do
    case decode(row[column]) do
      %{} = map ->
        Enum.flat_map(mapping, fn {key, table} ->
          case Map.get(map, key) do
            ids when is_list(ids) -> Enum.flat_map(ids, &scalar(&1, table))
            id -> scalar(id, table)
          end
        end)

      _other ->
        []
    end
  end

  defp extract({:uris, column}, row, _spec), do: uri_refs(row[column])

  defp extract({:meta_id, key, table}, row, spec) do
    case spec.meta && SecurityLabels.metadata_map(row[spec.meta]) do
      %{} = metadata -> scalar(Map.get(metadata, key), table)
      _other -> []
    end
  end

  defp scalar(id, table) when is_binary(id) and id != "", do: [{:row, table, id}]
  defp scalar(_id, _table), do: []

  defp links(list) when is_list(list), do: Enum.flat_map(list, &links/1)
  defp links(id) when is_binary(id), do: any(id)

  defp links(%{} = map) do
    type = Map.get(map, "type") || Map.get(map, "object_type") || Map.get(map, "kind")

    case Map.get(map, "id") || Map.get(map, "object_id") do
      id when is_binary(id) and id != "" ->
        case table_for_type(type) do
          nil -> any(id)
          table -> [{:row, table, id}]
        end

      _none ->
        keyed(map)
    end
  end

  defp links(_other), do: []

  # `%{"source_package_id" => id}`: the key names the table.
  defp keyed(map) do
    Enum.flat_map(map, fn
      {key, id} when is_binary(key) and is_binary(id) and id != "" ->
        if String.ends_with?(key, "_id") do
          case table_for_type(String.replace_suffix(key, "_id", "")) do
            nil -> []
            table -> [{:row, table, id}]
          end
        else
          []
        end

      _other ->
        []
    end)
  end

  # An id with no type is looked for in the anchor tables. A value that cannot
  # be an Engine id (a URL, a sentence) is not looked for.
  defp any(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_\-:.]{4,200}\z/, id), do: [{:any, id}], else: []
  end

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode(value) when is_list(value) or is_map(value), do: value
  defp decode(_value), do: nil
end
