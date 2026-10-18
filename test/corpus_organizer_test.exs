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
end
