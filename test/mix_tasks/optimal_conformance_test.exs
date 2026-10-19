defmodule Mix.Tasks.Optimal.ConformanceTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Auth.ApiKey

  setup do
    original = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, auth_required: true, bcrypt_cost: 4)
    on_exit(fn -> Application.put_env(:optimal_engine, :auth, original) end)

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "conformance-cli-#{System.unique_integer([:positive])}",
        scopes: ["*"],
        workspace_scope: ["*"]
      })

    port = free_port()

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: OptimalEngine.API.Router,
       options: [port: port, ip: {127, 0, 0, 1}, ref: ref()]}
    )

    on_exit(fn -> :ranch.stop_listener(ref()) end)

    {:ok, key: key, url: "http://127.0.0.1:#{port}"}
  end

  test "passes against a live Engine over HTTP", %{key: key, url: url} do
    assert :ok =
             Mix.Tasks.Optimal.Conformance.run([
               "--url",
               url,
               "--key",
               key,
               "--quiet",
               "--prefix",
               "conf-cli"
             ])
  end

  test "fails with a non-zero status when a check fails", %{url: url} do
    assert_raise Mix.Error, ~r/conformance failed/, fn ->
      Mix.Tasks.Optimal.Conformance.run(["--url", url, "--key", "not-a-key", "--quiet"])
    end
  end

  test "reads the key from a file and writes the report to a file", %{key: key, url: url} do
    key_path = Path.join(System.tmp_dir!(), "conformance-key-#{System.unique_integer([:positive])}")

    report_path =
      Path.join(System.tmp_dir!(), "conformance-report-#{System.unique_integer([:positive])}.json")

    File.write!(key_path, key <> "\n")
    on_exit(fn -> File.rm(key_path) end)
    on_exit(fn -> File.rm(report_path) end)

    assert :ok =
             Mix.Tasks.Optimal.Conformance.run([
               "--url",
               url,
               "--key-file",
               key_path,
               "--json",
               report_path,
               "--prefix",
               "conf-file"
             ])

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["summary"]["ok"] == true
    assert report["key_supplied"] == true
    refute File.read!(report_path) =~ key
  end

  test "prints its own usage" do
    assert :ok = Mix.Tasks.Optimal.Conformance.run(["--help"])
  end

  defp ref, do: :"optimal_conformance_task_#{System.unique_integer([:positive])}"

  # A free port on the loopback interface; the window between closing this
  # socket and the listener binding is small and the tests are not parallel.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
