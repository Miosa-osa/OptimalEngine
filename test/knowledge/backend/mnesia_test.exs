defmodule OptimalEngine.Knowledge.Backend.MnesiaTest do
  use ExUnit.Case, async: false

  import OptimalEngine.AtomProbe

  alias OptimalEngine.Knowledge.Backend.Mnesia

  setup do
    store_id = "mnesia_test_#{:erlang.unique_integer([:positive])}"
    {:ok, state} = Mnesia.init(store_id, copies: :ram_copies)
    on_exit(fn -> Mnesia.terminate(state) end)
    %{state: state}
  end

  test "assert and query round-trip", %{state: state} do
    {:ok, state} = Mnesia.assert(state, "alice", "knows", "bob")
    {:ok, results} = Mnesia.query(state, subject: "alice")
    assert {"alice", "knows", "bob"} in results
  end

  test "assert_many batch insert", %{state: state} do
    triples = [
      {"alice", "knows", "bob"},
      {"alice", "knows", "carol"},
      {"bob", "role", "user"}
    ]

    {:ok, _state} = Mnesia.assert_many(state, triples)
    {:ok, count} = Mnesia.count(state)
    assert count == 3
  end

  test "retract removes triple", %{state: state} do
    {:ok, state} = Mnesia.assert(state, "alice", "knows", "bob")
    {:ok, state} = Mnesia.retract(state, "alice", "knows", "bob")
    {:ok, count} = Mnesia.count(state)
    assert count == 0
  end

  describe "query patterns" do
    setup %{state: state} do
      triples = [
        {"alice", "knows", "bob"},
        {"alice", "knows", "carol"},
        {"alice", "role", "admin"},
        {"bob", "knows", "carol"},
        {"bob", "role", "user"},
        {"carol", "knows", "alice"}
      ]

      {:ok, state} = Mnesia.assert_many(state, triples)
      %{state: state}
    end

    test "subject only", %{state: state} do
      {:ok, results} = Mnesia.query(state, subject: "alice")
      assert length(results) == 3
    end

    test "predicate only", %{state: state} do
      {:ok, results} = Mnesia.query(state, predicate: "knows")
      assert length(results) == 4
    end

    test "object only", %{state: state} do
      {:ok, results} = Mnesia.query(state, object: "carol")
      assert length(results) == 2
    end

    test "subject + predicate", %{state: state} do
      {:ok, results} = Mnesia.query(state, subject: "alice", predicate: "knows")
      assert length(results) == 2
    end

    test "predicate + object", %{state: state} do
      {:ok, results} = Mnesia.query(state, predicate: "knows", object: "carol")
      assert length(results) == 2
    end

    test "subject + object", %{state: state} do
      {:ok, results} = Mnesia.query(state, subject: "alice", object: "carol")
      assert length(results) == 1
    end

    test "exact match", %{state: state} do
      {:ok, results} = Mnesia.query(state, subject: "alice", predicate: "knows", object: "bob")
      assert results == [{"alice", "knows", "bob"}]
    end

    test "wildcard returns all", %{state: state} do
      {:ok, results} = Mnesia.query(state, [])
      assert length(results) == 6
    end

    test "no match returns empty", %{state: state} do
      {:ok, results} = Mnesia.query(state, subject: "nobody")
      assert results == []
    end
  end

  test "sparql returns not supported", %{state: state} do
    assert {:error, :sparql_not_supported} = Mnesia.sparql(state, "SELECT ?s WHERE { ?s ?p ?o }")
  end

  describe "store ids" do
    test "an id that is not short plain lowercase text is refused and makes no atom" do
      bad = never_seen("zz_store") <> "-Upper"

      assert {:error, :invalid_store_id} = Mnesia.init(bad, [])
      refute_atom("mk_#{bad}_spo")

      for id <- ["", "Upper", "1abc", "has space", "a-b", String.duplicate("a", 33), nil, 12] do
        assert {:error, :invalid_store_id} = Mnesia.init(id, []), inspect(id)
      end
    end

    test "an id of 32 characters is accepted" do
      id = "a" <> String.duplicate("b", 31)

      assert {:ok, state} = Mnesia.init(id, copies: :ram_copies)
      on_exit(fn -> Mnesia.terminate(state) end)
    end

    test "a new id is refused once the node has opened as many as the cap allows", %{
      state: state
    } do
      original = Application.get_env(:optimal_engine, :mnesia_max_stores)
      Application.put_env(:optimal_engine, :mnesia_max_stores, 0)

      on_exit(fn ->
        if original,
          do: Application.put_env(:optimal_engine, :mnesia_max_stores, original),
          else: Application.delete_env(:optimal_engine, :mnesia_max_stores)
      end)

      id = never_seen("zz_store")

      assert {:error, :too_many_stores} = Mnesia.init(id, [])
      refute_atom("mk_#{id}_spo")

      # An id the node already opened can be opened again.
      assert {:ok, _state} = Mnesia.init(state.store_id, [])
    end
  end
end
