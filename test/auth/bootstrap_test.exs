defmodule OptimalEngine.Auth.BootstrapTest do
  @moduledoc """
  The operator-supplied bootstrap key: registered at boot, idempotent, explicit
  scopes, rotated by changing the token.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Auth.{ApiKey, Bootstrap}

  @tenant "default"

  defp token do
    id = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    "oe_#{id}_#{secret}"
  end

  defp env(token, extra \\ %{}), do: Map.merge(%{"OPTIMAL_BOOTSTRAP_KEY" => token}, extra)

  test "does nothing when no bootstrap key is configured" do
    assert :ok = Bootstrap.run(%{})
    assert :ok = Bootstrap.run(%{"OPTIMAL_BOOTSTRAP_KEY" => "  "})
  end

  test "registers a key that verifies, with explicit read and write scopes by default" do
    token = token()
    assert :ok = Bootstrap.run(env(token))

    assert {:ok, key} = ApiKey.verify(token)
    assert key.scopes == ["read", "write"]
    assert key.workspace_scope == ["*"]
    assert key.tenant_id == @tenant
    assert key.metadata == %{"source" => "bootstrap"}
  end

  test "scopes, tenant and workspaces come from the environment" do
    token = token()

    assert :ok =
             Bootstrap.run(
               env(token, %{
                 "OPTIMAL_BOOTSTRAP_SCOPES" => "read, write ,topology:write",
                 "OPTIMAL_BOOTSTRAP_WORKSPACES" => "miosa,compute",
                 "OPTIMAL_BOOTSTRAP_TENANT" => @tenant
               })
             )

    assert {:ok, key} = ApiKey.verify(token)
    assert key.scopes == ["read", "write", "topology:write"]
    assert key.workspace_scope == ["miosa", "compute"]
  end

  test "a second boot with the same token changes nothing" do
    token = token()
    assert :ok = Bootstrap.run(env(token))
    {:ok, before} = ApiKey.count(@tenant)

    assert :ok = Bootstrap.run(env(token))
    assert {:ok, ^before} = ApiKey.count(@tenant)
    assert {:ok, :exists} = ApiKey.ensure(token, %{tenant_id: @tenant, name: "bootstrap"})
  end

  test "a new token rotates: the new key works and the previous bootstrap key is revoked" do
    old = token()
    new = token()

    assert :ok = Bootstrap.run(env(old))
    assert {:ok, _} = ApiKey.verify(old)

    assert :ok = Bootstrap.run(env(new))
    assert {:ok, _} = ApiKey.verify(new)
    assert {:error, :revoked} = ApiKey.verify(old)
  end

  test "rotation never touches keys that were minted by hand" do
    {:ok, %{key: manual}} = ApiKey.mint(%{tenant_id: @tenant, name: "manual"})

    assert :ok = Bootstrap.run(env(token()))
    assert {:ok, _} = ApiKey.verify(manual)
  end

  test "a malformed or weak token fails closed and registers nothing" do
    {:ok, before} = ApiKey.count(@tenant)

    assert {:error, {:bootstrap_key, :invalid_token}} = Bootstrap.run(env("nonsense"))

    assert {:error, {:bootstrap_key, :weak_secret}} =
             Bootstrap.run(env("oe_" <> String.duplicate("a", 24) <> "_short"))

    assert {:ok, ^before} = ApiKey.count(@tenant)
  end

  test "a token that was rotated out is refused, never revived" do
    old = token()
    assert :ok = Bootstrap.run(env(old))
    assert :ok = Bootstrap.run(env(token()))

    assert {:error, {:bootstrap_key, :revoked}} = Bootstrap.run(env(old))
    assert {:error, :revoked} = ApiKey.verify(old)
  end

  test "the same id with a different secret is a conflict and the original keeps working" do
    original = token()
    assert :ok = Bootstrap.run(env(original))

    "oe_" <> <<id::binary-size(24), "_", _::binary>> = original
    forged = "oe_#{id}_#{String.duplicate("z", 40)}"

    assert {:error, {:bootstrap_key, :id_conflict}} = Bootstrap.run(env(forged))
    assert {:ok, _} = ApiKey.verify(original)
    assert {:error, :invalid} = ApiKey.verify(forged)
  end
end
