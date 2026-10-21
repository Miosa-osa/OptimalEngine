defmodule OptimalEngine.Conformance.Transport.Stub do
  @moduledoc """
  Answers every request with a canned Engine: a version route that is missing
  part of the release identity, a workspace route that accepts an anonymous
  caller, and 404 for everything else. It exists to prove that the suite fails,
  and says why, when an Engine is wrong. Test support only.
  """

  @behaviour OptimalEngine.Conformance.Transport

  @version %{
    "application" => "optimal_engine",
    "repository" => "example/repository",
    "version" => "0.3.8",
    "git_sha" => String.duplicate("a", 40),
    "api_version" => "v1",
    "contract_version" => 1,
    "expected_migration" => 83,
    "capabilities" => []
  }

  @impl true
  def request(%{method: method, url: url}) do
    case {method, URI.parse(url).path} do
      {:get, "/api/version"} ->
        json(200, @version)

      {:post, "/api/workspaces"} ->
        json(201, %{"id" => "stub-workspace", "slug" => "stub-workspace"})

      {:get, "/api/workspaces"} ->
        json(200, %{"workspaces" => []})

      {:get, "/api/auth/keys"} ->
        json(200, %{"keys" => []})

      {_method, _path} ->
        json(404, %{"error" => "not_found"})
    end
  end

  defp json(status, body),
    do:
      {:ok,
       %{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(body)}}
end
