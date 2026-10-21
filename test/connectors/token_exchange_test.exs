defmodule OptimalEngine.Connectors.TokenExchangeTest do
  @moduledoc """
  The token exchanges of the OAuth adapters (HubSpot, OneDrive, Salesforce,
  Dropbox, Zoom, Teams): what each puts on the wire, and what an answer other
  than a token becomes. The provider is a stub (`OptimalEngine.Test.BrokerStub`
  over the HTTP mock seam); no real provider is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.{
    Dropbox,
    Drive,
    Gmail,
    HubSpot,
    OneDrive,
    Salesforce,
    Teams,
    Zoom
  }

  alias OptimalEngine.Test.BrokerStub

  @form "application/x-www-form-urlencoded"

  # adapter => {config, credentials, a fragment of the token URL}
  @adapters [
    {HubSpot, %{"portal_id" => "1234", "objects" => ["contacts"]},
     %{
       "client_id" => "example-client",
       "client_secret" => "example&secret=+/",
       "refresh_token" => "example-refresh"
     }, "api.hubapi.com/oauth/v1/token"},
    {OneDrive, %{"tenant_id_ms" => "example-tenant", "drive_id" => "drive-1"},
     %{"client_id" => "example-client", "client_secret" => "example&secret=+/"},
     "login.microsoftonline.com/example-tenant/oauth2/v2.0/token"},
    {Teams, %{"tenant_id_ms" => "example-tenant", "team_ids" => ["team-1"]},
     %{"client_id" => "example-client", "client_secret" => "example&secret=+/"},
     "login.microsoftonline.com/example-tenant/oauth2/v2.0/token"},
    {Salesforce, %{"instance_url" => "https://example.my.salesforce.com", "objects" => ["Account"]},
     %{
       "client_id" => "example-client",
       "client_secret" => "example&secret=+/",
       "refresh_token" => "example-refresh"
     }, "login.salesforce.com/services/oauth2/token"},
    {Dropbox, %{"namespace" => "personal"},
     %{
       "app_key" => "example-client",
       "app_secret" => "example&secret=+/",
       "refresh_token" => "example-refresh"
     }, "api.dropboxapi.com/oauth2/token"}
  ]

  describe "the exchange" do
    for {mod, config, credentials, fragment} <- @adapters do
      @mod mod
      @config config
      @credentials credentials
      @fragment fragment

      test "#{inspect(mod)} posts a form with the client's credentials, encoded" do
        parent = self()

        api = fn url, opts ->
          if String.contains?(url, @fragment) do
            send(parent, {:exchange, opts})
            {200, %{"access_token" => "example-exchanged-token", "expires_in" => 3_600}}
          else
            {200,
             %{
               "value" => [],
               "results" => [],
               "records" => [],
               "entries" => [],
               "has_more" => false
             }}
          end
        end

        install(api)
        sync(@mod, @config, @credentials)

        assert_received {:exchange, opts}
        assert {"content-type", @form} in Keyword.fetch!(opts, :headers)
        assert Keyword.fetch!(opts, :method) == :post

        form = opts |> Keyword.fetch!(:body) |> URI.decode_query()

        assert form["client_secret"] == "example&secret=+/" or
                 form["app_secret"] == "example&secret=+/"

        assert (form["client_id"] || form["app_key"]) == "example-client"
      end

      test "#{inspect(mod)} reads a refused exchange as an expired grant" do
        for status <- [400, 401] do
          install(fn _url, _opts -> {status, %{"error" => "invalid_grant"}} end)
          assert {:error, :auth_expired} = sync(@mod, @config, @credentials), "status #{status}"
        end
      end

      test "#{inspect(mod)} reads a grant that is not valid as expired, and any other 400 by its error code only" do
        for code <- ~w(invalid_grant invalid_client unauthorized_client) do
          install(fn _url, _opts -> {400, %{"error" => code}} end)
          assert {:error, :auth_expired} = sync(@mod, @config, @credentials), code
        end

        install(fn _url, _opts ->
          {400,
           %{"error" => "invalid_request", "error_description" => "client_secret=leaked-detail"}}
        end)

        assert {:error, {:token_error, "invalid_request"}} = sync(@mod, @config, @credentials)

        install(fn _url, _opts -> {400, %{"message" => "no error field"}} end)
        assert {:error, {:token_error, "unknown"}} = sync(@mod, @config, @credentials)
      end

      test "#{inspect(mod)} passes a Retry-After on to the Runner, capped" do
        install(fn _url, _opts -> {429, %{}, [{"retry-after", "2"}]} end)
        assert {:error, {:rate_limited, 2_000}} = sync(@mod, @config, @credentials)

        install(fn _url, _opts -> {429, %{}, [{"retry-after", "86400"}]} end)
        assert {:error, {:rate_limited, 30_000}} = sync(@mod, @config, @credentials)

        install(fn _url, _opts -> {429, %{}, [{"retry-after", "soon"}]} end)
        assert {:error, :rate_limited} = sync(@mod, @config, @credentials)
      end

      test "#{inspect(mod)} reads a throttled exchange as rate limited and a failing one as transient" do
        install(fn _url, _opts -> {429, %{}} end)
        assert {:error, :rate_limited} = sync(@mod, @config, @credentials)

        for status <- [500, 502, 503] do
          install(fn _url, _opts -> {status, %{}} end)
          assert {:error, :transient} = sync(@mod, @config, @credentials), "status #{status}"
        end
      end

      test "#{inspect(mod)} says what it got when the exchange answers something else" do
        install(fn _url, _opts -> {418, %{"error" => "teapot"}} end)
        assert {:error, {:http, 418}} = sync(@mod, @config, @credentials)

        install(fn _url, _opts -> {200, %{"no" => "token"}} end)
        assert {:error, _reason} = sync(@mod, @config, @credentials)
      end
    end
  end

  describe "Zoom's exchange" do
    @zoom_config %{"account_id" => "example account&1"}
    @zoom_credentials %{"client_id" => "example-client", "client_secret" => "example&secret=+/"}

    test "authenticates the client with Basic, names the account in the URL, encoded, and sends a form" do
      parent = self()

      api = fn url, opts ->
        if String.contains?(url, "zoom.us/oauth/token") do
          send(parent, {:exchange, url, opts})
          {200, %{"access_token" => "example-exchanged-token"}}
        else
          {200, %{"meetings" => []}}
        end
      end

      install(api)
      sync(Zoom, @zoom_config, @zoom_credentials)

      assert_received {:exchange, url, opts}
      headers = Keyword.fetch!(opts, :headers)
      assert {"content-type", @form} in headers

      assert {"authorization", "Basic " <> basic} =
               Enum.find(headers, fn {name, _} -> name == "authorization" end)

      assert Base.decode64!(basic) == "example-client:example&secret=+/"
      assert url =~ "grant_type=account_credentials"
      assert url =~ "account_id=example+account%261" or url =~ "account_id=example%20account%261"
    end

    test "reads its failures like the others" do
      for {status, expected} <- [
            {400, :auth_expired},
            {401, :auth_expired},
            {429, :rate_limited},
            {503, :transient}
          ] do
        install(fn _url, _opts -> {status, %{"error" => "invalid_grant"}} end)
        assert {:error, ^expected} = sync(Zoom, @zoom_config, @zoom_credentials), "status #{status}"
      end
    end
  end

  describe "Gmail's and Drive's refresh" do
    @google_credentials %{
      "oauth_refresh_token" => "example-refresh",
      "client_id" => "example-client",
      "client_secret" => "example-secret"
    }
    @google [
      {Gmail, %{"user_email" => "jane@example.com", "labels" => ["INBOX"]}},
      {Drive, %{"scope" => "my_drive"}}
    ]

    for {mod, config} <- @google do
      @mod mod
      @config config

      test "#{inspect(mod)} keeps only the error code of a refused refresh" do
        install(fn _url, _opts ->
          {400,
           %{"error" => "invalid_request", "error_description" => "client_secret=leaked-detail"}}
        end)

        assert {:error, {:token_error, "invalid_request"}} =
                 sync(@mod, @config, @google_credentials)

        install(fn _url, _opts -> {400, %{"message" => "no error field"}} end)
        assert {:error, {:token_error, "unknown"}} = sync(@mod, @config, @google_credentials)
      end

      test "#{inspect(mod)} reads a revoked grant as expired, however Google says it" do
        for {status, code} <- [
              {400, "invalid_grant"},
              {400, "invalid_client"},
              {400, "unauthorized_client"},
              {401, "invalid_client"}
            ] do
          install(fn _url, _opts -> {status, %{"error" => code}} end)

          assert {:error, :auth_expired} = sync(@mod, @config, @google_credentials),
                 "#{status} #{code}"
        end
      end

      test "#{inspect(mod)} passes a Retry-After on to the Runner, capped" do
        install(fn _url, _opts -> {429, %{}, [{"retry-after", "2"}]} end)
        assert {:error, {:rate_limited, 2_000}} = sync(@mod, @config, @google_credentials)

        install(fn _url, _opts -> {429, %{}, [{"retry-after", "86400"}]} end)
        assert {:error, {:rate_limited, 30_000}} = sync(@mod, @config, @google_credentials)

        install(fn _url, _opts -> {429, %{}} end)
        assert {:error, :rate_limited} = sync(@mod, @config, @google_credentials)
      end

      test "#{inspect(mod)} reads a failing refresh as transient and anything else by its status" do
        for status <- [500, 503] do
          install(fn _url, _opts -> {status, %{}} end)
          assert {:error, :transient} = sync(@mod, @config, @google_credentials), "#{status}"
        end

        install(fn _url, _opts -> {418, %{"error" => "teapot"}} end)
        assert {:error, {:http, 418}} = sync(@mod, @config, @google_credentials)
      end
    end
  end

  describe "the error code of a refused exchange" do
    @dropbox_config %{"namespace" => "personal"}
    @dropbox_credentials %{
      "app_key" => "example-client",
      "app_secret" => "example-secret",
      "refresh_token" => "example-refresh"
    }

    test "is kept only if it looks like one" do
      long = String.duplicate("a", 65)

      for {sent, kept} <- [
            {"invalid_request", "invalid_request"},
            {String.duplicate("a", 64), String.duplicate("a", 64)},
            {long, "unknown"},
            {"client_secret=leaked-detail", "unknown"},
            {"Invalid Request", "unknown"},
            {"invalid_request\nx", "unknown"},
            {"", "unknown"}
          ] do
        install(fn _url, _opts -> {400, %{"error" => sent}} end)

        assert {:error, {:token_error, ^kept}} =
                 sync(Dropbox, @dropbox_config, @dropbox_credentials),
               "sent #{inspect(sent)}"
      end
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp install(api) do
    stub = BrokerStub.install(nil, api: api)
    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  defp sync(mod, config, credentials) do
    {:ok, state} = mod.init(Map.put(config, "credentials", credentials))
    mod.sync(state, nil)
  end
end
