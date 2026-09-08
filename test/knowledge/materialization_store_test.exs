defmodule OptimalEngine.Knowledge.MaterializationStoreTest do
  use ExUnit.Case, async: false
  alias OptimalEngine.Knowledge

  test "bridge materialization can run repeatedly without a stale named store" do
    assert {:ok, count} = OptimalEngine.Bridge.Knowledge.sync_and_materialize()
    assert is_integer(count)
    assert {:ok, _} = OptimalEngine.Bridge.Knowledge.sync_and_materialize()
  end

  test "reasoning executes in the owning store and persists inferred triples" do
    {:ok, store} = Knowledge.open("materialization-#{System.unique_integer([:positive])}")
    subclass = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
    :ok = Knowledge.assert_many(store, [{"urn:A", subclass, "urn:B"}, {"urn:B", subclass, "urn:C"}])
    assert {:ok, count} = Knowledge.Store.materialize(store)
    assert count >= 1
    assert {:ok, triples} = Knowledge.query(store, subject: "urn:A", object: "urn:C")
    assert {"urn:A", subclass, "urn:C"} in triples
    assert {:ok, 0} = Knowledge.Store.materialize(store)
    Knowledge.close(store)
  end
end
