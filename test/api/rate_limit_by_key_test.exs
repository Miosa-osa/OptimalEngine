defmodule OptimalEngine.API.RateLimitByKeyTest do
  @moduledoc """
  Rate limits apply after authentication: every API key has its own bucket
  (the size profile's requests per minute, or the key's own
  `rate_limit_per_minute`), and only unauthenticated requests share the peer
  IP's bucket. A request with an invalid key is unauthenticated, so it can
  never spend a real key's bucket. Health, status and Prometheus metrics stay
  exempt.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.{RateLimiter, Router}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "ratelimit-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Rate limit #{n}"})

    original = Application.get_env(:optimal_engine, :api_rate_limit)

    Application.put_env(:optimal_engine, :api_rate_limit,
      default_capacity: 3,
      default_per_minute: 3
    )

    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:optimal_engine, :api_rate_limit, original)
      RateLimiter.reset()
    end)

    %{tenant: tenant}
  end

  defp mint(tenant, metadata \\ %{}) do
    {:ok, %{id: id, key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "rate-limit-test",
        scopes: ["read"],
        workspace_scope: ["*"],
        metadata: metadata
      })

    {id, key}
  end

  defp call(path, token \\ nil) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp spend(token, times), do: for(_ <- 1..times, do: call("/api/auth/self", token).status)

  test "two keys from the same address have separate buckets", ctx do
    {_a, key_a} = mint(ctx.tenant)
    {_b, key_b} = mint(ctx.tenant)

    assert spend(key_a, 3) == [200, 200, 200]

    conn = call("/api/auth/self", key_a)
    assert conn.status == 429
    assert %{"error" => "rate_limited", "retry_after_ms" => ms} = Jason.decode!(conn.resp_body)
    assert is_integer(ms) and ms > 0
    assert [_] = get_resp_header(conn, "retry-after")

    assert call("/api/auth/self", key_b).status == 200
  end

  test "a keyed caller does not spend the address bucket of anonymous callers", ctx do
    {_a, key_a} = mint(ctx.tenant)

    assert spend(key_a, 3) == [200, 200, 200]
    assert call("/api/auth/self", key_a).status == 429

    assert call("/api/auth/self").status == 200
  end

  test "an invalid key never spends a real key's bucket", ctx do
    {id, key} = mint(ctx.tenant)
    forged = "oe_#{id}_#{String.duplicate("x", 40)}"

    assert spend(forged, 2) == [401, 401]
    assert spend(key, 3) == [200, 200, 200]
  end

  test "invalid keys spend the address bucket and are refused with 429 once it is empty",
       ctx do
    {id, _key} = mint(ctx.tenant)
    forged = "oe_#{id}_#{String.duplicate("y", 40)}"

    assert spend(forged, 3) == [401, 401, 401]

    conn = call("/api/auth/self", forged)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "rate_limited"

    assert call("/api/auth/self").status == 429
  end

  test "a key's own rate_limit_per_minute sets its bucket", ctx do
    {_id, key} = mint(ctx.tenant, %{"rate_limit_per_minute" => 2})

    assert spend(key, 2) == [200, 200]
    assert call("/api/auth/self", key).status == 429
  end

  test "health, status and Prometheus metrics stay exempt for keyed callers", ctx do
    {_id, key} = mint(ctx.tenant)
    assert spend(key, 3) == [200, 200, 200]
    assert call("/api/auth/self", key).status == 429

    for path <- ["/api/health", "/api/status", "/api/metrics/prometheus", "/v1/health"] do
      refute call(path, key).status == 429, "#{path} was rate limited"
    end
  end

  test "without explicit limits the size profile sets each key's bucket", ctx do
    Application.delete_env(:optimal_engine, :api_rate_limit)
    original_rate = Application.get_env(:optimal_engine, :api_per_minute)
    Application.put_env(:optimal_engine, :api_per_minute, 2)

    try do
      {_a, key_a} = mint(ctx.tenant)
      {_b, key_b} = mint(ctx.tenant)

      conn = call("/api/auth/self", key_a)
      assert get_resp_header(conn, "x-ratelimit-limit") == ["2"]
      assert call("/api/auth/self", key_a).status == 200
      assert call("/api/auth/self", key_a).status == 429
      assert call("/api/auth/self", key_b).status == 200
    after
      if original_rate,
        do: Application.put_env(:optimal_engine, :api_per_minute, original_rate),
        else: Application.delete_env(:optimal_engine, :api_per_minute)
    end
  end

  describe "minting a key with its own limit" do
    defp mint_over_http(body) do
      conn(:post, "/api/auth/keys", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)
    end

    test "POST /api/auth/keys accepts rate_limit_per_minute and the key is held to it" do
      conn =
        mint_over_http(%{"name" => "limited", "scopes" => ["read"], "rate_limit_per_minute" => 2})

      assert conn.status == 201
      %{"key" => key} = Jason.decode!(conn.resp_body)

      assert spend(key, 2) == [200, 200]
      assert call("/api/auth/self", key).status == 429
    end

    test "rate_limit_per_minute must be a positive integer" do
      for bad <- [0, -1, "10", 1.5] do
        RateLimiter.reset()
        conn = mint_over_http(%{"name" => "bad", "rate_limit_per_minute" => bad})
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"] == "invalid rate_limit_per_minute"
      end
    end

    test "a key never mints a key with a higher limit than its own, and its keys inherit it",
         ctx do
      {:ok, parent} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "parent",
          scopes: ["*"],
          workspace_scope: ["*"],
          metadata: %{"rate_limit_per_minute" => 10}
        })

      {:ok, parent} = OptimalEngine.Auth.ApiKey.verify(parent.key)
      issuance = OptimalEngine.Auth.KeyIssuance

      assert {:error, "rate_limit_exceeds_minter"} =
               issuance.attrs(parent, ctx.tenant, %{"name" => "c", "rate_limit_per_minute" => 11})

      assert {:ok, %{metadata: %{"rate_limit_per_minute" => 5}}} =
               issuance.attrs(parent, ctx.tenant, %{"name" => "c", "rate_limit_per_minute" => 5})

      assert {:ok, %{metadata: %{"rate_limit_per_minute" => 10}}} =
               issuance.attrs(parent, ctx.tenant, %{"name" => "c"})
    end
  end
end
