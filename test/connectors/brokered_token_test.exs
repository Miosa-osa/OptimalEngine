defmodule OptimalEngine.Connectors.BrokeredTokenTest do
  @moduledoc """
  Every adapter that calls its API with a bearer token takes it through
  `OptimalEngine.Connectors.AccessToken`, so each one, given a token issued by
  the broker:

    * calls its API with that token and never runs its own grant
    * survives one refusal with one re-fetch
    * fails a second refusal with `:broker_token_rejected`, whatever it does
      with errors of its own

  and, given a token directly, sends it as it is and maps a refusal as it
  always has. The broker and every API are stubs (`OptimalEngine.Test.BrokerStub`).
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.Gmail
  alias OptimalEngine.Connectors.{CredentialSource, Registry}
  alias OptimalEngine.Test.BrokerStub

  @slack_refusal {200, %{"ok" => false, "error" => "invalid_auth"}}

  # kind => {config, the API's answer (a recorded fixture, or a function), refusal}
  @adapters %{
    gmail: {%{"user_email" => "jane@example.com", "labels" => ["INBOX"]}, :fixture, nil},
    drive: {%{"scope" => "my_drive"}, :fixture, nil},
    notion: {
      %{
        "workspace_name" => "Example Co",
        "database_ids" => ["0a000000-0000-4000-8000-000000000003"]
      },
      :fixture,
      nil
    },
    slack:
      {%{"workspace_id" => "T0EXAMPLE1", "channels" => ["C0EXAMPLE2"]}, :fixture, @slack_refusal},
    dropbox: {%{"namespace" => "personal"}, :dropbox, nil},
    salesforce: {
      %{"instance_url" => "https://example.my.salesforce.com", "objects" => ["Account"]},
      :salesforce,
      nil
    },
    hubspot: {%{"portal_id" => "1234", "objects" => ["contacts"]}, :hubspot, nil},
    onedrive: {%{"tenant_id_ms" => "example-tenant", "drive_id" => "drive-1"}, :onedrive, nil},
    teams: {%{"tenant_id_ms" => "example-tenant", "team_ids" => ["team-1"]}, :teams, nil},
    zoom: {%{"account_id" => "example-account"}, :zoom, nil}
  }

  @scope %{id: "brokered-test", kind: "test", tenant_id: "default", workspace_id: "default"}

  for {kind, {config, answer, refusal}} <- @adapters do
    @kind kind
    @config config
    @answer answer
    @refusal refusal

    describe "#{kind} on a brokered token" do
      test "calls its API with the token and never runs its own grant" do
        stub = install(@kind, @answer, @refusal, issue: [{"example-issued-1", 3_600}])

        assert {:ok, %{signals: _, cursor: _}} = brokered_sync(@kind, @config)

        assert [_ | _] = BrokerStub.api_calls(stub)
        assert Enum.uniq(BrokerStub.bearers(stub)) == ["example-issued-1"]
        assert length(BrokerStub.broker_calls(stub)) == 1
      end

      test "survives one refusal with one re-fetch" do
        stub =
          install(@kind, @answer, @refusal,
            issue: [{"example-issued-1", 3_600}, {"example-issued-2", 3_600}],
            reject: ["example-issued-1"]
          )

        assert {:ok, %{signals: _, cursor: _}} = brokered_sync(@kind, @config)

        assert [{"example-issued-1", _refused} | rest] =
                 Enum.map(BrokerStub.api_calls(stub), &{&1.bearer, &1.status})

        assert Enum.all?(rest, fn {bearer, _status} -> bearer == "example-issued-2" end)
        assert length(BrokerStub.broker_calls(stub)) == 2
      end

      test "fails a second refusal with :broker_token_rejected" do
        stub =
          install(@kind, @answer, @refusal,
            issue: [{"example-issued-1", 3_600}, {"example-issued-2", 3_600}],
            reject: ["example-issued-1", "example-issued-2"]
          )

        assert {:error, :broker_token_rejected} = brokered_sync(@kind, @config)
        assert BrokerStub.bearers(stub) == ["example-issued-1", "example-issued-2"]
        assert length(BrokerStub.broker_calls(stub)) == 2
      end
    end

    describe "#{kind} on a token given directly" do
      test "sends it as it is and maps a refusal as it always has, without a retry" do
        stub = install(@kind, @answer, @refusal, reject: ["example-direct-token"])

        {:ok, mod} = Registry.fetch(@kind)

        {:ok, state} =
          mod.init(Map.put(@config, "credentials", %{"access_token" => "example-direct-token"}))

        assert {:error, :auth_expired} = mod.sync(state, nil)
        assert BrokerStub.bearers(stub) == ["example-direct-token"]
        assert BrokerStub.broker_calls(stub) == []
      end
    end
  end

  # The cursor a second run starts from, and what each API answers it with.
  defp incremental(:gmail) do
    {"900001",
     fn url, _opts ->
       if String.contains?(url, "/history"), do: {200, %{"historyId" => "900002"}}, else: {200, %{}}
     end}
  end

  defp incremental(:drive),
    do: {"page-token-1", fn _url, _opts -> {200, %{"changes" => [], "newStartPageToken" => "page-token-2"}} end}

  defp incremental(:notion),
    do: {"2026-10-01T00:00:00.000Z", fn _url, _opts -> {200, %{"results" => [], "has_more" => false}} end}

  defp incremental(:slack) do
    {Jason.encode!(%{"C0EXAMPLE2" => %{"oldest" => "1790000000.000001"}}),
     fn _url, _opts -> {200, %{"ok" => true, "messages" => [], "has_more" => false}} end}
  end

  defp incremental(:dropbox), do: {"dbx-cursor-1", answer(:dropbox)}
  defp incremental(:salesforce), do: {"2026-10-01T00:00:00.000+0000", answer(:salesforce)}
  defp incremental(:hubspot), do: {"contacts:after-1", answer(:hubspot)}
  defp incremental(:onedrive), do: {"https://graph.microsoft.com/v1.0/delta-0", answer(:onedrive)}
  defp incremental(:teams), do: {"2026-10-01T00:00:00Z", answer(:teams)}
  defp incremental(:zoom), do: {"2026-10-01", answer(:zoom)}

  for kind <- Map.keys(@adapters) do
    @kind kind

    describe "#{kind} on a brokered token, from a cursor" do
      test "calls its API with the token, and a refusal costs one re-fetch" do
        {config, _answer, refusal} = Map.fetch!(@adapters, @kind)
        {cursor, answer} = incremental(@kind)

        stub =
          install_with(answer, refusal,
            issue: [{"example-issued-1", 3_600}, {"example-issued-2", 3_600}],
            reject: ["example-issued-1"]
          )

        assert {:ok, %{signals: _, cursor: _}} = brokered_sync(@kind, config, cursor)

        assert [{"example-issued-1", _refused} | rest] =
                 Enum.map(BrokerStub.api_calls(stub), &{&1.bearer, &1.status})

        assert Enum.all?(rest, fn {bearer, _status} -> bearer == "example-issued-2" end)
        assert length(BrokerStub.broker_calls(stub)) == 2
      end

      test "a second refusal fails the sync with :broker_token_rejected" do
        {config, _answer, refusal} = Map.fetch!(@adapters, @kind)
        {cursor, answer} = incremental(@kind)

        stub =
          install_with(answer, refusal,
            issue: [{"example-issued-1", 3_600}, {"example-issued-2", 3_600}],
            reject: ["example-issued-1", "example-issued-2"]
          )

        assert {:error, :broker_token_rejected} = brokered_sync(@kind, config, cursor)
        assert BrokerStub.bearers(stub) == ["example-issued-1", "example-issued-2"]
        assert length(BrokerStub.broker_calls(stub)) == 2
      end
    end
  end

  describe "a stored connector with its own grant" do
    test "prefers the grant to a stale access token" do
      stub = BrokerStub.install(:gmail, [])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      {:ok, state} =
        Gmail.init(%{
          "user_email" => "jane@example.com",
          "labels" => ["INBOX"],
          "credentials" => %{
            "oauth_refresh_token" => "example-refresh-token",
            "client_id" => "example-client",
            "client_secret" => "example-client-secret",
            "access_token" => "stale-direct-token"
          }
        })

      assert {:ok, %{signals: _, cursor: _}} = Gmail.sync(state, nil)

      bearers = stub |> BrokerStub.bearers() |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert bearers == ["example-gmail-access-token"]
    end

    test "uses its access token when it has no complete grant" do
      stub = BrokerStub.install(:gmail, [])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      {:ok, state} =
        Gmail.init(%{
          "user_email" => "jane@example.com",
          "labels" => ["INBOX"],
          "credentials" => %{"access_token" => "direct-token", "client_id" => "example-client"}
        })

      assert {:ok, %{signals: _, cursor: _}} = Gmail.sync(state, nil)
      assert BrokerStub.bearers(stub) |> Enum.uniq() == ["direct-token"]
    end
  end

  describe "HubSpot's OAuth app" do
    test "exchanges its refresh token once per sync and calls with the result" do
      parent = self()

      api = fn url, opts ->
        if String.contains?(url, "/oauth/v1/token") do
          send(parent, {:token_request, Keyword.get(opts, :body)})
          {200, %{"access_token" => "example-hubspot-token", "expires_in" => 1_800}}
        else
          answer(:hubspot).(url, opts)
        end
      end

      stub = BrokerStub.install(nil, api: api)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      {:ok, mod} = Registry.fetch(:hubspot)

      {:ok, state} =
        mod.init(
          Map.put(elem(@adapters.hubspot, 0), "credentials", %{
            "client_id" => "example-client",
            "client_secret" => "example-client-secret",
            "refresh_token" => "example-refresh-token"
          })
        )

      assert {:ok, %{signals: [], cursor: nil}} = mod.sync(state, nil)

      assert_received {:token_request, body}
      assert URI.decode_query(body)["grant_type"] == "refresh_token"
      assert URI.decode_query(body)["refresh_token"] == "example-refresh-token"
      assert [nil, "example-hubspot-token"] = BrokerStub.bearers(stub)
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp install_with(answer, refusal, opts) do
    opts = if refusal, do: Keyword.put(opts, :reject_with, refusal), else: opts
    stub = BrokerStub.install(nil, Keyword.put(opts, :api, answer))
    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  defp install(kind, answer, refusal, opts) do
    opts = if refusal, do: Keyword.put(opts, :reject_with, refusal), else: opts

    stub =
      case answer do
        :fixture -> BrokerStub.install(kind, opts)
        name -> BrokerStub.install(nil, Keyword.put(opts, :api, answer(name)))
      end

    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  # The broker hands the Runner an issued token; the adapter starts from there.
  defp brokered_sync(kind, config, cursor \\ nil) do
    {:ok, mod} = Registry.fetch(kind)

    broker = %{
      "credential_source" => "broker",
      "broker_url" => BrokerStub.broker_url(),
      "broker_reference" => "conn_example_0001"
    }

    with {:ok, hydrated} <-
           CredentialSource.hydrate(Map.merge(config, broker), Map.put(@scope, :adapter, mod)),
         {:ok, state} <- mod.init(hydrated) do
      mod.sync(state, cursor)
    end
  end

  # The smallest successful answer of each API that has no recording.
  defp answer(:dropbox),
    do: fn _url, _opts -> {200, %{"entries" => [], "cursor" => "dbx-1", "has_more" => false}} end

  defp answer(:salesforce), do: fn _url, _opts -> {200, %{"records" => []}} end
  defp answer(:hubspot), do: fn _url, _opts -> {200, %{"results" => []}} end

  defp answer(:onedrive) do
    fn _url, _opts ->
      {200, %{"value" => [], "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/delta-1"}}
    end
  end

  defp answer(:teams) do
    fn url, _opts ->
      if String.contains?(url, "/messages"),
        do: {200, %{"value" => []}},
        else: {200, %{"value" => [%{"id" => "channel-1"}]}}
    end
  end

  defp answer(:zoom), do: fn _url, _opts -> {200, %{"meetings" => []}} end
end
