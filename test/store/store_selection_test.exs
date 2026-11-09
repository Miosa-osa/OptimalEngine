defmodule OptimalEngine.Store.SelectionTest do
  @moduledoc """
  The canonical store is chosen when the Engine boots, not when it is
  compiled: one build runs SQLite or PostgreSQL by OPTIMAL_STORE.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store

  test "the facade dispatches to the store this Engine was started with" do
    adapter = Application.fetch_env!(:optimal_engine, :store_adapter)
    assert Store.adapter() == adapter
    assert Store.selected?(adapter)

    other =
      if adapter == OptimalEngine.Store.SQLite,
        do: OptimalEngine.Store.Postgres,
        else: OptimalEngine.Store.SQLite

    refute Store.selected?(other)
  end

  # A second node from the same _build, started with the other store's name.
  defp boot_with(store) do
    System.cmd(
      "mix",
      [
        "run",
        "--no-start",
        "--no-compile",
        "-e",
        "IO.write(inspect(OptimalEngine.Store.adapter()))"
      ],
      env: [{"OPTIMAL_STORE", store}, {"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  @tag timeout: 120_000
  test "one build boots either store from OPTIMAL_STORE" do
    assert {out, 0} = boot_with("postgres")
    assert out =~ "OptimalEngine.Store.Postgres"

    assert {out, 0} = boot_with("sqlite")
    assert out =~ "OptimalEngine.Store.SQLite"
  end

  @tag timeout: 120_000
  test "an unknown store name stops the boot" do
    assert {out, status} = boot_with("mysql")
    assert status != 0
    assert out =~ "OPTIMAL_STORE must be sqlite or postgres"
  end
end
