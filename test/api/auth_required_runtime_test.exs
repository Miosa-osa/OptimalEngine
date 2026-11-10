defmodule OptimalEngine.API.AuthRequiredRuntimeTest do
  @moduledoc """
  `auth_required` is set once, at boot (`config/runtime.exs`, from
  `OPTIMAL_AUTH_REQUIRED`), and nothing in the Engine changes it while it
  runs. The AuthPlug, `Actor.engine_admin?/1` and the operator-only routes
  (`/api/metrics/prometheus`, the checks of `/api/health` and `/api/status`)
  read it per request, which is only sound while that holds: a keyless request
  is the local operator exactly when the Engine was started without
  `auth_required`.
  """
  use ExUnit.Case, async: true

  alias OptimalEngine.Release.Maintenance

  @lib Path.expand("../../lib", __DIR__)

  test "no code under lib/ writes the :auth application environment by name" do
    writers =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/Application\.(put_env|put_all_env|delete_env)\b/,
          line =~ ~r/:auth\b/,
          do: "#{Path.relative_to(path, @lib)}:#{n}: #{String.trim(line)}"

    assert writers == []
  end

  # The one place that writes the whole environment back (a maintenance VM,
  # before it starts the Engine with the API off) writes :auth unchanged.
  test "a maintenance VM keeps :auth as it was" do
    env = [auth: [auth_required: true, other: 1], api: [enabled: true, port: 1]]
    assert Keyword.get(Maintenance.quiet(env), :auth) == env[:auth]
  end
end
