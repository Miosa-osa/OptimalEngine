defmodule OptimalEngine.Store.Postgres.ProofScriptTest do
  @moduledoc """
  The two-engine proof drops the PostgreSQL schema it wrote when it ends, so
  it must only ever use a schema of its own: never the one a real store names
  in OPTIMAL_POSTGRES_SCHEMA, and only a name that starts with oe_proof_.
  These tests run the script's schema check; they need no database.
  """

  use ExUnit.Case, async: true

  @script "scripts/proof-postgres-two-engines.sh"

  defp run(env) do
    System.cmd("bash", [@script, "--print-schema"], env: env, stderr_to_stdout: true)
  end

  test "a real store's schema in OPTIMAL_POSTGRES_SCHEMA is never the proof's" do
    assert {schema, 0} =
             run([{"OPTIMAL_POSTGRES_SCHEMA", "public"}, {"OPTIMAL_PROOF_SCHEMA", nil}])

    assert String.trim(schema) =~ ~r/\Aoe_proof_\d+_\d+\z/
  end

  test "a proof schema that is not named oe_proof_ is refused before anything runs" do
    for name <- ["public", "optimal", "oe_proofx", "oe_proof_X; DROP"] do
      assert {output, 2} = run([{"OPTIMAL_PROOF_SCHEMA", name}])
      assert output =~ "refusing schema"
    end
  end

  test "a proof schema named oe_proof_ is used as given" do
    assert {"oe_proof_given_1\n", 0} = run([{"OPTIMAL_PROOF_SCHEMA", "oe_proof_given_1"}])
  end
end
