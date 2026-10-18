defmodule Mix.Tasks.OptimalReclassifyModesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.{Context, Signal, Store}
  alias OptimalEngine.Signal.Reclassifier

  @prose "Observed that the nightly export took forty minutes again. Worth checking the index window."
  @csv "date,region,orders\n2026-01-01,north,120\n2026-01-02,south,98\n2026-01-03,east,77"
  @code "defmodule Inventory do\n  def total(items), do: Enum.sum(items)\nend"
  @transcript "Alice: Thanks for joining, we review the import plan.\nBob: Staging is done.\nAlice: Then we require a dry run first."

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "reclassify_modes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{workspace_id: "reclassify-#{System.unique_integer([:positive])}", tmp_dir: tmp_dir}
  end

  # A row as older intake stored it: the bridge's mode and genre.
  defp insert(workspace_id, id, content, mode, genre, path \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    signal = %Signal{
      id: id,
      path: path,
      title: "Signal #{id}",
      mode: mode,
      genre: genre,
      type: :inform,
      format: :markdown,
      structure: "",
      created_at: now,
      modified_at: now,
      node: "inbox",
      sn_ratio: 0.6,
      entities: [],
      l0_summary: "#{String.upcase(genre)} | inbox | Signal #{id} [S/N: 0.6]",
      l1_description: "",
      content: content,
      routed_to: ["inbox"]
    }

    context = %{Context.from_signal(signal) | workspace_id: workspace_id}
    :ok = Store.insert_context(context)
    id
  end

  defp stored(id) do
    {:ok, [[mode, genre, l0]]} =
      Store.raw_query("SELECT mode, genre, l0_abstract FROM contexts WHERE id = ?1", [id])

    {mode, genre, l0}
  end

  defp run_task(args) do
    Mix.Task.reenable("optimal.reclassify_modes")
    capture_io(fn -> Mix.Tasks.Optimal.ReclassifyModes.run(args) end)
  end

  defp seed(%{workspace_id: ws} = ctx) do
    uid = System.unique_integer([:positive])

    engine_file = Path.join(ctx.tmp_dir, "signal.md")

    engine_content = """
    ---
    node: inbox
    title: Weekly notes
    signal:
      mode: code
      genre: chat
      type: inform
      format: markdown
      sn_ratio: 0.6
    tiers:
      l0: "NOTE | inbox | Weekly notes"
      l1: ""
    created_at: "2026-01-01T00:00:00Z"
    ---
    # Weekly notes

    #{@prose}
    """

    File.write!(engine_file, engine_content)

    authored = "---\nsignal:\n  mode: data\n---\n#{@prose}"

    %{
      chat_note: insert(ws, "chat-note-#{uid}", @prose, :code, "chat"),
      csv: insert(ws, "csv-#{uid}", @csv, :code, "note"),
      code: insert(ws, "code-#{uid}", @code, :code, "note"),
      transcript: insert(ws, "transcript-#{uid}", @transcript, :code, "transcript"),
      authored: insert(ws, "authored-#{uid}", authored, :data, "note"),
      engine_file: insert(ws, "engine-#{uid}", engine_content, :code, "chat", engine_file),
      other_ws: insert("other-#{uid}", "other-#{uid}", @prose, :code, "chat"),
      file_path: engine_file
    }
  end

  describe "Reclassifier.reclassify/1" do
    test "recomputes mode from content and only the bridge-default genre" do
      assert %{mode: "linguistic", genre: "note"} =
               Reclassifier.reclassify(%{content: @prose, mode: "code", genre: "chat"})

      assert %{mode: "data", genre: "note"} =
               Reclassifier.reclassify(%{content: @csv, mode: "code", genre: "note"})

      assert %{mode: "linguistic", genre: "transcript"} =
               Reclassifier.reclassify(%{content: @transcript, mode: "code", genre: "transcript"})
    end

    test "keeps an author's declared mode but recomputes an engine-written one" do
      authored = "---\nsignal:\n  mode: data\n---\n#{@prose}"

      assert %{mode: "data"} =
               Reclassifier.reclassify(%{content: authored, mode: "data", genre: "note"})

      engine = "---\nsignal:\n  mode: code\ntiers:\n  l0: x\n---\n#{@prose}"

      assert %{mode: "linguistic"} =
               Reclassifier.reclassify(%{content: engine, mode: "code", genre: "note"})
    end

    test "rewrites only engine-written frontmatter fields" do
      engine = "---\nsignal:\n  mode: code\n  genre: chat\ntiers:\n  l0: x\n---\nbody mode: code\n"
      synced = Reclassifier.sync_frontmatter(engine, "linguistic", "note")
      assert synced =~ "  mode: linguistic\n  genre: note\n"
      assert synced =~ "body mode: code"

      authored = "---\nsignal:\n  mode: code\n---\nbody\n"
      assert Reclassifier.sync_frontmatter(authored, "linguistic", "note") == authored
    end
  end

  describe "mix optimal.reclassify_modes" do
    test "requires a workspace" do
      Mix.Task.reenable("optimal.reclassify_modes")

      assert_raise Mix.Error, ~r/--workspace/, fn ->
        Mix.Tasks.Optimal.ReclassifyModes.run(["--dry-run"])
      end
    end

    test "--dry-run reports the changes and writes nothing", %{workspace_id: ws} = ctx do
      ids = seed(ctx)
      before_file = File.read!(ids.file_path)

      output = run_task(["--workspace", ws, "--dry-run"])

      assert output =~ "Signals scanned: 6"
      assert output =~ "Signals to change: 4"
      assert output =~ "code -> linguistic: 3"
      assert output =~ "code -> data: 1"
      assert output =~ "chat -> note: 2"
      assert output =~ "Dry run: nothing written."

      assert {"code", "chat", _} = stored(ids.chat_note)
      assert {"code", "note", _} = stored(ids.csv)
      assert File.read!(ids.file_path) == before_file
    end

    test "applies the changes to the store and engine-written files", %{workspace_id: ws} = ctx do
      ids = seed(ctx)

      output = run_task(["--workspace", ws])
      assert output =~ "Updated 4 signals and 1 signal files."

      assert {"linguistic", "note", "NOTE | inbox" <> _} = stored(ids.chat_note)
      assert {"data", "note", _} = stored(ids.csv)
      assert {"code", "note", _} = stored(ids.code)
      assert {"linguistic", "transcript", _} = stored(ids.transcript)
      assert {"data", "note", _} = stored(ids.authored)
      assert {"linguistic", "note", _} = stored(ids.engine_file)

      # Other workspaces are untouched.
      assert {"code", "chat", _} = stored(ids.other_ws)

      # The read cache serves the new values.
      assert {:ok, %Context{signal: %Signal{mode: :linguistic, genre: "note"}}} =
               Store.get_context(ids.chat_note)

      file = File.read!(ids.file_path)
      assert file =~ "  mode: linguistic\n  genre: note\n"

      # A second run finds nothing left to change.
      assert run_task(["--workspace", ws, "--dry-run"]) =~ "Signals to change: 0"
    end

    test "--no-files leaves signal files alone", %{workspace_id: ws} = ctx do
      ids = seed(ctx)
      before_file = File.read!(ids.file_path)

      assert run_task(["--workspace", ws, "--no-files"]) =~ "Updated 4 signals and 0 signal files."
      assert File.read!(ids.file_path) == before_file
      assert {"linguistic", "note", _} = stored(ids.engine_file)
    end
  end
end
