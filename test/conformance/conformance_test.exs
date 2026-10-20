defmodule OptimalEngine.ConformanceTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Conformance
  alias OptimalEngine.Conformance.{Checks, Client}

  require Logger

  setup do
    original = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, auth_required: true, bcrypt_cost: 4)
    on_exit(fn -> Application.put_env(:optimal_engine, :auth, original) end)

    {:ok, %{id: id, key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "conformance-test-#{System.unique_integer([:positive])}",
        scopes: ["*"],
        workspace_scope: ["*"]
      })

    {:ok, key: key, key_id: id}
  end

  describe "running against this Engine in process" do
    @tag :conformance
    test "every built-in check passes", %{key: key} do
      report =
        Conformance.run(
          url: "http://conformance.invalid",
          key: key,
          transport: OptimalEngine.Conformance.Transport.Plug
        )

      assert report["summary"]["failed"] == 0,
             "failing checks: #{inspect(Enum.filter(report["checks"], &(&1["status"] == "fail")), pretty: true, limit: :infinity)}"

      assert report["summary"]["passed"] + report["summary"]["skipped"] ==
               report["summary"]["checks"]

      assert report["summary"]["ok"] == true
      assert report["engine"]["application"] == "optimal_engine"
      assert report["workspaces"]["created_by_this_run"] != []

      groups = report["checks"] |> Enum.map(& &1["group"]) |> Enum.uniq() |> Enum.sort()

      assert groups ==
               ~w(analyses auth authority cleanup documentation operating scope setup signal storage stores sync version viability)

      assert report["checks"] |> Enum.all?(&is_map(&1["evidence"]))

      stores = Enum.find(report["checks"], &(&1["id"] == "stores.families_reachable"))
      assert stores["status"] == "pass"

      assert stores["evidence"]["declared_by_this_build"] ==
               OptimalEngine.StorageCatalog.family_ids()

      assert stores["evidence"]["declared_by_this_build"] == stores["evidence"]["listed"]
      assert stores["evidence"]["unreachable"] == []
    end

    @tag :conformance
    test "the report never carries the key", %{key: key} do
      report =
        Conformance.run(
          url: "http://conformance.invalid",
          key: key,
          transport: OptimalEngine.Conformance.Transport.Plug
        )

      refute inspect(report) =~ key
      refute Jason.encode!(report) =~ key
    end

    @tag :conformance
    test "a workspace-scoped key is refused on another workspace", %{key: key} do
      report =
        Conformance.run(
          url: "http://conformance.invalid",
          key: key,
          transport: OptimalEngine.Conformance.Transport.Plug
        )

      check = Enum.find(report["checks"], &(&1["id"] == "scope.key_confined_to_workspace"))
      assert check["status"] == "pass"
      assert check["evidence"]["other_workspace"]["status"] == 403
      assert check["evidence"]["own_workspace"]["status"] == 200
      assert check["evidence"]["revocation"]["status"] == 204
    end

    @tag :conformance
    test "the suite archives what it created", %{key: key} do
      report =
        Conformance.run(
          url: "http://conformance.invalid",
          key: key,
          transport: OptimalEngine.Conformance.Transport.Plug
        )

      cleanup = Enum.find(report["checks"], &(&1["id"] == "cleanup.no_leftovers"))
      assert cleanup["status"] == "pass"
      assert Enum.map(cleanup["evidence"]["archived_workspaces"], & &1["status"]) == [204, 204]
      assert cleanup["evidence"]["leftovers"] == %{"workspaces" => [], "keys" => []}
    end
  end

  describe "a wrong Engine" do
    test "fails with the expectation in the evidence" do
      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub
        )

      assert report["summary"]["ok"] == false
      assert report["summary"]["failed"] > 0
      assert report["engine"]["version"] == "0.3.4"

      contract = Enum.find(report["checks"], &(&1["id"] == "version.contract"))
      assert contract["status"] == "fail"
      assert "release_channel" in contract["evidence"]["missing_fields"]

      anonymous = Enum.find(report["checks"], &(&1["id"] == "auth.anonymous_denied"))
      assert anonymous["status"] == "fail"
      # The stub serves the anonymous caller, which is exactly the failure.
      assert anonymous["evidence"]["status"] == 200
      assert anonymous["evidence"]["expectation"] =~ "401"

      assert report["summary"]["groups"]["version"]["failed"] >= 1

      for check <- report["checks"] do
        assert is_binary(check["id"])
        assert is_binary(check["group"])
        assert check["status"] in ["pass", "fail", "skip"]
      end
    end

    test "an Engine that cannot be reached fails every check and still reports" do
      report = Conformance.run(url: "http://127.0.0.1:1", key: nil, timeout: 1_000)

      assert report["summary"]["ok"] == false
      assert report["summary"]["passed"] == 0
      assert report["engine"]["unreachable"]
    end
  end

  describe "extra checks" do
    test "load from a file and run with the suite" do
      path =
        write_extra("""
        [
          %{
            id: "stores.external_proof",
            group: "stores",
            description: "an external store proof runs",
            run: fn _client, _context -> {:ok, %{proved: true}} end
          }
        ]
        """)

      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub,
          extra_checks: path
        )

      check = Enum.find(report["checks"], &(&1["id"] == "stores.external_proof"))
      assert check["status"] == "pass"
      assert check["evidence"] == %{"proved" => true}
    end

    test "a check that raises is reported as a failure, not a crash" do
      path =
        write_extra("""
        [
          %{
            id: "stores.explodes",
            group: "stores",
            description: "a broken check",
            run: fn _client, _context -> raise "boom" end
          }
        ]
        """)

      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub,
          extra_checks: path
        )

      check = Enum.find(report["checks"], &(&1["id"] == "stores.explodes"))
      assert check["status"] == "fail"
      assert check["evidence"]["error"] =~ "boom"
    end

    test "a file that returns something else is one failing check" do
      path = write_extra("1 + 1")
      assert [check] = Checks.external(path)
      assert {:fail, evidence} = check.run.(nil, %{})
      assert evidence.error =~ "expected a list of checks"
    end

    test "a missing file is one failing check" do
      assert [check] = Checks.external("/nonexistent/checks.exs")
      assert {:fail, evidence} = check.run.(nil, %{})
      assert evidence.error == "no such file"
    end
  end

  describe "the client" do
    test "sends the key as a bearer token and never as a query parameter" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, headers: [], body: ~s({"ok": true})}}
      end

      client = %Client{
        url: "http://engine.invalid",
        key: "secret-key",
        transport: transport,
        timeout: 5_000
      }

      assert {:ok, %{status: 200, body: %{"ok" => true}}} =
               Client.get(client, "/api/version", query: [q: "x", limit: 5])

      assert_received {:request, request}
      assert request.url == "http://engine.invalid/api/version?q=x&limit=5"
      assert {"authorization", "Bearer secret-key"} in request.headers
      refute request.url =~ "secret-key"
    end

    test "an anonymous client sends no authorization header" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 401, headers: [], body: ~s({"error": "missing_api_key"})}}
      end

      client = %Client{url: "http://engine.invalid", transport: transport, timeout: 5_000}
      assert {:ok, %{status: 401}} = Client.get(client, "/api/workspaces")
      assert_received {:request, request}
      assert request.headers == []
    end
  end

  defp write_script(contents) do
    path =
      Path.join(System.tmp_dir!(), "conformance-proof-#{System.unique_integer([:positive])}.exs")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_extra(contents) do
    path =
      Path.join(System.tmp_dir!(), "conformance-extra-#{System.unique_integer([:positive])}.exs")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
