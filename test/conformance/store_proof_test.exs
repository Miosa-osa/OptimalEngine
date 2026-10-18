defmodule OptimalEngine.Conformance.StoreProofTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Conformance

  describe "the store reality proof" do
    test "a proof script that passes becomes one passing check" do
      path =
        write_script("""
        IO.puts(Jason.encode!(%{
          "stores" => [%{"store" => "relational", "status" => "pass", "evidence" => %{}}],
          "catalog_coverage" => %{"catalog_stores" => ["relational"], "proven_stores" => ["relational"], "complete" => true},
          "summary" => %{"stores" => 1, "passed" => 1, "failed" => 0, "providers" => 2, "providers_adapter_missing" => []}
        }))
        """)

      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub,
          store_proof: path
        )

      check = Enum.find(report["checks"], &(&1["id"] == "stores.reality_proof"))

      assert check["status"] == "pass"
      assert check["evidence"]["stores"] == %{"relational" => "pass"}
      assert check["evidence"]["catalog_coverage"]["complete"] == true
    end

    test "a proof script that fails says which store failed" do
      path =
        write_script("""
        IO.puts(Jason.encode!(%{
          "stores" => [
            %{"store" => "relational", "status" => "pass", "evidence" => %{}},
            %{"store" => "secrets", "status" => "fail", "evidence" => %{"error" => "no credential store"}}
          ],
          "catalog_coverage" => %{"complete" => true},
          "summary" => %{"stores" => 2, "passed" => 1, "failed" => 1}
        }))
        System.halt(1)
        """)

      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub,
          store_proof: path
        )

      check = Enum.find(report["checks"], &(&1["id"] == "stores.reality_proof"))

      assert check["status"] == "fail"
      assert check["evidence"]["exit_status"] == 1
      assert [%{"store" => "secrets"}] = check["evidence"]["failing"]
    end

    test "a missing proof script is a failing check, not a skipped one" do
      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub,
          store_proof: "/nonexistent/proof.exs"
        )

      check = Enum.find(report["checks"], &(&1["id"] == "stores.reality_proof"))

      assert check["status"] == "fail"
      assert check["evidence"]["error"] == "no such file"
    end

    test "the check is left out when no proof is named" do
      report =
        Conformance.run(
          url: "http://stub.invalid",
          key: "stub-key",
          transport: OptimalEngine.Conformance.Transport.Stub
        )

      refute Enum.any?(report["checks"], &(&1["id"] == "stores.reality_proof"))
    end
  end

  defp write_script(contents) do
    path =
      Path.join(System.tmp_dir!(), "conformance-proof-#{System.unique_integer([:positive])}.exs")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
