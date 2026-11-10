defmodule OptimalEngine.Connectors.CredentialVaultPathTest do
  @moduledoc """
  The OpenBao path of a connector's credentials is built from its tenant and
  id. An id or tenant that is not in the form real ids take (a letter or digit,
  then letters, digits, `.`, `_`, `:` and `-`, at most 128, no `..`) is
  refused before OpenBao is asked: a `/` would address another secret in the
  tenant's tree.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Connectors.CredentialVault
  alias OptimalEngine.Secrets
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    %{stub: stub}
  end

  @bad_ids [
    "a/b",
    "notion-1/../x",
    "/abs",
    "x/",
    "",
    ".hidden",
    "a..b",
    String.duplicate("a", 129),
    "with space",
    "new\nline"
  ]

  test "ids of the shapes real connectors have are accepted" do
    for id <- ["notion-ab12cd34ef", "pull:default:gmail", "ie-gone-8", "slack.team_1"] do
      assert {:ok, path} = CredentialVault.path("default", id)
      assert path == "optimal/connectors/default/#{id}"
    end
  end

  test "an id or tenant that could address another path is refused, and OpenBao is never asked",
       %{stub: stub} do
    for id <- @bad_ids do
      assert CredentialVault.path("default", id) == {:error, :invalid_connector_id}, inspect(id)

      assert CredentialVault.put(%{}, "default", id, %{"token" => "t"}) ==
               {:error, :invalid_connector_id}

      assert CredentialVault.get(%{}, "default", id) == {:error, :invalid_connector_id}
      assert CredentialVault.delete("default", id) == {:error, :invalid_connector_id}
    end

    assert CredentialVault.path("acme/other", "notion-1") == {:error, :invalid_connector_id}
    assert OpenBaoStub.requests(stub) == []
  end
end
