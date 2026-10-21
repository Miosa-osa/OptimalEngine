defmodule OptimalEngine.Connectors.BearerReachTest do
  @moduledoc """
  Where an access token may be sent. The two adapters that follow a URL the
  provider or the connector's config names (Salesforce's `instance_url`,
  OneDrive's `nextLink` and `deltaLink`) send it only to the provider's own
  hosts, over https. The provider is a stub (`OptimalEngine.Test.BrokerStub`).
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.{OneDrive, Salesforce}
  alias OptimalEngine.Test.BrokerStub

  defp install(api) do
    stub = BrokerStub.install(nil, api: api)
    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  describe "Salesforce's instance_url" do
    @config %{"objects" => ["Account"], "credentials" => %{"access_token" => "direct-token"}}

    test "must be an https URL on Salesforce's own domains" do
      stub = install(fn _url, _opts -> {200, %{"records" => []}} end)

      for url <- [
            "https://example.my.salesforce.com",
            "https://example.my.salesforce.com/",
            "https://example.lightning.force.com",
            "https://na1.salesforce.com"
          ] do
        assert {:ok, state} = Salesforce.init(Map.put(@config, "instance_url", url)), url
        assert {:ok, %{signals: [], cursor: _}} = Salesforce.sync(state, nil), url
      end

      assert Enum.uniq(BrokerStub.bearers(stub)) == ["direct-token"]
    end

    test "anywhere else is refused before the token is sent" do
      stub = install(fn _url, _opts -> {200, %{"records" => []}} end)

      for url <- [
            "https://evil.example.com",
            "http://example.my.salesforce.com",
            "https://salesforce.com.evil.example",
            "https://evilsalesforce.com",
            "https://example.my.salesforce.com.evil.example",
            "https://example.my.salesforce.com@evil.example",
            "https://example.my.salesforce.com:8443",
            "https://127.0.0.1",
            "example.my.salesforce.com"
          ] do
        assert {:error, {:invalid_config, :instance_url}} =
                 Salesforce.init(Map.put(@config, "instance_url", url)),
               url

        # A state built around init is refused by the sync itself.
        state = %{"instance_url" => url, "objects" => ["Account"], "access_token" => "direct-token"}
        assert {:error, {:invalid_config, :instance_url}} = Salesforce.sync(state, nil), url
      end

      assert BrokerStub.api_calls(stub) == []
    end
  end

  describe "OneDrive's links" do
    @graph "https://graph.microsoft.com/v1.0"

    defp onedrive_state do
      {:ok, state} =
        OneDrive.init(%{
          "tenant_id_ms" => "example-tenant",
          "drive_id" => "drive-1",
          "credentials" => %{"access_token" => "direct-token"}
        })

      state
    end

    test "a nextLink on Graph is followed, with the token" do
      stub =
        install(fn url, _opts ->
          if String.contains?(url, "page=2"),
            do: {200, %{"value" => [], "@odata.deltaLink" => @graph <> "/delta-2"}},
            else: {200, %{"value" => [], "@odata.nextLink" => @graph <> "/next?page=2"}}
        end)

      assert {:ok, %{signals: [], cursor: cursor}} = OneDrive.sync(onedrive_state(), nil)
      assert cursor == @graph <> "/delta-2"
      assert length(BrokerStub.api_calls(stub)) == 2
    end

    test "a nextLink anywhere else is refused, and the token goes only to Graph" do
      for link <- [
            "https://evil.example.net/steal",
            "http://graph.microsoft.com/v1.0/next",
            "https://graph.microsoft.com.evil.example/next",
            "https://graph.microsoft.com@evil.example/next",
            "https://graph.microsoft.com:8443/next"
          ] do
        stub = install(fn _url, _opts -> {200, %{"value" => [], "@odata.nextLink" => link}} end)

        assert {:error, :untrusted_url} = OneDrive.sync(onedrive_state(), nil), link

        assert [%{url: first}] = BrokerStub.api_calls(stub)
        assert String.starts_with?(first, @graph)
      end
    end

    test "a stored delta link anywhere else is refused before any call" do
      stub = install(fn _url, _opts -> {200, %{"value" => []}} end)

      for cursor <- ["https://evil.example.net/delta", "http://graph.microsoft.com/v1.0/delta"] do
        assert {:error, :untrusted_url} = OneDrive.sync(onedrive_state(), cursor), cursor
      end

      assert BrokerStub.api_calls(stub) == []
    end
  end
end
