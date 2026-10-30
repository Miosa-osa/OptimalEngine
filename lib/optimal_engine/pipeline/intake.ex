defmodule OptimalEngine.Pipeline.Intake do
  @moduledoc """
  Intake pipeline — classifies raw text, routes it to nodes, writes signal
  files to disk, and updates the SQLite index.

  This is the Evidence Intake gate:

  1. Scope: resolve the best-known `ScopeEnvelope` (actor, tenant, workspace,
     operation class, node hints, permissions) from caller options
  2. Source-first: persist the `SourcePackage` BEFORE any interpretation, so
     reject/quarantine paths can never lose the source evidence
  3. Classify: run Mode + Genre + Type + Format + Structure classification via `Classifier`
  4. Route: determine primary node + cross-reference nodes via `Router`
  5. Write: emit structured markdown files to the Node's `signals/` directory
     (folders resolve through workspace topology, with a legacy alias fallback)
  6. Cross-ref: write cross-references to secondary destinations
  7. Index: store the compatibility Context row in SQLite via `Store`
  8. Lineage: record a Derivation Ledger entry linking
     `source_package -> signal + context` with actor and policy

  Non-critical steps run async (fire-and-forget):
  - Episodic recording
  - SICA observation
  - Quality audit logging

  ## Quality Actions

  FailureModes violations trigger actions. In every case the Source Package
  is already durable and its `quarantine_state` plus a Derivation Ledger
  entry record what happened:

  - S/N < 0.3 → reject with `{:error, :signal_too_noisy}`; the Source Package
    is kept with `quarantine_state = "rejected"` and a `source_rejected`
    ledger entry
  - S/N < 0.6 AND (routing_failure OR inbox fallback) → result is
    `:quarantined`; the Source Package is marked
    `quarantine_state = "quarantined"` with a `source_quarantined` ledger entry
  - :bandwidth_overload → truncate L1 to 250 chars
  - :structure_failure → auto-apply genre skeleton (already happens)

  ## Usage

      {:ok, result} = OptimalEngine.Pipeline.Intake.process("Customer called about Product Suite pricing")

      {:ok, result} = OptimalEngine.Pipeline.Intake.process(
        "Customer called...",
        genre: "transcript",
        title: "Requirements Review Call",
        node: "products",
        entities: ["Alice", "Alice"]
      )

  ## Result shape

      %{
        signal: %Signal{},
        context: %Context{},
        source_package: %SourcePackage{},
        files_written: ["product-customer-portal/signals/2026-03-18-pricing-call.md"],
        routed_to: ["product-customer-portal", "operation-revenue"],
        cross_references: ["operation-revenue/signals/2026-03-18-pricing-call.md"],
        uri: "optimal://nodes/products/signals/2026-03-18-pricing-call.md",
        quality_violations: [{:bandwidth_overload, "..."}],
        quality_action: :accepted
      }

  ## Options

  - `:genre`    — Override auto-detected genre (e.g. "transcript")
  - `:node`     — Override primary node routing (e.g. "products")
  - `:title`    — Explicit title instead of auto-extracted one
  - `:entities` — Explicit entity list (merged with auto-extracted)
  - `:type`     — Force context type (:signal, :resource, :memory, :skill)

  Scope Envelope options (see `OptimalEngine.MemoryCore.ScopeEnvelope`):

  - `:actor` / `:actor_id` / `:created_by` — acting principal
  - `:tenant_id` / `:workspace_id` — evidence scope (default: "default")
  - `:operation_class` — operation being performed (default: "intake.process")
  - `:permissions` — permissions presented by the caller
  """

  use GenServer
  require Logger

  alias OptimalEngine.Pipeline.Classifier, as: Classifier
  alias OptimalEngine.Pipeline.Decomposer, as: Decomposer
  alias OptimalEngine.Pipeline.Parser.ParsedDoc
  alias OptimalEngine.Context
  alias OptimalEngine.Graph
  alias OptimalEngine.MemoryCore.Claim
  alias OptimalEngine.MemoryCore.ClaimExtractor
  alias OptimalEngine.MemoryCore.DerivationLedgerEntry
  alias OptimalEngine.MemoryCore.Episode
  alias OptimalEngine.MemoryCore.ScopeEnvelope
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.MemoryCore.SourcePackage
  alias OptimalEngine.MemoryCore.SourcePackageService
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Pipeline.Indexer, as: Indexer
  alias OptimalEngine.Pipeline.Intake.Address
  alias OptimalEngine.Pipeline.Intake.Writer, as: Writer
  alias OptimalEngine.Pipeline.Intake.Skeleton, as: Skeleton
  alias OptimalEngine.Pipeline.Router, as: Router
  alias OptimalEngine.Pipeline.SemanticProcessor, as: SemanticProcessor
  alias OptimalEngine.Signal
  alias OptimalEngine.Signal.{ModeDetector, TextHead, TimeLimit}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.ContextTenant
  alias OptimalEngine.Routing
  alias OptimalEngine.URI

  alias OptimalEngine.Bridge.Memory, as: BridgeMemory
  alias OptimalEngine.Bridge.Signal, as: BridgeSignal

  # Policy applied by the quality gate; recorded on reject/quarantine ledger entries.
  @quality_gate_policy "intake_quality_gate_v1"

  # Classification reads at most this much of a text (`classify/2`).
  @classify_bytes 65_536

  # Result type for process/2
  @type result :: %{
          signal: Signal.t(),
          context: Context.t(),
          source_package: SourcePackage.t(),
          files_written: [String.t()],
          routed_to: [String.t()],
          cross_references: [String.t()],
          uri: String.t(),
          quality_violations: [{atom(), String.t()}],
          quality_action: :accepted | :quarantined | :rejected,
          pending_claim: Claim.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Processes raw text through the full intake pipeline:
  classify → route → write files → index.

  Returns `{:ok, result}` or `{:error, reason}`.

  Options include all classification overrides plus:
  - `:workspace_id` — target workspace (default: "default")
  - `:write_files` — `false` stores the signal in the database only: no
    markdown file, no cross-reference copies, no summary sidecars (default
    `true`). Connector pulls use this.
  - `:source_id` — a stable id for the item in its source; the row id is
    derived from it and the workspace, so ingesting the same item again
    replaces its row instead of adding another
  - `:source_uri` — the row's uri when no file is written
  - `:occurred_at` — when the item happened (a `DateTime`); dates the signal
    instead of the time of intake
  - `:classified`: the `%Signal{}` that `classify/2` returned for this exact
    text, with `known_entities: known_entities()` and the same classification
    options; it is stored instead of classifying again. Calls to this function
    run one at a time, so a caller ingesting many texts classifies them in
    parallel first. A signal whose content is not this text is ignored.
  """
  @spec process(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def process(raw_text, opts \\ []) when is_binary(raw_text) do
    GenServer.call(__MODULE__, {:process, raw_text, opts}, 30_000)
  end

  @doc """
  The classification phase of `process/2`, without persisting anything: the
  pipeline classifier, the caller's overrides and the Signal Theory bridge.
  `process/2` stores exactly the Mode, Genre and Type this returns.

  Accepts the classification options of `process/2` (`:genre`, `:title`,
  `:node`, `:entities`, `:type`) plus `:known_entities` (default `[]`).
  The returned signal has no id or timestamps yet.

  A text longer than #{@classify_bytes} bytes is classified by its head
  (`OptimalEngine.Signal.TextHead`, whole lines up to #{@classify_bytes}
  bytes): genre, type, title and summaries come from the head; mode from the
  whole text, since a data document cut short no longer reads as data (the
  mode detector bounds what it reads itself); entities from the whole body
  after the frontmatter, as for a short text, within the classification time
  limit (past it, from the head); and the signal carries the whole text, so
  nothing is lost when it is stored. The time classification takes is
  bounded whatever the caller sends.
  """
  @spec classify(String.t(), keyword()) :: Signal.t()
  def classify(raw_text, opts \\ [])

  def classify(raw_text, opts)
      when is_binary(raw_text) and byte_size(raw_text) > @classify_bytes do
    head = TextHead.take(raw_text, @classify_bytes)
    named = Keyword.get(opts, :entities, [])
    names = Enum.uniq(Keyword.get(opts, :known_entities, []) ++ named)

    # The names the whole body mentions, after the frontmatter the head opens
    # with, as the classifier reads them from a short text's body. Bounded like
    # detection: past the classification limit only the head's names count,
    # which the classifier finds itself.
    {_frontmatter, head_body} = Classifier.parse_frontmatter(head)
    body = Classifier.mode_body(head, head_body, whole_text: raw_text)

    found =
      TimeLimit.run(fn -> Classifier.extract_entities(body, names) end, [],
        label: "entity extraction"
      )

    classify_text(head, raw_text, Keyword.put(opts, :entities, Enum.uniq(named ++ found)))
  end

  def classify(raw_text, opts) when is_binary(raw_text), do: classify_text(raw_text, raw_text, opts)

  # Classifies `raw_text`, the head of `whole` or all of it: Mode reads
  # `whole`, and the signal carries it.
  defp classify_text(raw_text, whole, opts) do
    # Merge explicit entities into known entities for extraction
    extra_entities = Keyword.get(opts, :entities, [])
    all_known = Enum.uniq(Keyword.get(opts, :known_entities, []) ++ extra_entities)
    genre = Keyword.get(opts, :genre)

    # Intake always produces a signal unless the caller explicitly forces another type.
    # Without this, content with an empty path is classified as :resource and loses
    # all Mode + Genre + Type + Format + Structure dimensions.
    forced_type = Keyword.get(opts, :type, :signal)

    classify_opts = [
      path: "",
      known_entities: all_known,
      type: forced_type,
      genre: genre,
      whole_text: whole
    ]

    ctx = Classifier.classify_context(raw_text, classify_opts)

    signal =
      case ctx.signal do
        %Signal{} = sig ->
          sig

        nil ->
          # Build a minimal signal from the context for non-signal types; the
          # context carries no Mode, so read it from the text.
          sig = Context.to_signal(ctx)
          {_frontmatter, body} = Classifier.parse_frontmatter(raw_text)
          body = Classifier.mode_body(raw_text, body, whole_text: whole)
          %{sig | mode: ModeDetector.resolve(body, genre: genre || sig.genre)}
      end

    # Apply option overrides
    signal
    |> maybe_override(:title, Keyword.get(opts, :title))
    |> maybe_override(:genre, genre)
    |> maybe_override(:node, Keyword.get(opts, :node))
    |> maybe_merge_entities(extra_entities)
    |> then(fn s -> %{s | content: raw_text, format: :markdown} end)
    |> enhance_with_signal_bridge(raw_text)
    |> regenerate_summaries()
    |> then(&%{&1 | content: whole})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:process, raw_text, opts}, _from, state) do
    result = run_pipeline(raw_text, opts)
    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private: Pipeline
  # ---------------------------------------------------------------------------

  defp run_pipeline(raw_text, opts) do
    scope = ScopeEnvelope.resolve(opts)

    source_package =
      SourcePackage.from_text(raw_text, ScopeEnvelope.source_package_opts(scope, opts))

    # Source-first: the Source Package is committed BEFORE any interpretation,
    # so reject/quarantine/failure paths can never lose the source evidence.
    with :ok <- persist_source_package(source_package),
         # Every detection while classifying shares one budget, so a crafted
         # document holds the intake process (and everyone queued behind it)
         # a bounded time. The source package written before it does not
         # count; the topology and entity names classification reads do.
         {:ok, signal} <- TimeLimit.with_budget(fn -> classify_step(raw_text, scope, opts) end),
         {:ok, signal} <- quality_gate(signal, source_package, scope),
         {:ok, signal, routed_to} <- route_step(signal, opts),
         # A row the writer will refuse is found before a file is written for it.
         :ok <- ContextTenant.check(signal.id, scope.workspace_id, stated_tenant(scope)),
         {:ok, primary_path} <- write_step(signal, scope, opts),
         {:ok, cross_paths} <- cross_ref_step(signal, routed_to, primary_path, scope, opts),
         {:ok, context} <-
           index_step(signal, primary_path, cross_paths, scope, source_package, opts),
         {:ok, pending_claim} <-
           extract_claims_step(source_package, signal, scope, opts) do
      # Persist detail objects for each extracted entity as a step record
      # attached to the source package (parent_object_type = "source_package").
      # Never fails the pipeline.
      persist_detail_objects(signal, source_package, scope)

      # Persist skeleton-section detail objects for structured genres
      # (transcript, decision-log). Each section name from the genre skeleton
      # becomes a step MDO attached to the source package, giving the episodic
      # layer a structured breakdown of what this document contains.
      # Never fails the pipeline.
      persist_skeleton_detail_objects(signal, source_package, scope)

      # Create an Episode row for transcript/meeting sources so the episodic
      # memory layer has a first-class record of this ingestion event.
      persist_episode_if_applicable(signal, source_package, pending_claim, scope)

      # Decompose content into chunks and embed them (async, non-blocking).
      # Chunks carry signal_id = context.id to satisfy the join key. If Ollama
      # is unavailable the chunks are still persisted and embeddings are skipped
      # gracefully; the maintenance sweep (OptimalEngine.Maintenance) embeds
      # them once the embedder answers.
      Task.start(fn -> decompose_and_embed(context, scope) end)

      # Additive graph population: link the extracted claim to the signal's
      # entities (claim --about--> entity). The context's own edges
      # (mentioned_in, co_occurs, lives_in) are already written by
      # Store.insert_context -> Graph.create_edges_for_context_db during the
      # index step. This step must never fail the pipeline.
      populate_graph_step(pending_claim, signal, scope)

      # Emit semantic edges with varied predicates (mentions, co_occurs_with)
      # distinct from the structural mentioned_in/co_occurs/lives_in edges
      # written by Store.insert_context. These populate the graph with domain
      # predicates queryable via Graph.assert_edge. Never fails the pipeline.
      emit_semantic_edges(signal, context, scope)

      uri = context.uri
      files_written = if primary_path, do: [relative(primary_path)], else: []
      cross_relatives = Enum.map(cross_paths, &relative/1)

      # Semantic processing: LLM-enhanced L0/L1 + embedding (async, non-blocking)
      Task.start(fn -> semantic_enhance(context) end)

      # Quality audit — determine violations and action
      violations = BridgeSignal.audit(signal)
      quality_action = determine_quality_action(signal, violations)
      record_quality_action(source_package, quality_action, signal, violations, scope)

      # Apply bandwidth fix if needed (truncate L1 for overloaded signals)
      signal = apply_bandwidth_fix(signal, violations)

      result = %{
        signal: signal,
        context: context,
        source_package: source_package,
        files_written: files_written,
        routed_to: routed_to,
        cross_references: cross_relatives,
        uri: uri,
        quality_violations: violations,
        quality_action: quality_action,
        pending_claim: pending_claim
      }

      record_memory_core_trace(
        source_package,
        signal,
        context,
        ScopeEnvelope.ledger_opts(scope, opts)
      )

      # Async: non-critical steps (episodic record, SICA observe, telemetry)
      Task.start(fn -> async_post_intake(signal, result, violations) end)

      :telemetry.execute(
        [:optimal_engine, :intake, :process],
        %{files_written: 1 + length(cross_paths)},
        %{node: signal.node, genre: signal.genre}
      )

      {:ok, result}
    end
  end

  # Source-first commit. Refuses to derive anything when the evidence cannot
  # be persisted — derived objects without source lineage are forbidden.
  defp persist_source_package(%SourcePackage{} = source_package) do
    case MemoryCoreStore.insert_source_package(source_package) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Intake] Source Package persist failed — refusing intake: #{inspect(reason)}")

        {:error, {:source_package_not_persisted, reason}}
    end
  rescue
    error ->
      Logger.error("[Intake] Source Package persist failed — refusing intake: #{inspect(error)}")
      {:error, {:source_package_not_persisted, error}}
  end

  defp record_memory_core_trace(source_package, signal, context, opts) do
    case SourcePackageService.record_ingested_signal(source_package, signal, context, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Intake] Memory Core provenance write failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[Intake] Memory Core provenance write failed: #{inspect(error)}")
      :ok
  end

  # Quality gate — reject signals based on S/N. The Source Package is already
  # durable; rejection only marks it and records the attempt in the ledger.
  defp quality_gate(%Signal{} = signal, %SourcePackage{} = source_package, scope) do
    sn = signal.sn_ratio || 0.6

    if sn < 0.3 do
      Logger.warning("[Intake] Rejecting signal — S/N #{sn} too low (< 0.3)")

      quarantine_source_package(source_package, "rejected", scope, %{
        reason: "signal_too_noisy",
        sn_ratio: sn
      })

      {:error, :signal_too_noisy}
    else
      {:ok, signal}
    end
  end

  # Determine quality action based on violations and S/N. A low-signal input
  # that could not be routed to a real Node (inbox fallback) is quarantined.
  defp determine_quality_action(%Signal{} = signal, violations) do
    sn = signal.sn_ratio || 0.6
    violation_modes = Enum.map(violations, &elem(&1, 0))

    cond do
      sn < 0.6 and :routing_failure in violation_modes ->
        :quarantined

      sn < 0.6 and inbox_fallback?(signal) ->
        :quarantined

      true ->
        :accepted
    end
  end

  defp inbox_fallback?(%Signal{} = signal) do
    signal.node in [nil, "inbox"] and (signal.routed_to || []) -- ["inbox"] == []
  end

  defp record_quality_action(_source_package, :accepted, _signal, _violations, _scope), do: :ok

  defp record_quality_action(source_package, :quarantined, signal, violations, scope) do
    quarantine_source_package(source_package, "quarantined", scope, %{
      reason: "low_signal_inbox_fallback",
      sn_ratio: signal.sn_ratio || 0.6,
      violations: Enum.map(violations, &elem(&1, 0))
    })
  end

  # Marks the already-persisted Source Package and records the intake attempt
  # in the Derivation Ledger so the reject/quarantine decision has lineage
  # (source, processor, actor, policy). Never fails the pipeline.
  defp quarantine_source_package(
         %SourcePackage{} = source_package,
         state,
         %ScopeEnvelope{} = scope,
         metadata
       ) do
    with :ok <- set_quarantine_state(source_package, state),
         :ok <- record_quarantine_ledger(source_package, state, scope, metadata) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[Intake] Failed to record #{state} state for #{source_package.id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Intake] Failed to record #{state} state for #{source_package.id}: #{inspect(error)}"
      )

      :ok
  end

  defp set_quarantine_state(%SourcePackage{id: id}, state) do
    Store.raw_execute(
      "UPDATE source_packages SET quarantine_state = ?1, updated_at = ?2 WHERE id = ?3",
      [state, DateTime.to_iso8601(DateTime.utc_now()), id]
    )
  end

  defp record_quarantine_ledger(%SourcePackage{} = source_package, state, scope, metadata) do
    source_ref = DerivationLedgerEntry.object_ref("source_package", source_package.id)

    entry =
      DerivationLedgerEntry.new(
        "intake.quality_gate",
        "source_" <> state,
        [source_ref],
        [source_ref],
        tenant_id: source_package.tenant_id,
        workspace_id: source_package.workspace_id,
        source_package_links: [source_ref],
        evidence_links: [source_ref],
        actor_id: scope.actor,
        parser_id: "optimal_engine.pipeline.intake",
        policy_version: @quality_gate_policy,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        metadata:
          Map.merge(metadata, %{
            operation_class: scope.operation_class,
            quarantine_state: state
          })
      )

    MemoryCoreStore.insert_derivation_entry(entry)
  end

  # Apply bandwidth overload fix to signal
  defp apply_bandwidth_fix(%Signal{} = signal, violations) do
    violation_modes = Enum.map(violations, &elem(&1, 0))

    if :bandwidth_overload in violation_modes do
      # Truncate L1 to 250 chars instead of 500
      l1 =
        (signal.l1_description || "")
        |> String.slice(0, 250)

      %{signal | l1_description: l1}
    else
      signal
    end
  end

  # Fill any dimension the classifier left unresolved via the bridge classifier.
  defp enhance_with_signal_bridge(signal, raw_text) do
    BridgeSignal.enhance_classification(signal, raw_text)
  rescue
    _ -> signal
  end

  # Async post-intake: episodic recording, SICA observation, quality logging
  defp async_post_intake(signal, result, violations) do
    # Episodic event
    BridgeMemory.record_event(:intake, %{
      genre: signal.genre,
      node: signal.node,
      title: signal.title,
      entities: signal.entities || [],
      routed_to: result.routed_to,
      quality_action: result.quality_action
    })

    # SICA observation
    BridgeMemory.observe_mutation(%{
      tool: "intake",
      input: signal.title || "",
      output: "routed to #{Enum.join(result.routed_to, ", ")}",
      success: true
    })

    # Log violations if any
    if violations != [] do
      Logger.debug(
        "[Intake] Signal quality violations: #{inspect(Enum.map(violations, &elem(&1, 0)))}"
      )
    end

    # Check SICA for new patterns and log them
    check_sica_patterns()
  rescue
    _ -> :ok
  end

  # Check if SICA has detected new patterns since last check
  defp check_sica_patterns do
    metrics = BridgeMemory.learning_metrics()
    pattern_count = Map.get(metrics, :patterns, 0)

    if pattern_count > 0 do
      patterns = BridgeMemory.patterns()

      Enum.each(patterns, fn {pattern_name, pattern_data} ->
        Logger.info("[Intake/SICA] Pattern detected: #{pattern_name} — #{inspect(pattern_data)}")
      end)
    end
  rescue
    _ -> :ok
  end

  @doc """
  The entity names classification matches against: the names in the legacy
  topology.yaml endpoints and in the canonical Topology.Node table (the
  source of truth), the gazetteer that drives entity extraction and semantic
  graph edges. `process/2` reads them on every call; a caller that classifies
  many texts with `classify/2` reads them once and passes them as
  `:known_entities`.
  """
  @spec known_entities() :: [String.t()]
  def known_entities, do: Enum.uniq(topology_entities(load_topology()) ++ db_entity_names())

  # Step 1: Classify
  defp classify_step(raw_text, scope, opts) do
    now = DateTime.utc_now()
    occurred_at = occurred_at(opts) || now
    id = source_context_id(scope.workspace_id, opts) || generate_id(raw_text, now)

    signal =
      case Keyword.get(opts, :classified) do
        %Signal{content: ^raw_text} = classified ->
          classified

        _ ->
          classify(raw_text, Keyword.put(opts, :known_entities, known_entities()))
      end

    {:ok, %{signal | id: id, created_at: occurred_at, modified_at: occurred_at}}
  end

  # Step 2: Route
  defp route_step(%Signal{} = signal, opts) do
    forced_node = Keyword.get(opts, :node)

    primary_node =
      if forced_node, do: forced_node, else: signal.node || "inbox"

    signal = %{signal | node: primary_node}

    routed_to =
      case Router.route(signal) do
        {:ok, destinations} -> destinations
        {:error, _} -> [primary_node]
      end

    signal = %{signal | routed_to: routed_to}

    {:ok, signal, routed_to}
  end

  # Step 3: Write primary file (Node folders resolve through workspace topology)
  defp write_step(%Signal{} = signal, %ScopeEnvelope{} = scope, opts) do
    if write_files?(opts),
      do: Writer.write_signal(signal, ScopeEnvelope.folder_scope(scope)),
      else: {:ok, nil}
  end

  # Step 4: Write cross-references. Each copy is named after the primary file,
  # so a signal's copies share its name wherever they land.
  defp cross_ref_step(%Signal{} = signal, routed_to, primary_path, %ScopeEnvelope{} = scope, opts) do
    if write_files?(opts),
      do: write_cross_refs(signal, routed_to, primary_path, scope),
      else: {:ok, []}
  end

  defp write_cross_refs(%Signal{} = signal, routed_to, primary_path, %ScopeEnvelope{} = scope) do
    folder_scope = ScopeEnvelope.folder_scope(scope)
    primary_folder = Writer.node_to_folder(signal.node, folder_scope)

    cross_nodes =
      routed_to
      |> Enum.reject(fn dest ->
        Writer.node_to_folder(dest, folder_scope) == primary_folder
      end)

    Writer.write_cross_references(
      signal,
      cross_nodes,
      Keyword.put(folder_scope, :primary_path, primary_path)
    )
  end

  # Step 5: Index — write the primary file to SQLite via Indexer. Without a
  # file the row is the only copy: its uri is the source's, and it has no path.
  defp index_step(
         %Signal{} = signal,
         primary_path,
         cross_paths,
         %ScopeEnvelope{} = scope,
         %SourcePackage{} = source_package,
         opts
       ) do
    # Build a complete context for storage
    uri =
      if primary_path,
        do: URI.from_path(primary_path),
        else:
          Keyword.get(opts, :source_uri) || "optimal://#{scope.workspace_id}/signals/#{signal.id}"

    workspace_id = scope.workspace_id

    context = %Context{
      id: signal.id,
      uri: uri,
      type: :signal,
      path: primary_path,
      title: signal.title,
      content: signal.content,
      l0_abstract: signal.l0_summary || "",
      l1_overview: signal.l1_description || "",
      signal: %{signal | path: primary_path},
      node: signal.node,
      sn_ratio: signal.sn_ratio || 0.6,
      entities: signal.entities || [],
      created_at: signal.created_at,
      modified_at: signal.modified_at,
      routed_to: signal.routed_to || [],
      workspace_id: workspace_id,
      # The tenant that ingests owns the row, also under a bare workspace id
      # that another tenant may use too. A caller that names no tenant leaves
      # it to the workspace.
      tenant_id: stated_tenant(scope),
      # The document names its source package and carries its labels from the
      # first write: nothing else on the row says what class it is, and
      # replication reads it before any ledger entry exists. A repaired
      # context keeps the record of the repair.
      metadata:
        SecurityLabels.put(
          Map.put(preserved_metadata(signal.id), "source_package_id", source_package.id),
          source_package.security_labels
        )
    }

    case Store.insert_context(context) do
      :ok ->
        if primary_path, do: index_cross_refs(signal, cross_paths, scope, context.metadata)
        {:ok, context}

      {:error, _} = err ->
        err
    end
  end

  # A context repaired by `OptimalEngine.UriRepair` records where it was in
  # `metadata.uri_repair`; writing it again must not erase that record.
  defp preserved_metadata(id) do
    case Store.raw_query("SELECT metadata FROM contexts WHERE id = ?1", [id]) do
      {:ok, [[json]]} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"uri_repair" => repair}} -> %{"uri_repair" => repair}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # The copies are indexed from the paths they were written to. Each row is
  # marked as a copy of this signal, so writing the signal again recognises its
  # own copies and updates them in place instead of adding new ones.
  defp index_cross_refs(%Signal{} = signal, cross_paths, %ScopeEnvelope{} = scope, metadata) do
    Enum.each(cross_paths, fn cross_path ->
      # Cross-ref Context rows must carry the intake's workspace scope.
      # Indexing without it stamps the struct default ("default"),
      # leaking workspace content into default-workspace surfaces.
      if File.exists?(cross_path) do
        Indexer.index_file(cross_path,
          workspace_id: scope.workspace_id,
          tenant_id: stated_tenant(scope),
          metadata: Address.copy_metadata(signal.id, metadata),
          # A copy is dated when its signal happened, not when its file was written.
          created_at: signal.created_at,
          modified_at: signal.modified_at
        )
      end
    end)
  end

  # Step 6: Extract a pending Claim from the Source Package.
  #
  # Closes the EXTRACTION break: intake now produces a Claim, not just a
  # Signal. Gated behind `memory.auto_extract_claims` (default ON) and an
  # optional per-call `:extract_claims` override. The Source Package is already
  # durable and the Signal/Context already indexed, so claim extraction is
  # additive — it must NEVER fail the pipeline. On disable or error it returns
  # `{:ok, nil}` and leaves existing intake behavior untouched.
  defp extract_claims_step(
         %SourcePackage{} = source_package,
         %Signal{} = signal,
         %ScopeEnvelope{} = scope,
         opts
       ) do
    if auto_extract_claims?(opts) do
      do_extract_claim(source_package, signal, scope, opts)
    else
      {:ok, nil}
    end
  rescue
    error ->
      Logger.warning("[Intake] Claim extraction failed (skipping): #{inspect(error)}")
      {:ok, nil}
  end

  defp do_extract_claim(source_package, signal, scope, _opts) do
    # The claim must record who fed it in: a known actor becomes the
    # evaluator (and can then not approve their own claim), an anonymous
    # intake is attributed to the pipeline itself. scope.actor alone was nil
    # on anonymous calls, which left evaluator_id empty and the self-review
    # gate inert on every intake-produced claim.
    intake_actor = scope.actor || "system:intake-pipeline"

    extract_opts = [
      signal_id: signal.id,
      workspace_id: scope.workspace_id,
      tenant_id: scope.tenant_id,
      actor_id: intake_actor,
      extracted_by: intake_actor,
      claim_text: signal.content || source_package.raw_text,
      metadata: %{
        node: signal.node,
        genre: signal.genre,
        title: signal.title,
        intake_signal_id: signal.id
      }
    ]

    case ClaimExtractor.extract_from_source(source_package, extract_opts) do
      {:ok, %Claim{} = claim} ->
        record_signal_to_claim_ledger(signal, claim, source_package, scope)
        {:ok, claim}

      {:error, reason} ->
        Logger.warning("[Intake] Claim extraction failed (skipping): #{inspect(reason)}")
        {:ok, nil}
    end
  end

  # Whether claim extraction runs. Per-call `:extract_claims` overrides the
  # `memory.auto_extract_claims` config flag (default ON).
  defp auto_extract_claims?(opts) do
    case Keyword.get(opts, :extract_claims) do
      nil ->
        :optimal_engine
        |> Application.get_env(:memory, [])
        |> Keyword.get(:auto_extract_claims, true)

      override ->
        override == true
    end
  end

  # Emit a `signal_to_claim` derivation ledger entry mirroring the
  # `source_to_signal_context` entry — linking the Signal (input) to the
  # extracted Claim (output) so the Signal -> Claim hop has explicit lineage.
  # Never fails the pipeline.
  defp record_signal_to_claim_ledger(
         %Signal{} = signal,
         %Claim{} = claim,
         %SourcePackage{} = source_package,
         %ScopeEnvelope{} = scope
       ) do
    signal_ref = DerivationLedgerEntry.object_ref("signal", signal.id)
    claim_ref = DerivationLedgerEntry.object_ref("claim", claim.id)
    source_ref = DerivationLedgerEntry.object_ref("source_package", source_package.id)

    entry =
      DerivationLedgerEntry.new(
        "intake.extract_claim",
        "signal_to_claim",
        [signal_ref],
        [claim_ref],
        tenant_id: source_package.tenant_id,
        workspace_id: source_package.workspace_id,
        source_package_links: [source_ref],
        evidence_links: [source_ref],
        actor_id: scope.actor,
        evaluator_id: claim.evaluator_id,
        parser_id: "optimal_engine.pipeline.intake",
        confidence_delta: claim.aggregate_confidence,
        precision_delta: claim.aggregate_precision,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        metadata: %{
          node: signal.node,
          genre: signal.genre,
          title: signal.title,
          claim_type: claim.claim_type
        }
      )

    case MemoryCoreStore.insert_derivation_entry(entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Intake] signal_to_claim ledger write failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[Intake] signal_to_claim ledger write failed: #{inspect(error)}")
      :ok
  end

  # Step 7: Populate the knowledge graph with claim->about->entity edges.
  #
  # The signal/context edges (mentioned_in, co_occurs, lives_in, cross_ref) are
  # already created synchronously inside Store.insert_context. This step only
  # adds the claim->entity links, which require the Claim id produced by the
  # claim-extraction step. Purely additive — never fails the pipeline.
  defp populate_graph_step(nil, _signal, _scope), do: :ok

  defp populate_graph_step(%Claim{id: claim_id}, %Signal{} = signal, %ScopeEnvelope{} = scope)
       when is_binary(claim_id) do
    entities = signal.entities || []

    if entities != [] do
      Graph.create_claim_edges(claim_id, entities,
        workspace_id: scope.workspace_id,
        tenant_id: stated_tenant(scope)
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("[Intake] Graph population failed (skipping): #{inspect(error)}")
      :ok
  end

  defp populate_graph_step(_claim, _signal, _scope), do: :ok

  # ---------------------------------------------------------------------------
  # Private: Detail objects + episode persistence
  # ---------------------------------------------------------------------------

  # Persist one MemoryDetailObject per extracted entity as a "step" record
  # attached to the source package. This converts previously dead code into a
  # live call: every intake with entities now writes detail rows.
  defp persist_detail_objects(
         %Signal{} = signal,
         %SourcePackage{} = source_package,
         %ScopeEnvelope{} = scope
       ) do
    entities = signal.entities || []

    entities
    |> Enum.with_index()
    |> Enum.each(fn {entity, idx} ->
      attrs = %{
        tenant_id: scope.tenant_id,
        workspace_id: scope.workspace_id,
        parent_object_type: "source_package",
        parent_object_id: source_package.id,
        detail_type: "step",
        detail_order: idx,
        detail_text: "entity: #{entity}",
        action_class: "entity_extraction",
        source_package_links: [source_package.id],
        metadata: %{node: signal.node, genre: signal.genre}
      }

      case MemoryCoreStore.insert_memory_detail_object(attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Intake] MemoryDetailObject persist failed (skipping): #{inspect(reason)}"
          )

          :ok
      end
    end)
  rescue
    error ->
      Logger.warning("[Intake] persist_detail_objects failed (skipping): #{inspect(error)}")
      :ok
  end

  # The genres that should produce an Episode record.
  @episode_genres ~w[transcript meeting]

  # Create an Episode row when the ingested source is a transcript or meeting.
  # Wires insert_episode into the live pipeline so episodes table grows on real
  # intake calls (not just test-fixture inserts).
  defp persist_episode_if_applicable(
         %Signal{} = signal,
         %SourcePackage{} = source_package,
         pending_claim,
         %ScopeEnvelope{} = scope
       ) do
    genre = signal.genre || ""

    if genre in @episode_genres do
      claim_id = if pending_claim, do: pending_claim.id, else: nil

      attrs = %{
        tenant_id: scope.tenant_id,
        workspace_id: scope.workspace_id,
        node_id: signal.node,
        kind: genre,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        summary: signal.title || signal.l0_summary || String.slice(signal.content || "", 0, 120),
        provenance: %{
          source_package_id: source_package.id,
          signal_id: signal.id,
          claim_id: claim_id
        },
        security_labels: source_package.security_labels || [],
        partition_ids: source_package.partition_ids || [],
        metadata: %{node: signal.node, genre: genre, sn_ratio: signal.sn_ratio}
      }

      case Episode.new(attrs) do
        {:ok, episode} ->
          case MemoryCoreStore.insert_episode(episode) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("[Intake] Episode persist failed (skipping): #{inspect(reason)}")
              :ok
          end

        {:error, reason} ->
          Logger.warning("[Intake] Episode build failed (skipping): #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("[Intake] persist_episode_if_applicable failed (skipping): #{inspect(error)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  # Async semantic enhancement: LLM summaries + embedding + sidecar files
  defp semantic_enhance(%Context{} = context) do
    case SemanticProcessor.process(context) do
      {:ok, enhanced} ->
        # Update the stored context with enhanced L0/L1
        if enhanced.l0_abstract != context.l0_abstract or
             enhanced.l1_overview != context.l1_overview do
          Store.raw_query(
            "UPDATE contexts SET l0_abstract = ?1, l1_overview = ?2 WHERE id = ?3",
            [enhanced.l0_abstract, enhanced.l1_overview, context.id]
          )
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_override(signal, _key, nil), do: signal
  defp maybe_override(signal, :title, val), do: %{signal | title: val}
  defp maybe_override(signal, :genre, val), do: %{signal | genre: val}
  defp maybe_override(signal, :node, val), do: %{signal | node: val}

  defp maybe_merge_entities(signal, []), do: signal

  defp maybe_merge_entities(signal, extra) do
    merged = Enum.uniq((signal.entities || []) ++ extra)
    %{signal | entities: merged}
  end

  defp regenerate_summaries(%Signal{} = signal) do
    l0 =
      "#{String.upcase(signal.genre || "note")} | #{signal.node || "inbox"} | #{signal.title || "Untitled"} [S/N: #{Float.round(signal.sn_ratio || 0.6, 1)}]"

    l1 =
      signal.content
      |> String.replace(~r/---.*?---/s, "")
      |> String.trim()
      |> String.slice(0, 500)

    %{signal | l0_summary: l0, l1_description: l1}
  end

  defp relative(abs_path) do
    root = Application.get_env(:optimal_engine, :root_path, "")
    String.replace_prefix(abs_path, root <> "/", "")
  end

  defp write_files?(opts), do: Keyword.get(opts, :write_files, true) != false

  # The tenant the caller named; the default the scope falls back to is not one.
  defp stated_tenant(%ScopeEnvelope{unresolved: unresolved, tenant_id: tenant_id}),
    do: if(:tenant_id in unresolved, do: nil, else: tenant_id)

  defp occurred_at(opts) do
    case Keyword.get(opts, :occurred_at) do
      %DateTime{} = at -> at
      _none -> nil
    end
  end

  @doc """
  The context id `process/2` gives an item ingested with `:source_id` into
  `workspace_id`. Stable per workspace: the same source item in one workspace
  is one row, and the same item pulled into two workspaces is two. Importers
  use it to link items to each other before every item is stored.
  """
  @spec context_id_for_source(String.t(), String.t()) :: String.t()
  def context_id_for_source(workspace_id, source_id)
      when is_binary(workspace_id) and is_binary(source_id) and source_id != "" do
    :crypto.hash(:sha256, "#{workspace_id}\0#{source_id}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp source_context_id(workspace_id, opts) do
    case Keyword.get(opts, :source_id) do
      source_id when is_binary(source_id) and source_id != "" ->
        context_id_for_source(workspace_id, source_id)

      _none ->
        nil
    end
  end

  defp generate_id(text, dt) do
    :crypto.hash(:sha256, text <> DateTime.to_iso8601(dt))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  # ---------------------------------------------------------------------------
  # Private: Decompose + embed
  # ---------------------------------------------------------------------------

  # Builds a ParsedDoc from the context content and runs decompose_and_store.
  # The crucial invariant: parsed_doc.signal_id must equal context.id so that
  # chunks.signal_id references the context row (avoids the prior ID-drift bug).
  # Failures are logged and swallowed — chunks/embeddings are not pipeline-critical.
  defp decompose_and_embed(%Context{} = context, %ScopeEnvelope{} = scope) do
    doc =
      ParsedDoc.new(
        signal_id: context.id,
        text: context.content || context.l1_overview || "",
        modality: :text
      )

    # Chunks are slices of the document and carry its class.
    class =
      context.metadata
      |> SecurityLabels.metadata_map()
      |> Map.get("security_labels", [])
      |> SecurityLabels.highest_class()

    opts =
      [
        tenant_id: scope.tenant_id,
        workspace_id: scope.workspace_id
      ]
      |> Keyword.merge(if class, do: [classification_level: class], else: [])

    case Decomposer.decompose_and_store(doc, opts) do
      {:ok, tree} ->
        Logger.debug("[Intake] Decomposed context #{context.id} into #{length(tree.chunks)} chunks")

      {:error, reason} ->
        Logger.warning("[Intake] decompose_and_store failed for #{context.id}: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("[Intake] decompose_and_embed failed (skipping): #{inspect(error)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Semantic edges
  # ---------------------------------------------------------------------------

  # Emits "mentions" (context -> entity) and "co_occurs_with" (entity -> entity)
  # edges (Graph.create_semantic_edges_for_context/1). These use different
  # predicates than the structural "mentioned_in" / "co_occurs" edges written by
  # insert_context, so they complement rather than duplicate the existing graph.
  # Never fails the pipeline.
  defp emit_semantic_edges(%Signal{} = signal, %Context{} = context, %ScopeEnvelope{} = scope) do
    Graph.create_semantic_edges_for_context(%{
      id: context.id,
      entities: signal.entities || [],
      workspace_id: scope.workspace_id,
      tenant_id: context.tenant_id
    })
  rescue
    error ->
      Logger.warning("[Intake] emit_semantic_edges failed (skipping): #{inspect(error)}")
      :ok
  end

  defp emit_semantic_edges(_signal, _context, _scope), do: :ok

  # ---------------------------------------------------------------------------
  # Private: Skeleton detail objects
  # ---------------------------------------------------------------------------

  # Genres whose skeleton sections map naturally to step-level MDOs.
  @skeleton_detail_genres ~w[transcript decision-log]

  # Creates one MemoryDetailObject per skeleton section for structured genres.
  # Uses the source_package as parent so the MDO hierarchy is:
  # source_package -> step (section name).
  # Only runs when the genre has a meaningful skeleton AND the content is
  # non-empty. Purely additive — never fails the pipeline.
  defp persist_skeleton_detail_objects(
         %Signal{} = signal,
         %SourcePackage{} = source_package,
         %ScopeEnvelope{} = scope
       ) do
    genre = signal.genre || ""

    if genre in @skeleton_detail_genres do
      sections = Skeleton.sections_for(genre)

      sections
      |> Enum.with_index()
      |> Enum.each(fn {section, idx} ->
        attrs = %{
          tenant_id: scope.tenant_id,
          workspace_id: scope.workspace_id,
          parent_object_type: "source_package",
          parent_object_id: source_package.id,
          detail_type: "step",
          detail_order: idx,
          detail_text: "section: #{section.name}",
          action_class: "skeleton_section",
          source_package_links: [source_package.id],
          metadata: %{
            genre: genre,
            section_name: section.name,
            required: section.required,
            auto: section.auto
          }
        }

        case MemoryCoreStore.insert_memory_detail_object(attrs) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Intake] MemoryDetailObject (skeleton) persist failed (skipping): #{inspect(reason)}"
            )

            :ok
        end
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[Intake] persist_skeleton_detail_objects failed (skipping): #{inspect(error)}"
      )

      :ok
  end

  defp load_topology do
    case Routing.load() do
      {:ok, t} -> t
      {:error, _} -> %{endpoints: %{}, root_path: nil}
    end
  end

  # Entity names from the canonical Topology.Node table. Includes each node's
  # full name plus its first token (so "Jane Example" also matches "Jane").
  # Resilient: any failure yields [] so intake never breaks on a topology read.
  defp db_entity_names do
    nodes =
      case OptimalEngine.Topology.Node.list() do
        {:ok, list} -> list
        list when is_list(list) -> list
        _ -> []
      end

    nodes
    |> Enum.flat_map(fn node ->
      name = Map.get(node, :name) || ""
      first = name |> String.split(" ") |> List.first("")
      [name, first]
    end)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp topology_entities(topology) do
    topology
    |> Map.get(:endpoints, %{})
    |> Map.values()
    |> Enum.flat_map(fn ep ->
      name = Map.get(ep, :name, "")
      first = name |> String.split(" ") |> List.first("")
      [name, first]
    end)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end
end
