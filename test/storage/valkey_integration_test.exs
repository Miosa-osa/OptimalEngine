defmodule OptimalEngine.Storage.ValkeyIntegrationTest do
  @moduledoc """
  The shared interface against a real Valkey, so the Lua the stub only imitates
  runs on a server. Skipped unless `OPTIMAL_TEST_VALKEY_URL` names one, e.g.

      docker run --rm -p 6390:6379 valkey/valkey:8.1
      OPTIMAL_TEST_VALKEY_URL=redis://127.0.0.1:6390/15 mix test --only valkey

  It writes only under `<Shared.key_prefix()>:shared:optimal_valkey_it*` and clears that.
  """
  use ExUnit.Case, async: false

  @moduletag :valkey

  alias OptimalEngine.API.RateLimiter
  alias OptimalEngine.Auth.KeyCache
  alias OptimalEngine.Storage.Shared
  alias OptimalEngine.Storage.Shared.Local
  alias OptimalEngine.Storage.Valkey
  alias OptimalEngine.Storage.Valkey.Pool

  @ns :optimal_valkey_it

  setup_all do
    url = System.fetch_env!("OPTIMAL_TEST_VALKEY_URL")
    {:ok, url: url}
  end

  setup %{url: url} do
    Local.new_table(@ns)
    Local.clear(@ns)
    start_supervised!({Pool, url: url, size: 2, timeout: 500})
    wait_until(&Pool.serving?/0)
    :ok = Shared.clear(@ns)
    :ok
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("Valkey did not come up")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "the provider's own proof still passes", %{url: url} do
    assert Valkey.health(url: url) == :healthy
    assert {:ok, %{read_back: true}} = Valkey.round_trip(url: url)
  end

  test "cache, clear, counter and lease run on the server" do
    assert Shared.backend() == :valkey
    :ok = Shared.put(@ns, {:term, 1}, %{"v" => [1, 2.5]}, 60_000)
    assert {:ok, %{"v" => [1, 2.5]}} = Shared.get(@ns, {:term, 1})
    assert Local.get(@ns, {:term, 1}) == :miss

    :ok = Shared.clear(@ns)
    assert Shared.get(@ns, {:term, 1}) == :miss

    assert {:ok, 1} = Shared.incr(@ns, "c", 60_000)
    assert {:ok, 2} = Shared.incr(@ns, "c", 60_000)
    assert {:ok, pttl} = Pool.command(["PTTL", Shared.valkey_key(@ns, "c", gen())])
    assert pttl in 1..60_000

    assert {:ok, token} = Shared.lock(@ns, "l", 60_000)
    assert {:error, :locked} = Shared.lock(@ns, "l", 60_000)
    :ok = Shared.unlock(@ns, "l", "stale")
    assert {:error, :locked} = Shared.lock(@ns, "l", 60_000)
    :ok = Shared.unlock(@ns, "l", token)
    assert {:ok, _} = Shared.lock(@ns, "l", 60_000)
  end

  test "the bucket script keeps the local limiter's arithmetic" do
    for deny <- [:keep, :advance] do
      key = {:bucket, deny}
      assert :ok = Shared.take_token(@ns, key, 2, 1.0e-6, deny, 60_000)
      assert :ok = Shared.take_token(@ns, key, 2, 1.0e-6, deny, 60_000)
      assert {:limited, tokens, elapsed} = Shared.take_token(@ns, key, 2, 1.0e-6, deny, 60_000)
      assert tokens >= 0.0 and tokens < 1.0
      assert is_integer(elapsed) and elapsed >= 0
    end

    for _ <- 1..2 do
      Process.sleep(30)
      Shared.take_token(@ns, {:bucket, :advance}, 2, 1.0e-6, :advance, 60_000)
    end

    assert {:limited, _, kept} = Shared.take_token(@ns, {:bucket, :keep}, 2, 1.0e-6, :keep, 60_000)
    assert kept >= 60

    assert {:limited, _, advanced} =
             Shared.take_token(@ns, {:bucket, :advance}, 2, 1.0e-6, :advance, 60_000)

    assert advanced < 60

    # A fast refill gives a token back.
    assert :ok = Shared.take_token(@ns, "fast", 1, 1.0, :keep, 60_000)
    Process.sleep(5)
    assert :ok = Shared.take_token(@ns, "fast", 1, 1.0, :keep, 60_000)
  end

  test "after an outage the bucket script keeps the lower of the local and the server bucket" do
    # This node spent a fresh bucket down to nothing while Valkey was away.
    Local.new_table(@ns)

    :ets.insert(
      @ns,
      {"after-outage", {0.0, System.monotonic_time(:millisecond), :fallback},
       System.monotonic_time(:millisecond) + 60_000}
    )

    assert {:limited, tokens, _} = Shared.take_token(@ns, "after-outage", 3, 1.0e-6, :keep, 60_000)
    assert tokens < 1.0

    # The server bucket now carries that count; the local row is its mirror.
    assert [{"after-outage", {mirrored, _at}, _}] = :ets.lookup(@ns, "after-outage")
    assert mirrored < 1.0
    :ets.delete(@ns, "after-outage")
    assert {:limited, _, _} = Shared.take_token(@ns, "after-outage", 3, 1.0e-6, :keep, 60_000)
  end

  test "denied API checks do not refill the bucket faster than its rate" do
    RateLimiter.reset()
    key = "it-hammer:#{System.unique_integer([:positive])}"
    assert :ok = RateLimiter.check(key, 1, 60)
    Process.sleep(600)
    assert {:rate_limited, _, remaining: 0, reset_at: _} = RateLimiter.check(key, 1, 60)
    Process.sleep(300)
    assert {:rate_limited, _, remaining: 0, reset_at: _} = RateLimiter.check(key, 1, 60)
    Process.sleep(200)
    assert :ok = RateLimiter.check(key, 1, 60)
  end

  test "the API limiter and the key cache answer as on ETS" do
    RateLimiter.reset()
    key = "it:#{System.unique_integer([:positive])}"
    for _ <- 1..2, do: assert(:ok = RateLimiter.check(key, 2, 1))
    assert {:rate_limited, ms, remaining: 0, reset_at: _} = RateLimiter.check(key, 2, 1)
    assert ms > 0 and ms <= 60_000

    id = "it-key-#{System.unique_integer([:positive])}"
    :ok = KeyCache.remember(id, "secret", "$2b$hash")
    assert KeyCache.verified?(id, "secret", "$2b$hash")
    :ok = KeyCache.forget(id)
    refute KeyCache.verified?(id, "secret", "$2b$hash")
  end

  defp gen do
    case Pool.command(["GET", "#{Shared.key_prefix()}:shared:#{@ns}:gen"]) do
      {:ok, nil} -> 0
      {:ok, g} -> String.to_integer(g)
    end
  end
end
