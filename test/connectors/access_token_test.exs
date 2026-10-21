defmodule OptimalEngine.Connectors.AccessTokenTest do
  @moduledoc """
  The bearer token an OAuth connector calls its API with: a token given
  directly, the adapter's own grant, or a token issued by the broker, which is
  renewed before it expires and once after a refusal, and never more.

  The API is the stub in `OptimalEngine.Test.BrokerStub` and the broker is a
  counted renew function, so nothing real is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.AccessToken
  alias OptimalEngine.Test.BrokerStub

  @api "https://api.example.com/v1/items"

  setup do
    {:ok, renewals} = Agent.start(fn -> [] end)
    on_exit(fn -> if Process.alive?(renewals), do: Agent.stop(renewals) end)
    {:ok, renewals: renewals}
  end

  # A broker-issued token whose renewals answer `answers` in order and are counted.
  defp issued(value, expires_in, answers, renewals) do
    {:ok, queue} = Agent.start(fn -> answers end)

    renew = fn ->
      Agent.update(renewals, &[:renewed | &1])

      case Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end) do
        {token, seconds} when is_binary(token) -> {:ok, issued(token, seconds, [], renewals)}
        {:error, reason} -> {:error, reason}
      end
    end

    AccessToken.issued(value, in_seconds(expires_in), renew)
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp renewed(renewals), do: renewals |> Agent.get(& &1) |> length()

  defp ok_api(_url, _opts), do: {200, %{"items" => []}}

  defp no_grant(_state), do: flunk("the grant must not run when a token is given")

  describe "a token given directly" do
    test "is sent as the bearer, and a refusal comes back as it was" do
      stub = BrokerStub.install(nil, api: &ok_api/2, reject: ["direct-token"])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      result =
        AccessToken.session(%{"access_token" => "direct-token"}, &no_grant/1, fn token ->
          AccessToken.get_json(token, @api)
        end)

      assert {:ok, %{status: 401}} = result
      assert BrokerStub.bearers(stub) == ["direct-token"]
    end
  end

  describe "the adapter's own grant" do
    test "runs once per sync and its token is the bearer" do
      stub = BrokerStub.install(nil, api: &ok_api/2)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      parent = self()

      grant = fn _state ->
        send(parent, :granted)
        {:ok, "granted-token"}
      end

      assert {:ok, %{status: 200}} =
               AccessToken.session(%{}, grant, fn token ->
                 {:ok, _} = AccessToken.get_json(token, @api)
                 AccessToken.get_json(token, @api)
               end)

      assert_received :granted
      refute_received :granted
      assert BrokerStub.bearers(stub) == ["granted-token", "granted-token"]
    end

    test "a grant that fails ends the sync before any call" do
      fun = fn _token -> flunk("no call may run after a failed grant") end

      assert {:error, :auth_expired} =
               AccessToken.session(%{}, fn _ -> {:error, :auth_expired} end, fun)
    end

    test "a grant refused by the API is never retried" do
      stub = BrokerStub.install(nil, api: &ok_api/2, reject: ["granted-token"])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:ok, %{status: 401}} =
               AccessToken.session(%{}, fn _ -> {:ok, "granted-token"} end, fn token ->
                 AccessToken.get_json(token, @api)
               end)

      assert length(BrokerStub.api_calls(stub)) == 1
    end
  end

  describe "a token issued by the broker" do
    test "is used as it is while it is valid", %{renewals: renewals} do
      stub = BrokerStub.install(nil, api: &ok_api/2)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{"access_token" => issued("issued-1", 3_600, [], renewals)}

      AccessToken.session(state, &no_grant/1, fn token ->
        for _ <- 1..3, do: {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
      end)

      assert BrokerStub.bearers(stub) == ["issued-1", "issued-1", "issued-1"]
      assert renewed(renewals) == 0
    end

    test "is replaced before a call when it expires within 60 seconds", %{renewals: renewals} do
      stub = BrokerStub.install(nil, api: &ok_api/2)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{"access_token" => issued("issued-short", 30, [{"issued-long", 3_600}], renewals)}

      AccessToken.session(state, &no_grant/1, fn token ->
        {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
        {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
      end)

      assert BrokerStub.bearers(stub) == ["issued-long", "issued-long"]
      assert renewed(renewals) == 1
    end

    test "a replacement that is itself expiring is used without asking again", %{
      renewals: renewals
    } do
      stub = BrokerStub.install(nil, api: &ok_api/2)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{"access_token" => issued("issued-a", 10, [{"issued-b", 10}], renewals)}

      AccessToken.session(state, &no_grant/1, fn token ->
        for _ <- 1..5, do: {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
      end)

      assert renewed(renewals) == 1
      assert Enum.uniq(BrokerStub.bearers(stub)) == ["issued-b"]
    end

    test "a refusal fetches one new token and retries that call", %{renewals: renewals} do
      stub = BrokerStub.install(nil, api: &ok_api/2, reject: ["issued-1"])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{"access_token" => issued("issued-1", 3_600, [{"issued-2", 3_600}], renewals)}

      assert {:ok, %{status: 200}} =
               AccessToken.session(state, &no_grant/1, fn token ->
                 {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
                 AccessToken.get_json(token, @api)
               end)

      # The refused call was retried with the new token, and the next call
      # carried it from the start.
      assert BrokerStub.bearers(stub) == ["issued-1", "issued-2", "issued-2"]
      assert renewed(renewals) == 1
    end

    test "a second refusal fails the sync with :broker_token_rejected", %{renewals: renewals} do
      stub = BrokerStub.install(nil, api: &ok_api/2, reject: ["issued-1", "issued-2"])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{
        "access_token" =>
          issued("issued-1", 3_600, [{"issued-2", 3_600}, {"issued-3", 3_600}], renewals)
      }

      result =
        AccessToken.session(state, &no_grant/1, fn token ->
          assert {:error, :broker_token_rejected} = AccessToken.get_json(token, @api)

          # Later calls answer the same error without touching the network.
          assert {:error, :broker_token_rejected} = AccessToken.get_json(token, @api)
          {:ok, :the_adapter_ignored_the_error}
        end)

      assert result == {:error, :broker_token_rejected}
      assert renewed(renewals) == 1
      assert BrokerStub.bearers(stub) == ["issued-1", "issued-2"]
    end

    test "the one re-fetch is spent: a later refusal fails without asking again", %{
      renewals: renewals
    } do
      stub = BrokerStub.install(nil, api: &ok_api/2, expire: %{"issued-1" => 1, "issued-2" => 1})
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{
        "access_token" =>
          issued("issued-1", 3_600, [{"issued-2", 3_600}, {"issued-3", 3_600}], renewals)
      }

      assert {:error, :broker_token_rejected} =
               AccessToken.session(state, &no_grant/1, fn token ->
                 {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
                 {:ok, %{status: 200}} = AccessToken.get_json(token, @api)
                 AccessToken.get_json(token, @api)
               end)

      assert renewed(renewals) == 1
      assert BrokerStub.bearers(stub) == ["issued-1", "issued-1", "issued-2", "issued-2"]
    end

    test "a broker that cannot answer the re-fetch fails the sync with its reason", %{
      renewals: renewals
    } do
      stub = BrokerStub.install(nil, api: &ok_api/2, reject: ["issued-1"])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{
        "access_token" => issued("issued-1", 3_600, [{:error, :broker_unreachable}], renewals)
      }

      assert {:error, :broker_unreachable} =
               AccessToken.session(state, &no_grant/1, fn token ->
                 AccessToken.get_json(token, @api)
                 {:ok, :swallowed}
               end)

      assert length(BrokerStub.api_calls(stub)) == 1
    end

    test "an early renewal the broker refuses fails the sync before the call", %{
      renewals: renewals
    } do
      stub = BrokerStub.install(nil, api: &ok_api/2)
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      state = %{"access_token" => issued("issued-1", 5, [{:error, :broker_refused}], renewals)}

      assert {:error, :broker_refused} =
               AccessToken.session(state, &no_grant/1, &AccessToken.get_json(&1, @api))

      assert BrokerStub.api_calls(stub) == []
    end

    test "an adapter's own refusal test decides what a refusal is", %{renewals: renewals} do
      stub =
        BrokerStub.install(nil,
          api: &ok_api/2,
          reject: ["issued-1"],
          reject_with: {200, %{"ok" => false, "error" => "invalid_auth"}}
        )

      on_exit(fn -> BrokerStub.uninstall(stub) end)

      refused? = fn
        {:ok, %{body: %{"ok" => false, "error" => "invalid_auth"}}} -> true
        _other -> false
      end

      state = %{"access_token" => issued("issued-1", 3_600, [{"issued-2", 3_600}], renewals)}

      assert {:ok, %{status: 200, body: %{"items" => []}}} =
               AccessToken.session(state, &no_grant/1, fn token ->
                 AccessToken.get_json(token, @api, rejected?: refused?)
               end)

      assert BrokerStub.bearers(stub) == ["issued-1", "issued-2"]
    end
  end

  describe "secrecy and scope" do
    test "inspect shows the source and the expiry, never the value", %{renewals: renewals} do
      token = issued("issued-secret-value", 3_600, [], renewals)

      refute inspect(token) =~ "issued-secret-value"
      refute inspect(%{"access_token" => token, "config" => [token]}) =~ "issued-secret-value"
      assert inspect(token) =~ "broker"
      assert inspect(token) =~ "expires_at"
    end

    test "a session leaves nothing behind in the process, even when the sync raises" do
      before = MapSet.new(Process.get_keys())

      assert_raise RuntimeError, fn ->
        AccessToken.session(%{"access_token" => "direct-token"}, &no_grant/1, fn _token ->
          raise "boom"
        end)
      end

      assert MapSet.new(Process.get_keys()) == before
    end

    test "a session is used from the process that opened it" do
      AccessToken.session(%{"access_token" => "direct-token"}, &no_grant/1, fn token ->
        task = Task.async(fn -> catch_error(AccessToken.get_json(token, @api)) end)
        assert %ArgumentError{} = Task.await(task)
      end)
    end

    test "a state with no access token and a blank grant is missing credentials" do
      assert {:error, {:missing_credentials, [:access_token]}} =
               AccessToken.session(%{}, fn _ -> {:ok, nil} end, fn _ -> :unreachable end)
    end
  end
end
