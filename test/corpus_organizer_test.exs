defmodule OptimalEngine.CorpusOrganizerTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.CorpusOrganizer

  @rules %{
    "default:northwind" => [{"northwind", 10}, {"northwind clinic", 10}, {"jane example", 5}],
    "default:product" => [{"product suite", 10}, {"module installation", 5}]
  }

  setup do
    original = Application.get_env(:optimal_engine, :corpus_routing_rules)
    Application.put_env(:optimal_engine, :corpus_routing_rules, @rules)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:optimal_engine, :corpus_routing_rules),
        else: Application.put_env(:optimal_engine, :corpus_routing_rules, original)
    end)
  end

  test "routes canonical workspace markers with a clear margin" do
    result = CorpusOrganizer.classify("Northwind onboarding with Jane Example")
    assert result.confidence == :high
    assert result.workspace_id == "default:northwind"
  end

  test "keeps mixed or marker-free records in routing review" do
    assert CorpusOrganizer.classify("general weekly discussion").confidence == :unresolved

    result = CorpusOrganizer.classify("Product suite module for Northwind")
    assert result.confidence == :review
    assert is_nil(result.workspace_id)
  end

  test "with no rules configured nothing is routed" do
    Application.delete_env(:optimal_engine, :corpus_routing_rules)
    Application.delete_env(:optimal_engine, :corpus_routing_rules_path)

    assert CorpusOrganizer.rules() == %{}
    result = CorpusOrganizer.classify("Northwind onboarding")
    assert result.confidence == :unresolved
    assert is_nil(result.proposed_workspace_id)
  end

  test "rules load from a YAML or JSON file" do
    Application.delete_env(:optimal_engine, :corpus_routing_rules)
    dir = Path.join(System.tmp_dir!(), "corpus-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    yaml = Path.join(dir, "rules.yaml")

    File.write!(yaml, """
    rules:
      "default:northwind":
        - {marker: "Northwind", weight: 10}
    """)

    json = Path.join(dir, "rules.json")

    File.write!(
      json,
      ~s({"rules": {"default:product": [{"marker": "product suite", "weight": 10}]}})
    )

    try do
      Application.put_env(:optimal_engine, :corpus_routing_rules_path, yaml)
      assert CorpusOrganizer.rules() == %{"default:northwind" => [{"northwind", 10}]}
      assert CorpusOrganizer.classify("Northwind kickoff").workspace_id == "default:northwind"

      Application.put_env(:optimal_engine, :corpus_routing_rules_path, json)
      assert CorpusOrganizer.rules() == %{"default:product" => [{"product suite", 10}]}
    after
      Application.delete_env(:optimal_engine, :corpus_routing_rules_path)
      File.rm_rf!(dir)
    end
  end

  describe "intake in the store" do
    setup do
      n = System.unique_integer([:positive])
      workspace = "default:intake-#{n}"

      {:ok, _} =
        OptimalEngine.Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, 'default', ?2, ?2, 'active', '{}')",
          [workspace, "intake-#{n}"]
        )

      original = Application.get_env(:optimal_engine, :corpus_source_workspace)
      Application.put_env(:optimal_engine, :corpus_source_workspace, workspace)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:optimal_engine, :corpus_source_workspace),
          else: Application.put_env(:optimal_engine, :corpus_source_workspace, original)
      end)

      for i <- 1..250 do
        {:ok, _} =
          OptimalEngine.Store.raw_query(
            "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, 'default', ?2, 'signal', ?3, ?4, datetime('now'))",
            [
              "intake-#{n}-#{String.pad_leading(Integer.to_string(i), 4, "0")}",
              workspace,
              "Weekly note #{i}",
              "General discussion with no workspace markers, item #{i}."
            ]
          )
      end

      %{workspace: workspace}
    end

    test "the preview reads every intake record in pages" do
      assert {:ok, preview} = CorpusOrganizer.preview(page_size: 40)
      assert preview.total == 250
      assert length(preview.unresolved) == 250
    end

    test "queueing writes each review entry once and leaves unchanged entries alone",
         %{workspace: workspace} do
      assert {:ok, 250} = CorpusOrganizer.queue_remaining(page_size: 40, batch_size: 60)

      {:ok, [[queued_at]]} =
        OptimalEngine.Store.raw_query(
          "SELECT json_extract(metadata, '$.routing_review.queued_at') FROM contexts WHERE workspace_id = ?1 ORDER BY id LIMIT 1",
          [workspace]
        )

      assert is_binary(queued_at)
      assert {:ok, 0} = CorpusOrganizer.queue_remaining(page_size: 40, batch_size: 60)

      {:ok, [[again]]} =
        OptimalEngine.Store.raw_query(
          "SELECT json_extract(metadata, '$.routing_review.queued_at') FROM contexts WHERE workspace_id = ?1 ORDER BY id LIMIT 1",
          [workspace]
        )

      assert again == queued_at
    end
  end

  describe "placement by meaning" do
    setup do
      n = System.unique_integer([:positive])
      tenant = "meaning-#{n}"
      {:ok, _} = OptimalEngine.Tenancy.Tenant.create(%{id: tenant, name: "Meaning tenant"})
      org = "#{tenant}:org"

      {:ok, _} =
        OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

      [intake, alpha, beta, small] =
        for slug <- ~w(intake alpha beta small) do
          {:ok, ws} =
            OptimalEngine.Workspace.create(%{
              tenant_id: tenant,
              organization_id: org,
              slug: slug,
              name: slug
            })

          ws.id
        end

      for i <- 1..4 do
        filed!(tenant, alpha, "alpha-#{n}-#{i}", [1.0, 0.1 * i, 0.0, 0.0])
        filed!(tenant, beta, "beta-#{n}-#{i}", [0.1 * i, 1.0, 0.0, 0.0])
      end

      for i <- 1..2, do: filed!(tenant, small, "small-#{n}-#{i}", [0.0, 0.0, 1.0, 0.1 * i])

      original = Application.get_env(:optimal_engine, :corpus_source_workspace)
      semantic = Application.get_env(:optimal_engine, :corpus_semantic_placement)
      Application.put_env(:optimal_engine, :corpus_source_workspace, intake)
      Application.put_env(:optimal_engine, :corpus_routing_rules, %{})

      on_exit(fn ->
        restore(:corpus_source_workspace, original)
        restore(:corpus_semantic_placement, semantic)
      end)

      %{n: n, tenant: tenant, intake: intake, alpha: alpha, beta: beta, small: small}
    end

    test "the method and its parameters come from the semantic settings" do
      Application.put_env(:optimal_engine, :corpus_semantic_placement, %{"enabled" => true})

      settings = CorpusOrganizer.semantic_settings()
      assert %{method: :centroid, margin: 0.04, k: 10, share: 0.8} = settings
      assert settings.min_similarity == 0.0

      Application.put_env(:optimal_engine, :corpus_semantic_placement, %{
        "enabled" => true,
        "method" => "knn",
        "k" => 7,
        "share" => 0.75,
        "min_similarity" => 0.7
      })

      assert %{method: :knn, k: 7, share: 0.75, min_similarity: 0.7} =
               CorpusOrganizer.semantic_settings()

      Application.put_env(:optimal_engine, :corpus_semantic_placement, %{
        enabled: true,
        method: :agree,
        share: 1
      })

      assert %{method: :agree, k: 10, share: 1} = CorpusOrganizer.semantic_settings()
    end

    test "an unknown method, or a k or share out of range, turns placement by meaning off" do
      for invalid <- [
            %{"method" => "nearest"},
            %{"k" => 0},
            %{"k" => 2.5},
            %{"share" => 0},
            %{"share" => 1.5},
            %{"share" => "high"}
          ] do
        Application.put_env(
          :optimal_engine,
          :corpus_semantic_placement,
          Map.put(invalid, "enabled", true)
        )

        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert CorpusOrganizer.semantic_settings() == nil
               end) =~ "placement by meaning is off"
      end
    end

    test "is off unless enabled", ctx do
      id = filed!(ctx.tenant, ctx.intake, "plain-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])
      Application.delete_env(:optimal_engine, :corpus_semantic_placement)

      assert {:ok, preview} = CorpusOrganizer.preview()
      assert %{confidence: :unresolved, workspace_id: nil} = proposal(preview, id)
    end

    test "a record near one workspace's documents and clearly apart from the next is placed there, with evidence",
         ctx do
      enable()
      id = filed!(ctx.tenant, ctx.intake, "near-alpha-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :high, method: :semantic} = result
      assert result.workspace_id == ctx.alpha
      assert result.semantic.similarity > 0.95
      assert result.semantic.margin >= 0.04

      assert {:ok, %{moved: 1}} = CorpusOrganizer.apply_high_confidence(preview: preview)

      assert {:ok, [[workspace, placement]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT workspace_id, json_extract(metadata, '$.routing_placement') FROM contexts WHERE id = ?1",
                 [id]
               )

      assert workspace == ctx.alpha
      placement = Jason.decode!(placement)
      assert placement["method"] == "semantic"
      assert placement["semantic_method"] == "centroid"
      assert placement["workspace_id"] == ctx.alpha
      assert placement["margin"] >= 0.04
      assert is_binary(placement["placed_at"])

      assert {:ok, [[^workspace]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT workspace_id FROM vectors WHERE context_id = ?1",
                 [id]
               )
    end

    test "a record between two workspaces goes to review with the closest proposed", ctx do
      enable()
      id = filed!(ctx.tenant, ctx.intake, "between-#{ctx.n}", [0.7, 0.72, 0.0, 0.0])

      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :review, workspace_id: nil} = result
      assert result.proposed_workspace_id == ctx.beta
      assert result.semantic.workspace_id == ctx.beta
      assert result.semantic.margin < 0.04

      assert {:ok, written} = CorpusOrganizer.queue_remaining(preview: preview)
      assert written >= 1

      assert {:ok, [[queued]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT json_extract(metadata, '$.routing_review.semantic.workspace_id') FROM contexts WHERE id = ?1",
                 [id]
               )

      assert queued == ctx.beta
    end

    test "a marker proposal for another workspace blocks placement by meaning, in every method",
         ctx do
      Application.put_env(:optimal_engine, :corpus_routing_rules, %{
        ctx.beta => [{"beta launch", 5}]
      })

      id =
        filed!(ctx.tenant, ctx.intake, "marked-#{ctx.n}", [1.0, 0.05, 0.0, 0.0],
          title: "Beta launch notes"
        )

      for method <- ~w(centroid knn agree) do
        enable(%{method: method, k: 3})
        assert {:ok, preview} = CorpusOrganizer.preview()
        result = proposal(preview, id)
        assert result.semantic.method == String.to_existing_atom(method)
        assert %{confidence: :review, workspace_id: nil} = result
        assert result.proposed_workspace_id == ctx.beta
        assert result.semantic.workspace_id == ctx.alpha
      end
    end

    test "a workspace with too few documents and an excluded workspace are never targets", ctx do
      enable(%{exclude: [ctx.alpha]})
      near_small = filed!(ctx.tenant, ctx.intake, "near-small-#{ctx.n}", [0.0, 0.0, 1.0, 0.05])
      near_alpha = filed!(ctx.tenant, ctx.intake, "near-alpha-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      assert {:ok, preview} = CorpusOrganizer.preview()

      for id <- [near_small, near_alpha] do
        result = proposal(preview, id)
        refute result.workspace_id in [ctx.small, ctx.alpha]
        refute result.proposed_workspace_id in [ctx.small, ctx.alpha]
      end
    end

    test "by nearest documents: small and excluded workspaces vote but never win, among three targets",
         ctx do
      {:ok, gamma} =
        OptimalEngine.Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "gamma",
          name: "gamma"
        })

      for i <- 1..4,
          do: filed!(ctx.tenant, gamma.id, "gamma-#{ctx.n}-#{i}", [0.0, 0.0, 0.1 * i, 1.0])

      near_small = filed!(ctx.tenant, ctx.intake, "three-small-#{ctx.n}", [0.0, 0.0, 1.0, 0.05])
      near_alpha = filed!(ctx.tenant, ctx.intake, "three-alpha-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      for method <- ~w(knn agree) do
        enable(%{exclude: [ctx.alpha], method: method, k: 5})
        assert {:ok, preview} = CorpusOrganizer.preview()

        # The two small documents are the closest and dilute the vote; the
        # leading target is the third one.
        small = proposal(preview, near_small)
        assert %{confidence: :review, workspace_id: nil} = small
        assert small.proposed_workspace_id == gamma.id
        assert %{votes: 3, neighbours: 5} = small.semantic
        assert small.semantic.share < 0.5

        # Four excluded documents are the closest; one target document votes.
        alpha = proposal(preview, near_alpha)
        assert %{confidence: :review, workspace_id: nil} = alpha
        assert alpha.proposed_workspace_id == ctx.beta
        assert %{votes: 1, neighbours: 5} = alpha.semantic
        assert alpha.semantic.share < 0.2
      end
    end

    test "by nearest documents: only documents of the record's dimensions vote", ctx do
      for i <- 1..3 do
        filed!(ctx.tenant, ctx.alpha, "alpha-short-#{ctx.n}-#{i}", [1.0, 0.0, 0.1 * i])
        filed!(ctx.tenant, ctx.beta, "beta-short-#{ctx.n}-#{i}", [0.0, 1.0, 0.1 * i])
      end

      short = filed!(ctx.tenant, ctx.intake, "short-#{ctx.n}", [1.0, 0.05, 0.0])
      long = filed!(ctx.tenant, ctx.intake, "long-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      enable(%{method: "knn", k: 20, share: 0.8})
      assert {:ok, preview} = CorpusOrganizer.preview()

      result = proposal(preview, short)
      assert %{confidence: :high, method: :semantic} = result
      assert result.workspace_id == ctx.alpha
      assert %{votes: 3, neighbours: 6} = result.semantic

      assert %{votes: 4, neighbours: 10} = proposal(preview, long).semantic
    end

    test "by nearest documents: a record whose closest filed documents are all in one workspace is placed there, with the vote as evidence",
         ctx do
      enable(%{method: "knn", k: 3, share: 0.8})
      id = filed!(ctx.tenant, ctx.intake, "knn-alpha-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :high, method: :semantic} = result
      assert result.workspace_id == ctx.alpha

      assert %{method: :knn, share: 1.0, votes: 3, neighbours: 3} = result.semantic
      assert result.semantic.similarity > 0.99

      assert {:ok, %{moved: 1}} = CorpusOrganizer.apply_high_confidence(preview: preview)

      assert {:ok, [[workspace, placement]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT workspace_id, json_extract(metadata, '$.routing_placement') FROM contexts WHERE id = ?1",
                 [id]
               )

      assert workspace == ctx.alpha

      assert %{
               "method" => "semantic",
               "semantic_method" => "knn",
               "workspace_id" => workspace_id,
               "share" => 1.0,
               "votes" => 3,
               "neighbours" => 3,
               "similarity" => similarity,
               "placed_at" => placed_at
             } = Jason.decode!(placement)

      assert workspace_id == ctx.alpha
      assert similarity > 0.99
      assert is_binary(placed_at)
    end

    test "by nearest documents: a split vote goes to review with the leading workspace proposed",
         ctx do
      enable(%{method: "knn", k: 4, share: 0.8})
      id = filed!(ctx.tenant, ctx.intake, "knn-split-#{ctx.n}", [0.7, 0.72, 0.0, 0.0])

      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :review, workspace_id: nil} = result
      assert result.proposed_workspace_id == ctx.beta
      assert %{method: :knn, votes: 2, neighbours: 4} = result.semantic
      assert result.semantic.workspace_id == ctx.beta
      assert result.semantic.share > 0.5 and result.semantic.share < 0.8

      assert {:ok, written} = CorpusOrganizer.queue_remaining(preview: preview)
      assert written >= 1

      assert {:ok, [[method, share]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT json_extract(metadata, '$.routing_review.semantic.method'), json_extract(metadata, '$.routing_review.semantic.share') FROM contexts WHERE id = ?1",
                 [id]
               )

      assert method == "knn"
      assert share < 0.8
    end

    test "by nearest documents: a unanimous vote whose closest document is below min_similarity is not placed",
         ctx do
      id = filed!(ctx.tenant, ctx.intake, "knn-far-#{ctx.n}", [1.0, 0.05, 0.0, 1.0])

      enable(%{method: "knn", k: 3, share: 0.8, min_similarity: 0.9})
      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :unresolved, workspace_id: nil, proposed_workspace_id: nil} = result
      assert %{method: :knn, share: 1.0} = result.semantic
      assert result.semantic.workspace_id == ctx.alpha
      assert result.semantic.similarity < 0.9

      enable(%{method: "knn", k: 3, share: 0.8, min_similarity: 0.5})
      assert {:ok, preview} = CorpusOrganizer.preview()
      assert %{confidence: :high, workspace_id: workspace_id} = proposal(preview, id)
      assert workspace_id == ctx.alpha
    end

    test "agree: nearest documents and the centroid must name the same workspace", ctx do
      for i <- 1..3,
          do: filed!(ctx.tenant, ctx.beta, "beta-edge-#{ctx.n}-#{i}", [1.0, 0.0, 0.0, 0.35])

      edge = filed!(ctx.tenant, ctx.intake, "edge-#{ctx.n}", [1.0, 0.0, 0.0, 0.3])
      near_alpha = filed!(ctx.tenant, ctx.intake, "agree-alpha-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      enable(%{method: "knn", k: 3, share: 0.8})
      assert {:ok, preview} = CorpusOrganizer.preview()
      assert %{confidence: :high, workspace_id: workspace_id} = proposal(preview, edge)
      assert workspace_id == ctx.beta

      enable(%{method: "agree", k: 3, share: 0.8, margin: 0.04})
      assert {:ok, preview} = CorpusOrganizer.preview()

      result = proposal(preview, edge)
      assert %{confidence: :review, workspace_id: nil} = result
      assert %{method: :agree, share: 1.0} = result.semantic
      assert result.semantic.workspace_id == ctx.beta
      assert result.semantic.centroid_workspace_id == ctx.alpha

      result = proposal(preview, near_alpha)
      assert %{confidence: :high, method: :semantic} = result
      assert result.workspace_id == ctx.alpha
      assert %{method: :agree, share: 1.0, votes: 3} = result.semantic
      assert result.semantic.centroid_workspace_id == ctx.alpha
      assert result.semantic.centroid_similarity > 0.95
      assert result.semantic.margin >= 0.04

      assert {:ok, %{moved: 1}} = CorpusOrganizer.apply_high_confidence(preview: preview)

      assert {:ok, [[placement]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT json_extract(metadata, '$.routing_placement') FROM contexts WHERE id = ?1",
                 [near_alpha]
               )

      placement = Jason.decode!(placement)
      assert placement["semantic_method"] == "agree"
      assert placement["share"] == 1.0
      assert placement["margin"] >= 0.04
      assert placement["centroid_workspace_id"] == ctx.alpha
      assert placement["centroid_similarity"] > 0.95
      assert placement["similarity"] > 0.99
    end

    test "the daily population job places by meaning and reports it", ctx do
      enable()
      id = filed!(ctx.tenant, ctx.intake, "daily-#{ctx.n}", [1.0, 0.05, 0.0, 0.0])

      assert {:ok, result} =
               OptimalEngine.Analyses.run_now(ctx.tenant, ctx.intake, "workspace_population")

      assert result.report.status == "ok"
      assert result.report.report["moved_by_meaning"] == 1
      assert result.report.report["embedding"]["embedded"] == 0
      assert result.report.summary =~ "1 by meaning"

      assert {:ok, [[workspace]]} =
               OptimalEngine.Store.raw_query("SELECT workspace_id FROM contexts WHERE id = ?1", [id])

      assert workspace == ctx.alpha
    end

    test "a record without a vector keeps its marker result", ctx do
      enable()

      {:ok, _} =
        OptimalEngine.Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', 'No vector', 'Plain text.', datetime('now'))",
          ["novec-#{ctx.n}", ctx.tenant, ctx.intake]
        )

      assert {:ok, preview} = CorpusOrganizer.preview()
      assert %{confidence: :unresolved, semantic: nil} = proposal(preview, "novec-#{ctx.n}")
    end
  end

  defp enable(extra \\ %{}) do
    Application.put_env(
      :optimal_engine,
      :corpus_semantic_placement,
      Map.merge(%{enabled: true, min_examples: 3, margin: 0.04}, extra)
    )
  end

  defp proposal(preview, id) do
    Enum.find(preview.high_confidence ++ preview.review ++ preview.unresolved, &(&1.id == id))
  end

  defp filed!(tenant, workspace, id, vector, opts \\ []) do
    {:ok, _} =
      OptimalEngine.Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', ?4, 'Body.', datetime('now'))",
        [id, tenant, workspace, Keyword.get(opts, :title, "Document #{id}")]
      )

    :ok = OptimalEngine.Store.Vectors.store(id, vector)
    id
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_engine, key)
  defp restore(key, value), do: Application.put_env(:optimal_engine, key, value)
end
