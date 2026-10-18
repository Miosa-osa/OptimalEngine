defmodule OptimalEngine.Connectors.CredentialTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Credential

  @valid_key Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  setup do
    original = System.get_env("CONNECTOR_KEY")

    on_exit(fn ->
      if original,
        do: System.put_env("CONNECTOR_KEY", original),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    :ok
  end

  describe "encrypt/1 + decrypt/1 round-trip" do
    test "plaintext comes back identical" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      creds = %{"bot_token" => "xoxb-abc", "scope" => "channels:history"}

      assert {:ok, envelope} = Credential.encrypt(creds)
      assert is_binary(envelope)
      assert {:ok, ^creds} = Credential.decrypt(envelope)
    end

    test "ciphertext differs across two calls for the same plaintext (IV randomness)" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      creds = %{"k" => "v"}

      {:ok, e1} = Credential.encrypt(creds)
      {:ok, e2} = Credential.encrypt(creds)

      refute e1 == e2
    end
  end

  describe "error cases" do
    test "missing key returns :key_missing on encrypt" do
      System.delete_env("CONNECTOR_KEY")
      assert {:error, :key_missing} = Credential.encrypt(%{"x" => 1})
    end

    test "missing key returns :key_missing on decrypt" do
      System.delete_env("CONNECTOR_KEY")
      assert {:error, :key_missing} = Credential.decrypt("not-a-real-envelope")
    end

    test "invalid envelope rejected" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      assert {:error, :bad_envelope} = Credential.decrypt("notbase64!!!")
    end

    test "tampered envelope fails auth" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      {:ok, envelope} = Credential.encrypt(%{"x" => "y"})

      # Flip a middle byte by decoding, mutating, re-encoding.
      bad =
        envelope
        |> Base.decode64!()
        |> then(fn <<head::binary-size(30), byte, rest::binary>> ->
          <<head::binary, byte + 1, rest::binary>>
        end)
        |> Base.encode64()

      assert {:error, :auth_failed} = Credential.decrypt(bad)
    end
  end

  describe "persisted connector rows" do
    alias OptimalEngine.Connectors.Runner
    alias OptimalEngine.Store

    defp stored_config(id) do
      {:ok, [[json]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      json
    end

    test "string-keyed credentials are stored only as an envelope" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      id = "credential-string-#{System.unique_integer([:positive])}"

      assert {:ok, ^id} =
               Runner.upsert_row(%{
                 id: id,
                 kind: :slack,
                 config: %{"channels" => ["C01"], "credentials" => %{"bot_token" => "xoxb-str"}}
               })

      json = stored_config(id)
      refute json =~ "xoxb-str"
      assert {:ok, %{"credentials_ciphertext" => envelope} = config} = Jason.decode(json)
      refute Map.has_key?(config, "credentials")
      assert {:ok, %{"bot_token" => "xoxb-str"}} = Credential.decrypt(envelope)
    end

    test "atom-keyed credentials are stored only as an envelope" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      id = "credential-atom-#{System.unique_integer([:positive])}"

      assert {:ok, ^id} =
               Runner.upsert_row(%{
                 id: id,
                 kind: :slack,
                 config: %{channels: ["C01"], credentials: %{bot_token: "xoxb-atom"}}
               })

      json = stored_config(id)
      refute json =~ "xoxb-atom"
      assert {:ok, %{"credentials_ciphertext" => envelope} = config} = Jason.decode(json)
      refute Map.has_key?(config, "credentials")
      assert config["channels"] == ["C01"]
      assert {:ok, %{"bot_token" => "xoxb-atom"}} = Credential.decrypt(envelope)
    end

    test "credentials are refused, never stored in plaintext, without a master key" do
      System.delete_env("CONNECTOR_KEY")
      id = "credential-nokey-#{System.unique_integer([:positive])}"

      for config <- [
            %{"credentials" => %{"bot_token" => "xoxb-plain"}},
            %{credentials: %{bot_token: "xoxb-plain"}}
          ] do
        assert {:error, :connector_key_missing} =
                 Runner.upsert_row(%{id: id, kind: :slack, config: config})
      end

      assert {:ok, []} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
    end

    test "non-map credentials are rejected instead of persisted" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      id = "credential-invalid-#{System.unique_integer([:positive])}"

      assert {:error, :invalid_credentials} =
               Runner.upsert_row(%{id: id, kind: :slack, config: %{"credentials" => "xoxb-raw"}})

      assert {:ok, []} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
    end

    test "configs without credentials do not need a master key" do
      System.delete_env("CONNECTOR_KEY")
      id = "credential-none-#{System.unique_integer([:positive])}"

      assert {:ok, ^id} =
               Runner.upsert_row(%{id: id, kind: :slack, config: %{"channels" => ["C01"]}})
    end
  end

  describe "ready?/0" do
    test "true when key set, false otherwise" do
      System.put_env("CONNECTOR_KEY", @valid_key)
      assert Credential.ready?()

      System.delete_env("CONNECTOR_KEY")
      refute Credential.ready?()
    end
  end
end
