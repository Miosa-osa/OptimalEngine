defmodule OptimalEngine.Storage.SharedTest do
  @moduledoc """
  The shared cache, counter, lock and rate-limit interface: on local ETS
  without Valkey, on Valkey through the supervised pool when it is configured,
  and back on ETS, without failing a call, while Valkey is down.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.API.RateLimiter
  alias OptimalEngine.Auth.KeyCache
  alias OptimalEngine.Connectors.RateLimit
  alias OptimalEngine.Storage.Shared
  alias OptimalEngine.Storage.Shared.Local
  alias OptimalEngine.Storage.Valkey
  alias OptimalEngine.Storage.Valkey.Pool
  alias OptimalEngine.Sync.GateCache
  alias OptimalEngine.TestSupport.ValkeyStub

  @ns :optimal_shared_test

  setup do
    Local.new_table(@ns)
    Local.clear(@ns)
    previous = System.get_env(Valkey.env_name())
    System.delete_env(Valkey.env_name())

    on_exit(fn ->
      if previous,
        do: System.put_env(Valkey.env_name(), previous),
        else: System.delete_env(Valkey.env_name())
    end)

    :ok
  end

  defp start_pool(stub, opts \\ []) do
    url = "redis://#{Keyword.get(opts, :userinfo, "")}127.0.0.1:#{stub.port}"
    start_supervised!({Pool, [url: url, size: 2, timeout: 200] ++ Keyword.drop(opts, [:userinfo])})
    wait_until(&Pool.serving?/0)
  end

  defp stub! do
    {:ok, stub} = ValkeyStub.start()
    on_exit(fn -> ValkeyStub.stop(stub) end)
    stub
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # A connection learns the server is gone on its next command.
  defp go_down(stub) do
    ValkeyStub.set_mode(stub, :down)
    wait_until(fn -> Shared.get(:optimal_shared_test, "probe") == :miss and not Pool.serving?() end)
  end

  defp generation(stub, ns) do
    case ValkeyStub.keys(stub)["optimal:shared:#{ns}:gen"] do
      nil -> 0
      gen -> String.to_integer(gen)
    end
  end

  defp shared_keys(stub),
    do:
      stub
      |> ValkeyStub.keys()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "optimal:shared:"))

  describe "without Valkey" do
    test "the pool does not start and everything runs locally" do
      assert Pool.start_link([]) == :ignore
      refute Pool.serving?()
      assert Shared.backend() == :local

      assert Shared.get(@ns, "a") == :miss
      assert :ok = Shared.put(@ns, "a", %{v: 1}, 1_000)
      assert {:ok, %{v: 1}} = Shared.get(@ns, "a")
      assert :ok = Shared.delete(@ns, "a")
      assert Shared.get(@ns, "a") == :miss
    end

    test "an invalid URL is not a pool, never a crash" do
      System.put_env(Valkey.env_name(), "http://127.0.0.1:1")
      assert Pool.start_link([]) == :ignore
    end

    test "entries expire, and a full table drops the expired ones first" do
      :ok = Shared.put(@ns, "short", 1, 1)
      :ok = Shared.put(@ns, "long", 2, 60_000)
      Process.sleep(5)
      assert Shared.get(@ns, "short") == :miss

      :ok = Shared.put(@ns, "third", 3, 60_000, max_entries: 2)
      assert {:ok, 2} = Shared.get(@ns, "long")
      assert {:ok, 3} = Shared.get(@ns, "third")

      :ok = Shared.put(@ns, "fourth", 4, 60_000, max_entries: 2)
      assert Shared.get(@ns, "long") == :miss
      assert {:ok, 4} = Shared.get(@ns, "fourth")
    end

    test "counters, leases and clear" do
      assert {:ok, 1} = Shared.incr(@ns, "c", 60_000)
      assert {:ok, 2} = Shared.incr(@ns, "c", 60_000)

      assert {:ok, token} = Shared.lock(@ns, "l", 60_000)
      assert {:error, :locked} = Shared.lock(@ns, "l", 60_000)
      :ok = Shared.unlock(@ns, "l", "not-the-token")
      assert {:error, :locked} = Shared.lock(@ns, "l", 60_000)
      :ok = Shared.unlock(@ns, "l", token)
      assert {:ok, _} = Shared.lock(@ns, "l", 60_000)

      assert {:ok, short} = Shared.lock(@ns, "lease", 1)
      Process.sleep(5)
      assert {:ok, other} = Shared.lock(@ns, "lease", 60_000)
      assert other != short

      :ok = Shared.clear(@ns)
      assert {:ok, 1} = Shared.incr(@ns, "c", 60_000)
    end

    test "a denied bucket step keeps or advances its stamp as asked" do
      for deny <- [:keep, :advance] do
        key = {:bucket, deny}
        assert :ok = Shared.take_token(@ns, key, 2, 1.0e-9, deny, 60_000)
        assert :ok = Shared.take_token(@ns, key, 2, 1.0e-9, deny, 60_000)
        assert {:limited, tokens, _elapsed} = Shared.take_token(@ns, key, 2, 1.0e-9, deny, 60_000)
        assert tokens < 1.0
      end

      # Two denied steps 20 ms apart: the kept stamp is still the last token's,
      # the advanced one is the first denial's.
      for _ <- 1..2 do
        Process.sleep(20)
        Shared.take_token(@ns, {:bucket, :advance}, 2, 1.0e-9, :advance, 60_000)
      end

      assert {:limited, _, kept} =
               Shared.take_token(@ns, {:bucket, :keep}, 2, 1.0e-9, :keep, 60_000)

      assert kept >= 40

      assert {:limited, _, advanced} =
               Shared.take_token(@ns, {:bucket, :advance}, 2, 1.0e-9, :advance, 60_000)

      assert advanced < 40
    end

    test "a missing table reads empty and ignores writes, but a bucket recreates its own" do
      table = :optimal_shared_test_missing
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)

      assert Shared.get(table, "k") == :miss
      assert :ok = Shared.put(table, "k", 1, 1_000)
      assert :ets.whereis(table) == :undefined
      assert :ok = Shared.take_token(table, "b", 1, 1.0, :keep, 1_000)
      assert :ets.whereis(table) != :undefined
    end
  end

  describe "on Valkey" do
    test "values are written to Valkey signed, read back, and a tampered value is a miss" do
      stub = stub!()
      start_pool(stub)
      assert Shared.backend() == :valkey

      :ok = Shared.put(@ns, "doc", %{"a" => [1, 2]}, 60_000)
      assert {:ok, %{"a" => [1, 2]}} = Shared.get(@ns, "doc")
      # Read from Valkey, not from the local table.
      assert Local.get(@ns, "doc") == :miss

      key = Shared.valkey_key(@ns, "doc")
      stored = ValkeyStub.keys(stub)[key]
      assert is_binary(stored)
      refute stored == :erlang.term_to_binary(%{"a" => [1, 2]})
      assert ValkeyStub.pttl(stub, key) in 1..60_000

      ValkeyStub.put_raw(stub, key, :erlang.term_to_binary(:forged))
      assert Shared.get(@ns, "doc") == :miss

      # A value signed for one key does not verify under another.
      :ok = Shared.put(@ns, "other", :mine, 60_000)
      ValkeyStub.put_raw(stub, key, ValkeyStub.keys(stub)[Shared.valkey_key(@ns, "other")])
      assert Shared.get(@ns, "doc") == :miss
    end

    test "scripts are loaded once with EVAL and run by EVALSHA after" do
      stub = stub!()
      start_pool(stub)

      for i <- 1..3, do: Shared.get(@ns, "k#{i}")
      names = stub |> ValkeyStub.commands() |> Enum.map(&hd/1)
      assert Enum.count(names, &(&1 == "EVAL")) == 1
      assert Enum.count(names, &(&1 == "EVALSHA")) == 3
    end

    test "clear moves the generation: one command, every key gone" do
      stub = stub!()
      start_pool(stub)

      for i <- 1..5, do: :ok = Shared.put(@ns, "k#{i}", i, 60_000)
      assert {:ok, 3} = Shared.get(@ns, "k3")
      :ok = Shared.clear(@ns)
      assert Shared.get(@ns, "k3") == :miss
      assert ValkeyStub.keys(stub)["optimal:shared:#{@ns}:gen"] == "1"
    end

    test "counters and leases are shared through Valkey" do
      stub = stub!()
      start_pool(stub)

      assert {:ok, 1} = Shared.incr(@ns, "c", 60_000)
      assert {:ok, 2} = Shared.incr(@ns, "c", 60_000)
      assert {:ok, token} = Shared.lock(@ns, "l", 60_000)
      assert {:error, :locked} = Shared.lock(@ns, "l", 60_000)
      # The local table knows nothing of the lease.
      assert {:ok, _} = Local.lock(@ns, "l", "x", 60_000)
      :ok = Shared.unlock(@ns, "l", token)
      assert {:ok, _} = Shared.lock(@ns, "l", 60_000)
    end

    test "Valkey down: calls answer locally within the timeout, and the pool reconnects" do
      stub = stub!()
      start_pool(stub)
      :ok = Shared.put(@ns, "k", :remote, 60_000)

      ValkeyStub.set_mode(stub, :down)
      wait_until(fn -> Shared.put(@ns, "probe", 1, 60_000) == :ok and not Pool.serving?() end)

      assert Shared.backend() == :local
      assert :ok = Shared.put(@ns, "k", :local, 60_000)
      assert {:ok, :local} = Shared.get(@ns, "k")
      # A bucket this node never saw opens empty during an outage; at 1 token/ms
      # it has one again a moment later.
      assert {:limited, +0.0, 0} = Shared.take_token(@ns, "b", 1, 1.0, :keep, 60_000)
      Process.sleep(5)
      assert :ok = Shared.take_token(@ns, "b", 1, 1.0, :keep, 60_000)

      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      assert {:ok, :remote} = Shared.get(@ns, "k")
    end

    test "a server that stops answering costs one timeout, then the calls run locally" do
      stub = stub!()
      start_pool(stub)
      ValkeyStub.set_mode(stub, :hang)

      {micros, result} = :timer.tc(fn -> Shared.put(@ns, "k", 1, 60_000) end)
      assert result == :ok
      assert micros < 1_000_000
      assert {:ok, 1} = Local.get(@ns, "k")

      # A reconnect to a server that accepts and never answers is not "up".
      wait_until(fn -> Shared.put(@ns, "k2", 2, 60_000) == :ok and not Pool.serving?() end)
      Process.sleep(400)
      refute Pool.serving?()
      {micros, :ok} = :timer.tc(fn -> Shared.put(@ns, "k3", 3, 60_000) end)
      assert micros < 50_000

      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0, 400)
    end

    test "a connection the server dropped while idle is reopened for the next command" do
      stub = stub!()
      start_pool(stub, size: 1)
      :ok = Shared.put(@ns, "k", 1, 60_000)

      ValkeyStub.disconnect_all(stub)
      Process.sleep(20)
      assert {:ok, 1} = Shared.get(@ns, "k")
      assert Local.get(@ns, "k") == :miss
    end

    test "a delete made while Valkey is down is applied before Valkey is read again" do
      stub = stub!()
      start_pool(stub)
      :ok = Shared.put(@ns, "revoked", :verified, 60_000)
      :ok = Shared.put(@ns, "cleared", :verified, 60_000)
      other_ns = :optimal_shared_test_other
      Local.new_table(other_ns)
      :ok = Shared.put(other_ns, "x", 1, 60_000)

      go_down(stub)
      :ok = Shared.delete(@ns, "revoked")
      :ok = Shared.clear(other_ns)
      assert Pool.stats().pending == 2

      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      assert Shared.get(@ns, "revoked") == :miss
      assert {:ok, :verified} = Shared.get(@ns, "cleared")
      assert Shared.get(other_ns, "x") == :miss
      assert Pool.stats().pending == 0
    end

    test "the URL's credential authenticates every connection and is never logged" do
      {:ok, stub} = ValkeyStub.start(password: "pool-s3cret")
      on_exit(fn -> ValkeyStub.stop(stub) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_pool(stub, userinfo: ":pool-s3cret@")
          :ok = Shared.put(@ns, "k", 1, 60_000)
          go_down(stub)
          Process.sleep(50)
        end)

      assert Enum.count(ValkeyStub.commands(stub), &match?(["AUTH", "pool-s3cret"], &1)) >= 2
      refute log =~ "pool-s3cret"
    end
  end

  describe "the Engine's shared state on Valkey" do
    setup do
      stub = stub!()
      start_pool(stub)
      RateLimiter.reset()
      RateLimit.reset()
      GateCache.clear()
      on_exit(fn -> Local.clear(:optimal_api_rate_limit_buckets) end)
      %{stub: stub}
    end

    test "the API rate limiter's bucket lives in Valkey, so every node draws on it", %{stub: stub} do
      for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:shared", 3, 1))

      # Another node has an empty local table: the bucket is still empty.
      Local.clear(:optimal_api_rate_limit_buckets)

      assert {:rate_limited, retry_after_ms, remaining: 0, reset_at: reset_at} =
               RateLimiter.check("key:shared", 3, 1)

      assert retry_after_ms > 0 and retry_after_ms <= 60_000
      assert reset_at > System.monotonic_time(:millisecond)

      assert Enum.any?(shared_keys(stub), &String.contains?(&1, "optimal_api_rate_limit_buckets"))
      # This node keeps only the last state Valkey answered, for an outage.
      assert [{"key:shared", {tokens, _at}, _expires}] =
               :ets.lookup(:optimal_api_rate_limit_buckets, "key:shared")

      assert tokens < 1.0
    end

    test "a Valkey outage continues from the last bucket Valkey answered, never a full one",
         %{stub: stub} do
      for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:blip", 3, 1))
      assert {:rate_limited, _, _} = RateLimiter.check("key:blip", 3, 1)

      go_down(stub)
      assert {:rate_limited, _, _} = RateLimiter.check("key:blip", 3, 1)

      # The connector limiter too.
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      for _ <- 1..3, do: :ok = RateLimit.check({:slack, "blip"}, 1, 3)
      go_down(stub)
      assert {:error, :rate_limited, _} = RateLimit.check({:slack, "blip"}, 1, 3)
    end

    test "a bucket this node never saw opens empty during an outage", %{stub: stub} do
      go_down(stub)
      assert {:rate_limited, retry_after_ms, _} = RateLimiter.check("key:unseen", 3, 1)
      assert retry_after_ms > 0
      assert {:error, :rate_limited, _} = RateLimit.check({:slack, "unseen"}, 1, 3)
    end

    test "when Valkey returns, the lower of the outage bucket and Valkey's wins", %{stub: stub} do
      # Valkey keeps 2 of 3; during the outage this node spends them locally.
      assert :ok = RateLimiter.check("key:back", 3, 1)
      go_down(stub)
      for _ <- 1..2, do: assert(:ok = RateLimiter.check("key:back", 3, 1))
      assert {:rate_limited, _, _} = RateLimiter.check("key:back", 3, 1)

      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      # Valkey alone still holds 2 tokens; the local spend counts.
      assert {:rate_limited, _, _} = RateLimiter.check("key:back", 3, 1)
      Local.clear(:optimal_api_rate_limit_buckets)
      assert {:rate_limited, _, _} = RateLimiter.check("key:back", 3, 1)

      # The other way round, Valkey's lower count is kept: another node spent it.
      for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:other", 3, 1))
      Local.clear(:optimal_api_rate_limit_buckets)
      assert {:rate_limited, _, _} = RateLimiter.check("key:other", 3, 1)
    end

    test "denied API checks on Valkey do not refill the bucket faster than its rate" do
      key = "key:hammer-#{System.unique_integer([:positive])}"
      assert :ok = RateLimiter.check(key, 1, 60)
      Process.sleep(600)
      assert {:rate_limited, _, remaining: 0, reset_at: _} = RateLimiter.check(key, 1, 60)
      Process.sleep(300)
      assert {:rate_limited, _, remaining: 0, reset_at: _} = RateLimiter.check(key, 1, 60)
      Process.sleep(200)
      assert :ok = RateLimiter.check(key, 1, 60)
    end

    test "the connector limiter's bucket lives in Valkey with the same answers" do
      for _ <- 1..3, do: :ok = RateLimit.check({:slack, "t1"}, 1, 3)
      Local.clear(:optimal_connector_ratelimit)
      assert {:error, :rate_limited, ms} = RateLimit.check({:slack, "t1"}, 1, 3)
      assert ms > 0 and ms <= 1_000
      assert {:error, :timeout} = RateLimit.wait({:slack, "t1"}, 1, 3, timeout: 50)
    end

    test "a verified key is shared, and revoking it removes it from Valkey", %{stub: stub} do
      :ok = KeyCache.remember("key-1", "secret", "$2b$hash")
      assert KeyCache.verified?("key-1", "secret", "$2b$hash")
      refute KeyCache.verified?("key-1", "secret-x", "$2b$hash")
      refute KeyCache.verified?("key-1", "secret", "$2b$other")

      key = Shared.valkey_key(:optimal_engine_key_cache, "key-1")
      stored = ValkeyStub.keys(stub)[key]
      refute stored =~ "secret"
      refute stored =~ "$2b$hash"

      :ok = KeyCache.forget("key-1")
      refute Map.has_key?(ValkeyStub.keys(stub), key)
      refute KeyCache.verified?("key-1", "secret", "$2b$hash")
    end

    test "a revoke while Valkey is down still invalidates the shared entry", %{stub: stub} do
      :ok = KeyCache.remember("key-2", "secret", "$2b$hash")
      go_down(stub)

      :ok = KeyCache.forget("key-2")
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)

      refute KeyCache.verified?("key-2", "secret", "$2b$hash")

      refute Map.has_key?(
               ValkeyStub.keys(stub),
               Shared.valkey_key(:optimal_engine_key_cache, "key-2")
             )
    end

    test "the gate cache keeps entries on Valkey, scoped to this store", %{stub: stub} do
      key = {:index, "tenant", "ws", :peer, 1}
      counter = :counters.new(1, [])
      build = fn -> :counters.add(counter, 1, 1) && %{built: :counters.get(counter, 1)} end

      assert %{built: 1} = GateCache.fetch(key, [["sync_capture", 1]], build)
      assert %{built: 1} = GateCache.fetch(key, [["sync_capture", 1]], build)
      assert %{built: 2} = GateCache.fetch(key, [["sync_capture", 2]], build)

      replica = OptimalEngine.Sync.replica_id()
      gen = generation(stub, :optimal_sync_gate_cache)

      assert Map.has_key?(
               ValkeyStub.keys(stub),
               Shared.valkey_key(:optimal_sync_gate_cache, {replica, key}, gen)
             )

      assert :ets.info(:optimal_sync_gate_cache, :size) == 0

      :ok = GateCache.clear()
      assert %{built: 3} = GateCache.fetch(key, [["sync_capture", 2]], build)
    end

    test "without a replica id the gate cache keeps its entries in local ETS", %{stub: stub} do
      previous = Application.fetch_env(:optimal_engine, :sync_gate_cache_replica_id)
      Application.put_env(:optimal_engine, :sync_gate_cache_replica_id, nil)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:optimal_engine, :sync_gate_cache_replica_id, value)
          :error -> Application.delete_env(:optimal_engine, :sync_gate_cache_replica_id)
        end
      end)

      key = {:index, "tenant", "ws-no-replica", :peer, 1}
      counter = :counters.new(1, [])
      build = fn -> :counters.add(counter, 1, 1) && %{built: :counters.get(counter, 1)} end

      assert %{built: 1} = GateCache.fetch(key, [["sync_capture", 1]], build)
      assert %{built: 1} = GateCache.fetch(key, [["sync_capture", 1]], build)
      assert %{built: 2} = GateCache.fetch(key, [["sync_capture", 2]], build)

      # Nothing went to Valkey: the stamp means nothing without the store's id.
      refute Enum.any?(shared_keys(stub), &String.contains?(&1, "optimal_sync_gate_cache:0:"))
      assert {:ok, {[["sync_capture", 2]], %{built: 2}}} = Local.get(:optimal_sync_gate_cache, key)

      :ok = GateCache.clear()
      assert %{built: 3} = GateCache.fetch(key, [["sync_capture", 2]], build)
    end
  end
end
