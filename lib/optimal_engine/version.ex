defmodule OptimalEngine.Version do
  @moduledoc """
  Canonical release identity for a running Optimal Engine build.

  The application version comes from the OTP application specification.
  Git and build metadata are captured when this module is compiled, so a
  release reports the code it contains instead of the state of a later checkout.
  The release channel is deployment state, read at request time, so an
  operator can start one build on a different channel without rebuilding it.
  """

  alias OptimalEngine.MemoryCore.{AssociativeProjection, EvidencePlan}
  alias OptimalEngine.Retrieval.{CandidatePortfolio, ProfileRouter}
  alias OptimalEngine.Store.Migrations

  @default_release_channel "dev"

  @source_root Path.expand("../..", __DIR__)
  @external_resource Path.join(@source_root, "engine-contract.json")
  @contract @external_resource |> File.read!() |> Jason.decode!()
  # Build-time metadata. A release build sets both variables; an unset or empty
  # variable means the checkout's own commit and the compilation time are used.
  @git_sha (case System.get_env("OPTIMAL_ENGINE_GIT_SHA") do
              value when is_binary(value) and value != "" ->
                value

              _ ->
                case System.cmd("git", ["rev-parse", "HEAD"],
                       cd: @source_root,
                       stderr_to_stdout: true
                     ) do
                  {sha, 0} -> String.trim(sha)
                  _ -> "unknown"
                end
            end)
  @build_timestamp (case System.get_env("OPTIMAL_ENGINE_BUILD_TIMESTAMP") do
                      value when is_binary(value) and value != "" ->
                        value

                      _ ->
                        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                    end)

  @spec info() :: map()
  def info do
    %{
      application: "optimal_engine",
      repository: @contract["repository"],
      contract_version: @contract["contract_version"],
      capabilities: @contract["capabilities"],
      version: application_version(),
      release_channel: release_channel(),
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

  @doc """
  The release channel this Engine serves: `stable`, `beta`, `pinned`, or `dev`.

  Set by `OPTIMAL_RELEASE_CHANNEL`; an unversioned local build reports `dev`.
  An update controller compares this with the channel it intended to run.
  """
  @spec release_channel() :: String.t()
  def release_channel do
    case Application.get_env(:optimal_engine, :release_channel) do
      channel when is_binary(channel) and channel != "" -> channel
      _ -> @default_release_channel
    end
  end

  @doc "Release channels the runtime accepts, plus the unversioned local default."
  @spec release_channels() :: [String.t()]
  def release_channels, do: [@default_release_channel | ~w(stable beta pinned)]

  defp expected_migration do
    Migrations.all()
    |> List.last()
    |> elem(0)
  end
end
