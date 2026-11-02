defmodule OptimalEngine.Storage.ProvidersTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{Planner, Providers}

  test "provider ids are unique and credentials are never returned" do
    providers = Providers.list()
    ids = Enum.map(providers, & &1.id)

    assert length(ids) == length(Enum.uniq(ids))
    assert "postgres" in ids
    assert "s3" in ids
    assert "nats_jetstream" in ids
    assert "valkey" in ids
    assert "qdrant" in ids
    assert "duckdb" in ids
    assert "openbao" in ids
    assert "fractal" in ids

    encoded = Jason.encode!(providers)
    refute encoded =~ "secret_access_key"
    refute encoded =~ "token_value"
  end

  test "local workspace plan uses embedded providers" do
    assert {:ok, plan} = Planner.plan(["desktop_local"])

    ids = Enum.map(plan.providers, & &1.id)
    assert ids == ~w(sqlite fts5 embedded_vectors rocksdb filesystem ets)
    assert plan.ready
    assert plan.adapter_missing == []
    assert Enum.all?(plan.providers, & &1.adapter_implemented)

    for provider <- plan.providers, provider.id != "rocksdb" do
      assert provider.lifecycle_state == "active", provider.id
    end
  end

  describe "the RocksDB provider" do
    setup do
      knowledge = Application.get_env(:optimal_engine, :knowledge, [])
      on_exit(fn -> Application.put_env(:optimal_engine, :knowledge, knowledge) end)
      {:ok, knowledge: knowledge}
    end

    test "is active when the knowledge store runs on RocksDB", %{knowledge: knowledge} do
      Application.put_env(:optimal_engine, :knowledge, Keyword.put(knowledge, :backend, "rocksdb"))

      assert {:ok, rocksdb} = Providers.get("rocksdb")
      assert rocksdb.lifecycle_state == "active"
      assert rocksdb.health == "healthy"
    end

    test "is available, not active, when the knowledge store runs on ETS", %{
      knowledge: knowledge
    } do
      Application.put_env(:optimal_engine, :knowledge, Keyword.put(knowledge, :backend, "ets"))

      for opts <- [[], [probe: true]] do
        assert {:ok, rocksdb} = Providers.get("rocksdb", opts)
        assert rocksdb.lifecycle_state == "available"
        assert rocksdb.health == "healthy"
      end

      assert {:ok, plan} = Planner.plan(["desktop_local"])
      assert plan.ready
    end
  end

  test "a canonical store the build does not run on is never ready, however healthy" do
    refute Planner.ready?(%{id: "postgres", lifecycle_state: "available", selected: false})
    assert Planner.ready?(%{id: "postgres", lifecycle_state: "available", selected: true})
    assert Planner.ready?(%{id: "s3", lifecycle_state: "available"})
    refute Planner.ready?(%{id: "s3", lifecycle_state: "configured_unverified"})
  end

  @unimplemented ~w(qdrant duckdb openbao fractal)

  test "every provider declares whether an adapter is implemented" do
    for provider <- Providers.list() do
      assert is_boolean(provider.adapter_implemented), "#{provider.id} lacks adapter_implemented"
    end

    implemented = Providers.list() |> Enum.filter(& &1.adapter_implemented) |> Enum.map(& &1.id)

    assert Enum.sort(implemented) ==
             Enum.sort(
               ~w(sqlite fts5 embedded_vectors rocksdb filesystem ets s3 postgres valkey nats_jetstream)
             )
  end

  test "the canonical store providers say which one this build selected" do
    {:ok, sqlite} = Providers.get("sqlite")
    {:ok, postgres} = Providers.get("postgres")

    assert sqlite.selected == OptimalEngine.Store.selected?(OptimalEngine.Store.SQLite)
    assert postgres.selected == OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres)
    assert sqlite.selected != postgres.selected

    {:ok, s3} = Providers.get("s3")
    refute Map.has_key?(s3, :selected)
  end

  test "providers without an adapter report adapter_missing even when configured" do
    System.put_env("OPTIMAL_QDRANT_URL", "http://127.0.0.1:1")
    System.put_env("OPTIMAL_POSTGRES_URL", "postgres://user:pass@127.0.0.1:1/db")
    on_exit(fn -> System.delete_env("OPTIMAL_QDRANT_URL") end)
    on_exit(fn -> System.delete_env("OPTIMAL_POSTGRES_URL") end)

    for id <- @unimplemented do
      assert {:ok, provider} = Providers.get(id)
      refute provider.adapter_implemented
      assert provider.lifecycle_state == "adapter_missing"
    end

    assert {:ok, qdrant} = Providers.get("qdrant")
    assert qdrant.configured
  end

  test "a passing network probe never makes a missing adapter available" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    # An endpoint that answers every request 200, as a reachable partner would.
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      :gen_tcp.close(socket)
    end)

    System.put_env("OPTIMAL_FRACTAL_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_FRACTAL_CREDENTIAL_REF", "ref")

    on_exit(fn ->
      Enum.each(~w(OPTIMAL_FRACTAL_ENDPOINT OPTIMAL_FRACTAL_CREDENTIAL_REF), &System.delete_env/1)
    end)

    try do
      assert {:ok, provider} = Providers.get("fractal", probe: true)
      assert provider.health == "healthy"
      refute provider.adapter_implemented
      assert provider.lifecycle_state == "adapter_missing"
    after
      :gen_tcp.close(listener)
    end
  end

  test "plans flag providers whose adapters are missing and are never ready" do
    assert {:ok, plan} = Planner.plan(["cloud_team"])
    refute plan.ready

    assert Enum.sort(plan.adapter_missing) == Enum.sort(~w(openbao))

    # Every provider in this plan either has no adapter or is not configured;
    # none of them is ready to serve.
    for provider <- plan.providers do
      refute provider.lifecycle_state in ["active", "available"], provider.id
    end

    assert Enum.all?(
             plan.providers,
             &(&1.id in ["s3", "postgres", "valkey", "nats_jetstream"] or
                 &1.lifecycle_state == "adapter_missing")
           )
  end

  test "plans combine use cases without duplicate providers" do
    assert {:ok, plan} = Planner.plan(["cloud_team", "multi_device", "media_archive"])
    ids = Enum.map(plan.providers, & &1.id)

    assert length(ids) == length(Enum.uniq(ids))
    assert "postgres" in ids
    assert "s3" in ids
    assert "openbao" in ids
    assert "nats_jetstream" in ids
    assert "valkey" in ids
  end

  test "unknown use cases are rejected" do
    assert {:error, {:unknown_use_cases, ["made_up"]}} = Planner.plan(["made_up"])
  end
end
