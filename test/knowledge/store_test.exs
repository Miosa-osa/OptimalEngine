defmodule OptimalEngine.Knowledge.StoreTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Knowledge.Store

  setup do
    store_id = "test_store_#{:erlang.unique_integer([:positive])}"

    pid = start_supervised!({Store, store_id: store_id, name: :"store_#{store_id}"})

    %{store: pid}
  end

  test "assert and query round-trip", %{store: store} do
    :ok = Store.assert(store, "alice", "knows", "bob")
    {:ok, results} = Store.query(store, subject: "alice")
    assert {"alice", "knows", "bob"} in results
  end

  test "assert_many inserts batch", %{store: store} do
    triples = [
      {"a", "p1", "x"},
      {"b", "p2", "y"},
      {"c", "p3", "z"}
    ]

    :ok = Store.assert_many(store, triples)
    {:ok, count} = Store.count(store)
    assert count == 3
  end

  test "retract removes triple", %{store: store} do
    :ok = Store.assert(store, "alice", "knows", "bob")
    :ok = Store.retract(store, "alice", "knows", "bob")
    {:ok, count} = Store.count(store)
    assert count == 0
  end

  test "sparql falls back to the built-in engine for the ETS backend", %{store: store} do
    :ok = Store.assert(store, "alice", "knows", "bob")
    :ok = Store.assert(store, "bob", "knows", "carol")

    assert {:ok, [%{"o" => "bob"}]} = Store.sparql(store, "SELECT ?o WHERE { <alice> <knows> ?o }")

    assert {:ok, [%{"c" => "carol"}]} =
             Store.sparql(store, "SELECT ?c WHERE { <alice> <knows> ?b . ?b <knows> ?c }")

    assert {:error, _} = Store.sparql(store, "NOT SPARQL AT ALL")
  end

  test "count returns number of triples", %{store: store} do
    {:ok, count} = Store.count(store)
    assert count == 0

    :ok = Store.assert(store, "a", "b", "c")
    {:ok, count} = Store.count(store)
    assert count == 1
  end
end
