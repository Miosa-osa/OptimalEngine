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
  alias OptimalEngine.Pipeline.Parser.Asset
  alias OptimalEngine.Workspace.Filesystem

  @spec store_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def store_file(path, opts \\ []) when is_binary(path) do
    with {:ok, asset} <- Asset.from_path(path, opts),
         {:ok, storage_path} <- copy_asset(asset, opts),
         {:ok, source_package} <- record_source_package(asset, storage_path, opts),
         asset_id = asset_id(asset, source_package),
         :ok <- upsert_asset(asset_id, asset, storage_path, source_package, opts),
         :ok <- record_derivation(asset_id, asset, source_package, opts),
         {:ok, stored_asset} <- get(asset_id, opts) do
      {:ok, %{asset: stored_asset, source_package: source_package}}
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
end
