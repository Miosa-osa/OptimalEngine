defmodule OptimalEngine.Pipeline.IntakeModeTest do
  @moduledoc """
  End-to-end Mode classification through `Intake.process/2`.

  Asserts the mode and genre that land in the `contexts` row, not only what
  the classifier returns, because the Signal Theory bridge runs between
  classification and storage and used to overwrite both.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Store

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("optimal_intake_mode_test_#{:rand.uniform(99_999)}")
    File.mkdir_p!(tmp_dir)

    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, tmp_dir)

    for folder <- ~w[inbox team person-operator project-platform-launch operation-revenue] do
      File.mkdir_p!(Path.join([tmp_dir, folder, "signals"]))
    end

    on_exit(fn ->
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(tmp_dir)
    end)

    %{workspace_id: "intake-mode-#{System.unique_integer([:positive])}"}
  end

  @transcript """
  [00:00:05] Alice: Thanks for joining. We review the migration timeline and the open risks.
  [00:00:21] Bob: The staging cutover is done and production is scheduled for the 14th.
  [00:01:02] Alice: Any blockers on the data export?
  [00:01:15] Carol: The export job needs a larger disk, otherwise we are on track.
  [00:02:40] Alice: Then we require a dry run first and keep the first class support path open.
  """

  @email """
  Subject: Vendor renewal next steps

  Hi team,

  The vendor sent the renewal terms this morning. We need to confirm the seat count by Friday
  and decide whether to keep the premium support tier. I will import the usage numbers into the
  review sheet before our call.

  Best regards,
  Dana
  """

  @chat "hey, can you take a look at the deploy checklist before lunch? thanks!"

  @note """
  Observed that the nightly export took forty minutes again.
  Worth checking whether the index rebuild runs in the same window.
  """

  @spec_md """
  # Export Service Spec

  ## Goal
  Give operators a reliable nightly export of workspace data.

  ## Requirements
  - Exports run once per night and finish within thirty minutes.
  - Each export is a single compressed archive per workspace.
  - Failed exports retry twice before alerting the on-call operator.

  ## Acceptance Criteria
  - [ ] An archive exists for every active workspace each morning.
  - [ ] Alerts fire within five minutes of the final failed retry.
  """

  @source_code """
  import csv


  def load_rows(path):
      with open(path) as handle:
          return list(csv.DictReader(handle))


  def total(rows):
      return sum(float(row["amount"]) for row in rows)
  """

  @csv """
  date,region,orders,revenue
  2026-01-01,north,120,4800.50
  2026-01-01,south,98,3920.00
  2026-01-02,north,131,5240.25
  2026-01-02,south,104,4160.00
  """

  @json ~s({"event": "order.created", "order_id": "ord_1001", "items": [{"sku": "A-1", "qty": 2}], "total": 42.5})

  @cases [
    {"meeting transcript", @transcript, "linguistic"},
    {"email", @email, "linguistic"},
    {"chat message", @chat, "linguistic"},
    {"note", @note, "linguistic"},
    {"markdown spec", @spec_md, "linguistic"},
    {"source code", @source_code, "code"},
    {"CSV table", @csv, "data"},
    {"JSON payload", @json, "data"}
  ]

  for {label, text, expected_mode} <- @cases do
    test "#{label} is stored with mode #{expected_mode}", %{workspace_id: workspace_id} do
      {:ok, result} =
        Intake.process(unquote(text), node: "operator", workspace_id: workspace_id)

      {stored_mode, _genre} = stored_dimensions(result.signal.id)

      assert stored_mode == unquote(expected_mode),
             "#{unquote(label)} stored as #{inspect(stored_mode)}"

      assert to_string(result.signal.mode) == unquote(expected_mode)
    end
  end

  test "a plain note keeps genre note instead of becoming chat", %{workspace_id: workspace_id} do
    {:ok, result} = Intake.process(@note, node: "operator", workspace_id: workspace_id)

    assert {"linguistic", "note"} == stored_dimensions(result.signal.id)
    assert result.signal.genre == "note"
  end

  test "an explicit genre hint is never replaced by the bridge", %{workspace_id: workspace_id} do
    {:ok, result} =
      Intake.process(@chat, node: "operator", genre: "message", workspace_id: workspace_id)

    assert {"linguistic", "message"} == stored_dimensions(result.signal.id)
  end

  defp stored_dimensions(id) do
    {:ok, [[mode, genre]]} =
      Store.raw_query("SELECT mode, genre FROM contexts WHERE id = ?1", [id])

    {mode, genre}
  end
end
