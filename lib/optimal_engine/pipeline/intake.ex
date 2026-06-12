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
  alias OptimalEngine.Context
  alias OptimalEngine.MemoryCore.DerivationLedgerEntry
  alias OptimalEngine.MemoryCore.ScopeEnvelope
  alias OptimalEngine.MemoryCore.SourcePackage
  alias OptimalEngine.MemoryCore.SourcePackageService
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Pipeline.Indexer, as: Indexer
  alias OptimalEngine.Pipeline.Intake.Writer, as: Writer
  alias OptimalEngine.Pipeline.Router, as: Router
  alias OptimalEngine.Pipeline.SemanticProcessor, as: SemanticProcessor
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Routing
  alias OptimalEngine.URI

  alias OptimalEngine.Bridge.Memory, as: BridgeMemory
  alias OptimalEngine.Bridge.Signal, as: BridgeSignal

  # Policy applied by the quality gate; recorded on reject/quarantine ledger entries.
  @quality_gate_policy "intake_quality_gate_v1"

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
          quality_action: :accepted | :quarantined | :rejected
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
  """
  @spec process(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def process(raw_text, opts \\ []) when is_binary(raw_text) do
    GenServer.call(__MODULE__, {:process, raw_text, opts}, 30_000)
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
         {:ok, signal} <- classify_step(raw_text, opts),
         signal = enhance_with_signal_bridge(signal, raw_text),
         {:ok, signal} <- quality_gate(signal, source_package, scope),
         {:ok, signal, routed_to} <- route_step(signal, opts),
         {:ok, primary_path} <- write_step(signal, scope),
         {:ok, cross_paths} <- cross_ref_step(signal, routed_to, scope),
         {:ok, context} <- index_step(signal, primary_path, scope) do
      uri = URI.from_path(primary_path)
      primary_relative = relative(primary_path)
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
        files_written: [primary_relative],
        routed_to: routed_to,
        cross_references: cross_relatives,
        uri: uri,
        quality_violations: violations,
        quality_action: quality_action
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

  # Augment signal classification with the bridge classifier when available.
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

  # Step 1: Classify
  defp classify_step(raw_text, opts) do
    topology = load_topology()
    known_entities = topology_entities(topology)

    # Merge explicit entities into known entities for extraction
    extra_entities = Keyword.get(opts, :entities, [])
    all_known = Enum.uniq(known_entities ++ extra_entities)

    # Intake always produces a signal unless the caller explicitly forces another type.
    # Without this, content with an empty path is classified as :resource and loses
    # all Mode + Genre + Type + Format + Structure dimensions.
    forced_type = Keyword.get(opts, :type, :signal)
    classify_opts = [path: "", known_entities: all_known, type: forced_type]

    ctx = Classifier.classify_context(raw_text, classify_opts)

    signal =
      case ctx.signal do
        %Signal{} = sig ->
          sig

        nil ->
          # Build a minimal signal from the context for non-signal types
          Context.to_signal(ctx)
      end

    now = DateTime.utc_now()
    id = generate_id(raw_text, now)

    # Apply option overrides
    signal =
      signal
      |> maybe_override(:title, Keyword.get(opts, :title))
      |> maybe_override(:genre, Keyword.get(opts, :genre))
      |> maybe_override(:node, Keyword.get(opts, :node))
      |> maybe_merge_entities(extra_entities)
      |> then(fn s ->
        %{
          s
          | id: id,
            created_at: now,
            modified_at: now,
            content: raw_text,
            format: :markdown
        }
      end)
      |> regenerate_summaries()

    {:ok, signal}
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
  defp write_step(%Signal{} = signal, %ScopeEnvelope{} = scope) do
    Writer.write_signal(signal, ScopeEnvelope.folder_scope(scope))
  end

  # Step 4: Write cross-references
  defp cross_ref_step(%Signal{} = signal, routed_to, %ScopeEnvelope{} = scope) do
    folder_scope = ScopeEnvelope.folder_scope(scope)
    primary_folder = Writer.node_to_folder(signal.node, folder_scope)

    cross_nodes =
      routed_to
      |> Enum.reject(fn dest ->
        Writer.node_to_folder(dest, folder_scope) == primary_folder
      end)

    Writer.write_cross_references(signal, cross_nodes, folder_scope)
  end

  # Step 5: Index — write the primary file to SQLite via Indexer
  defp index_step(%Signal{} = signal, primary_path, %ScopeEnvelope{} = scope) do
    # Build a complete context for storage
    uri = URI.from_path(primary_path)
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
      metadata: %{}
    }

    case Store.insert_context(context) do
      :ok ->
        index_cross_refs(signal, scope)
        {:ok, context}

      {:error, _} = err ->
        err
    end
  end

  defp index_cross_refs(%Signal{} = signal, %ScopeEnvelope{} = scope) do
    folder_scope = ScopeEnvelope.folder_scope(scope)
    primary_folder = Writer.node_to_folder(signal.node, folder_scope)

    Enum.each(signal.routed_to || [], fn dest ->
      if Writer.node_to_folder(dest, folder_scope) != primary_folder do
        cross_path = cross_file_path(signal, dest, folder_scope)

        # Cross-ref Context rows must carry the intake's workspace scope.
        # Indexing without it stamps the struct default ("default"),
        # leaking workspace content into default-workspace surfaces.
        if File.exists?(cross_path) do
          Indexer.index_file(cross_path, workspace_id: scope.workspace_id)
        end
      end
    end)
  end

  defp cross_file_path(%Signal{} = signal, dest_node, folder_scope) do
    root = Application.get_env(:optimal_engine, :root_path, "")
    dest_folder = Writer.node_to_folder(dest_node, folder_scope)
    filename = Writer.relative_path(%{signal | node: dest_node}, folder_scope) |> Path.basename()
    Path.join([root, dest_folder, "signals", filename])
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

  defp generate_id(text, dt) do
    :crypto.hash(:sha256, text <> DateTime.to_iso8601(dt))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp load_topology do
    case Routing.load() do
      {:ok, t} -> t
      {:error, _} -> %{endpoints: %{}, root_path: nil}
    end
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
