defmodule OptimalEngine.API.ClientCompatibilityTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router

  @opts Router.init([])
  @engine OptimalEngine.Version.application_version()

  defp request(method, path, user_agent) do
    conn =
      conn(method, path)
      |> put_req_header("user-agent", user_agent)

    Router.call(conn, @opts)
  end

  defp client_version(major, minor, patch), do: "optimal-cli/#{major}.#{minor}.#{patch}"

  describe "a client on another major version" do
    test "is refused on a data route" do
      [major, minor, patch] = String.split(@engine, ".")
      other_major = String.to_integer(major) + 1

      conn =
        request(
          :get,
          "/api/stats",
          client_version(other_major, String.to_integer(minor), String.to_integer(patch))
        )

      assert conn.status == 426
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"] == "client_incompatible"
      assert body["engine"] == @engine
      assert body["required"] == "major:#{major}"
    end

    test "can still ask what the Engine is, so it can explain itself" do
      [major, minor, patch] = String.split(@engine, ".")
      other_major = String.to_integer(major) + 1

      conn =
        request(
          :get,
          "/api/version",
          client_version(other_major, String.to_integer(minor), String.to_integer(patch))
        )

      assert conn.status == 200
    end
  end

  describe "a client on another minor version" do
    test "is served with an outdated marker" do
      [major, minor, patch] = String.split(@engine, ".")
      other_minor = String.to_integer(minor) + 1

      conn =
        request(
          :get,
          "/api/stats",
          client_version(String.to_integer(major), other_minor, String.to_integer(patch))
        )

      assert conn.status == 200
      assert [header] = get_resp_header(conn, "x-optimal-client-outdated")
      assert header =~ "engine=#{@engine}"
    end
  end

  describe "a matching or absent client" do
    test "a patch difference is silent" do
      [major, minor, patch] = String.split(@engine, ".")
      other_patch = String.to_integer(patch) + 1

      conn =
        request(
          :get,
          "/api/stats",
          client_version(String.to_integer(major), String.to_integer(minor), other_patch)
        )

      assert conn.status == 200
      assert get_resp_header(conn, "x-optimal-client-outdated") == []
    end

    test "no user agent is untouched" do
      conn = Router.call(conn(:get, "/api/stats"), @opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-optimal-client-outdated") == []
    end

    test "an unrelated user agent is untouched" do
      assert request(:get, "/api/stats", "curl/8.4.0").status == 200
    end
  end
end
