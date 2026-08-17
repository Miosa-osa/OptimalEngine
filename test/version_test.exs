defmodule OptimalEngine.VersionTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Version

  test "returns one complete release identity" do
    info = Version.info()

    assert info.application == "optimal_engine"
    assert info.version == "0.3.0"
    assert info.git_sha =~ ~r/^(unknown|[0-9a-f]{40})$/
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(info.build_timestamp)
    assert info.api_version == "v1"
    assert info.expected_migration == 62
    assert info.components.evidence_plan == "evidence-plan-v1"
    assert info.components.profile_router == "profile-router-v1"
    assert info.components.candidate_portfolio == "candidate-portfolio-v1"
    assert info.components.associative_projection == "associative-v1"
  end
end
