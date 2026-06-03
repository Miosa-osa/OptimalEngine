defmodule OptimalEngine.MemoryCore.AssetStore do
  @moduledoc """
  Governed storage for raw multimodal artifacts.

  Parsers can extract text, OCR, transcripts, frames, or summaries, but the raw
  file is still the evidence. This module preserves that file in the workspace
  asset store, writes an `assets` row, creates a Source Package for the raw
  artifact, and records the derivation link.
  """

  alias OptimalEngine.{Store, Workspace}
  alias OptimalEngine.MemoryCore.{DerivationLedgerEntry, ID, JSON, SourcePackage}
  alias OptimalEngine.Pipeline.MultimodalToolRegistry
  alias OptimalEngine.Pipeline.Parser.Asset
  alias OptimalEngine.Workspace.Filesystem

  @spec store_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def store_file(path, opts \\ []) when is_binary(path) do
    with {:ok, asset} <- Asset.from_path(path, opts),
         {:ok, result} <- store_asset(asset, opts) do
      {:ok, result}
    end
  end

  @spec store_asset(Asset.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def store_asset(asset, opts \\ [])

  def store_asset(%Asset{path: path} = asset, opts) when is_binary(path) do
    with {:ok, storage_path} <- copy_asset(asset, opts),
         {:ok, source_package} <- record_source_package(asset, storage_path, opts),
         asset_id = asset_id(asset, source_package),
         :ok <- upsert_asset(asset_id, asset, storage_path, source_package, opts),
         :ok <- record_derivation(asset_id, asset, source_package, opts),
         {:ok, stored_asset} <- get(asset_id, opts) do
      {:ok, %{asset: stored_asset, source_package: source_package}}
    end
  end

  def store_asset(%Asset{} = _asset, _opts), do: {:error, :asset_path_required}

  @spec record_adapter_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_adapter_run(asset_id, opts \\ []) when is_binary(asset_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    with {:ok, asset} <- get(asset_id, tenant_id: tenant_id, workspace_id: workspace_id),
         {:ok, tool} <- adapter_tool(opts),
         {:ok, run} <- build_adapter_run(asset, tool, opts),
         :ok <- insert_adapter_run(run),
         :ok <- record_adapter_derivation(run, asset, tool, opts) do
      {:ok, run}
    end
  end

  @spec list_adapter_runs(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_adapter_runs(asset_id, opts \\ []) when is_binary(asset_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT id, tenant_id, workspace_id, asset_id, source_package_id, adapter_id,
           adapter_role, modality, status, started_at, completed_at, input_hash,
           output_hash, output_text, output_ref, model_id, model_version,
           confidence, precision, error_reason, security_labels, partition_ids,
           metadata, derivation_ledger_id, created_by, created_at
    FROM asset_adapter_runs
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND asset_id = ?3
    ORDER BY created_at DESC
    """

    case Store.raw_query(sql, [tenant_id, workspace_id, asset_id]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_adapter_run/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get(asset_id, opts \\ []) when is_binary(asset_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT id, tenant_id, workspace_id, content_type, size_bytes, storage_path,
           created_at, content_hash, modality, source_package_id, original_path,
           trust_label, retention_class, access_policy_id, security_labels,
           partition_ids, metadata
    FROM assets
    WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3
    """

    case Store.raw_query(sql, [asset_id, tenant_id, workspace_id]) do
      {:ok, [row]} -> {:ok, row_to_asset(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_tool(opts) do
    adapter_id = Keyword.fetch!(opts, :adapter_id)
    normalized = normalize_adapter_id(adapter_id)

    case MultimodalToolRegistry.get(normalized) do
      nil -> {:error, {:unknown_adapter, adapter_id}}
      tool -> {:ok, tool}
    end
  end

  defp normalize_adapter_id(id) when is_atom(id), do: id

  defp normalize_adapter_id(id) when is_binary(id) do
    id
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :unknown
  end

  defp build_adapter_run(asset, tool, opts) do
    now = timestamp()
    output_text = Keyword.get(opts, :output_text, "")
    output_ref = Keyword.get(opts, :output_ref)
    status = Keyword.get(opts, :status, "completed")
    input_hash = Keyword.get(opts, :input_hash, asset.content_hash)
    output_hash = Keyword.get(opts, :output_hash) || derived_output_hash(output_text, output_ref)

    run = %{
      id: Keyword.get(opts, :id, ID.random_id("aar")),
      tenant_id: asset.tenant_id,
      workspace_id: asset.workspace_id,
      asset_id: asset.id,
      source_package_id: asset.source_package_id,
      adapter_id: Atom.to_string(tool.id),
      adapter_role: adapter_role(tool, opts),
      modality: Keyword.get(opts, :modality, asset.modality),
      status: status,
      started_at: Keyword.get(opts, :started_at, now),
      completed_at: Keyword.get(opts, :completed_at, if(status == "running", do: nil, else: now)),
      input_hash: input_hash,
      output_hash: output_hash,
      output_text: output_text,
      output_ref: output_ref,
      model_id: Keyword.get(opts, :model_id),
      model_version: Keyword.get(opts, :model_version),
      confidence: Keyword.get(opts, :confidence),
      precision: Keyword.get(opts, :precision),
      error_reason: Keyword.get(opts, :error_reason),
      security_labels: Keyword.get(opts, :security_labels, asset.security_labels),
      partition_ids: Keyword.get(opts, :partition_ids, asset.partition_ids),
      metadata: Keyword.get(opts, :metadata, %{}),
      derivation_ledger_id: nil,
      created_by: Keyword.get(opts, :actor_id),
      created_at: now
    }

    {:ok, run}
  end

  defp adapter_role(tool, opts) do
    case Keyword.get(opts, :adapter_role) do
      nil -> tool.roles |> List.first() |> to_string()
      role -> to_string(role)
    end
  end

  defp derived_output_hash("", nil), do: nil

  defp derived_output_hash(output_text, output_ref) do
    material = [output_text || "", ":", output_ref || ""]
    "sha256:" <> ID.sha256(IO.iodata_to_binary(material))
  end

  defp insert_adapter_run(run) do
    sql = """
    INSERT INTO asset_adapter_runs (
      id, tenant_id, workspace_id, asset_id, source_package_id, adapter_id,
      adapter_role, modality, status, started_at, completed_at, input_hash,
      output_hash, output_text, output_ref, model_id, model_version,
      confidence, precision, error_reason, security_labels, partition_ids,
      metadata, derivation_ledger_id, created_by, created_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11, ?12,
      ?13, ?14, ?15, ?16, ?17,
      ?18, ?19, ?20, ?21, ?22,
      ?23, ?24, ?25, ?26
    )
    """

    Store.raw_execute(sql, [
      run.id,
      run.tenant_id,
      run.workspace_id,
      run.asset_id,
      run.source_package_id,
      run.adapter_id,
      run.adapter_role,
      run.modality,
      run.status,
      run.started_at,
      run.completed_at,
      run.input_hash,
      run.output_hash,
      run.output_text,
      run.output_ref,
      run.model_id,
      run.model_version,
      run.confidence,
      run.precision,
      run.error_reason,
      JSON.list(run.security_labels),
      JSON.list(run.partition_ids),
      JSON.map(run.metadata),
      run.derivation_ledger_id,
      run.created_by,
      run.created_at
    ])
  end

  defp record_adapter_derivation(run, asset, tool, opts) do
    asset_ref = DerivationLedgerEntry.object_ref("asset", asset.id)
    run_ref = DerivationLedgerEntry.object_ref("asset_adapter_run", run.id)

    source_refs =
      if is_binary(asset.source_package_id) do
        [DerivationLedgerEntry.object_ref("source_package", asset.source_package_id)]
      else
        []
      end

    ledger =
      DerivationLedgerEntry.new(
        "asset_adapter.#{Atom.to_string(tool.id)}",
        "asset_to_derived_multimodal_output",
        [asset_ref],
        [run_ref],
        tenant_id: asset.tenant_id,
        workspace_id: asset.workspace_id,
        source_package_links: source_refs,
        evidence_links: [asset_ref | source_refs],
        actor_id: Keyword.get(opts, :actor_id),
        parser_id: "optimal_engine.pipeline.multimodal_tool_registry",
        model_id: run.model_id,
        model_version: run.model_version,
        confidence_delta: run.confidence,
        precision_delta: run.precision,
        security_labels: run.security_labels,
        partition_ids: run.partition_ids,
        metadata: %{
          adapter_run_id: run.id,
          adapter_id: run.adapter_id,
          adapter_role: run.adapter_role,
          status: run.status,
          output_hash: run.output_hash
        }
      )

    case OptimalEngine.MemoryCore.Store.insert_derivation_entry(ledger) do
      :ok -> attach_derivation_ledger(run.id, ledger.id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_derivation_ledger(run_id, ledger_id) do
    Store.raw_execute(
      "UPDATE asset_adapter_runs SET derivation_ledger_id = ?1 WHERE id = ?2",
      [ledger_id, run_id]
    )
  end

  defp copy_asset(%Asset{} = asset, opts) do
    root = Application.get_env(:optimal_engine, :root_path, File.cwd!())
    workspace_id = Keyword.get(opts, :workspace_id, "default")
    workspace_slug = workspace_slug(workspace_id)
    workspace_path = Filesystem.path(root, workspace_slug)
    hash_slug = String.replace_prefix(asset.hash, "sha256:", "")
    shard = String.slice(hash_slug, 0, 2) || "00"
    ext = asset.path |> Path.extname() |> String.downcase()
    target_dir = Path.join([workspace_path, "assets", shard])
    target_path = Path.join(target_dir, "#{hash_slug}#{ext}")

    with :ok <- File.mkdir_p(target_dir),
         :ok <- maybe_copy(asset.path, target_path) do
      {:ok, target_path}
    end
  end

  defp maybe_copy(source_path, target_path) do
    if File.exists?(target_path) do
      :ok
    else
      File.cp(source_path, target_path)
    end
  end

  defp record_source_package(%Asset{} = asset, storage_path, opts) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    source_package =
      SourcePackage.from_artifact(
        storage_path,
        asset.hash,
        source_type: Keyword.get(opts, :source_type, "file"),
        source_class: Atom.to_string(asset.modality),
        source_system: Keyword.get(opts, :source_system, "asset_store"),
        source_uri: Keyword.get(opts, :source_uri, asset.path),
        verbatim_archive_uri: storage_path,
        trust_label: Keyword.get(opts, :trust_label, "unreviewed"),
        retention_class: Keyword.get(opts, :retention_class, "standard"),
        access_policy_id: Keyword.get(opts, :access_policy_id),
        security_labels: Keyword.get(opts, :security_labels, []),
        partition_ids: Keyword.get(opts, :partition_ids, []),
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        actor_id: Keyword.get(opts, :actor_id),
        raw_text: Keyword.get(opts, :extracted_text, ""),
        metadata:
          Map.merge(asset.metadata || %{}, %{
            asset_id: ID.content_id("asset", [tenant_id, ":", workspace_id, ":", asset.hash]),
            content_hash: asset.hash,
            content_type: asset.content_type,
            modality: Atom.to_string(asset.modality),
            original_path: asset.path,
            storage_path: storage_path,
            size_bytes: asset.size
          })
      )

    case OptimalEngine.MemoryCore.Store.insert_source_package(source_package) do
      :ok -> {:ok, source_package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp asset_id(%Asset{} = asset, %SourcePackage{} = source_package) do
    ID.content_id("asset", [
      source_package.tenant_id,
      ":",
      source_package.workspace_id,
      ":",
      asset.hash
    ])
  end

  defp upsert_asset(
         asset_id,
         %Asset{} = asset,
         storage_path,
         %SourcePackage{} = source_package,
         opts
       ) do
    sql = """
    INSERT INTO assets (
      id, tenant_id, workspace_id, content_type, size_bytes, storage_path,
      content_hash, modality, source_package_id, original_path, trust_label,
      retention_class, access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11,
      ?12, ?13, ?14, ?15, ?16
    )
    ON CONFLICT(id) DO UPDATE SET
      tenant_id = excluded.tenant_id,
      workspace_id = excluded.workspace_id,
      content_type = excluded.content_type,
      size_bytes = excluded.size_bytes,
      storage_path = excluded.storage_path,
      content_hash = excluded.content_hash,
      modality = excluded.modality,
      source_package_id = excluded.source_package_id,
      original_path = excluded.original_path,
      trust_label = excluded.trust_label,
      retention_class = excluded.retention_class,
      access_policy_id = excluded.access_policy_id,
      security_labels = excluded.security_labels,
      partition_ids = excluded.partition_ids,
      metadata = excluded.metadata
    """

    Store.raw_execute(sql, [
      asset_id,
      source_package.tenant_id,
      source_package.workspace_id,
      asset.content_type,
      asset.size,
      storage_path,
      asset.hash,
      Atom.to_string(asset.modality),
      source_package.id,
      asset.path,
      Keyword.get(opts, :trust_label, "unreviewed"),
      Keyword.get(opts, :retention_class, "standard"),
      Keyword.get(opts, :access_policy_id),
      JSON.list(Keyword.get(opts, :security_labels, [])),
      JSON.list(Keyword.get(opts, :partition_ids, [])),
      JSON.map(Map.merge(asset.metadata || %{}, Keyword.get(opts, :metadata, %{})))
    ])
  end

  defp record_derivation(asset_id, %Asset{} = asset, %SourcePackage{} = source_package, opts) do
    source_ref = DerivationLedgerEntry.object_ref("source_package", source_package.id)
    asset_ref = DerivationLedgerEntry.object_ref("asset", asset_id)

    ledger =
      DerivationLedgerEntry.new(
        "asset_store.preserve_file",
        "raw_file_to_source_package_asset",
        [],
        [source_ref, asset_ref],
        tenant_id: source_package.tenant_id,
        workspace_id: source_package.workspace_id,
        source_package_links: [source_ref],
        evidence_links: [source_ref, asset_ref],
        actor_id: Keyword.get(opts, :actor_id),
        parser_id: "optimal_engine.memory_core.asset_store",
        access_policy_id: source_package.access_policy_id,
        security_labels: source_package.security_labels,
        partition_ids: source_package.partition_ids,
        metadata: %{
          asset_id: asset_id,
          content_hash: asset.hash,
          modality: Atom.to_string(asset.modality)
        }
      )

    OptimalEngine.MemoryCore.Store.insert_derivation_entry(ledger)
  end

  defp workspace_slug(workspace_id) do
    case Workspace.get(workspace_id) do
      {:ok, workspace} -> workspace.slug
      _ -> workspace_id
    end
  end

  defp row_to_asset([
         id,
         tenant_id,
         workspace_id,
         content_type,
         size_bytes,
         storage_path,
         created_at,
         content_hash,
         modality,
         source_package_id,
         original_path,
         trust_label,
         retention_class,
         access_policy_id,
         security_labels,
         partition_ids,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      content_type: content_type,
      size_bytes: size_bytes,
      storage_path: storage_path,
      created_at: created_at,
      content_hash: content_hash,
      modality: modality,
      source_package_id: source_package_id,
      original_path: original_path,
      trust_label: trust_label,
      retention_class: retention_class,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      metadata: decode_map(metadata)
    }
  end

  defp row_to_adapter_run([
         id,
         tenant_id,
         workspace_id,
         asset_id,
         source_package_id,
         adapter_id,
         adapter_role,
         modality,
         status,
         started_at,
         completed_at,
         input_hash,
         output_hash,
         output_text,
         output_ref,
         model_id,
         model_version,
         confidence,
         precision,
         error_reason,
         security_labels,
         partition_ids,
         metadata,
         derivation_ledger_id,
         created_by,
         created_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      asset_id: asset_id,
      source_package_id: source_package_id,
      adapter_id: adapter_id,
      adapter_role: adapter_role,
      modality: modality,
      status: status,
      started_at: started_at,
      completed_at: completed_at,
      input_hash: input_hash,
      output_hash: output_hash,
      output_text: output_text,
      output_ref: output_ref,
      model_id: model_id,
      model_version: model_version,
      confidence: confidence,
      precision: precision,
      error_reason: error_reason,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      metadata: decode_map(metadata),
      derivation_ledger_id: derivation_ledger_id,
      created_by: created_by,
      created_at: created_at
    }
  end

  defp decode_list(nil), do: []

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_map(nil), do: %{}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
