defmodule OptimalEngine.Authority.KeysTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.Keys
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "keys-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Keys #{n}"})
    previous = System.get_env("OPTIMAL_AUTHORITY_KEY")
    on_exit(fn -> System.put_env("OPTIMAL_AUTHORITY_KEY", previous) end)
    %{tenant: tenant}
  end

  test "private keys are wrapped and never stored in the clear", %{tenant: tenant} do
    {:ok, key} = Keys.active(tenant, "grant")

    {:ok, [[stored, wrapped]]} =
      Store.raw_query("SELECT private_key, wrapped FROM authority_keys WHERE kid = ?1", [key.kid])

    assert wrapped == 1
    refute stored == Base.encode64(key.private_key)
    assert key.kid == Keys.thumbprint(key.public_key)
  end

  test "grant and evidence keys are separate", %{tenant: tenant} do
    {:ok, grant} = Keys.active(tenant, "grant")
    {:ok, evidence} = Keys.active(tenant, "evidence")
    refute grant.kid == evidence.kid
    assert {:error, :unknown_key} = Keys.verification_key(tenant, evidence.kid, "grant")
  end

  test "a wrong wrapping key cannot unwrap", %{tenant: tenant} do
    {:ok, _key} = Keys.active(tenant, "grant")
    System.put_env("OPTIMAL_AUTHORITY_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
    assert {:error, :unwrap_failed} = Keys.active(tenant, "grant")
  end

  test "an authenticated deployment refuses to create keys without a wrapping key", %{
    tenant: tenant
  } do
    System.delete_env("OPTIMAL_AUTHORITY_KEY")
    auth = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.put(auth, :auth_required, true))

    try do
      assert {:error, :authority_key_missing} = Keys.active(tenant, "grant")
    after
      Application.put_env(:optimal_engine, :auth, auth)
    end
  end

  test "the JWK set publishes active and retired keys but not revoked ones", %{tenant: tenant} do
    {:ok, first} = Keys.active(tenant, "grant")
    {:ok, second} = Keys.rotate(tenant, "grant")
    {:ok, third} = Keys.rotate(tenant, "grant")
    :ok = Keys.revoke(tenant, second.kid)

    kids = Keys.jwks(tenant)["keys"] |> Enum.map(& &1["kid"])
    assert first.kid in kids
    assert third.kid in kids
    refute second.kid in kids
    assert {:ok, _} = Keys.verification_key(tenant, first.kid, "grant")
    assert {:error, :key_revoked} = Keys.verification_key(tenant, second.kid, "grant")
  end

  defp active_kids(tenant, purpose) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT kid FROM authority_keys WHERE tenant_id = ?1 AND purpose = ?2 AND status = 'active'",
        [tenant, purpose]
      )

    List.flatten(rows)
  end

  test "rotations that run at once leave exactly one active key, the last one made", %{
    tenant: tenant
  } do
    {:ok, _first} = Keys.active(tenant, "grant")

    rotated =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Keys.rotate(tenant, "grant") end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.all?(rotated, &match?({:ok, _}, &1))
    assert [kid] = active_kids(tenant, "grant")
    assert {:ok, %{kid: ^kid}} = Keys.active(tenant, "grant")
  end

  test "first use from many callers at once creates one active key", %{tenant: tenant} do
    made =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Keys.active(tenant, "evidence") end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert [kid] = active_kids(tenant, "evidence")
    assert Enum.all?(made, &match?({:ok, %{kid: ^kid}}, &1))
  end

  test "two rotations within one second: the active key is the newer one", %{tenant: tenant} do
    {:ok, _} = Keys.active(tenant, "grant")
    {:ok, _older} = Keys.rotate(tenant, "grant")
    {:ok, newer} = Keys.rotate(tenant, "grant")

    # Every key of the tenant stamped with the same instant.
    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_keys SET created_at = '2026-01-01T00:00:00.000' WHERE tenant_id = ?1",
        [tenant]
      )

    assert [kid] = active_kids(tenant, "grant")
    assert kid == newer.kid
    assert {:ok, %{kid: ^kid}} = Keys.active(tenant, "grant")
  end

  test "keys an older build left active together resolve the same way every time", %{
    tenant: tenant
  } do
    {:ok, one} = Keys.active(tenant, "grant")
    {:ok, two} = Keys.rotate(tenant, "grant")

    # What a race in an older build could leave: two active keys, one instant.
    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_keys SET status = 'active', retired_at = NULL, created_at = '2026-01-01T00:00:00.000' WHERE tenant_id = ?1",
        [tenant]
      )

    expected = Enum.max([one.kid, two.kid])

    for _ <- 1..10, do: assert({:ok, %{kid: ^expected}} = Keys.active(tenant, "grant"))

    # The next rotation leaves one active key again.
    {:ok, three} = Keys.rotate(tenant, "grant")
    assert active_kids(tenant, "grant") == [three.kid]
  end
end
