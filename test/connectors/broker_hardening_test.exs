defmodule OptimalEngine.Connectors.BrokerHardeningTest do
  @moduledoc """
  What the Engine will and will not do with a credential broker: the URL it may
  call, what an answer must look like to be believed, and the sealing of the
  reference it presents. The broker is `OptimalEngine.Test.BrokerStub`; no real
  broker is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.{AccessToken, Credential, CredentialSource}
  alias OptimalEngine.Test.BrokerStub

  @miosa "https://api.miosa.ai/api/v1/connect/broker/credentials"
  @scope %{
    id: "miosa:conn_1:gmail",
    kind: "gmail",
    tenant_id: "default",
    workspace_id: "default:ops"
  }
  @config %{
    "credential_source" => "broker",
    "broker_url" => @miosa,
    "broker_reference" => "conn_1.example-signature"
  }

  setup do
    saved =
      for key <- [:credential_broker_hosts, :credential_broker_paths],
          do: {key, Application.get_env(:optimal_engine, key)}

    original_key = System.get_env("CONNECTOR_KEY")

    Application.put_env(:optimal_engine, :credential_broker_hosts, ["api.miosa.ai"])
    Application.delete_env(:optimal_engine, :credential_broker_paths)
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    on_exit(fn ->
      for {key, value} <- saved do
        if value == nil,
          do: Application.delete_env(:optimal_engine, key),
          else: Application.put_env(:optimal_engine, key, value)
      end

      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    :ok
  end

  # What a stored connector's config holds: the reference sealed for its id.
  defp sealed(config \\ @config) do
    {:ok, sealed} = CredentialSource.seal_reference(config, %{id: @scope.id})
    sealed
  end

  defp broker(issue) do
    stub = BrokerStub.install(nil, broker_url: @miosa, issue: issue)
    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  describe "the broker URL is pinned to a host, a port and a path" do
    test "the MIOSA broker is accepted, and so is the explicit default port and any host case" do
      assert :ok = CredentialSource.check_url(@miosa)

      assert :ok =
               CredentialSource.check_url(
                 "https://api.miosa.ai:443/api/v1/connect/broker/credentials"
               )

      assert :ok =
               CredentialSource.check_url("https://API.Miosa.AI/api/v1/connect/broker/credentials")
    end

    test "another port, a trailing dot, an uppercase scheme or an empty userinfo is refused" do
      for url <- [
            "https://api.miosa.ai:8443/api/v1/connect/broker/credentials",
            "https://api.miosa.ai:80/api/v1/connect/broker/credentials",
            "https://api.miosa.ai./api/v1/connect/broker/credentials",
            "HTTPS://api.miosa.ai/api/v1/connect/broker/credentials",
            "Https://api.miosa.ai/api/v1/connect/broker/credentials",
            "https://@api.miosa.ai/api/v1/connect/broker/credentials",
            "https://user@api.miosa.ai/api/v1/connect/broker/credentials",
            "https://api.miosa.ai%2eevil.example/api/v1/connect/broker/credentials",
            "https://api.miosa.ai\\\\@evil.example/api/v1/connect/broker/credentials"
          ] do
        assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(url), url
      end
    end

    test "a host that only looks like the allowed one is refused" do
      for url <- [
            "https://api.miosa.аi/api/v1/connect/broker/credentials",
            "https://api.miosa.ai.evil.example/api/v1/connect/broker/credentials",
            "https://evil-api.miosa.ai/api/v1/connect/broker/credentials",
            "https://127.0.0.1/api/v1/connect/broker/credentials",
            "https://[::1]/api/v1/connect/broker/credentials"
          ] do
        assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(url), url
      end
    end

    test "only the broker's path is accepted, by default /api/v1/connect/broker/" do
      for url <- [
            "https://api.miosa.ai/",
            "https://api.miosa.ai/api/v1/internal/connect/broker/credentials",
            "https://api.miosa.ai/api/v1/connect/brokerage",
            "https://api.miosa.ai/api/v1/connect/broker/../../admin",
            "https://api.miosa.ai/api/v1/connect/broker/%2e%2e/admin",
            "https://api.miosa.ai/api/v1/connect/broker//credentials",
            "https://api.miosa.ai/api/v1/connect/broker/credentials?next=https://evil.example",
            "https://api.miosa.ai/api/v1/connect/broker/credentials#frag",
            "https://api.miosa.ai/api/v1/connect/broker/credentials\nx"
          ] do
        assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(url), url
      end
    end

    test "the path prefixes are configurable" do
      Application.put_env(:optimal_engine, :credential_broker_paths, ["/connect/"])

      assert :ok = CredentialSource.check_url("https://api.miosa.ai/connect/credentials")
      assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(@miosa)
    end

    test "an empty, blank or malformed path prefix allows nothing" do
      for bad <- ["", " ", "/", "/api;v=1/", "api/v1/connect/broker/", "/api/v1/../broker/"] do
        Application.put_env(:optimal_engine, :credential_broker_paths, [bad])
        assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(@miosa), inspect(bad)
      end

      Application.put_env(
        :optimal_engine,
        :credential_broker_paths,
        "  , ;,/api/v1/connect/broker/"
      )

      assert :ok = CredentialSource.check_url(@miosa)

      Application.put_env(:optimal_engine, :credential_broker_paths, [" ", ""])
      assert {:error, :broker_url_not_allowed} = CredentialSource.check_url(@miosa)
    end

    test "a path with a matrix parameter is refused" do
      assert {:error, :broker_url_not_allowed} =
               CredentialSource.check_url(
                 "https://api.miosa.ai/api/v1/connect/broker/credentials;jsessionid=1"
               )
    end

    test "a refused URL is never called" do
      stub = broker([{"example-issued-token-1", 3_600}])

      for url <- [
            "https://api.miosa.ai:8443/api/v1/connect/broker/credentials",
            "https://api.miosa.ai/elsewhere"
          ] do
        assert {:error, :broker_url_not_allowed} =
                 CredentialSource.hydrate(sealed(Map.put(@config, "broker_url", url)), @scope)
      end

      assert BrokerStub.broker_calls(stub) == []
    end

    test "a renewal checks the URL again" do
      stub =
        BrokerStub.install(nil,
          broker_url: @miosa,
          issue: [{"example-issued-token-1", 3_600}, {"example-issued-token-2", 3_600}],
          api: fn _url, _opts -> {200, %{}} end,
          reject: ["example-issued-token-1"]
        )

      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:ok, hydrated} = CredentialSource.hydrate(sealed(), @scope)
      Application.put_env(:optimal_engine, :credential_broker_hosts, [])

      result =
        AccessToken.session(
          %{"access_token" => hydrated["credentials"]["access_token"]},
          fn _state -> flunk("no grant") end,
          &AccessToken.get_json(&1, "https://api.example.com/v1/items")
        )

      assert {:error, :broker_url_not_allowed} = result
      assert length(BrokerStub.broker_calls(stub)) == 1
    end
  end

  describe "the broker call itself" do
    test "does not retry, verifies TLS, caps the answer and carries no header of the Engine's own" do
      stub = broker([{"example-issued-token-1", 3_600}])
      assert {:ok, _config} = CredentialSource.hydrate(sealed(), @scope)

      assert [call] = BrokerStub.broker_calls(stub)
      assert call.headers == []
      assert call.opts[:follow_redirects] == false
      assert call.opts[:single_attempt] == true
      assert call.opts[:verify_tls] == true
      assert call.opts[:max_body_bytes] in 1..1_048_576
    end
  end

  describe "an answer is believed only when it is a credential" do
    test "a 200 that carries an error is a refusal, whatever else it carries" do
      for body <- [
            %{"error" => "unauthorized"},
            %{"error" => "invalid_request", "error_description" => "no"},
            %{"error" => "x", "credentials" => %{"access_token" => "example-token"}}
          ] do
        broker([{:body, body}])
        assert {:error, :broker_refused} = CredentialSource.hydrate(sealed(), @scope), inspect(body)
      end
    end

    test "an absurd or negative expires_in cannot raise" do
      for seconds <- [1_000_000_000_000_000_000_000_000, -5, 0] do
        broker([
          {:body, %{"credentials" => %{"access_token" => "example-token", "expires_in" => seconds}}}
        ])

        assert {:ok, config} = CredentialSource.hydrate(sealed(), @scope), inspect(seconds)
        assert %AccessToken{expires_at: %DateTime{}} = config["credentials"]["access_token"]
      end
    end
  end

  describe "the sealed reference is bound to its connector" do
    @binding %{id: "miosa:conn_1:gmail"}

    test "opens for the connector it was sealed for" do
      {:ok, sealed} = CredentialSource.seal_reference(@config, @binding)
      refute Map.has_key?(sealed, "broker_reference")

      stub = broker([{"example-issued-token-1", 3_600}])
      assert {:ok, _config} = CredentialSource.hydrate(sealed, @scope)
      assert [%{body: %{"reference" => "conn_1.example-signature"}}] = BrokerStub.broker_calls(stub)
    end

    test "does not open when copied to another connector" do
      {:ok, sealed} = CredentialSource.seal_reference(@config, @binding)
      stub = broker([{"example-issued-token-1", 3_600}])

      assert {:error, :broker_reference_unreadable} =
               CredentialSource.hydrate(sealed, %{@scope | id: "miosa:conn_2:gmail"})

      assert {:error, :broker_reference_unreadable} =
               CredentialSource.hydrate(sealed, Map.delete(@scope, :id))

      assert BrokerStub.broker_calls(stub) == []
    end

    test "opens in whatever workspace the connector is in, so a rename or a move keeps it working" do
      {:ok, sealed} = CredentialSource.seal_reference(@config, @binding)
      stub = broker([{"example-issued-token-1", 3_600}])

      assert {:ok, _config} =
               CredentialSource.hydrate(sealed, %{@scope | workspace_id: "default:renamed"})

      assert [%{body: %{"workspace_id" => "default:renamed"}}] = BrokerStub.broker_calls(stub)
    end

    test "a seal made without a connector is refused, and a plaintext reference is not read" do
      assert_raise FunctionClauseError, fn -> CredentialSource.seal_reference(@config, nil) end

      stub = broker([{"example-issued-token-1", 3_600}])
      assert {:error, :broker_not_configured} = CredentialSource.hydrate(@config, @scope)
      assert BrokerStub.broker_calls(stub) == []
    end

    test "the envelope takes associated data, and an empty one by default" do
      {:ok, envelope} = Credential.encrypt(%{"a" => "b"}, "bound")
      assert {:ok, %{"a" => "b"}} = Credential.decrypt(envelope, "bound")
      assert {:error, :auth_failed} = Credential.decrypt(envelope, "other")
      assert {:error, :auth_failed} = Credential.decrypt(envelope)

      {:ok, plain} = Credential.encrypt(%{"a" => "b"})
      assert {:ok, %{"a" => "b"}} = Credential.decrypt(plain)
      assert {:error, :auth_failed} = Credential.decrypt(plain, "bound")
    end
  end
end
