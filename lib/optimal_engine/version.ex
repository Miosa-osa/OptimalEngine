defmodule OptimalEngine.Version do
  @moduledoc """
  Canonical release identity for a running Optimal Engine build.

  The application version comes from the OTP application specification.
  Git and build metadata are captured when this module is compiled, so a
  release reports the code it contains instead of the state of a later checkout.
  """

  alias OptimalEngine.MemoryCore.{AssociativeProjection, EvidencePlan}
  alias OptimalEngine.Retrieval.{CandidatePortfolio, ProfileRouter}
  alias OptimalEngine.Store.Migrations

  @source_root Path.expand("../..", __DIR__)
  @git_sha System.get_env("OPTIMAL_ENGINE_GIT_SHA") ||
             (case System.cmd("git", ["rev-parse", "HEAD"],
                     cd: @source_root,
                     stderr_to_stdout: true
                   ) do
                {sha, 0} -> String.trim(sha)
                _ -> "unknown"
              end)
  @build_timestamp System.get_env("OPTIMAL_ENGINE_BUILD_TIMESTAMP") ||
                     DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec info() :: map()
  def info do
    %{
      application: "optimal_engine",
      version: application_version(),
      git_sha: @git_sha,
      build_timestamp: @build_timestamp,
      api_version: "v1",
      expected_migration: expected_migration(),
      components: %{
        evidence_plan: EvidencePlan.version(),
        profile_router: ProfileRouter.version(),
        candidate_portfolio: CandidatePortfolio.version(),
        associative_projection: AssociativeProjection.version()
      }
    }
  end

  @spec application_version() :: String.t()
  def application_version do
    case Application.spec(:optimal_engine, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp expected_migration do
    Migrations.all()
    |> List.last()
    |> elem(0)
  end
end
