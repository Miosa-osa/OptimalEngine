defmodule OptimalEngine.Imports.Notion.PlanTest do
  @moduledoc """
  Planning a Notion export from its paths (ids, kinds, parents) and resolving
  the links inside its pages. Pure: no store.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Imports.Notion.{Database, Links, Plan}
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  defp plan do
    Fixture.files()
    |> Enum.map(fn {path, _content} -> %{path: path} end)
    |> Plan.build()
  end

  test "pages, databases, assets and litter are told apart; the _all view wins" do
    i = Fixture.ids()
    plan = plan()

    kinds = Map.new(plan.items, &{&1.id, &1.kind})

    assert kinds == %{
             i.handbook => :page,
             i.onboarding => :page,
             i.first_week => :page,
             i.write_guide => :page,
             i.standalone => :page,
             i.tasks => :database
           }

    assert plan.assets == 1
    # .DS_Store and the plain Tasks view
    assert plan.skipped == 2
    assert plan.by_id[i.tasks].path =~ "_all.csv"
    assert plan.by_id[i.tasks].title == "Tasks"
    assert plan.by_id[i.first_week].title == "First Week"
  end

  test "each item's parent is the owner of the nearest folder above it" do
    i = Fixture.ids()
    parents = Map.new(plan().items, &{&1.id, &1.parent})

    assert parents[i.handbook] == nil
    assert parents[i.standalone] == nil
    assert parents[i.onboarding] == i.handbook
    assert parents[i.first_week] == i.onboarding
    assert parents[i.tasks] == i.handbook
    assert parents[i.write_guide] == i.tasks
  end

  test "a folder with no exported page falls back to the next owner up; ids come from names" do
    id = "aaaabbbbccccddddeeeeffff00001111"

    plan =
      Plan.build([
        %{path: "Export Wrapper/Top #{id}.md"},
        %{path: "Export Wrapper/Top #{id}/Orphan Folder/Deep #{String.reverse(id)}.md"},
        %{path: "Export Wrapper/Plan v1.2/No Id Page.md"}
      ])

    parents = Map.new(plan.items, &{&1.title, &1.parent})
    assert parents["Top"] == nil
    assert parents["Deep"] == id
    assert parents["No Id Page"] == nil

    no_id = Enum.find(plan.items, &(&1.title == "No Id Page"))
    assert no_id.id == Plan.path_id("Export Wrapper/Plan v1.2/No Id Page.md")
    assert Plan.id_of("Plan v1.2 #{id}") == id
  end

  test "a second page with the same id is reported, not planned twice" do
    id = "aaaabbbbccccddddeeeeffff00001111"
    plan = Plan.build([%{path: "A #{id}.md"}, %{path: "copy/A #{id}.md"}])

    assert length(plan.items) == 1
    assert [%{"reason" => "duplicate_page", "path" => "copy/A " <> _}] = plan.errors
  end

  test "links resolve by relative path, by notion.so id, and by id when the path is off" do
    i = Fixture.ids()
    plan = plan()
    uri = &"optimal://ws/notion/#{&1}"

    {handbook_path, handbook_text} =
      Enum.find(
        Fixture.files(),
        &String.starts_with?(elem(&1, 0), "Team Handbook #{i.handbook}.md")
      )

    result = Links.rewrite(handbook_text, handbook_path, plan, uri)
    assert result.targets == [i.onboarding, i.tasks]
    assert result.unresolved == 1
    assert result.text =~ "[Onboarding](optimal://ws/notion/#{i.onboarding})"
    assert result.text =~ "[Tasks](optimal://ws/notion/#{i.tasks})"
    assert result.text =~ "(https://example.com/handbook)"
    assert result.text =~ "![diagram](Team%20Handbook%20#{i.handbook}/diagram.png)"

    onboarding_path = "Team Handbook #{i.handbook}/Onboarding #{i.onboarding}.md"
    {_, onboarding_text} = Enum.find(Fixture.files(), &(elem(&1, 0) == onboarding_path))
    result = Links.rewrite(onboarding_text, onboarding_path, plan, uri)
    assert result.targets == [i.handbook]
    assert result.unresolved == 0
    refute result.text =~ "notion.so"

    assert {:ok, id} = Links.resolve("Somewhere%20Else%20#{i.first_week}.md", "x/y", plan)
    assert id == i.first_week
    assert :unresolved == Links.resolve("../../../../outside.md", "a", plan)
    assert :ignore == Links.resolve("mailto:someone@example.com", ".", plan)
    assert :ignore == Links.resolve("#heading", ".", plan)
  end

  test "a database CSV is parsed and rendered as a table; a row without a page has its own text" do
    {:ok, table} =
      Database.parse("\uFEFFName,Status\nWrite guide,Done\n\"Quoted, name\",\"Two\nlines\"\n,\n")

    assert table.columns == ["Name", "Status"]
    assert table.rows == [["Write guide", "Done"], ["Quoted, name", "Two\nlines"]]

    text =
      Database.text(
        "Tasks",
        table,
        fn
          0 -> "optimal://ws/notion/row0"
          _ -> nil
        end,
        100_000
      )

    assert text =~ "# Tasks"
    assert text =~ "Notion database with 2 rows. Columns: Name, Status."
    assert text =~ "| [Write guide](optimal://ws/notion/row0) | Done |"
    assert text =~ "| Quoted, name | Two lines |"

    row = Database.row_text(table.columns, ["Review guide", "Open"], "Tasks", 100_000)
    assert row == "# Review guide\n\nRow of the Notion database Tasks.\n\nStatus: Open"

    assert {:error, :csv_unreadable} = Database.parse("Name\n\"never closed\n")
  end

  test "link matching stays linear on lines built to make a regex backtrack" do
    plan = plan()
    uri = &"optimal://ws/notion/#{&1}"
    mib = 1024 * 1024

    lines = [
      # Many unclosed brackets, then a long run with nothing to close them.
      String.duplicate("[", mib) <> String.duplicate("a", mib),
      # One link whose target never closes.
      "[a link that never closes](" <> String.duplicate("x", 2 * mib),
      # Nested pairs that never close the outer bracket.
      "[" <> String.duplicate("[a]", div(2 * mib, 3)),
      # A long label, then a real link at the end.
      String.duplicate("word ", div(mib, 5)) <> "[Tasks](Tasks%20#{Fixture.ids().tasks}.csv)"
    ]

    for line <- lines do
      task = Task.async(fn -> Links.rewrite(line, "page.md", plan, uri) end)
      assert {:ok, result} = Task.yield(task, 10_000) || Task.shutdown(task), "line did not finish"
      assert byte_size(result.text) > 0
    end

    [last] = Enum.take(lines, -1)
    assert Links.rewrite(last, "page.md", plan, uri).targets == [Fixture.ids().tasks]
  end

  test "a CSV of N + 1 rows is read as N rows and marked as cut" do
    csv = "Name,Status\n" <> Enum.map_join(1..4, "", &"Row #{&1},Open\n")

    assert {:ok, %{rows: rows, truncated: true}} = Database.parse(csv, 3)
    assert Enum.map(rows, &hd/1) == ["Row 1", "Row 2", "Row 3"]

    assert {:ok, %{rows: all, truncated: false}} = Database.parse(csv, 4)
    assert length(all) == 4

    table = %{columns: ["Name", "Status"], rows: rows, truncated: true}
    text = Database.text("Big", table, fn _ -> nil end, 100_000)
    assert text =~ "Notion database with the first 3 rows."
  end

  test "blank rows count toward the scan limit, so a CSV of blank lines stops early" do
    blank = String.duplicate(",\n", Database.scan_limit(10) + 5)
    csv = "Name,Status\n" <> blank <> "Late row,Open\n"

    assert {:ok, %{rows: [], truncated: true}} = Database.parse(csv, 10)

    # Within the limit, blank rows are skipped and the real ones kept.
    assert {:ok, %{rows: [["Row", "Open"]], truncated: false}} =
             Database.parse("Name,Status\n,\n,\nRow,Open\n", 10)
  end

  test "database and row texts are clipped to the page limit on a character boundary" do
    long = String.duplicate("\u00e9", 500)
    table = %{columns: ["Name", "Notes"], rows: [["Row", long]], truncated: false}

    row = Database.row_text(table.columns, ["Row", long], "Tasks", 101)
    assert byte_size(row) <= 101
    assert String.valid?(row)

    text = Database.text("Tasks", table, fn _ -> nil end, 64)
    assert byte_size(text) <= 64
    assert String.valid?(text)
  end
end
