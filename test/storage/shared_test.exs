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
    case ValkeyStub.keys(stub)["#{Shared.key_prefix()}:#{ns}:gen"] do
      nil -> 0
      gen -> String.to_integer(gen)
    end
  end

  defp shared_keys(stub),
    do:
      stub
      |> ValkeyStub.keys()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, Shared.key_prefix() <> ":"))

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
      assert ValkeyStub.keys(stub)["#{Shared.key_prefix()}:#{@ns}:gen"] == "1"
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

    test "an Engine with no prefix defers no invalidation it could never apply" do
      stub = stub!()
      start_pool(stub)
      Shared.reset_key_prefix()

      ExUnit.CaptureLog.capture_log(fn ->
        Shared.key_prefix(
          query: fn _sql, _params -> {:ok, []} end,
          store: OptimalEngine.Store.SQLite
        )
      end)

      for n <- 1..50, do: :ok = Shared.delete(@ns, "revoked-#{n}")
      :ok = Shared.clear(@ns)
      assert Pool.stats().pending == 0
    after
      Shared.reset_key_prefix()
    end

    test "deferred invalidations are coalesced and bounded" do
      stub = stub!()
      start_pool(stub)
      previous = Application.fetch_env(:optimal_engine, :valkey_pending_max)
      Application.put_env(:optimal_engine, :valkey_pending_max, 5)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:optimal_engine, :valkey_pending_max, value)
          :error -> Application.delete_env(:optimal_engine, :valkey_pending_max)
        end
      end)

      :ok = Shared.put(:optimal_shared_test_b, "k-1", :v, 60_000)
      go_down(stub)
      for _ <- 1..3, do: :ok = Shared.delete(@ns, "same")
      assert Pool.stats().pending == 1

      # A clear covers every earlier invalidation of its namespace.
      :ok = Shared.delete(@ns, "other")
      :ok = Shared.clear(@ns)
      assert Pool.stats().pending == 1

      # Past the bound the queue collapses to one clear per namespace.
      for n <- 1..20, do: :ok = Shared.delete(:optimal_shared_test_b, "k-#{n}")
      assert Pool.stats().pending <= 5

      # Nothing deleted during the outage is read back afterwards.
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      assert Shared.get(:optimal_shared_test_b, "k-1") == :miss
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

  describe "the key prefix" do
    setup do
      previous =
        Map.new(
          ~w(OPTIMAL_VALKEY_KEY_PREFIX OPTIMAL_POSTGRES_URL OPTIMAL_POSTGRES_SCHEMA OPTIMAL_ENGINE_ID),
          &{&1, System.get_env(&1)}
        )

      Enum.each(Map.keys(previous), &System.delete_env/1)
      Shared.reset_key_prefix()

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)

        Shared.reset_key_prefix()
      end)

      :ok
    end

    defp digest(identity),
      do:
        :crypto.hash(:sha256, "optimal-engine valkey prefix:" <> identity)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

    # Resolves the prefix as the data path does, with the replica id query
    # answering `answer` ({:ok, rows} or {:error, reason}) on `store`.
    defp prefix_with(answer, store \\ OptimalEngine.Store.SQLite, opts \\ []) do
      Shared.key_prefix([query: fn _sql, _params -> answer end, store: store] ++ opts)
    end

    test "OPTIMAL_ENGINE_ID names the Engine ahead of the replica id" do
      System.put_env("OPTIMAL_ENGINE_ID", "db_prod_1")
      prod = Shared.key_prefix()
      assert prod == "optimal:shared:" <> digest("engine:db_prod_1")

      # A staging copy restored from prod's dump has prod's replica id, but its
      # own Engine id, so it never draws on prod's buckets.
      System.put_env("OPTIMAL_ENGINE_ID", "db_staging_7")
      Shared.reset_key_prefix()
      refute Shared.key_prefix() == prod
    end

    test "a stale OPTIMAL_POSTGRES_URL on a SQLite Engine is never its identity" do
      System.put_env("OPTIMAL_POSTGRES_URL", "postgres://engine:pw@db.example:5432/eng_a")
      none = fn _sql, _params -> {:ok, []} end

      assert Shared.resolve_prefix(store: OptimalEngine.Store.SQLite, query: none) ==
               :unidentified

      assert {:ok, _} = Shared.resolve_prefix(store: OptimalEngine.Store.Postgres, query: none)
    end

    test "a replica id read that keeps failing is warned about and stops holding buckets closed" do
      stub = stub!()
      start_pool(stub)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..25, do: assert(prefix_with({:error, :busy}) == nil)
          # Past 20 failures the data path waits instead of reading the store.
          assert Shared.key_prefix() == nil
          # Valkey is up, but this Engine shares nothing on it: a local bucket, not an outage.
          assert :ok = Shared.take_token(@ns, "never-named", 2, 1.0e-9, :keep, 60_000)
        end)

      assert length(String.split(log, "could not read its replica id")) == 2
      assert log =~ "OPTIMAL_VALKEY_KEY_PREFIX"
    end

    test "a store without a sync_identity table has no replica id, from SQLite's own error" do
      dir = Path.join(System.tmp_dir!(), "no-identity-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, db} = Exqlite.Sqlite3.open(Path.join(dir, "empty.db"))
      on_exit(fn -> Exqlite.Sqlite3.close(db) end)

      query = fn sql, _params ->
        case Exqlite.Sqlite3.prepare(db, sql) do
          {:ok, stmt} -> Exqlite.Sqlite3.fetch_all(db, stmt)
          {:error, reason} -> {:error, reason}
        end
      end

      assert {:error, _no_such_table} =
               query.("SELECT replica_id FROM sync_identity WHERE id = 1", [])

      assert Shared.replica_identity(query) == :none
    end

    test "defaults to optimal:shared:<hash of the replica id>, the same every time" do
      expected = "optimal:shared:" <> digest(OptimalEngine.Sync.replica_id())

      assert Shared.key_prefix() == expected
      Shared.reset_key_prefix()
      assert Shared.key_prefix() == expected
      # Inside optimal:shared:*, so a Valkey ACL written for the old keys still covers it.
      assert String.starts_with?(Shared.valkey_key(@ns, "k"), expected <> ":#{@ns}:")
    end

    test "a replica id that cannot be read is not pinned, and Valkey waits for it" do
      stub = stub!()
      start_pool(stub)
      parent = self()

      busy = fn _sql, _params ->
        send(parent, :read)
        {:error, :busy}
      end

      # Read again on the next call, never kept from the failure.
      assert Shared.key_prefix(query: busy) == nil
      assert_received :read
      assert Shared.key_prefix(query: busy) == nil
      assert_received :read

      # No prefix to share yet: the call runs on local ETS and writes nothing.
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..20, do: Shared.key_prefix(query: busy)
      end)

      :ok = Shared.put(@ns, "doc", :v, 60_000)
      assert {:ok, :v} = Shared.get(@ns, "doc")
      assert ValkeyStub.keys(stub) |> Map.keys() |> Enum.filter(&(&1 =~ "#{@ns}")) == []

      assert prefix_with({:ok, [["replica-xyz"]]}) == "optimal:shared:" <> digest("replica-xyz")

      # Once read, it is kept even if a later read would fail.
      assert prefix_with({:error, :busy}) == "optimal:shared:" <> digest("replica-xyz")
    end

    test "on the PostgreSQL store without a replica id, its URL names the Engine, never its credentials" do
      none = fn _sql, _params -> {:ok, []} end
      on_pg = fn -> Shared.resolve_prefix(store: OptimalEngine.Store.Postgres, query: none) end

      System.put_env(
        "OPTIMAL_POSTGRES_URL",
        "postgres://engine:s3cret@db.example:5432/eng_a?sslmode=require"
      )

      assert {:ok, "optimal:shared:" <> _ = a} = on_pg.()
      refute a =~ "s3cret"

      System.put_env("OPTIMAL_POSTGRES_URL", "postgres://other:rotated@db.example:5432/eng_a")
      assert on_pg.() == {:ok, a}

      System.put_env("OPTIMAL_POSTGRES_URL", "postgres://engine:s3cret@db.example:5432/eng_b")
      refute on_pg.() == {:ok, a}

      System.put_env("OPTIMAL_POSTGRES_SCHEMA", "tenant_b")
      System.put_env("OPTIMAL_POSTGRES_URL", "postgres://engine:s3cret@db.example:5432/eng_a")
      refute on_pg.() == {:ok, a}
    end

    @tag :postgres
    test "a PostgreSQL store without a sync_identity table has no replica id, from PostgreSQL's own error" do
      alias OptimalEngine.Test.PostgresStore
      schema = PostgresStore.unique_schema("oe_valkey_id")
      on_exit(fn -> PostgresStore.drop_schema(schema) end)
      pool = PostgresStore.start_pool(schema)

      query = fn sql, params ->
        case OptimalEngine.Store.Postgres.Connection.query(pool, sql, params) do
          {:ok, %{rows: rows}} -> {:ok, rows}
          {:error, reason} -> {:error, reason}
        end
      end

      assert {:error, _undefined_table} =
               query.("SELECT replica_id FROM sync_identity WHERE id = 1", [])

      assert Shared.replica_identity(query) == :none

      System.put_env("OPTIMAL_POSTGRES_URL", PostgresStore.url())
      System.put_env("OPTIMAL_POSTGRES_SCHEMA", schema)

      assert {:ok, "optimal:shared:" <> _} =
               Shared.resolve_prefix(store: OptimalEngine.Store.Postgres, query: query)
    end

    test "with nothing to name the Engine, it warns and keeps Valkey out of it" do
      stub = stub!()
      start_pool(stub)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert prefix_with({:ok, []}) == nil
          assert :ok = Shared.take_token(@ns, "bucket", 2, 1.0e-9, :keep, 60_000)
        end)

      assert log =~ "OPTIMAL_VALKEY_KEY_PREFIX"
      assert ValkeyStub.keys(stub) |> Map.keys() |> Enum.filter(&(&1 =~ "#{@ns}")) == []
    end

    test "an Engine with nothing to name it is not looked up again on every call" do
      parent = self()

      none = fn _sql, _params ->
        send(parent, :read)
        {:ok, []}
      end

      ExUnit.CaptureLog.capture_log(fn ->
        assert Shared.key_prefix(query: none, store: OptimalEngine.Store.SQLite) == nil
        assert Shared.key_prefix(query: none, store: OptimalEngine.Store.SQLite) == nil
        # The data path too: it answers from the cached outcome.
        assert Shared.key_prefix() == nil
      end)

      assert_received :read
      refute_received :read
    end

    test "with no prefix there is no Valkey key either" do
      ExUnit.CaptureLog.capture_log(fn -> assert prefix_with({:ok, []}) == nil end)
      assert Shared.valkey_key(@ns, "k") == {:error, :no_key_prefix}
    end

    test "a PostgreSQL Engine named by its URL moves to its replica id once the table exists" do
      System.put_env("OPTIMAL_POSTGRES_URL", "postgres://engine:pw@db.example:5432/eng_a")
      pg = OptimalEngine.Store.Postgres

      # Booted before sync_identity existed: named by its URL, rechecked later.
      by_url = prefix_with({:ok, []}, pg, recheck_ms: 0)
      assert "optimal:shared:" <> _ = by_url

      # Once the replica id can be read, every node ends on the same prefix.
      assert prefix_with({:ok, [["replica-pg"]]}, pg) == "optimal:shared:" <> digest("replica-pg")

      # Rechecked on a slow timer, not on every call.
      Shared.reset_key_prefix()
      assert prefix_with({:ok, []}, pg) == by_url
      assert prefix_with({:ok, [["replica-pg"]]}, pg) == by_url
    end

    test "OPTIMAL_VALKEY_KEY_PREFIX=optimal, the layout before the prefix, is refused" do
      for value <- ["optimal", "optimal:shared:x"] do
        System.put_env("OPTIMAL_VALKEY_KEY_PREFIX", value)
        Shared.reset_key_prefix()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert "optimal:shared:" <> hash = Shared.key_prefix()
            refute hash == "" or String.starts_with?(hash, "x") or hash =~ ":shared"
          end)

        assert log =~ "OPTIMAL_VALKEY_KEY_PREFIX"
      end
    end

    test "OPTIMAL_VALKEY_KEY_PREFIX sets it, and Engines with different prefixes never collide" do
      stub = stub!()
      start_pool(stub)

      System.put_env("OPTIMAL_VALKEY_KEY_PREFIX", "engine-a")
      Shared.reset_key_prefix()
      assert Shared.key_prefix() == "engine-a:shared"
      :ok = Shared.put(@ns, "doc", :from_a, 60_000)
      for _ <- 1..2, do: assert(:ok = Shared.take_token(@ns, "bucket", 2, 1.0e-9, :keep, 60_000))
      assert {:limited, _, _} = Shared.take_token(@ns, "bucket", 2, 1.0e-9, :keep, 60_000)
      assert Enum.all?(shared_keys(stub), &String.starts_with?(&1, "engine-a:shared:"))

      # Engine B on the same Valkey, a node of its own.
      System.put_env("OPTIMAL_VALKEY_KEY_PREFIX", "engine-b")
      Shared.reset_key_prefix()
      Local.clear(@ns)
      assert Shared.get(@ns, "doc") == :miss
      assert :ok = Shared.take_token(@ns, "bucket", 2, 1.0e-9, :keep, 60_000)
      :ok = Shared.clear(@ns)

      System.put_env("OPTIMAL_VALKEY_KEY_PREFIX", "engine-a")
      Shared.reset_key_prefix()
      assert {:ok, :from_a} = Shared.get(@ns, "doc")
    end

    test "an invalid prefix is refused with a warning, and the default is used" do
      System.put_env("OPTIMAL_VALKEY_KEY_PREFIX", "has space{}")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert "optimal:shared:" <> _ = Shared.key_prefix()
        end)

      assert log =~ "OPTIMAL_VALKEY_KEY_PREFIX"
    end
  end

  describe "the bucket mirror" do
    setup do
      previous = Application.fetch_env(:optimal_engine, :shared_bucket_max_entries)
      Application.put_env(:optimal_engine, :shared_bucket_max_entries, 10)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:optimal_engine, :shared_bucket_max_entries, value)
          :error -> Application.delete_env(:optimal_engine, :shared_bucket_max_entries)
        end
      end)
    end

    test "every Valkey answer is mirrored, but the table never grows past its bound" do
      for n <- 1..50, do: :ok = Local.mirror_bucket(@ns, "client-#{n}", 3.0, 60_000)
      assert :ets.info(@ns, :size) <= 10
    end

    test "a flood of new keys evicts the oldest mirrors in a batch, never all of them" do
      # Later rows expire later: client-10 is the newest.
      for n <- 1..10, do: :ok = Local.mirror_bucket(@ns, "client-#{n}", 3.0, 60_000 + n * 1_000)
      :ok = Local.mirror_bucket(@ns, "client-11", 3.0, 80_000)

      size = :ets.info(@ns, :size)
      assert size <= 10 and size >= 5
      assert :ets.member(@ns, "client-11")
      assert :ets.member(@ns, "client-10")
      refute :ets.member(@ns, "client-1")
    end

    test "eviction drops the fullest buckets first, never an exhausted one" do
      # The exhausted buckets were written first, so they expire first.
      for n <- 1..5, do: :ok = Local.mirror_bucket(@ns, "spent-#{n}", 0.0, 60_000 + n)
      for n <- 1..5, do: :ok = Local.mirror_bucket(@ns, "idle-#{n}", 3.0, 90_000 + n)
      :ok = Local.mirror_bucket(@ns, "new", 3.0, 120_000)

      for n <- 1..5, do: assert(:ets.member(@ns, "spent-#{n}"))
      assert :ets.member(@ns, "new")
    end

    test "what a node spent during an outage is claimed by one step only, and given back on failure" do
      opts = [missing: :empty, mark: :fallback]
      :ok = Local.mirror_bucket(@ns, "hot", 3.0, 60_000)
      assert :ok = Local.take_token(@ns, "hot", 3, 1.0e-9, :keep, 60_000, opts)
      assert :ok = Local.take_token(@ns, "hot", 3, 1.0e-9, :keep, 60_000, opts)

      assert Local.claim_fallback_spent(@ns, "hot") == 2
      # A second step in flight at the same time charges nothing more.
      assert Local.claim_fallback_spent(@ns, "hot") == nil

      # The step that claimed it could not reach Valkey: it is owed again.
      :ok = Local.restore_fallback_spent(@ns, "hot", 2)
      assert Local.fallback_spent(@ns, "hot") == 2
      assert Local.claim_fallback_spent(@ns, "hot") == 2
    end

    test "the local bucket table is bounded the same way" do
      for n <- 1..50,
          do: Local.take_token(@ns, "local-#{n}", 3, 1.0e-6, :keep, 60_000 + n)

      assert :ets.info(@ns, :size) <= 10
      assert :ets.member(@ns, "local-50")
    end
  end

  describe "the signing key" do
    defmodule FakeSecrets do
      @moduledoc false
      def fetch("CONNECTOR_KEY") do
        case System.get_env("CONNECTOR_KEY") do
          "openbao:" <> _ref ->
            case :persistent_term.get({__MODULE__, :answer}) do
              fun when is_function(fun, 0) -> fun.()
              answer -> answer
            end

          nil ->
            {:error, :not_set}

          value ->
            {:ok, value}
        end
      end
    end

    setup do
      previous_key = System.get_env("CONNECTOR_KEY")
      previous_resolver = Application.fetch_env(:optimal_engine, :secrets_resolver)
      Application.put_env(:optimal_engine, :secrets_resolver, FakeSecrets)
      Shared.reset_signing_key()

      on_exit(fn ->
        if previous_key,
          do: System.put_env("CONNECTOR_KEY", previous_key),
          else: System.delete_env("CONNECTOR_KEY")

        case previous_resolver do
          {:ok, value} -> Application.put_env(:optimal_engine, :secrets_resolver, value)
          :error -> Application.delete_env(:optimal_engine, :secrets_resolver)
        end

        Shared.reset_signing_key()
      end)

      stub = stub!()
      start_pool(stub)
      :ok
    end

    # Two processes on one Valkey: the second has a signing key of its own
    # making, from the same configuration.
    defp shared_between_nodes? do
      :ok = Shared.put(@ns, "signed", :value, 60_000)
      Shared.reset_signing_key()
      Shared.get(@ns, "signed") == {:ok, :value}
    end

    test "a CONNECTOR_KEY that is an OpenBao reference is resolved, not used raw" do
      hex = Base.encode16(:crypto.strong_rand_bytes(32))
      :persistent_term.put({FakeSecrets, :answer}, {:ok, hex})
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")
      assert shared_between_nodes?()

      # The same key given plainly signs the same way.
      System.put_env("CONNECTOR_KEY", hex)
      Shared.reset_signing_key()
      assert {:ok, :value} = Shared.get(@ns, "signed")
    end

    test "a reference that cannot be read signs with a key of this node's own, and says so" do
      :persistent_term.put(
        {FakeSecrets, :answer},
        {:error, {:secret_unavailable, "CONNECTOR_KEY", :openbao_sealed}}
      )

      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")

      log = ExUnit.CaptureLog.capture_log(fn -> refute shared_between_nodes?() end)
      assert log =~ "CONNECTOR_KEY"
      refute log =~ "optimal/engine#connector_key"
    end

    test "one process derives the key while the others wait for it" do
      parent = self()

      :persistent_term.put({FakeSecrets, :answer}, fn ->
        send(parent, :resolved)
        Process.sleep(50)
        {:error, {:secret_unavailable, "CONNECTOR_KEY", :openbao_sealed}}
      end)

      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")

      ExUnit.CaptureLog.capture_log(fn ->
        1..10
        |> Enum.map(fn n -> Task.async(fn -> Shared.put(@ns, "c-#{n}", n, 60_000) end) end)
        |> Enum.each(&Task.await/1)
      end)

      assert_received :resolved
      refute_received :resolved
      # Every caller signed with the one key: each reads the others' entries.
      for n <- 1..10, do: assert(Shared.get(@ns, "c-#{n}") == {:ok, n})
    end

    test "a resolver that raises or exits never fails the caller" do
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")

      for answer <- [fn -> raise "boom" end, fn -> exit(:timeout) end] do
        :persistent_term.put({FakeSecrets, :answer}, answer)
        Shared.reset_signing_key()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert :ok = Shared.put(@ns, "doc", :v, 60_000)
            assert {:ok, :v} = Shared.get(@ns, "doc")
          end)

        assert log =~ "CONNECTOR_KEY"
      end
    end

    test "a resolved CONNECTOR_KEY is trimmed, and a malformed one is logged by name only" do
      hex = Base.encode16(:crypto.strong_rand_bytes(32))
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")
      :persistent_term.put({FakeSecrets, :answer}, {:ok, "  " <> hex <> "\n"})
      assert shared_between_nodes?()

      :persistent_term.put({FakeSecrets, :answer}, {:ok, "not-a-key-value-123"})
      Shared.reset_signing_key()

      log = ExUnit.CaptureLog.capture_log(fn -> refute shared_between_nodes?() end)
      assert log =~ "CONNECTOR_KEY"
      refute log =~ "not-a-key-value-123"
    end

    test "without a resolver a reference is never taken for the key" do
      Application.put_env(:optimal_engine, :secrets_resolver, :no_such_resolver)
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")

      log = ExUnit.CaptureLog.capture_log(fn -> refute shared_between_nodes?() end)
      assert log =~ "CONNECTOR_KEY"
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

    test "after an outage Valkey is charged what this node spent, never set to its count",
         %{stub: stub} do
      # A client this node never saw: denied during the outage, so it spent
      # nothing, and the cluster's bucket must still be full when Valkey is back.
      go_down(stub)
      assert {:rate_limited, _, _} = RateLimiter.check("key:fresh", 3, 1)
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:fresh", 3, 1))
      assert {:rate_limited, _, _} = RateLimiter.check("key:fresh", 3, 1)

      # A mirrored bucket of 2: one token spent locally is one token less on Valkey.
      assert :ok = RateLimiter.check("key:spent", 3, 1)
      go_down(stub)
      assert :ok = RateLimiter.check("key:spent", 3, 1)
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)
      assert :ok = RateLimiter.check("key:spent", 3, 1)
      assert {:rate_limited, _, _} = RateLimiter.check("key:spent", 3, 1)
    end

    test "OPTIMAL_VALKEY_OUTAGE_POLICY=open gives an unseen client a normal local bucket", %{
      stub: stub
    } do
      previous = System.get_env("OPTIMAL_VALKEY_OUTAGE_POLICY")
      System.put_env("OPTIMAL_VALKEY_OUTAGE_POLICY", "open")

      on_exit(fn ->
        if previous,
          do: System.put_env("OPTIMAL_VALKEY_OUTAGE_POLICY", previous),
          else: System.delete_env("OPTIMAL_VALKEY_OUTAGE_POLICY")
      end)

      go_down(stub)
      for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:open", 3, 1))
      assert {:rate_limited, _, _} = RateLimiter.check("key:open", 3, 1)

      # Closed, the default: an unseen client waits for its bucket to refill.
      System.put_env("OPTIMAL_VALKEY_OUTAGE_POLICY", "closed")
      assert {:rate_limited, _, _} = RateLimiter.check("key:closed", 3, 1)
    end

    test "a command Valkey refuses is not an outage: buckets stay node-local, and it is logged once",
         %{stub: stub} do
      ValkeyStub.fail_when(stub, fn
        [cmd | _] when cmd in ["EVAL", "EVALSHA"] -> "NOPERM this user has no permissions"
        _ -> nil
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # A new client gets a normal bucket, never the outage's closed one.
          for _ <- 1..3, do: assert(:ok = RateLimiter.check("key:acl", 3, 1))
          assert {:rate_limited, _, _} = RateLimiter.check("key:acl", 3, 1)
          assert :ok = RateLimiter.check("key:acl-other", 3, 1)
        end)

      assert Pool.serving?()
      assert length(String.split(log, "NOPERM")) == 2
    end

    test "steps in flight after an outage charge Valkey what was spent once, not once each",
         %{stub: stub} do
      take = fn -> Shared.take_token(@ns, "hot", 10, 1.0e-9, :keep, 600_000) end
      assert :ok = take.()
      go_down(stub)
      assert :ok = take.()
      ValkeyStub.set_mode(stub, :normal)
      wait_until(&Pool.serving?/0)

      # 10 - 1 - 1 (spent during the outage) - 5 = 3 left.
      1..5 |> Enum.map(fn _ -> Task.async(take) end) |> Enum.each(&(:ok = Task.await(&1)))
      for _ <- 1..3, do: assert(:ok = take.())
      assert {:limited, _, _} = take.()
    end

    test "a legacy scan that fails part way never deletes a generation key", %{stub: stub} do
      :ok = ValkeyStub.put_raw(stub, "optimal:shared:optimal_legacy_idle:gen", "3")

      ValkeyStub.fail_when(stub, fn
        ["SCAN", _cursor, "MATCH", "optimal:shared:optimal_legacy_idle:*" | _] -> "ERR busy"
        _ -> nil
      end)

      Shared.reset_legacy_cleanup()
      _ = Shared.get(@ns, "anything")

      wait_until(fn ->
        Enum.any?(ValkeyStub.commands(stub), &(Enum.join(&1, " ") =~ "optimal_legacy_idle:*"))
      end)

      Process.sleep(100)

      assert Map.has_key?(ValkeyStub.keys(stub), "optimal:shared:optimal_legacy_idle:gen")
    end

    test "once nothing of the old layout is left, a later boot does not scan for it again",
         %{stub: stub} do
      :ok = ValkeyStub.put_raw(stub, "optimal:shared:optimal_legacy_once:gen", "1")
      Shared.reset_legacy_cleanup()
      _ = Shared.get(@ns, "anything")

      wait_until(fn ->
        not Map.has_key?(ValkeyStub.keys(stub), "optimal:shared:optimal_legacy_once:gen")
      end)

      scans = fn -> Enum.count(ValkeyStub.commands(stub), &match?(["SCAN" | _], &1)) end
      wait_until(fn -> Enum.any?(Map.keys(ValkeyStub.keys(stub)), &(&1 =~ "legacy")) end)
      before = scans.()

      Shared.reset_legacy_cleanup()
      _ = Shared.get(@ns, "anything")
      Process.sleep(200)
      assert scans.() == before
    end

    test "the generation key expires unless used, and a use renews it", %{stub: stub} do
      :ok = Shared.clear(@ns)
      gen = "#{Shared.key_prefix()}:#{@ns}:gen"
      assert ValkeyStub.pttl(stub, gen) > 0

      # One written before it had a TTL gets one on its next use.
      :ok = ValkeyStub.put_raw(stub, gen, "4")
      :ok = ValkeyStub.persist(stub, gen)
      assert ValkeyStub.pttl(stub, gen) == nil
      _ = Shared.get(@ns, "anything")
      assert ValkeyStub.pttl(stub, gen) > 0
    end

    test "the generation keys of the layout before the prefix are removed once nothing is under them",
         %{stub: stub} do
      :ok = ValkeyStub.put_raw(stub, "optimal:shared:optimal_legacy_idle:gen", "3")
      :ok = ValkeyStub.put_raw(stub, "optimal:shared:optimal_legacy_busy:gen", "2")
      # An Engine still on the old layout keeps a live key there.
      :ok = ValkeyStub.put_raw(stub, "optimal:shared:optimal_legacy_busy:2:k:x", "v")

      Shared.reset_legacy_cleanup()
      _ = Shared.get(@ns, "anything")

      wait_until(fn ->
        not Map.has_key?(ValkeyStub.keys(stub), "optimal:shared:optimal_legacy_idle:gen")
      end)

      assert Map.has_key?(ValkeyStub.keys(stub), "optimal:shared:optimal_legacy_busy:gen")
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
