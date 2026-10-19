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

    test "a marker proposal for another workspace blocks placement by meaning", ctx do
      enable()

      Application.put_env(:optimal_engine, :corpus_routing_rules, %{
        ctx.beta => [{"beta launch", 5}]
      })

      id =
        filed!(ctx.tenant, ctx.intake, "marked-#{ctx.n}", [1.0, 0.05, 0.0, 0.0],
          title: "Beta launch notes"
        )

      assert {:ok, preview} = CorpusOrganizer.preview()
      result = proposal(preview, id)
      assert %{confidence: :review, workspace_id: nil} = result
      assert result.proposed_workspace_id == ctx.beta
      assert result.semantic.workspace_id == ctx.alpha
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
