defmodule OptimalEngine.Connectors.LegacyIdsTest do
  @moduledoc """
  A connector row an older build wrote may hold an id outside the form ids
  take now, which names no OpenBao path (`CredentialVault.path/2`). Readiness
  counts them (`connector_ids`, a warning with the count and no id), the boot
  logs the count, and `mix optimal.connector invalid-ids` lists them for the
  operator.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors.CredentialVault
  alias OptimalEngine.{Health, Store}

  setup do
    n = System.unique_integer([:positive])
    legacy = "legacy/#{n}/notion"
    good = "notion-legacy-#{n}"

    for id <- [legacy, good] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, 'default', 'default', 'notion', '{}', 0)",
          [id]
        )
    end

    on_exit(fn ->
      Store.raw_query("DELETE FROM connectors WHERE id IN (?1, ?2)", [legacy, good])
    end)

    %{legacy: legacy, good: good}
  end

  test "the invalid ids are found, the valid one is not", ctx do
    assert {:ok, ids} = CredentialVault.invalid_ids()
    assert {"default", ctx.legacy} in ids
    refute {"default", ctx.good} in ids
  end

  test "readiness warns with the count, never an id", ctx do
    report = Health.ready(skip: [:embedder])
    assert {:warn, {:connector_ids_invalid, count}} = report.checks.connector_ids
    assert count >= 1
    refute inspect(report) =~ ctx.legacy
  end

  test "the boot warning names the count, never an id", ctx do
    log = capture_log(fn -> CredentialVault.warn_invalid_ids() end)
    assert log =~ ~r/\d+ connector/
    refute log =~ ctx.legacy
  end

  test "the mix task lists them for the operator", ctx do
    out = capture_io(fn -> Mix.Tasks.Optimal.Connector.run(["invalid-ids"]) end)
    assert out =~ ctx.legacy
    refute out =~ ctx.good
  end
end
