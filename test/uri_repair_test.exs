defmodule OptimalEngine.UriRepairTest do
  @moduledoc """
  Contexts that already share an `optimal://` URI (written before addresses
  were made unique) are repaired: the earliest keeps the address, the others get
  the suffixed address a new ingest would have received, and every context has
  its own file again.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.UriRepair
  alias OptimalEngine.URI, as: OptimalURI

  setup do
    root = Path.join(System.tmp_dir!(), "optimal_uri_repair_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(root)
    end)

    %{root: root, ws: "uri-repair-#{System.unique_integer([:positive])}"}
  end

  defp signals_dir(root, ws), do: Path.join([root, ws, "team", "signals"])

  # The file a signal would have been written to before the fix.
  defp shared_path(root, ws), do: Path.join(signals_dir(root, ws), "2026-03-01-weekly-review.md")

  defp context(ws, id, path, title, body, minute, routed_to \\ ["team"]) do
    created = DateTime.new!(~D[2026-03-01], Time.new!(10, minute, 0))

    signal = %Signal{
      id: id,
      path: path,
      title: title,
      mode: :linguistic,
      genre: "note",
      type: :inform,
      format: :markdown,
      created_at: created,
      modified_at: created,
      node: "team",
      sn_ratio: 0.7,
      entities: [],
      l0_summary: "NOTE | team | #{title}",
      l1_description: body,
      content: body,
      routed_to: routed_to
    }

    %Context{
      id: id,
      uri: path && OptimalURI.from_path(path),
      type: :signal,
      path: path,
      title: title,
      content: body,
      l0_abstract: signal.l0_summary,
      l1_overview: body,
      signal: signal,
      node: "team",
      sn_ratio: 0.7,
      entities: [],
      created_at: created,
      modified_at: created,
      routed_to: routed_to,
      workspace_id: ws,
      metadata: %{}
    }
  end

  # What the engine wrote to the shared path: the last writer's text.
  defp write_as_last_writer(%Context{} = ctx) do
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, Writer.render(Context.to_signal(ctx)))
  end

  defp seed_collision(ctx) do
    path = shared_path(ctx.root, ctx.ws)

    c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget approved", 0)
    c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "second: hiring paused", 5)
    c3 = context(ctx.ws, "33333333cccccccc", path, "Weekly review", "third: launch moved", 10)

    # Insert out of order: the earliest is decided by time, not by arrival here.
    for c <- [c3, c1, c2], do: :ok = Store.insert_context(c)
    write_as_last_writer(c3)

    %{c1: c1, c2: c2, c3: c3, path: path}
  end

  defp row(id) do
    {:ok, [[uri, path, metadata]]} =
      Store.raw_query("SELECT uri, path, metadata FROM contexts WHERE id = ?1", [id])

    %{uri: uri, path: path, metadata: Jason.decode!(metadata)}
  end

  defp id8(id), do: binary_part(id, 0, 8)

  describe "run/1" do
    test "the earliest keeps the address and the others get suffixed ones", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      shared_uri = OptimalURI.from_path(path)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.contexts == 3
      assert report.kept == 1
      assert report.repaired == 2
      assert report.errors == []

      assert row(c1.id).uri == shared_uri
      assert row(c1.id).path == path

      stem = String.trim_trailing(path, ".md")
      assert row(c2.id).path == "#{stem}-#{id8(c2.id)}.md"
      assert row(c3.id).path == "#{stem}-#{id8(c3.id)}.md"
      assert row(c2.id).uri == OptimalURI.from_path(row(c2.id).path)
      assert String.ends_with?(row(c2.id).uri, "-#{id8(c2.id)}.md")

      uris = for c <- [c1, c2, c3], do: row(c.id).uri
      assert length(Enum.uniq(uris)) == 3
    end

    test "every context has its own file with its own text", ctx do
      %{c1: c1, c2: c2, c3: c3} = seed_collision(ctx)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
      assert report.files_written == 2
      assert report.files_rewritten == 1

      assert File.read!(row(c1.id).path) =~ "first: budget approved"
      assert File.read!(row(c2.id).path) =~ "second: hiring paused"
      assert File.read!(row(c3.id).path) =~ "third: launch moved"

      refute File.read!(row(c1.id).path) =~ "third: launch moved"
    end

    test "the old shared address is kept on each repaired row", ctx do
      %{c1: c1, c2: c2, path: path} = seed_collision(ctx)
      shared_uri = OptimalURI.from_path(path)

      assert {:ok, _report} = UriRepair.run(workspace_id: ctx.ws)

      repair = row(c2.id).metadata["uri_repair"]
      assert repair["previous_uri"] == shared_uri
      assert repair["previous_path"] == path
      assert repair["kept_by"] == c1.id
      assert is_binary(repair["repaired_at"])

      refute Map.has_key?(row(c1.id).metadata, "uri_repair")
    end

    test "a read of the repaired context sees the new address, not a cached one", ctx do
      %{c2: c2} = seed_collision(ctx)
      assert {:ok, %{uri: before_uri}} = Store.get_context(c2.id)

      assert {:ok, _report} = UriRepair.run(workspace_id: ctx.ws)

      assert {:ok, %{uri: after_uri}} = Store.get_context(c2.id)
      refute after_uri == before_uri
      assert after_uri == row(c2.id).uri
    end

    test "a second run finds nothing to do", ctx do
      seed_collision(ctx)

      assert {:ok, %{repaired: 2}} = UriRepair.run(workspace_id: ctx.ws)
      assert {:ok, again} = UriRepair.run(workspace_id: ctx.ws)

      assert again.groups == 0
      assert again.repaired == 0
      assert again.files_written == 0
    end

    test "a dry run reports the plan and changes nothing", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      files_before = Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws, dry_run: true)

      assert report.dry_run
      assert report.groups == 1
      assert report.repaired == 2
      assert report.files_written == 0

      assert Enum.sort(Enum.map(report.changes, & &1.id)) == Enum.sort([c2.id, c3.id])
      assert Enum.all?(report.changes, &(&1.from == OptimalURI.from_path(path)))

      for c <- [c1, c2, c3], do: assert(row(c.id).uri == OptimalURI.from_path(path))
      assert Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*")) == files_before
    end

    test "rows that index the same file are one document, not a collision", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "only one", 0)

      # The indexer names the row of a file by the hash of its path.
      twin_id = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 32)
      twin = context(ctx.ws, twin_id, path, "Weekly review", "only one", 1)

      :ok = Store.insert_context(c1)
      :ok = Store.insert_context(twin)
      write_as_last_writer(c1)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 0
      assert report.repaired == 0
      assert report.skipped_twins == 1
      assert row(twin_id).uri == row(c1.id).uri
    end

    test "a twin row does not hide a real collision next to it", ctx do
      %{c2: c2, path: path} = seed_collision(ctx)
      twin_id = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 32)
      :ok = Store.insert_context(context(ctx.ws, twin_id, path, "Weekly review", "third", 11))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 2
      assert report.skipped_twins == 1
      assert row(twin_id).uri == OptimalURI.from_path(path)
      assert row(c2.id).uri != OptimalURI.from_path(path)
    end

    test "a URI that is not the address of the row's file is left alone and counted", ctx do
      path = Path.join(signals_dir(ctx.root, ctx.ws), "elsewhere.md")
      a = %{context(ctx.ws, "aaaaaaaa11111111", path, "A", "a", 0) | uri: "optimal://custom/shared"}
      b = %{context(ctx.ws, "bbbbbbbb22222222", path, "B", "b", 1) | uri: "optimal://custom/shared"}
      :ok = Store.insert_context(a)
      :ok = Store.insert_context(b)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 0
      assert report.skipped_not_file_addressed == 2
      assert row(a.id).uri == "optimal://custom/shared"
      assert row(b.id).uri == "optimal://custom/shared"
    end

    test "another workspace is not touched", ctx do
      seed_collision(ctx)

      other_ws = "uri-repair-other-#{System.unique_integer([:positive])}"
      other_path = shared_path(ctx.root, other_ws)
      o1 = context(other_ws, "99999999aaaaaaaa", other_path, "Weekly review", "other one", 0)
      o2 = context(other_ws, "88888888bbbbbbbb", other_path, "Weekly review", "other two", 5)
      :ok = Store.insert_context(o1)
      :ok = Store.insert_context(o2)

      assert {:ok, %{repaired: 2}} = UriRepair.run(workspace_id: ctx.ws)

      assert row(o1.id).uri == row(o2.id).uri
    end

    test "a file at the kept address that matches no context is left alone", ctx do
      %{c1: c1, path: path} = seed_collision(ctx)
      File.write!(path, "edited by hand, matches nobody\n")

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 2
      assert report.files_left_alone == 1
      assert File.read!(path) == "edited by hand, matches nobody\n"
      assert row(c1.id).uri == OptimalURI.from_path(path)
    end

    test "a limit separates that many groups and reports the rest", ctx do
      seed_collision(ctx)

      other_path = Path.join(signals_dir(ctx.root, ctx.ws), "2026-03-01-second-review.md")
      o1 = context(ctx.ws, "44444444dddddddd", other_path, "Second review", "one", 0)
      o2 = context(ctx.ws, "55555555eeeeeeee", other_path, "Second review", "two", 5)
      :ok = Store.insert_context(o1)
      :ok = Store.insert_context(o2)
      write_as_last_writer(o2)

      assert {:ok, first} = UriRepair.run(workspace_id: ctx.ws, limit: 1)
      assert first.groups == 1
      assert first.groups_remaining == 1

      assert {:ok, second} = UriRepair.run(workspace_id: ctx.ws, limit: 1)
      assert second.groups == 1
      assert second.groups_remaining == 0

      assert {:ok, third} = UriRepair.run(workspace_id: ctx.ws)
      assert third.groups == 0
      assert third.groups_remaining == 0
    end

    test "contexts with the same title and creation time are told apart by their text", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget approved", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "second: hiring paused", 0)
      for c <- [c1, c2], do: :ok = Store.insert_context(c)

      # The second writer's text is what the kept address holds.
      write_as_last_writer(c2)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_rewritten == 1
      assert File.read!(row(c1.id).path) =~ "first: budget approved"
      refute File.read!(row(c1.id).path) =~ "second: hiring paused"
      assert File.read!(row(c2.id).path) =~ "second: hiring paused"
    end

    test "untitled contexts on one path each get their own file", ctx do
      path = Path.join(signals_dir(ctx.root, ctx.ws), "2026-03-01-untitled.md")
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "", "untitled one: kickoff notes", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "", "untitled two: call summary", 5)
      c3 = context(ctx.ws, "33333333cccccccc", path, "", "untitled three: follow ups", 10)
      for c <- [c1, c2, c3], do: :ok = Store.insert_context(c)
      write_as_last_writer(c3)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.repaired == 2

      for {c, text} <- [
            {c1, "untitled one"},
            {c2, "untitled two"},
            {c3, "untitled three"}
          ] do
        assert File.read!(row(c.id).path) =~ text
      end

      assert [c1, c2, c3] |> Enum.map(&row(&1.id).uri) |> Enum.uniq() |> length() == 3
    end

    test "archived contexts are left alone and do not take a file", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      :ok =
        Store.raw_execute("UPDATE contexts SET archived_at = ?1 WHERE id = ?2", [
          "2026-04-01T00:00:00Z",
          c3.id
        ])

      Store.evict_cached([c3.id])
      files_before = Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.contexts == 2
      assert report.repaired == 1
      assert report.skipped_archived == 1

      assert row(c1.id).uri == OptimalURI.from_path(path)
      assert row(c2.id).uri != OptimalURI.from_path(path)
      assert row(c3.id).uri == OptimalURI.from_path(path)

      assert length(Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))) ==
               length(files_before) + 1
    end

    test "rows with no file or that are not signals are counted, not touched", ctx do
      no_file = %{context(ctx.ws, "aaaaaaaa11111111", nil, "Shared", "a", 0) | uri: "optimal://c/x"}
      also = %{context(ctx.ws, "bbbbbbbb22222222", nil, "Shared", "b", 1) | uri: "optimal://c/x"}

      resource = %{
        context(ctx.ws, "cccccccc33333333", "/tmp/x.md", "R", "c", 2)
        | type: :resource,
          signal: nil,
          uri: "optimal://c/x"
      }

      for c <- [no_file, also, resource], do: :ok = Store.insert_context(c)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 0
      assert report.skipped_no_file == 2
      assert report.skipped_not_signal == 1
    end

    test "cross-reference copies are written again, one per context", ctx do
      path = shared_path(ctx.root, ctx.ws)
      routed = ["team", "operation-revenue"]
      revenue = Path.join([ctx.root, ctx.ws, "operation-revenue", "signals"])
      copy = Path.join(revenue, Path.basename(path))

      c1 =
        context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: invoice one", 0, routed)

      c2 =
        context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "second: invoice two", 5, routed)

      c3 =
        context(
          ctx.ws,
          "33333333cccccccc",
          path,
          "Weekly review",
          "third: invoice three",
          10,
          routed
        )

      for c <- [c1, c2, c3], do: :ok = Store.insert_context(c)
      write_as_last_writer(c3)

      # The copy of the last writer is what was left at the shared name, and the
      # indexer has one row for it.
      File.mkdir_p!(revenue)

      File.write!(
        copy,
        Writer.render(%{Context.to_signal(c3) | node: "operation-revenue"}, cross_ref_from: "team")
      )

      {:ok, _} = OptimalEngine.Pipeline.Indexer.index_file(copy, workspace_id: ctx.ws)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.cross_copies_written == 2
      assert report.cross_copies_rewritten == 1
      assert report.files_regenerated == report.files_written + report.files_rewritten + 3
      assert report.errors == []

      # Each context has a copy under its own file name, holding its own text.
      for {c, text} <- [{c1, "invoice one"}, {c2, "invoice two"}, {c3, "invoice three"}] do
        copy_path = Path.join(revenue, Path.basename(row(c.id).path))
        assert File.read!(copy_path) =~ text

        assert {:ok, [[metadata]]} =
                 Store.raw_query("SELECT metadata FROM contexts WHERE path = ?1", [copy_path])

        assert Jason.decode!(metadata)["cross_ref_of"] == c.id
      end

      assert length(Path.wildcard(Path.join(revenue, "*.md"))) == 3
    end

    test "a context without text is still given its own address and file", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget approved", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "", 5)
      for c <- [c1, c2], do: :ok = Store.insert_context(c)
      write_as_last_writer(c1)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 1
      assert report.without_content == 1
      assert File.exists?(row(c2.id).path)
      assert File.read!(path) =~ "first: budget approved"
    end

    test "the repaired addresses are the ones a new ingest would have chosen", ctx do
      %{c2: c2, path: path} = seed_collision(ctx)

      assert {:ok, _report} = UriRepair.run(workspace_id: ctx.ws)

      expected =
        OptimalEngine.Pipeline.Intake.Address.choose(Path.basename(path), c2.id, fn name ->
          name == Path.basename(path)
        end)

      assert Path.basename(row(c2.id).path) == expected
    end
  end
end
