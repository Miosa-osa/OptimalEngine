defmodule OptimalEngine.VersionTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Version

  test "returns one complete release identity" do
    info = Version.info()

    assert info.application == "optimal_engine"
    assert info.version == "0.3.13"
    assert info.release_channel == "dev"
    assert "dev" in Version.release_channels()
    contract = File.read!(Path.expand("../engine-contract.json", __DIR__)) |> Jason.decode!()
    assert info.repository == contract["repository"]
    assert info.contract_version == contract["contract_version"]
    assert info.capabilities == contract["capabilities"]
    # The platform cuts over to the bundle job routes per Engine on this.
    assert "bundle_jobs_v1" in info.capabilities
    # The routes `POST /api/maintenance/graph/backfill` and
    # `POST /api/maintenance/embeddings {"kind": "chunks"}` run durable jobs.
    assert "maintenance_jobs_v1" in info.capabilities
    assert info.version == contract["version"]
    assert info.expected_migration == contract["expected_migration"]
    assert info.git_sha =~ ~r/^(unknown|[0-9a-f]{40})$/
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(info.build_timestamp)
    assert info.api_version == "v1"
    assert info.expected_migration == 86
    assert info.components.evidence_plan == "evidence-plan-v1"
    assert info.components.profile_router == "profile-router-v1"
    assert info.components.candidate_portfolio == "candidate-portfolio-v1"
    assert info.components.associative_projection == "associative-v2"
  end

  test "the runtime channel setting wins, and without it the build's channel is reported" do
    prior = Application.get_env(:optimal_engine, :release_channel)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:optimal_engine, :release_channel, prior),
        else: Application.delete_env(:optimal_engine, :release_channel)
    end)

    Application.put_env(:optimal_engine, :release_channel, "beta")
    assert Version.release_channel() == "beta"

    Application.delete_env(:optimal_engine, :release_channel)
    # Compiled from OPTIMAL_RELEASE_CHANNEL at build time ("dev" in a plain test build).
    assert Version.release_channel() in Version.release_channels()
  end

  test "an unpinned build reports the commit of the checkout it was compiled from" do
    root = Path.expand("..", __DIR__)

    with "" <- System.get_env("OPTIMAL_ENGINE_GIT_SHA", ""),
         {sha, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      assert Version.info().git_sha == String.trim(sha)
    end
  end
end
