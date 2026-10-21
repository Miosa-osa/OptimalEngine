defmodule OptimalEngine.Auth.BootstrapTest do
  @moduledoc """
  The operator-supplied bootstrap key: registered at boot, idempotent, explicit
  scopes, rotated by changing the token.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  @root_grants %{
    "source" => "bootstrap",
    "allowed_security_labels" => ["*"],
    "allowed_partitions" => ["*"],
    "grants_initialized" => true
  }

  defp id_of(token), do: token |> String.split("_") |> Enum.at(1)

  defp sql!(statement, params) do
    {:ok, _} = OptimalEngine.Store.raw_query(statement, params)
    :ok
  end

  test "registers a key that verifies, with explicit read and write scopes by default" do
    token = token()
    assert :ok = Bootstrap.run(env(token))

    assert {:ok, key} = ApiKey.verify(token)
    assert key.scopes == ["read", "write"]
    assert key.workspace_scope == ["*"]
    assert key.tenant_id == @tenant
  end

  test "a read,write bootstrap key gets no label or partition grants, now or at a later boot" do
    token = token()
    assert :ok = Bootstrap.run(env(token))
    assert {:ok, key} = ApiKey.verify(token)
    assert key.metadata == %{"source" => "bootstrap"}

    assert capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(env(token)) end) == ""
    assert {:ok, again} = ApiKey.verify(token)
    assert again.metadata == %{"source" => "bootstrap"}
  end

  test "a bootstrap key with * or admin scope holds every label and partition, marked" do
    for scopes <- ["*", "read,write,admin"] do
      token = token()
      assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => scopes}))
      assert {:ok, key} = ApiKey.verify(token)
      assert key.metadata == @root_grants, scopes
    end
  end

  test "a root key registered before the grants existed is given them once, with a warning" do
    token = token()
    id = id_of(token)
    root = env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"})
    assert :ok = Bootstrap.run(root)

    :ok =
      sql!(
        "UPDATE api_keys SET metadata = json_remove(metadata, '$.allowed_security_labels', '$.allowed_partitions', '$.grants_initialized') WHERE id = ?1",
        [id]
      )

    assert {:ok, bare} = ApiKey.verify(token)
    assert bare.metadata == %{"source" => "bootstrap"}

    log = capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(root) end)
    assert log =~ "registered before label and partition grants existed"
    assert log =~ id

    assert {:ok, key} = ApiKey.verify(token)
    assert key.metadata == @root_grants

    # Marked, so the next boot is silent and changes nothing.
    assert capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(root) end) == ""
    assert {:ok, ^key} = ApiKey.verify(token)
  end

  test "grants the operator narrowed are left as they are, including none" do
    token = token()
    id = id_of(token)
    assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))

    :ok =
      sql!(
        "UPDATE api_keys SET metadata = json_set(metadata, '$.allowed_security_labels', json('[\"internal\"]'), '$.allowed_partitions', json('[]')) WHERE id = ?1",
        [id]
      )

    assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))
    assert {:ok, narrowed} = ApiKey.verify(token)
    assert narrowed.metadata["allowed_security_labels"] == ["internal"]
    assert narrowed.metadata["allowed_partitions"] == []

    # Even with the fields gone (nothing granted), the marker keeps a boot from widening them.
    :ok =
      sql!(
        "UPDATE api_keys SET metadata = json_remove(metadata, '$.allowed_security_labels', '$.allowed_partitions') WHERE id = ?1",
        [id]
      )

    assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))
    assert {:ok, none} = ApiKey.verify(token)
    assert none.metadata == %{"source" => "bootstrap", "grants_initialized" => true}
  end

  describe "an existing key is brought to the environment" do
    test "scopes and workspaces that changed under the same token are applied, with a warning" do
      token = token()
      assert :ok = Bootstrap.run(env(token))

      changed =
        env(token, %{
          "OPTIMAL_BOOTSTRAP_SCOPES" => "read",
          "OPTIMAL_BOOTSTRAP_WORKSPACES" => "miosa"
        })

      log = capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(changed) end)

      assert log =~ "it now holds scopes"
      assert {:ok, key} = ApiKey.verify(token)
      assert key.scopes == ["read"]
      assert key.workspace_scope == ["miosa"]

      assert capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(changed) end) == ""
    end

    test "a key that stops being root gives up its wildcard grants and keeps the others" do
      token = token()
      id = id_of(token)
      assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))

      :ok =
        sql!(
          "UPDATE api_keys SET metadata = json_set(metadata, '$.allowed_security_labels', json('[\"*\",\"internal\"]')) WHERE id = ?1",
          [id]
        )

      log = capture_log([level: :warning], fn -> assert :ok = Bootstrap.run(env(token)) end)

      assert log =~ "no longer root"
      assert {:ok, key} = ApiKey.verify(token)
      assert key.scopes == ["read", "write"]
      assert key.metadata["allowed_security_labels"] == ["internal"]
      assert key.metadata["allowed_partitions"] == []
    end

    test "a key that becomes root is given the grants once, like one that predates them" do
      token = token()
      assert :ok = Bootstrap.run(env(token))
      assert {:ok, plain} = ApiKey.verify(token)
      assert plain.metadata == %{"source" => "bootstrap"}

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Bootstrap.run(env(token, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))
        end)

      assert log =~ "registered before label and partition grants existed"
      assert {:ok, key} = ApiKey.verify(token)
      assert key.scopes == ["*"]
      assert key.metadata == @root_grants
    end

    test "a rotated token is a new key with the defaults for its scopes" do
      old = token()
      new = token()
      assert :ok = Bootstrap.run(env(old, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))

      :ok =
        sql!(
          "UPDATE api_keys SET metadata = json_set(metadata, '$.allowed_security_labels', json('[\"internal\"]')) WHERE id = ?1",
          [id_of(old)]
        )

      assert :ok = Bootstrap.run(env(new, %{"OPTIMAL_BOOTSTRAP_SCOPES" => "*"}))
      assert {:ok, key} = ApiKey.verify(new)
      assert key.metadata == @root_grants
    end
  end

  test "scopes, tenant and workspaces come from the environment" do
    token = token()

    assert :ok =
             Bootstrap.run(
               env(token, %{
                 "OPTIMAL_BOOTSTRAP_SCOPES" => "read, write ,topology:write",
                 "OPTIMAL_BOOTSTRAP_WORKSPACES" => "sales,support",
                 "OPTIMAL_BOOTSTRAP_TENANT" => @tenant
               })
             )

    assert {:ok, key} = ApiKey.verify(token)
    assert key.scopes == ["read", "write", "topology:write"]
    assert key.workspace_scope == ["sales", "support"]
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
