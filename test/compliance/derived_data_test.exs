defmodule OptimalEngine.Compliance.DerivedDataTest do
  @moduledoc """
  Erasing a context takes everything derived from it, in every table that holds text or
  a vector made from it, and the files those rows point at; what belongs to other
  contexts stays.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.DerivedData
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Store

  # table -> column that names the erased context's material, for the counts below.
  @derived [
    {"vectors", "context_id"},
    {"chunks", "signal_id"},
    {"entity_mentions", "context_id"},
    {"claims", "signal_id"},
    {"episodes", "id"},
    {"processor_runs", "context_id"},
    {"decisions", "context_id"},
    {"graph_edges", "source_id"},
    {"graph_edges", "target_id"}
  ]

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "derived-data-#{n}")
    cache = Path.join(root, "cache")
    File.mkdir_p!(cache)

    saved = Map.new([:root_path, :cache_path], &{&1, Application.get_env(:optimal_engine, &1)})
    Application.put_env(:optimal_engine, :root_path, root)
    Application.put_env(:optimal_engine, :cache_path, cache)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      Store.raw_query("DROP TABLE IF EXISTS source_packages_fts", [])
      File.rm_rf(root)
    end)

    %{n: n, root: root, cache: cache}
  end

  describe "erase_contexts/2" do
    test "removes every table derived from the contexts and leaves other contexts alone", ctx do
      gone = seed!("gone-#{ctx.n}", ctx)
      kept = seed!("kept-#{ctx.n}", ctx)

      assert {:ok, removed} = DerivedData.erase_contexts("default", [gone.context])

      for {table, column} <- @derived do
        value = if table == "episodes", do: gone.episode, else: gone.context
        assert count(table, column, value) == 0, "#{table} still holds the erased context's rows"

        kept_value = if table == "episodes", do: kept.episode, else: kept.context
        assert count(table, column, kept_value) >= 1, "#{table} lost the other context's rows"
      end

      assert count("contexts", "id", gone.context) == 0
      assert count("contexts", "id", kept.context) == 1
      assert count("chunk_embeddings", "chunk_id", gone.chunk) == 0
      assert count("chunk_embeddings", "chunk_id", kept.chunk) == 1
      assert count("source_packages", "id", gone.package) == 0
      assert count("source_packages", "id", kept.package) == 1
      assert count("facts", "id", gone.fact) == 0
      assert count("facts", "id", kept.fact) == 1
      assert count("resolution_decisions", "id", gone.resolution) == 0
      assert count("decomposition_runs", "id", gone.run) == 0
      assert count("assets", "id", gone.asset) == 0
      assert count("assets", "id", kept.asset) == 1
      assert count("asset_extractions", "id", gone.extraction) == 0
      assert count("asset_transcripts", "id", gone.transcript) == 0
      assert count("asset_ocr_spans", "id", gone.span) == 0
      assert count("asset_extractions", "id", kept.extraction) == 1
      assert count("wiki_pages", "slug", gone.slug) == 0
      assert count("citations", "wiki_slug", gone.slug) == 0
      assert count("wiki_pages", "slug", kept.slug) == 1
      assert count("citations", "wiki_slug", kept.slug) == 1

      assert %{
               contexts: 1,
               vectors: 1,
               chunks: 1,
               chunk_embeddings: 1,
               claims: 1,
               facts: 1,
               entity_mentions: 1,
               resolution_decisions: 1,
               source_packages: 1,
               decomposition_runs: 1,
               assets: 1,
               asset_extractions: 1,
               asset_transcripts: 1,
               asset_ocr_spans: 1,
               wiki_pages: 1,
               citations: 1,
               episodes: 1,
               processor_runs: 1,
               decisions: 1,
               graph_edges: 2
             } = removed
    end

    test "removes the files the deleted rows point at and no others", ctx do
      gone = seed!("files-gone-#{ctx.n}", ctx)
      kept = seed!("files-kept-#{ctx.n}", ctx)
      # A run whose recorded checkpoint is not the file this Engine names for it: the
      # row goes, the file is not ours to remove.
      foreign = Path.join(ctx.cache, "decomposition/not-a-run-of-ours.json")
      File.mkdir_p!(Path.dirname(foreign))
      File.write!(foreign, "unrelated")

      sql!(
        """
        INSERT INTO decomposition_runs (id, organization_id, workspace_id, source_package_id, strategy, checkpoint_uri)
        VALUES (?1, 'org', 'default', ?2, 'deterministic', ?3)
        """,
        ["run-extra-#{ctx.n}", gone.package, foreign]
      )

      assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

      refute File.exists?(gone.asset_file)
      refute File.exists?(gone.checkpoint_file)
      assert File.exists?(kept.asset_file)
      assert File.exists?(kept.checkpoint_file)
      assert File.exists?(foreign)
    end

    test "a forged checkpoint row removes no file but the run's own", ctx do
      gone = seed!("forged-run-gone-#{ctx.n}", ctx)
      kept = seed!("forged-run-kept-#{ctx.n}", ctx)

      # A bundle import writes these rows as they come: any run id, any path, any workspace.
      authority = Path.join(ctx.root, "agent-authority.json")
      File.write!(authority, ~s({"authority": true}))
      other_run = Path.join(ctx.cache, "decomposition/other-#{ctx.n}.json")
      File.write!(other_run, checkpoint_body("other-#{ctx.n}", "default", "another run"))
      foreign = Path.join(ctx.cache, "decomposition/foreign-#{ctx.n}.json")
      File.write!(foreign, checkpoint_body("foreign-#{ctx.n}", "default:someone-else", "theirs"))

      forged = [
        {"agent-authority", "default", authority},
        {"claims-another-run-#{ctx.n}", "default", other_run},
        {"foreign-#{ctx.n}", "default:someone-else", foreign},
        {"relative-#{ctx.n}", "default", "relative-#{ctx.n}.json"}
      ]

      for {id, workspace, uri} <- forged do
        sql!(
          """
          INSERT INTO decomposition_runs (id, organization_id, workspace_id, source_package_id, strategy, checkpoint_uri)
          VALUES (?1, 'org', ?2, ?3, 'deterministic', ?4)
          """,
          [id, workspace, gone.package, uri]
        )
      end

      assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

      refute File.exists?(gone.checkpoint_file)
      assert File.exists?(kept.checkpoint_file)
      for path <- [authority, other_run, foreign], do: assert(File.exists?(path))
      assert count("decomposition_runs", "source_package_id", gone.package) == 0
    end

    test "a forged asset row removes no file outside the erased workspace's assets", ctx do
      gone = seed!("forged-asset-gone-#{ctx.n}", ctx)

      victim = Path.join(ctx.root, "other-ws/assets/ab/victim-#{ctx.n}.bin")
      File.mkdir_p!(Path.dirname(victim))
      File.write!(victim, "another workspace's bytes")
      note = Path.join(ctx.root, "tenants/acme/sales/nodes/note-#{ctx.n}.md")
      File.mkdir_p!(Path.dirname(note))
      File.write!(note, "a note")

      forged = [
        {"default", victim},
        {"default:other-ws", victim},
        {"default", Path.join(ctx.root, "other-ws/./assets/ab/victim-#{ctx.n}.bin")},
        {"default", Path.join(ctx.root, "assets/ab/../../other-ws/assets/ab/victim-#{ctx.n}.bin")},
        {"default", note}
      ]

      for {{workspace, path}, i} <- Enum.with_index(forged) do
        sql!(
          """
          INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
          VALUES (?1, 'default', 'text/plain', 1, ?2, ?3, ?4)
          """,
          ["forged-asset-#{ctx.n}-#{i}", path, workspace, gone.package]
        )
      end

      assert {:ok, %{assets: assets}} = DerivedData.erase_contexts("default", [gone.context])

      assert assets == 1 + length(forged)
      refute File.exists?(gone.asset_file)
      assert File.exists?(victim)
      assert File.exists?(note)
    end

    test "an asset file is not removed through a link", ctx do
      gone = seed!("link-gone-#{ctx.n}", ctx)

      outside = Path.join(Path.dirname(ctx.root), "derived-data-outside-#{ctx.n}")
      target = Path.join(outside, "linked-#{ctx.n}.bin")
      File.mkdir_p!(outside)
      File.write!(target, "bytes behind a link")
      on_exit(fn -> File.rm_rf(outside) end)
      File.ln_s!(outside, Path.join(ctx.root, "assets/cd"))

      sql!(
        """
        INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
        VALUES (?1, 'default', 'text/plain', 1, ?2, 'default', ?3)
        """,
        ["link-asset-#{ctx.n}", Path.join(ctx.root, "assets/cd/linked-#{ctx.n}.bin"), gone.package]
      )

      assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

      assert File.exists?(target)
      refute File.exists?(gone.asset_file)
    end

    test "a file that a remaining asset names another way is shared too", ctx do
      gone = seed!("alias-gone-#{ctx.n}", ctx)
      kept = seed!("alias-kept-#{ctx.n}", ctx)

      # The same file, spelled with a detour.
      detour =
        Path.join(ctx.root, "assets/cd/../ab/#{Path.basename(gone.asset_file)}")

      {:ok, _} =
        Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [detour, kept.asset])

      assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

      assert File.exists?(gone.asset_file)
      assert count("assets", "id", kept.asset) == 1
    end

    test "an asset file shared with an asset that stays is kept", ctx do
      gone = seed!("share-gone-#{ctx.n}", ctx)
      kept = seed!("share-kept-#{ctx.n}", ctx)

      # Two assets of the same content hash share their bytes.
      {:ok, _} =
        Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [
          gone.asset_file,
          kept.asset
        ])

      assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

      assert File.exists?(gone.asset_file)
      assert count("assets", "id", kept.asset) == 1
    end

    test "a source package that another context still refers to stays", ctx do
      first = seed!("pkg-first-#{ctx.n}", ctx)
      second = seed!("pkg-second-#{ctx.n}", ctx)

      {:ok, _} =
        Store.raw_query(
          "UPDATE contexts SET metadata = json_set(metadata, '$.source_package_id', ?1) WHERE id = ?2",
          [first.package, second.context]
        )

      assert {:ok, removed} = DerivedData.erase_contexts("default", [first.context])

      assert count("source_packages", "id", first.package) == 1
      assert Map.get(removed, :source_packages) == 0
      # Its claim by the erased context goes, and the package's files stay with the package.
      assert count("claims", "signal_id", first.context) == 0
      assert File.exists?(first.asset_file)
    end

    test "ids that are not the tenant's are ignored", ctx do
      other = seed!("tenant-#{ctx.n}", ctx)

      assert {:ok, removed} = DerivedData.erase_contexts("another-tenant", [other.context])

      assert removed.contexts == 0
      assert count("contexts", "id", other.context) == 1
      assert count("claims", "signal_id", other.context) == 1
    end

    test "goes in batches, and a failed batch leaves the rest for a second run", ctx do
      size = DerivedData.batch_size()
      ids = for i <- 1..(size * 2 + 50), do: "batch-#{ctx.n}-#{i}"
      Enum.each(ids, &context!(&1, "default", "default", "text of #{&1}"))

      # The third batch cannot be deleted.
      poison = List.last(ids)

      {:ok, _} =
        Store.raw_query(
          """
          CREATE TRIGGER IF NOT EXISTS derived_data_test_poison BEFORE DELETE ON contexts
          WHEN old.id = '#{poison}'
          BEGIN SELECT RAISE(ABORT, 'refused'); END
          """,
          []
        )

      assert {:error, _} = DerivedData.erase_contexts("default", ids)

      remaining = Enum.count(ids, &(count("contexts", "id", &1) == 1))
      assert remaining == 50

      {:ok, _} = Store.raw_query("DROP TRIGGER derived_data_test_poison", [])
      assert {:ok, %{contexts: 50}} = DerivedData.erase_contexts("default", ids)
      assert Enum.all?(ids, &(count("contexts", "id", &1) == 0))
    end

    test "deletes a source package's full-text index rows where an older database has one", ctx do
      seeded = seed!("fts-#{ctx.n}", ctx)

      {:ok, _} =
        Store.raw_query(
          "CREATE VIRTUAL TABLE source_packages_fts USING fts5(id, raw_text)",
          []
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages_fts(rowid, id, raw_text) SELECT rowid, id, raw_text FROM source_packages WHERE id = ?1",
          [seeded.package]
        )

      assert count("source_packages_fts", "id", seeded.package) == 1

      assert {:ok, %{source_packages_fts: 1}} =
               DerivedData.erase_contexts("default", [seeded.context])

      assert count("source_packages_fts", "id", seeded.package) == 0
    end
  end

  describe "file_plan/3 and remove_planned_files/1" do
    test "remove the files of the package and the rows this Engine made from it", ctx do
      {seeded, entry} = planned!(ctx, "plan-gone")

      assert entry.package == seeded.package
      assert entry.contexts == [seeded.context]

      assert {:ok, %{entries: 1, kept: 0, files: 2, rows: rows}} =
               DerivedData.remove_planned_files([entry])

      assert rows >= 4

      refute File.exists?(seeded.asset_file)
      refute File.exists?(seeded.checkpoint_file)

      for {table, id} <- [
            {"decomposition_runs", seeded.run},
            {"assets", seeded.asset},
            {"asset_extractions", seeded.extraction},
            {"asset_transcripts", seeded.transcript},
            {"asset_ocr_spans", seeded.span}
          ] do
        assert count(table, "id", id) == 0, "#{table} still holds the package's row"
      end
    end

    test "keep the files and rows of a package that is still here", ctx do
      {seeded, entry} = planned!(ctx, "plan-present", package: :stays)

      assert {:ok, %{entries: 0, kept: 1, files: 0, rows: 0}} =
               DerivedData.remove_planned_files([entry])

      assert File.exists?(seeded.asset_file)
      assert File.exists?(seeded.checkpoint_file)
      assert count("assets", "id", seeded.asset) == 1
      assert count("decomposition_runs", "id", seeded.run) == 1
    end

    test "keep the files of a package a context created after the plan refers to", ctx do
      {seeded, entry} = planned!(ctx, "plan-context")
      context!("late-#{ctx.n}", "default", "default", "created after the plan")

      sql!("UPDATE contexts SET metadata = ?1 WHERE id = ?2", [
        Jason.encode!(%{"source_package_id" => seeded.package}),
        "late-#{ctx.n}"
      ])

      assert {:ok, %{entries: 0, kept: 1, files: 0}} = DerivedData.remove_planned_files([entry])

      assert File.exists?(seeded.asset_file)
      assert File.exists?(seeded.checkpoint_file)
    end

    test "keep the files of a package a claim refers to", ctx do
      {seeded, entry} = planned!(ctx, "plan-claim")

      sql!(
        "INSERT INTO claims (id, source_package_id, claim_text) VALUES (?1, ?2, 'a claim')",
        ["late-claim-#{ctx.n}", seeded.package]
      )

      assert {:ok, %{entries: 0, kept: 1}} = DerivedData.remove_planned_files([entry])

      assert File.exists?(seeded.asset_file)
      assert File.exists?(seeded.checkpoint_file)
    end

    test "keep an asset file that an asset outside the entry names, spelled either way", ctx do
      {seeded, entry} = planned!(ctx, "plan-shared")

      for {id, path} <- [
            {"same-#{ctx.n}", seeded.asset_file},
            {"detour-#{ctx.n}",
             Path.join(Path.dirname(seeded.asset_file), "../ab/#{Path.basename(seeded.asset_file)}")}
          ] do
        sql!(
          """
          INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id)
          VALUES (?1, 'default', 'application/octet-stream', 1, ?2, 'default')
          """,
          [id, path]
        )
      end

      assert {:ok, %{entries: 1, kept: 0, files: 1}} = DerivedData.remove_planned_files([entry])

      assert File.exists?(seeded.asset_file)
      refute File.exists?(seeded.checkpoint_file)
    end

    test "a plan with nothing to remove answers zeros" do
      assert {:ok, %{entries: 0, kept: 0, files: 0}} = DerivedData.remove_planned_files([])
    end
  end

  describe "preview/2" do
    test "counts what erase_contexts/2 would remove and removes nothing", ctx do
      seeded = seed!("preview-#{ctx.n}", ctx)

      assert {:ok, counts} = DerivedData.preview("default", [seeded.context])

      assert %{contexts: 1, claims: 1, source_packages: 1, assets: 1, wiki_pages: 1} = counts
      assert count("contexts", "id", seeded.context) == 1
      assert count("claims", "signal_id", seeded.context) == 1
      assert count("source_packages", "id", seeded.package) == 1
      assert File.exists?(seeded.asset_file)
      assert File.exists?(seeded.checkpoint_file)
    end
  end

  describe "delete_derived/1" do
    test "removes the derived material and keeps the contexts", ctx do
      seeded = seed!("derived-only-#{ctx.n}", ctx)

      assert {:ok, %{claims: 1, chunks: 1}} = DerivedData.delete_derived([seeded.context])

      assert count("contexts", "id", seeded.context) == 1
      assert count("claims", "signal_id", seeded.context) == 0
      assert count("chunks", "signal_id", seeded.context) == 0
      assert count("source_packages", "id", seeded.package) == 0
      refute File.exists?(seeded.asset_file)
    end
  end

  defp checkpoint_body(run_id, workspace, text) do
    Jason.encode!(%{
      run_id: run_id,
      workspace_id: workspace,
      output: %{chunks: [%{text: text}]}
    })
  end

  # The contexts of the plan go the way a replica's go: their rows are deleted by
  # something else, and the files are removed afterwards. The package goes with them, as the
  # origin deletes it with its last context, unless the test says `package: :stays`.
  defp planned!(ctx, label, opts \\ []) do
    seeded = seed!("#{label}-#{ctx.n}", ctx)
    assert {:ok, [entry]} = DerivedData.file_plan("default", "default", [seeded.context])
    # A peer's erasure deletes the claims before the context, and so does the replica.
    {:ok, _} = Store.raw_query("DELETE FROM claims WHERE signal_id = ?1", [seeded.context])
    {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", [seeded.context])

    if Keyword.get(opts, :package) != :stays do
      {:ok, _} = Store.raw_query("DELETE FROM source_packages WHERE id = ?1", [seeded.package])
    end

    {seeded, entry}
  end

  # ── seed data ──────────────────────────────────────────────────────────────

  # One context with a row in each table that is made from it, and the files two of them
  # point at. Every id carries `label`.
  defp seed!(label, ctx) do
    package = "pkg-#{label}"
    context = "ctx-#{label}"
    chunk = "#{context}:chk-0"
    claim = "claim-#{label}"
    mention = "mention-#{label}"
    asset = "asset-#{label}"
    run = "run-#{label}"
    slug = "wiki-#{label}"

    asset_file = Path.join(ctx.root, "assets/ab/#{label}.bin")
    checkpoint_file = Path.join(ctx.cache, "decomposition/#{run}.json")
    File.mkdir_p!(Path.dirname(asset_file))
    File.mkdir_p!(Path.dirname(checkpoint_file))
    File.write!(asset_file, "bytes of #{label}")
    File.write!(checkpoint_file, checkpoint_body(run, "default", "text of #{label}"))

    sql!(
      "INSERT INTO source_packages (id, content_hash, raw_text) VALUES (?1, ?2, ?3)",
      [package, "hash-#{label}", "raw text of #{label}"]
    )

    context!(context, "default", "default", "text of #{label}")

    sql!("UPDATE contexts SET metadata = ?1 WHERE id = ?2", [
      Jason.encode!(%{"source_package_id" => package}),
      context
    ])

    :ok =
      Store.insert_chunks([
        Chunk.new(
          id: chunk,
          signal_id: context,
          tenant_id: "default",
          workspace_id: "default",
          text: "text of #{label}"
        )
      ])

    :ok =
      Store.insert_embeddings([
        %{
          chunk_id: chunk,
          tenant_id: "default",
          model: "test",
          modality: :text,
          dim: 4,
          vector: [1.0, 0.0, 0.0, 0.0],
          workspace_id: "default"
        }
      ])

    :ok = Store.Vectors.store(context, [1.0, 0.0, 0.0, 0.0], workspace_id: "default")

    sql!(
      "INSERT INTO claims (id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4)",
      [claim, package, context, "claim text of #{label}"]
    )

    sql!("INSERT INTO facts (id, fact_text, accepted_claim_ids) VALUES (?1, ?2, ?3)", [
      "fact-#{label}",
      "fact text of #{label}",
      Jason.encode!([claim])
    ])

    sql!(
      """
      INSERT INTO entity_mentions (id, workspace_id, source_package_id, context_id, surface_text, normalized_text)
      VALUES (?1, 'default', ?2, ?3, ?4, ?4)
      """,
      [mention, package, context, "surface of #{label}"]
    )

    sql!(
      "INSERT INTO resolution_decisions (id, workspace_id, mention_id, decision, actor_id) VALUES (?1, 'default', ?2, 'link', 'test')",
      ["resolution-#{label}", mention]
    )

    sql!(
      """
      INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
      VALUES (?1, 'default', 'application/octet-stream', 10, ?2, 'default', ?3)
      """,
      [asset, asset_file, package]
    )

    sql!(
      """
      INSERT INTO asset_adapter_runs (id, tenant_id, workspace_id, asset_id, adapter_id, adapter_role, modality, status, started_at)
      VALUES (?1, 'default', 'default', ?2, 'test', 'ocr', 'text', 'ok', datetime('now'))
      """,
      ["adapter-#{label}", asset]
    )

    sql!(
      """
      INSERT INTO asset_extractions (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_type, modality, content_text)
      VALUES (?1, 'default', 'default', ?2, ?3, 'text', 'text', ?4)
      """,
      ["extraction-#{label}", asset, "adapter-#{label}", "extracted #{label}"]
    )

    sql!(
      """
      INSERT INTO asset_transcripts (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_id, transcript_text)
      VALUES (?1, 'default', 'default', ?2, ?3, ?4, ?5)
      """,
      ["transcript-#{label}", asset, "adapter-#{label}", "extraction-#{label}", "said #{label}"]
    )

    sql!(
      """
      INSERT INTO asset_ocr_spans (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_id, span_text)
      VALUES (?1, 'default', 'default', ?2, ?3, ?4, ?5)
      """,
      ["span-#{label}", asset, "adapter-#{label}", "extraction-#{label}", "read #{label}"]
    )

    sql!(
      """
      INSERT INTO decomposition_runs (id, organization_id, workspace_id, source_package_id, strategy, checkpoint_uri)
      VALUES (?1, 'org', 'default', ?2, 'deterministic', ?3)
      """,
      [run, package, checkpoint_file]
    )

    sql!(
      "INSERT INTO episodes (id, summary, provenance) VALUES (?1, ?2, ?3)",
      ["episode-#{label}", "episode of #{label}", Jason.encode!(%{"signal_id" => context})]
    )

    sql!(
      "INSERT INTO processor_runs (tenant_id, context_id, architecture_id, processor, field) VALUES ('default', ?1, 'arch', 'proc', 'field')",
      [context]
    )

    sql!(
      "INSERT INTO decisions (context_id, title, decision) VALUES (?1, 'title', ?2)",
      [context, "decided #{label}"]
    )

    # One edge from the context and one to it.
    sql!(
      "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES ('default', 'default', ?1, ?2, 'mentions')",
      [context, "entity-#{label}"]
    )

    sql!(
      "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES ('default', 'default', ?1, ?2, 'cites')",
      ["other-#{label}", context]
    )

    sql!("INSERT INTO wiki_pages (tenant_id, slug, body) VALUES ('default', ?1, ?2)", [
      slug,
      "page about #{label}"
    ])

    sql!(
      "INSERT INTO citations (tenant_id, wiki_slug, chunk_id, claim_hash) VALUES ('default', ?1, ?2, 'h')",
      [slug, chunk]
    )

    %{
      context: context,
      package: package,
      chunk: chunk,
      fact: "fact-#{label}",
      resolution: "resolution-#{label}",
      run: run,
      asset: asset,
      extraction: "extraction-#{label}",
      transcript: "transcript-#{label}",
      span: "span-#{label}",
      slug: slug,
      episode: "episode-#{label}",
      asset_file: asset_file,
      checkpoint_file: checkpoint_file
    }
  end

  defp context!(id, tenant, workspace, text) do
    sql!(
      """
      INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, genre, node)
      VALUES (?1, ?2, ?3, ?4, 't', ?5, 'note', 'person-operator')
      """,
      [id, tenant, workspace, "optimal://derived-data/#{id}", text]
    )
  end

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end

  defp count(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end
end
