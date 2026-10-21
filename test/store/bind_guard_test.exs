defmodule OptimalEngine.Store.BindGuardTest do
  # A request parameter SQLite cannot hold must fail that request only: the
  # Store is one process every tenant's calls go through.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @int64_max 9_223_372_036_854_775_807
  @past_int64 @int64_max + 1

  defp store_pid, do: Process.whereis(OptimalEngine.Store.SQLite)

  # The router answers a server error with 500 and raises it again, so a
  # failed request is either.
  defp request_fails?(conn) do
    Router.call(conn, Router.init([])).status >= 400
  rescue
    _error -> true
  catch
    :exit, _reason -> true
  end

  test "a parameter SQLite cannot hold is an error, and the Store keeps running" do
    store = store_pid()
    assert is_pid(store)

    assert {:error, {:invalid_parameter, _}} = Store.raw_query("SELECT ?1", [@past_int64])
    assert {:error, {:invalid_parameter, _}} = Store.raw_query("SELECT ?1", [-@past_int64 - 1])
    assert {:error, {:invalid_parameter, _}} = Store.raw_query("SELECT ?1", [%{"a" => 1}])
    assert {:error, {:invalid_parameter, _}} = Store.raw_query("SELECT ?1, ?2", [1])

    assert {:error, {:invalid_parameter, _}} =
             Store.raw_execute(
               "UPDATE schema_migrations SET version = version WHERE version = ?1",
               [@past_int64]
             )

    assert store_pid() == store
    assert {:ok, [[@int64_max]]} = Store.raw_query("SELECT ?1", [@int64_max])
  end

  test "an evidence page past the 64-bit range fails the request, not the Store" do
    n = System.unique_integer([:positive])
    tenant = "bind-guard-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Bind guard #{n}"})

    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "owner", scopes: ["*"], workspace_scope: ["*"]})

    store = store_pid()
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      for path <- [
            "/api/authority/evidence?after=#{@past_int64}",
            "/api/authority/evidence/export?after=#{@past_int64}"
          ] do
        assert conn(:get, path)
               |> put_req_header("authorization", "Bearer " <> key)
               |> request_fails?(),
               path
      end
    after
      Application.put_env(:optimal_engine, :auth, original)
    end

    assert store_pid() == store
  end
end
