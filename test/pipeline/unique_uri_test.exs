defmodule OptimalEngine.Pipeline.UniqueUriTest do
  @moduledoc """
  An `optimal://` URI names exactly one context in its workspace.

  The file name of a written signal is `{date}-{title slug}.md`, and the URI is
  derived from the file path. The slug keeps 60 characters, so titles that
  differ only after that, or the same title on the same day, used to give two
  contexts one path: the second ingest overwrote the first file while both rows
  survived under one address.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Pipeline.Intake.Address
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Signal
  alias OptimalEngine.Store

  @occurred ~U[2026-03-01 10:00:00Z]

  # 80 characters every title below starts with: past the 60 the file name keeps.
  @shared "weekly pipeline review " |> String.duplicate(5) |> String.slice(0, 80)

  setup do
    root =
      Path.join(System.tmp_dir!(), "optimal_unique_uri_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(root)
    end)

    %{root: root, ws: "unique-uri-#{System.unique_integer([:positive])}"}
  end

  defp ingest(ws, title, body, extra \\ []) do
    Intake.process(
      body,
      [workspace_id: ws, node: "team", title: title, occurred_at: @occurred] ++ extra
    )
  end

  # The signal contexts written to the team folder (cross-reference copies, if
  # the router adds any, live in other folders).
  defp rows(ws) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, uri, path FROM contexts
        WHERE workspace_id = ?1 AND type = 'signal' AND path LIKE '%/team/signals/%'
        ORDER BY id
        """,
        [ws]
      )

    rows
  end

  defp team_files(root, ws), do: Path.wildcard(Path.join([root, ws, "team", "signals", "*.md"]))

  defp signal(id, title, node \\ "team") do
    %Signal{
      id: id,
      title: title,
      mode: :linguistic,
      genre: "note",
      type: :inform,
      format: :markdown,
      created_at: @occurred,
      modified_at: @occurred,
      node: node,
      sn_ratio: 0.7,
      entities: [],
      l0_summary: "NOTE | #{node} | #{title}",
      l1_description: "Test signal: #{title}",
      content: "Raw content #{id} for #{title}",
      routed_to: []
    }
  end

  describe "intake" do
    test "titles identical for 80 characters then different get different URIs and files", ctx do
      {:ok, a} = ingest(ctx.ws, @shared <> " alpha", "Team sync notes: alpha budget decision")
      {:ok, b} = ingest(ctx.ws, @shared <> " beta", "Team sync notes: beta hiring decision")

      refute a.uri == b.uri

      [file_a] = a.files_written
      [file_b] = b.files_written
      refute file_a == file_b

      assert File.read!(Path.join(ctx.root, file_a)) =~ "alpha budget decision"
      assert File.read!(Path.join(ctx.root, file_b)) =~ "beta hiring decision"

      # One row and one address per context.
      stored = rows(ctx.ws)
      assert length(stored) == 2
      assert stored |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> length() == 2
    end

    test "the same title on the same day is two documents, not one", ctx do
      {:ok, a} = ingest(ctx.ws, "Meeting notes", "Team sync notes: first meeting, budget")
      {:ok, b} = ingest(ctx.ws, "Meeting notes", "Team sync notes: second meeting, hiring")

      refute a.uri == b.uri

      [file_a] = a.files_written
      [file_b] = b.files_written
      assert File.read!(Path.join(ctx.root, file_a)) =~ "first meeting"
      assert File.read!(Path.join(ctx.root, file_b)) =~ "second meeting"
    end

    test "the first context keeps the plain name, the later one gets a suffix from its id",
         ctx do
      {:ok, a} = ingest(ctx.ws, @shared <> " alpha", "Team sync notes: alpha budget decision")
      {:ok, b} = ingest(ctx.ws, @shared <> " beta", "Team sync notes: beta hiring decision")

      id8_a = binary_part(a.signal.id, 0, 8)
      id8_b = binary_part(b.signal.id, 0, 8)

      refute Path.basename(a.uri) =~ id8_a
      assert String.ends_with?(Path.basename(b.uri), "-#{id8_b}.md")

      assert String.starts_with?(
               Path.basename(b.uri),
               Path.basename(a.uri) |> String.trim_trailing(".md")
             )
    end

    test "a context ingested again keeps its URI and its file, on any later day", ctx do
      {:ok, first} =
        ingest(ctx.ws, "Roadmap decision", "Team sync notes: roadmap v1", source_id: "crm:item-9")

      # The next update of the same source item: another day, edited text.
      {:ok, second} =
        Intake.process("Team sync notes: roadmap v2, two phases",
          workspace_id: ctx.ws,
          node: "team",
          title: "Roadmap decision",
          source_id: "crm:item-9"
        )

      assert second.signal.id == first.signal.id
      assert second.uri == first.uri
      assert second.files_written == first.files_written

      [file] = second.files_written
      assert File.read!(Path.join(ctx.root, file)) =~ "roadmap v2"
      assert [[_id, uri, _path]] = rows(ctx.ws)
      assert uri == first.uri

      assert length(team_files(ctx.root, ctx.ws)) == 1
    end

    test "re-ingesting both sides of a collision changes neither address", ctx do
      title = @shared <> " same"

      {:ok, a1} = ingest(ctx.ws, title, "Team sync notes: a, version 1", source_id: "k:a")
      {:ok, b1} = ingest(ctx.ws, title, "Team sync notes: b, version 1", source_id: "k:b")
      refute a1.uri == b1.uri

      {:ok, a2} = ingest(ctx.ws, title, "Team sync notes: a, version 2", source_id: "k:a")
      {:ok, b2} = ingest(ctx.ws, title, "Team sync notes: b, version 2", source_id: "k:b")

      assert a2.uri == a1.uri
      assert b2.uri == b1.uri

      assert File.read!(Path.join(ctx.root, hd(a2.files_written))) =~ "a, version 2"
      assert File.read!(Path.join(ctx.root, hd(b2.files_written))) =~ "b, version 2"
      assert length(rows(ctx.ws)) == 2
    end

    test "cross-reference copies are unique too, and a context ingested again updates its own",
         ctx do
      invoice = fn key, body ->
        Intake.process(body,
          workspace_id: ctx.ws,
          node: "team",
          genre: "invoice",
          title: "Invoice 77",
          occurred_at: @occurred,
          source_id: key
        )
      end

      revenue = fn result ->
        Enum.filter(result.cross_references, &String.contains?(&1, "operation-revenue"))
      end

      {:ok, a1} = invoice.("inv:a", "Invoice 77. Amount: $5,000. Payment due: 2026-04-01. First.")
      {:ok, b1} = invoice.("inv:b", "Invoice 77. Amount: $9,000. Payment due: 2026-05-01. Second.")

      assert [copy_a] = revenue.(a1)
      assert [copy_b] = revenue.(b1)
      refute copy_a == copy_b

      # A copy is named after its primary file, wherever it lands.
      assert Path.basename(copy_a) == Path.basename(hd(a1.files_written))
      assert Path.basename(copy_b) == Path.basename(hd(b1.files_written))
      assert File.read!(Path.join(ctx.root, copy_a)) =~ "First."
      assert File.read!(Path.join(ctx.root, copy_b)) =~ "Second."

      # The row of a copy says whose copy it is.
      {:ok, [[metadata]]} =
        Store.raw_query("SELECT metadata FROM contexts WHERE path = ?1", [
          Path.join(ctx.root, copy_a)
        ])

      assert Jason.decode!(metadata)["cross_ref_of"] == a1.signal.id

      # Ingesting a context again rewrites its copy; it adds none.
      {:ok, a2} = invoice.("inv:a", "Invoice 77. Amount: $5,500. Payment due: 2026-04-01. Edited.")
      assert revenue.(a2) == [copy_a]
      assert File.read!(Path.join(ctx.root, copy_a)) =~ "Edited."

      copies = Path.wildcard(Path.join([ctx.root, ctx.ws, "operation-revenue", "signals", "*.md"]))
      assert length(copies) == 2
    end

    test "a cross-reference copy of a labelled document carries its labels and source package",
         ctx do
      {:ok, labelled} =
        Intake.process("Invoice 78. Amount: $5,000. Payment due: 2026-04-01. Restricted.",
          workspace_id: ctx.ws,
          node: "team",
          genre: "invoice",
          title: "Invoice 78",
          occurred_at: @occurred,
          source_id: "inv:labelled",
          security_labels: ["restricted"]
        )

      assert [copy] =
               Enum.filter(labelled.cross_references, &String.contains?(&1, "operation-revenue"))

      {:ok, [[metadata]]} =
        Store.raw_query("SELECT metadata FROM contexts WHERE path = ?1", [
          Path.join(ctx.root, copy)
        ])

      copy_metadata = Jason.decode!(metadata)
      assert copy_metadata["cross_ref_of"] == labelled.signal.id
      assert copy_metadata["security_labels"] == ["restricted"]
      assert copy_metadata["source_package_id"] == labelled.source_package.id
    end

    test "untitled documents never take the plain name", ctx do
      untitled = fn title, key, body ->
        {:ok, result} = ingest(ctx.ws, title, body, source_id: key)
        result
      end

      first = untitled.("", "u:1", "Team sync notes: untitled one")
      second = untitled.("Untitled", "u:2", "Team sync notes: untitled two")
      third = untitled.("!!!", "u:3", "Team sync notes: untitled three")

      uris = Enum.map([first, second, third], & &1.uri)
      assert uris |> Enum.uniq() |> length() == 3

      for result <- [first, second, third] do
        assert Path.basename(result.uri) =~ ~r/^2026-03-01-untitled-[0-9a-f]{8}\.md$/
        assert Path.basename(result.uri) =~ binary_part(result.signal.id, 0, 8)
      end

      # Ingesting one again changes neither its address nor the others.
      again = untitled.("", "u:1", "Team sync notes: untitled one, edited")
      assert again.uri == first.uri
      assert File.read!(Path.join(ctx.root, hd(again.files_written))) =~ "edited"
      assert length(team_files(ctx.root, ctx.ws)) == 3
    end

    test "a title with no ASCII letters is untitled, not a shared file name", ctx do
      {:ok, a} =
        ingest(ctx.ws, "日本語のタイトル", "Team sync notes: kickoff, first meeting", source_id: "j:1")

      {:ok, b} =
        ingest(ctx.ws, "日本語のタイトル", "Team sync notes: kickoff, second meeting", source_id: "j:2")

      refute a.uri == b.uri

      for result <- [a, b] do
        assert Path.basename(result.uri) =~ ~r/^2026-03-01-untitled-[0-9a-f]{8}\.md$/
      end
    end

    test "writing a repaired context again keeps its record of the repair", ctx do
      {:ok, first} =
        ingest(ctx.ws, "Roadmap", "Team sync notes: roadmap, version one", source_id: "r:1")

      repair = %{"previous_uri" => "optimal://old", "kept_by" => "someone", "repaired_at" => "now"}

      :ok =
        Store.raw_execute("UPDATE contexts SET metadata = ?1 WHERE id = ?2", [
          Jason.encode!(%{"uri_repair" => repair, "other" => "dropped"}),
          first.signal.id
        ])

      Store.evict_cached([first.signal.id])

      {:ok, again} =
        ingest(ctx.ws, "Roadmap", "Team sync notes: roadmap, version two", source_id: "r:1")

      assert again.uri == first.uri

      {:ok, [[metadata]]} =
        Store.raw_query("SELECT metadata FROM contexts WHERE id = ?1", [first.signal.id])

      # The write replaces the metadata (the stray key is gone), keeps the record
      # of the repair, and names the source package of this write.
      assert Jason.decode!(metadata) == %{
               "uri_repair" => repair,
               "source_package_id" => again.source_package.id
             }
    end

    test "the same sequence gives the same URIs in a fresh workspace store", ctx do
      sequence = [
        {@shared <> " alpha", "s:1"},
        {@shared <> " beta", "s:2"},
        {@shared <> " alpha", "s:3"},
        {"Meeting notes", "s:4"},
        {"Meeting notes", "s:5"}
      ]

      run = fn pass ->
        for {title, key} <- sequence do
          {:ok, r} = ingest(ctx.ws, title, "Team sync notes #{key} pass #{pass}", source_id: key)
          r.uri
        end
      end

      wipe = fn ->
        {:ok, ids} = Store.raw_query("SELECT id FROM contexts WHERE workspace_id = ?1", [ctx.ws])
        Enum.each(ids, fn [id] -> :ok = Store.delete_context(id) end)
        File.rm_rf!(Path.join(ctx.root, ctx.ws))
      end

      first = run.(1)
      assert first |> Enum.uniq() |> length() == length(sequence)

      wipe.()
      assert rows(ctx.ws) == []

      assert run.(2) == first
    end
  end

  describe "writer" do
    test "a cross-reference copy never overwrites another signal's file", ctx do
      a = signal("aaaa1111bbbb2222", @shared <> " alpha")
      b = signal("cccc3333dddd4444", @shared <> " alpha")

      {:ok, [path_a]} =
        Writer.write_cross_references(a, ["operation-revenue"], workspace_id: ctx.ws)

      {:ok, [path_b]} =
        Writer.write_cross_references(b, ["operation-revenue"], workspace_id: ctx.ws)

      refute path_a == path_b
      assert File.read!(path_a) =~ "Raw content aaaa1111bbbb2222"
      assert File.read!(path_b) =~ "Raw content cccc3333dddd4444"
    end

    test "the body of a file is what the writer rendered after the frontmatter", ctx do
      s = signal("abab1212abab1212", "Quarterly review")

      assert {:ok, path} = Writer.write_signal(s, workspace_id: ctx.ws)
      text = File.read!(path)

      assert Writer.body_of_file(text) == {:ok, Writer.body(s)}
      assert String.ends_with?(text, Writer.body(s))
      assert Writer.body_of_file("no frontmatter here") == :no_frontmatter
      assert Writer.body_of_file("---\nnever closed\n") == :no_frontmatter

      # A write leaves no temporary file behind.
      assert path |> Path.dirname() |> File.ls!() |> Enum.sort() == [Path.basename(path)]
    end

    test "writing the same signal twice is one file", ctx do
      s = signal("eeee5555ffff6666", "Quarterly review")

      {:ok, first} = Writer.write_signal(s, workspace_id: ctx.ws)
      {:ok, second} = Writer.write_signal(s, workspace_id: ctx.ws)

      assert first == second
      assert Path.wildcard(Path.join([ctx.root, ctx.ws, "**", "*.md"])) == [first]
    end

    test "ids that share their first 8 characters still get different files", ctx do
      ids = ["deadbeef00000001", "deadbeef00000002", "deadbeef00000003"]

      paths =
        for id <- ids do
          {:ok, path} = Writer.write_signal(signal(id, @shared <> " same"), workspace_id: ctx.ws)
          path
        end

      assert paths |> Enum.uniq() |> length() == 3
      assert paths |> Enum.map(&File.read!/1) |> Enum.uniq() |> length() == 3
    end
  end

  describe "Address.choose/3" do
    test "the plain name when nothing holds it" do
      assert Address.choose("2026-03-01-notes.md", "0123456789abcdef", fn _ -> false end) ==
               {:ok, "2026-03-01-notes.md"}
    end

    test "a suffix from the id when the plain name is taken" do
      taken = MapSet.new(["2026-03-01-notes.md"])

      assert Address.choose("2026-03-01-notes.md", "0123456789abcdef", &MapSet.member?(taken, &1)) ==
               {:ok, "2026-03-01-notes-01234567.md"}
    end

    test "a longer suffix when the short one is taken too" do
      taken = MapSet.new(["2026-03-01-notes.md", "2026-03-01-notes-01234567.md"])

      assert Address.choose("2026-03-01-notes.md", "0123456789abcdef", &MapSet.member?(taken, &1)) ==
               {:ok, "2026-03-01-notes-0123456789abcdef.md"}
    end

    test "an untitled document never takes the plain name, even when it is free" do
      assert Address.choose("2026-03-01-untitled.md", "0123456789abcdef", fn _ -> false end,
               always_suffix: true
             ) == {:ok, "2026-03-01-untitled-01234567.md"}

      taken = MapSet.new(["2026-03-01-untitled-01234567.md"])

      assert Address.choose(
               "2026-03-01-untitled.md",
               "0123456789abcdef",
               &MapSet.member?(taken, &1),
               always_suffix: true
             ) == {:ok, "2026-03-01-untitled-0123456789abcdef.md"}
    end

    test "an error, never a name another context holds, when every candidate is taken" do
      assert Address.choose("2026-03-01-notes.md", "0123456789abcdef", fn _ -> true end) ==
               {:error, :no_free_name}

      assert Address.choose("2026-03-01-notes.md", "0123456789abcdef", fn _ -> true end,
               always_suffix: true
             ) == {:error, :no_free_name}
    end

    test "the candidates are 8, 16 and 32 characters of the id, then its SHA-256" do
      id = "0123456789abcdef0123456789abcdef0123"

      assert [short, medium, long, digest] = Address.candidate_suffixes(id)
      assert short == "01234567"
      assert medium == "0123456789abcdef"
      assert long == "0123456789abcdef0123456789abcdef"
      assert digest == :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)

      # An id with no letters or digits falls back to the digest.
      assert [first | _] = Address.candidate_suffixes("---")
      assert byte_size(first) == 8
    end

    test "no double dash when the slug ended on a dash" do
      taken = MapSet.new(["2026-03-01-.md"])

      assert Address.choose("2026-03-01-.md", "0123456789abcdef", &MapSet.member?(taken, &1)) ==
               {:ok, "2026-03-01-01234567.md"}
    end

    test "the answer depends on the name, the id and what is taken, not on the store" do
      sequence = [
        {"2026-03-01-notes.md", "aaaaaaaa11111111"},
        {"2026-03-01-notes.md", "bbbbbbbb22222222"},
        {"2026-03-01-other.md", "cccccccc33333333"},
        {"2026-03-01-notes.md", "dddddddd44444444"}
      ]

      play = fn ->
        Enum.reduce(sequence, {MapSet.new(), []}, fn {name, id}, {taken, out} ->
          {:ok, chosen} = Address.choose(name, id, &MapSet.member?(taken, &1))
          {MapSet.put(taken, chosen), [chosen | out]}
        end)
        |> elem(1)
        |> Enum.reverse()
      end

      store_one = play.()
      store_two = play.()

      assert store_one == store_two
      assert store_one |> Enum.uniq() |> length() == 4
    end
  end

  describe "schema" do
    test "migration 77 indexes the address columns the collision check reads" do
      assert {:ok, [[77]]} =
               Store.raw_query("SELECT version FROM schema_migrations WHERE version = 77", [])

      {:ok, names} =
        Store.raw_query(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'contexts'",
          []
        )

      names = List.flatten(names)
      assert "idx_contexts_ws_uri" in names
      assert "idx_contexts_ws_path" in names
    end
  end
end
