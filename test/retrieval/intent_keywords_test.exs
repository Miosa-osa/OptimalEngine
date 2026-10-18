defmodule OptimalEngine.Retrieval.IntentKeywordsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Retrieval.IntentAnalyzer

  setup do
    original = Application.get_env(:optimal_engine, :intent_node_keywords)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:optimal_engine, :intent_node_keywords),
        else: Application.put_env(:optimal_engine, :intent_node_keywords, original)
    end)
  end

  test "keywords match whole words only" do
    Application.put_env(:optimal_engine, :intent_node_keywords, %{"ed" => "operator"})

    assert IntentAnalyzer.detect_node_hints("we need the pricing deck") == ["operation-revenue"]
    assert "operator" in IntentAnalyzer.detect_node_hints("what did ed decide")
  end

  test "deployment keywords merge over the generic vocabulary" do
    Application.put_env(:optimal_engine, :intent_node_keywords, %{
      "Northwind" => "operation-delivery"
    })

    keywords = IntentAnalyzer.node_keywords()
    assert keywords["northwind"] == "operation-delivery"
    assert keywords["pricing"] == "operation-revenue"
    assert IntentAnalyzer.detect_node_hints("northwind kickoff") == ["operation-delivery"]
  end

  test "with no deployment keywords only the generic vocabulary applies" do
    Application.put_env(:optimal_engine, :intent_node_keywords, %{})
    assert IntentAnalyzer.detect_node_hints("northwind kickoff") == []
  end
end
