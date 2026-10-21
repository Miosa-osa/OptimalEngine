defmodule OptimalEngine.Authority.EvidenceKeysTest do
  @moduledoc """
  `GET /api/authority/evidence/keys/:kid`: one evidence key as a public JWK, for a
  verifier holding an export. Active and retired keys are served, a retired one with
  its `retired_at`; an unknown kid, a grant key and a revoked key are not; the route
  needs the grant that reads evidence.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.{Evidence, JWS, Keys}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    tenant = "evidence-keys-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Evidence keys"})
    {:ok, entry} = Evidence.append(tenant, "decision.allowed", %{subject: "agent:keys"})
    %{tenant: tenant, kid: entry["kid"]}
  end

  test "an active evidence key is served as a public JWK, and so is every JWKS entry", ctx do
    conn = get_key(ctx.tenant, ctx.kid)
    assert conn.status == 200
    jwk = Jason.decode!(conn.resp_body)

    assert Map.keys(jwk) |> Enum.sort() == ~w(alg crv kid kty optimal_purpose x)

    assert %{
             "kty" => "OKP",
             "crv" => "Ed25519",
             "kid" => kid,
             "alg" => "EdDSA",
             "optimal_purpose" => "evidence"
           } = jwk

    assert kid == ctx.kid
    {:ok, x} = JWS.decode64(jwk["x"])
    assert byte_size(x) == 32
    assert Keys.thumbprint(x) == ctx.kid

    listed = Enum.find(Keys.jwks(ctx.tenant)["keys"], &(&1["kid"] == ctx.kid))
    assert %{"alg" => "EdDSA", "x" => listed_x} = listed
    assert listed_x == jwk["x"]
    assert Enum.all?(Keys.jwks(ctx.tenant)["keys"], &(&1["alg"] == "EdDSA"))
  end

  test "a retired evidence key is still served, with when it was retired", ctx do
    {:ok, _new} = Keys.rotate(ctx.tenant, "evidence")

    conn = get_key(ctx.tenant, ctx.kid)
    assert conn.status == 200
    jwk = Jason.decode!(conn.resp_body)
    assert %{"kid" => kid, "optimal_purpose" => "evidence", "alg" => "EdDSA"} = jwk
    assert kid == ctx.kid
    # Retired to the millisecond, so a verifier can place it against an entry's recorded_at.
    assert jwk["retired_at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/
    assert {:ok, _at, 0} = DateTime.from_iso8601(jwk["retired_at"])

    {:ok, active} = Keys.active(ctx.tenant, "evidence")
    assert active.kid != ctx.kid
    refute Map.has_key?(Jason.decode!(get_key(ctx.tenant, active.kid).resp_body), "retired_at")
  end

  test "an unknown kid, a grant key, a revoked key and another tenant's key answer 404", ctx do
    {:ok, grant_key} = Keys.active(ctx.tenant, "grant")

    other = "evidence-keys-other-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: other, name: "Evidence keys, other"})
    {:ok, other_entry} = Evidence.append(other, "decision.allowed", %{subject: "agent:keys"})

    for kid <- ["no-such-kid", grant_key.kid, other_entry["kid"]] do
      conn = get_key(ctx.tenant, kid)
      assert conn.status == 404, kid
      assert Jason.decode!(conn.resp_body) == %{"error" => "evidence key not found"}
    end

    :ok = Keys.revoke(ctx.tenant, ctx.kid)
    assert get_key(ctx.tenant, ctx.kid).status == 404
  end

  test "a key without the grant that reads evidence is refused", ctx do
    assert get_key(ctx.tenant, ctx.kid, ["read", "write"]).status == 403
    assert get_key(ctx.tenant, ctx.kid, ["authority:read"]).status == 200
  end

  defp get_key(tenant, kid, scopes \\ ["*"]) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "evidence-keys-#{System.unique_integer([:positive])}",
          scopes: scopes,
          workspace_scope: ["*"]
        })

      conn(:get, "/api/authority/evidence/keys/" <> URI.encode_www_form(kid))
      |> put_req_header("authorization", "Bearer " <> key)
      |> Router.call(@opts)
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end
end
