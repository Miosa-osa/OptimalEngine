defmodule OptimalEngine.UriRepairTest do
  @moduledoc """
  Contexts that already share an `optimal://` URI (written before addresses
  were made unique) are repaired: the earliest keeps the address, the others get
  the suffixed address a new ingest would have received, and every context has
  its own file again, written from its own row.

  The repair is safe to interrupt: the new files and the kept file come first,
  the rows move last, and nothing a person may have edited is replaced.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.UriRepair
  alias OptimalEngine.URI, as: OptimalURI
  alias OptimalEngine.Workspace
  alias OptimalEngine.Workspace.Filesystem

  setup do
    root = Path.join(System.tmp_dir!(), "optimal_uri_repair_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      Application.delete_env(:optimal_engine, :uri_repair_checkpoint)
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(root)
    end)

    %{root: root, ws: "uri-repair-#{System.unique_integer([:positive])}"}
  end

  defp signals_dir(root, ws, folder \\ "team"), do: Path.join([root, ws, folder, "signals"])

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

  # The text of a context as the writer renders it from its stored row.
  defp render_of(id) do
    {:ok, ctx} = Store.get_context(id)
    Writer.render(Context.to_signal(ctx))
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

  defp crash_at(step) do
    Application.put_env(:optimal_engine, :uri_repair_checkpoint, fn
      ^step -> raise "crash at #{step}"
      _ -> :ok
    end)
  end

  defp no_crash, do: Application.delete_env(:optimal_engine, :uri_repair_checkpoint)

  defp journal_entries(report) do
    report.journal
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # Every member's own text is the file at its own address.
  defp assert_everyone_has_their_own_file(contexts) do
    for c <- contexts do
      assert File.read!(row(c.id).path) == render_of(c.id), "the file of #{c.id}"
    end

    uris = Enum.map(contexts, &row(&1.id).uri)
    assert length(Enum.uniq(uris)) == length(uris)
    paths = Enum.map(contexts, &row(&1.id).path)
    assert length(Enum.uniq(paths)) == length(paths)
  end

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
    end

    test "every context has its own file, holding exactly its own text", ctx do
      %{c1: c1, c2: c2, c3: c3} = seed_collision(ctx)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_written == 2
      assert report.files_rewritten == 1
      assert report.backups == 1
      assert report.files_regenerated == 3

      assert_everyone_has_their_own_file([c1, c2, c3])
      assert File.read!(row(c1.id).path) =~ "first: budget approved"
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
      assert again.files_regenerated == 0
    end

    test "the repaired addresses are the ones a new ingest would have chosen", ctx do
      %{c2: c2, path: path} = seed_collision(ctx)

      assert {:ok, _report} = UriRepair.run(workspace_id: ctx.ws)

      {:ok, expected} =
        OptimalEngine.Pipeline.Intake.Address.choose(Path.basename(path), c2.id, fn name ->
          name == Path.basename(path)
        end)

      assert Path.basename(row(c2.id).path) == expected
    end

    test "rows that index the same file are one document, not a collision", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "only one", 0)

      # The indexer names the row of a file by the hash of its path.
      twin_id = OptimalEngine.Pipeline.Intake.Address.file_index_id(path)
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
      twin_id = OptimalEngine.Pipeline.Intake.Address.file_index_id(path)
      :ok = Store.insert_context(context(ctx.ws, twin_id, path, "Weekly review", "third", 11))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 2
      assert report.skipped_twins == 1
      assert row(twin_id).uri == OptimalURI.from_path(path)
      assert row(c2.id).uri != OptimalURI.from_path(path)
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

    test "a limit takes that many groups, and a cursor continues after them", ctx do
      seed_collision(ctx)

      other_path = Path.join(signals_dir(ctx.root, ctx.ws), "2026-03-01-second-review.md")
      o1 = context(ctx.ws, "44444444dddddddd", other_path, "Second review", "one", 0)
      o2 = context(ctx.ws, "55555555eeeeeeee", other_path, "Second review", "two", 5)
      :ok = Store.insert_context(o1)
      :ok = Store.insert_context(o2)
      write_as_last_writer(o2)

      assert {:ok, first} = UriRepair.scan(workspace_id: ctx.ws, limit: 1)
      assert first.groups == 1
      assert first.groups_remaining == 1
      assert is_binary(first.next_after)

      assert {:ok, second} = UriRepair.scan(workspace_id: ctx.ws, limit: 1, after: first.next_after)
      assert second.groups == 1
      assert second.groups_remaining == 0
      assert second.next_after == nil

      pages = [first, second] |> Enum.flat_map(& &1.groups_detail) |> Enum.map(& &1.uri)
      assert length(Enum.uniq(pages)) == 2

      # A real run takes the same pages.
      assert {:ok, run} = UriRepair.run(workspace_id: ctx.ws, limit: 1)
      assert run.groups == 1 and run.groups_remaining == 1
      assert {:ok, last} = UriRepair.run(workspace_id: ctx.ws, limit: 1)
      assert last.groups == 1 and last.groups_remaining == 0
      assert {:ok, %{groups: 0}} = UriRepair.run(workspace_id: ctx.ws)
    end
  end

  describe "the plan" do
    test "reads and plans, and changes nothing", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      files_before = Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))
      kept_before = File.read!(path)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws, dry_run: true)

      assert report.dry_run
      assert report.journal == nil
      assert report.groups == 1
      assert report.repaired == 2
      assert report.files_written == 0
      assert report.files_regenerated == 0

      for c <- [c1, c2, c3], do: assert(row(c.id).uri == OptimalURI.from_path(path))
      assert Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*")) == files_before
      assert File.read!(path) == kept_before
      refute File.exists?(Path.join(ctx.root, ".system"))
    end

    test "says, per workspace, what would be written, replaced and left alone", ctx do
      %{c1: c1, c2: c2, c3: c3} = seed_collision(ctx)

      assert {:ok, report} = UriRepair.scan(workspace_id: ctx.ws)

      kept_bytes = byte_size(render_of(c1.id))
      new_bytes = byte_size(render_of(c2.id)) + byte_size(render_of(c3.id))

      assert report.files_to_write == 2
      assert report.files_to_rewrite == 1
      assert report.files_left_alone == 0
      assert report.bytes_to_write == kept_bytes + new_bytes

      assert [workspace] = report.workspaces
      assert workspace.workspace_id == ctx.ws
      assert workspace.groups == 1
      assert workspace.contexts_to_repair == 2
      assert workspace.files_to_write == 2
      assert workspace.files_to_rewrite == 1
      assert workspace.files_left_alone == 0
      assert workspace.bytes_to_write == report.bytes_to_write
    end

    test "says, per group, who keeps the address and where each other context goes", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      assert {:ok, %{groups_detail: [group]}} = UriRepair.scan(workspace_id: ctx.ws)

      assert group.status == "repair"
      assert group.uri == OptimalURI.from_path(path)

      assert group.keeper == %{
               id: c1.id,
               title: "Weekly review",
               path: path,
               uri: OptimalURI.from_path(path),
               uri_differs_from_path: false
             }

      assert [m2, m3] = group.contexts
      assert m2.id == c2.id and m3.id == c3.id

      for {m, c} <- [{m2, c2}, {m3, c3}] do
        assert m.from_uri == OptimalURI.from_path(path)
        assert m.from_path == path
        assert m.to_path == String.replace_suffix(path, ".md", "-#{id8(c.id)}.md")
        assert m.to_uri == OptimalURI.from_path(m.to_path)
        assert m.bytes == byte_size(render_of(c.id))
        assert m.sha256 == OptimalEngine.AtomicFile.sha256(render_of(c.id))
        assert m.file == "absent"
        assert m.uri_differs_from_path == false
        assert m.acl_rows == 0
      end
    end

    test "explains every case where the kept file is replaced or left alone", ctx do
      %{c3: c3, path: path} = seed_collision(ctx)

      # The file holds the last writer's text: replaced, and the reason names it.
      assert {:ok, %{groups_detail: [%{kept_file: kept}]}} = UriRepair.scan(workspace_id: ctx.ws)
      assert kept.action == "rewrite"
      assert kept.holds == c3.id
      assert kept.reason =~ c3.id
      assert kept.path == path

      # A body that is the text of no context: left alone, and why.
      File.write!(path, "---\nnode: team\n---\n\n# Weekly review\n\nedited by hand\n")
      assert {:ok, %{groups_detail: [%{kept_file: edited}]}} = UriRepair.scan(workspace_id: ctx.ws)
      assert edited.action == "left_alone"
      assert edited.reason =~ "no context"

      # No frontmatter: left alone.
      File.write!(path, "just text\n")
      assert {:ok, %{groups_detail: [%{kept_file: plain}]}} = UriRepair.scan(workspace_id: ctx.ws)
      assert plain.action == "left_alone"
      assert plain.reason =~ "frontmatter"

      # No file: created. The keeper's own text: nothing to do.
      File.rm!(path)
      assert {:ok, %{groups_detail: [%{kept_file: missing}]}} = UriRepair.scan(workspace_id: ctx.ws)
      assert missing.action == "create"

      File.write!(path, render_of("11111111aaaaaaaa"))
      assert {:ok, %{groups_detail: [%{kept_file: own}]}} = UriRepair.scan(workspace_id: ctx.ws)
      assert own.action == "unchanged"
    end

    test "counts the records that name the shared URI", ctx do
      %{c2: c2, path: path} = seed_collision(ctx)
      shared_uri = OptimalURI.from_path(path)

      :ok =
        Store.raw_execute(
          "INSERT INTO acls (tenant_id, resource_uri, principal_id, permission) VALUES ('default', ?1, 'user:ann', 'read')",
          [shared_uri]
        )

      :ok =
        Store.raw_execute(
          "INSERT INTO events (tenant_id, principal, kind, target_uri) VALUES ('default', 'user:ann', 'read', ?1)",
          [shared_uri]
        )

      :ok =
        Store.raw_execute(
          "INSERT INTO open_loops (id, tenant_id, workspace_id, kind, title, fingerprint, source_uri, source_context_id) VALUES ('loop-1', 'default', ?1, 'follow_up', 'Call', 'fp-1', ?2, ?3)",
          [ctx.ws, shared_uri, c2.id]
        )

      assert {:ok, %{groups_detail: [group]}} = UriRepair.scan(workspace_id: ctx.ws)

      assert group.references == %{
               acls: 1,
               memories: 0,
               open_loops: 1,
               events: 1,
               wiki_citations: 0
             }

      assert Enum.all?(group.contexts, &(&1.acl_rows == 1))
    end

    test "a group in which a context has no text is skipped, and says which", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget approved", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "", 5)
      c3 = context(ctx.ws, "33333333cccccccc", path, "Weekly review", "third: launch moved", 10)
      for c <- [c1, c2, c3], do: :ok = Store.insert_context(c)
      write_as_last_writer(c3)
      files_before = Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.groups_skipped_empty_content == 1
      assert report.repaired == 0
      assert [%{status: "skipped", empty_contexts: [empty], reason: reason}] = report.groups_detail
      assert empty == c2.id
      assert reason =~ c2.id

      for c <- [c1, c2, c3], do: assert(row(c.id).uri == OptimalURI.from_path(path))
      assert Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*")) == files_before
      assert File.read!(path) == render_of(c3.id)
    end
  end

  describe "the kept file" do
    test "a body edited by hand is never replaced, even with the title and time of a member",
         ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      # The frontmatter is c3's, the body is not.
      edited =
        String.replace(
          render_of(c3.id),
          "third: launch moved",
          "third: launch moved, and then some"
        )

      File.write!(path, edited)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_left_alone == 1
      assert report.files_rewritten == 0
      assert report.backups == 0
      assert File.read!(path) == edited
      assert_everyone_has_their_own_file([c2, c3])
      assert row(c1.id).path == path
      assert [%{kept_file: %{action: "left_alone"}}] = report.groups_detail
    end

    test "when the keeper wrote last there is nothing to replace", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      File.write!(path, render_of(c1.id))
      before_bytes = File.read!(path)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_already_correct == 1
      assert report.files_rewritten == 0
      assert report.backups == 0
      assert File.read!(path) == before_bytes
      assert_everyone_has_their_own_file([c1, c2, c3])
    end

    test "a missing file is created from the keeper's row, with no backup", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      File.rm!(path)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_written == 3
      assert report.backups == 0
      assert_everyone_has_their_own_file([c1, c2, c3])
    end

    test "the old bytes are copied to a backup before the file is replaced", ctx do
      %{c3: c3, path: path} = seed_collision(ctx)
      old_bytes = File.read!(path)
      old_sha = OptimalEngine.AtomicFile.sha256(old_bytes)
      assert old_bytes == render_of(c3.id)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.backups == 1

      backup =
        Path.join([Path.dirname(report.journal), "backups", "#{old_sha}-#{Path.basename(path)}"])

      assert File.read!(backup) == old_bytes
      assert File.read!(path) != old_bytes
    end

    test "the keeper's cross-reference copy that holds another text is replaced, with a backup",
         ctx do
      path = shared_path(ctx.root, ctx.ws)
      routed = ["team", "operation-revenue"]
      revenue = signals_dir(ctx.root, ctx.ws, "operation-revenue")
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

      # What was left at the shared name is the last writer's copy, and the
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
      assert report.backups == 2
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

    test "the cross-reference copies of a labelled context are as labelled as it is", ctx do
      path = shared_path(ctx.root, ctx.ws)
      routed = ["team", "operation-revenue"]
      revenue = signals_dir(ctx.root, ctx.ws, "operation-revenue")
      labels = %{"security_labels" => ["restricted"], "source_package_id" => "sp-77"}

      c1 =
        context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: invoice one", 0, routed)

      c2 =
        %{
          context(
            ctx.ws,
            "22222222bbbbbbbb",
            path,
            "Weekly review",
            "second: invoice two",
            5,
            routed
          )
          | metadata: labels
        }

      for c <- [c1, c2], do: :ok = Store.insert_context(c)
      write_as_last_writer(c2)

      assert {:ok, %{errors: []}} = UriRepair.run(workspace_id: ctx.ws)

      copy_path = Path.join(revenue, Path.basename(row(c2.id).path))

      assert {:ok, [[metadata]]} =
               Store.raw_query("SELECT metadata FROM contexts WHERE path = ?1", [copy_path])

      copy = Jason.decode!(metadata)
      assert copy["cross_ref_of"] == c2.id
      assert copy["security_labels"] == ["restricted"]
      assert copy["source_package_id"] == "sp-77"
    end

    test "a text that only a context moved by an earlier run holds is still recognised", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      # An earlier run moved c3 away (its file, its row) and stopped there.
      c3_path = String.replace_suffix(path, ".md", "-#{id8(c3.id)}.md")
      File.write!(c3_path, render_of(c3.id))

      :ok =
        Store.raw_execute(
          "UPDATE contexts SET uri = ?1, path = ?2, metadata = ?3 WHERE id = ?4",
          [
            OptimalURI.from_path(c3_path),
            c3_path,
            Jason.encode!(%{"uri_repair" => %{"kept_by" => c1.id, "previous_uri" => "x"}}),
            c3.id
          ]
        )

      Store.evict_cached([c3.id])

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.repaired == 1
      assert report.files_rewritten == 1
      assert_everyone_has_their_own_file([c1, c2, c3])
    end
  end

  describe "contexts that need care" do
    test "contexts with the same title and creation time are told apart by their text", ctx do
      path = shared_path(ctx.root, ctx.ws)
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget approved", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "second: hiring paused", 0)
      for c <- [c1, c2], do: :ok = Store.insert_context(c)
      write_as_last_writer(c2)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_rewritten == 1
      assert_everyone_has_their_own_file([c1, c2])
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
      assert_everyone_has_their_own_file([c1, c2, c3])
    end

    test "a title with no ASCII letters is repaired like any other", ctx do
      path = Path.join(signals_dir(ctx.root, ctx.ws), "2026-03-01-.md")
      c1 = context(ctx.ws, "11111111aaaaaaaa", path, "日本語のタイトル", "first: kickoff", 0)
      c2 = context(ctx.ws, "22222222bbbbbbbb", path, "日本語のタイトル", "second: review", 5)
      for c <- [c1, c2], do: :ok = Store.insert_context(c)
      write_as_last_writer(c2)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 1
      assert_everyone_has_their_own_file([c1, c2])
      assert Path.basename(row(c2.id).path) == "2026-03-01-#{id8(c2.id)}.md"
    end

    test "archived contexts are left alone, even when one wrote the kept file last", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      :ok =
        Store.raw_execute("UPDATE contexts SET archived_at = ?1 WHERE id = ?2", [
          "2026-04-01T00:00:00Z",
          c3.id
        ])

      Store.evict_cached([c3.id])
      files_before = length(Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*")))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.groups == 1
      assert report.contexts == 2
      assert report.repaired == 1
      assert report.skipped_archived == 1

      assert row(c1.id).uri == OptimalURI.from_path(path)
      assert row(c2.id).uri != OptimalURI.from_path(path)
      assert row(c3.id).uri == OptimalURI.from_path(path)

      # c3 wrote last: its text is replaced by c1's, after a backup, and c3 gets no new file.
      assert report.files_rewritten == 1
      assert report.backups == 1
      assert File.read!(path) == render_of(c1.id)

      assert length(Path.wildcard(Path.join(signals_dir(ctx.root, ctx.ws), "*"))) ==
               files_before + 1
    end

    test "a stored URI that is not the address of the path is repaired, and listed", ctx do
      a_path = Path.join(signals_dir(ctx.root, ctx.ws, "team"), "2026-03-01-x.md")
      b_path = Path.join(signals_dir(ctx.root, ctx.ws, "ops"), "2026-03-01-x.md")
      old_uri = "optimal://nodes/x/2026-03-01-x.md"

      a = %{context(ctx.ws, "aaaaaaaa11111111", a_path, "X", "from team", 0) | uri: old_uri}
      b = %{context(ctx.ws, "bbbbbbbb22222222", b_path, "X", "from ops", 5) | uri: old_uri}
      for c <- [a, b], do: :ok = Store.insert_context(c)
      File.mkdir_p!(Path.dirname(a_path))
      File.mkdir_p!(Path.dirname(b_path))
      File.write!(a_path, render_of(a.id))
      File.write!(b_path, render_of(b.id))

      assert {:ok, %{groups_detail: [group]} = plan} = UriRepair.scan(workspace_id: ctx.ws)
      assert plan.uri_differs_from_path == 2
      assert group.keeper.uri_differs_from_path

      assert [%{uri_differs_from_path: true, uri_differs_reason: reason, old_file_stays: true}] =
               group.contexts

      assert reason =~ "not the address of its path"
      # Its file in the other folder is not the kept file: the plan says it stays.
      assert plan.old_files_left_in_place == 1
      assert [%{old_files_left_in_place: 1}] = plan.workspaces

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.repaired == 1
      assert row(a.id).uri == old_uri
      assert row(b.id).uri == "optimal://nodes/x/2026-03-01-x-#{id8(b.id)}.md"

      assert row(b.id).path ==
               Path.join(signals_dir(ctx.root, ctx.ws, "ops"), "2026-03-01-x-#{id8(b.id)}.md")

      assert File.read!(row(b.id).path) == render_of(b.id)
      # Its own file, in its own folder, is not touched.
      assert File.read!(b_path) == render_of(b.id)
    end

    for {name, outside_dir} <- [
          {"another folder of the root", ["someone-elses-tenant", "team", "signals"]},
          {"a path that climbs out of the workspace", ["__ws__", "team", "..", "..", "stolen"]}
        ] do
      test "a context whose path is #{name} is skipped and reported, and nothing is written",
           ctx do
        dir =
          unquote(outside_dir)
          |> Enum.map(&if(&1 == "__ws__", do: ctx.ws, else: &1))
          |> then(&Path.join([ctx.root | &1]))

        path = Path.join(dir, "2026-03-01-weekly-review.md")
        refute String.starts_with?(Path.expand(path), Path.join(ctx.root, ctx.ws) <> "/")

        c1 = context(ctx.ws, "11111111aaaaaaaa", path, "Weekly review", "first: budget", 0)
        c2 = context(ctx.ws, "22222222bbbbbbbb", path, "Weekly review", "second: hiring", 5)
        for c <- [c1, c2], do: :ok = Store.insert_context(c)

        File.mkdir_p!(Path.expand(dir))
        File.write!(Path.expand(path), "somebody else's file\n")
        before = File.ls!(Path.expand(dir))

        assert {:ok, plan} = UriRepair.scan(workspace_id: ctx.ws)
        assert plan.groups == 1
        assert plan.groups_skipped_outside_workspace == 1
        assert plan.repaired == 0

        assert [%{status: "skipped", skip: "outside_workspace", paths_outside_workspace: [^path]}] =
                 plan.groups_detail

        assert [%{groups_skipped_outside_workspace: 1, contexts_to_repair: 0}] = plan.workspaces

        assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
        assert report.groups_skipped_outside_workspace == 1
        assert report.repaired == 0
        assert report.errors == []

        # Nothing was read into a new file, written or replaced there, and the rows stay.
        assert File.ls!(Path.expand(dir)) == before
        assert File.read!(Path.expand(path)) == "somebody else's file\n"
        assert Path.wildcard(Path.join(ctx.root, "**/*22222222*")) == []
        assert row(c2.id).uri == c2.uri
        assert row(c2.id).path == path
      end
    end

    test "tenant-wide leaves the other tenants alone", ctx do
      n = System.unique_integer([:positive])

      workspaces =
        for tenant <- ["uri-t1-#{n}", "uri-t2-#{n}"] do
          {:ok, _} = Tenant.create(%{id: tenant, name: tenant})
          org = "#{tenant}:org"

          {:ok, _} =
            OptimalEngine.Organization.create(%{
              id: org,
              tenant_id: tenant,
              slug: "org",
              name: "Org"
            })

          {:ok, workspace} =
            Workspace.create(%{
              tenant_id: tenant,
              organization_id: org,
              slug: "notes",
              name: "Notes"
            })

          {tenant, workspace.id}
        end

      [{t1, w1}, {t2, w2}] = workspaces

      for {w, tag} <- [{w1, "one"}, {w2, "two"}] do
        path =
          Path.join([
            Filesystem.path(ctx.root, w),
            "team",
            "signals",
            "2026-03-01-weekly-review.md"
          ])

        a = context(w, "aaaa#{tag}1111aaaa", path, "Weekly review", "a #{tag}", 0)
        b = context(w, "bbbb#{tag}2222bbbb", path, "Weekly review", "b #{tag}", 5)
        for c <- [a, b], do: :ok = Store.insert_context(c)
        write_as_last_writer(b)
      end

      assert {:ok, report} = UriRepair.run(tenant_id: t1)

      assert report.groups == 1
      assert report.repaired == 1
      assert [%{workspace_id: ^w1}] = report.workspaces
      assert {:ok, %{groups: 1, workspaces: [%{workspace_id: ^w2}]}} = UriRepair.scan(tenant_id: t2)
    end

    test "acl rows of the shared URI follow each repaired context", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      shared_uri = OptimalURI.from_path(path)

      for {principal, permission} <- [{"user:ann", "read"}, {"user:bob", "write"}] do
        :ok =
          Store.raw_execute(
            "INSERT INTO acls (tenant_id, resource_uri, principal_id, permission) VALUES ('default', ?1, ?2, ?3)",
            [shared_uri, principal, permission]
          )
      end

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
      assert report.acls_copied == 4

      for c <- [c2, c3] do
        {:ok, rows} =
          Store.raw_query(
            "SELECT principal_id, permission FROM acls WHERE tenant_id = 'default' AND resource_uri = ?1 ORDER BY principal_id",
            [row(c.id).uri]
          )

        assert rows == [["user:ann", "read"], ["user:bob", "write"]]
      end

      {:ok, kept} =
        Store.raw_query("SELECT COUNT(*) FROM acls WHERE resource_uri = ?1", [row(c1.id).uri])

      assert kept == [[2]]
    end

    test "memories and open loops that name a context by id move with it", ctx do
      %{c1: c1, c2: c2, path: path} = seed_collision(ctx)
      shared_uri = OptimalURI.from_path(path)

      :ok =
        Store.raw_execute(
          "INSERT INTO chunks (id, tenant_id, signal_id, scale) VALUES ('chunk-c2', 'default', ?1, 'chunk')",
          [c2.id]
        )

      :ok =
        Store.raw_execute(
          "INSERT INTO memories (id, tenant_id, workspace_id, content, citation_uri, source_chunk_id) VALUES ('mem-c2', 'default', ?1, 'm', ?2, 'chunk-c2')",
          [ctx.ws, shared_uri]
        )

      for {id, context_id} <- [{"loop-c1", c1.id}, {"loop-c2", c2.id}] do
        :ok =
          Store.raw_execute(
            "INSERT INTO open_loops (id, tenant_id, workspace_id, kind, title, fingerprint, source_uri, source_context_id) VALUES (?1, 'default', ?2, 'follow_up', 'Call', ?1, ?3, ?4)",
            [id, ctx.ws, shared_uri, context_id]
          )
      end

      :ok =
        Store.raw_execute(
          "INSERT INTO events (tenant_id, principal, kind, target_uri) VALUES ('default', 'user:ann', 'read', ?1)",
          [shared_uri]
        )

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
      assert report.memories_moved == 1
      assert report.open_loops_moved == 1

      new_uri = row(c2.id).uri

      assert {:ok, [[^new_uri]]} =
               Store.raw_query("SELECT citation_uri FROM memories WHERE id = 'mem-c2'", [])

      assert {:ok, [[^new_uri]]} =
               Store.raw_query("SELECT source_uri FROM open_loops WHERE id = 'loop-c2'", [])

      assert {:ok, [[^shared_uri]]} =
               Store.raw_query("SELECT source_uri FROM open_loops WHERE id = 'loop-c1'", [])

      # An event names the URI only: it resolves to the context that keeps it.
      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM events WHERE target_uri = ?1", [shared_uri])
    end
  end

  describe "the journal" do
    test "records every step of a run, with the old and new address and the hashes", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      before_run = OptimalEngine.AtomicFile.sha256(File.read!(path))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.journal =~ ".system/uri-repair/#{report.run_id}/journal.jsonl"
      entries = journal_entries(report)
      assert Enum.all?(entries, &(&1["run_id"] == report.run_id and is_binary(&1["at"])))

      events = Enum.map(entries, & &1["event"])
      assert hd(events) == "run_started"
      assert List.last(events) == "run_finished"

      for c <- [c2, c3] do
        written = Enum.find(entries, &(&1["event"] == "file_written" and &1["context_id"] == c.id))
        assert written["old_uri"] == OptimalURI.from_path(path)
        assert written["new_uri"] == row(c.id).uri
        assert written["old_path"] == path
        assert written["new_path"] == row(c.id).path
        assert written["new_sha256"] == OptimalEngine.AtomicFile.sha256(File.read!(row(c.id).path))

        committed =
          Enum.find(entries, &(&1["event"] == "rows_planned" and &1["context_id"] == c.id))

        assert committed["new_sha256"] == written["new_sha256"]
        # What the old address held before this run touched anything.
        assert committed["old_sha256"] == before_run
        assert Enum.any?(entries, &(&1["event"] == "row_committed" and &1["context_id"] == c.id))
      end

      rewritten = Enum.find(entries, &(&1["event"] == "kept_file_rewritten"))
      assert rewritten["context_id"] == c1.id
      assert rewritten["holds"] == c3.id
      assert rewritten["old_sha256"] != rewritten["new_sha256"]
      assert File.exists?(rewritten["backup"])

      assert OptimalEngine.AtomicFile.sha256(File.read!(rewritten["backup"])) ==
               rewritten["old_sha256"]
    end

    test "is only for a real run", ctx do
      seed_collision(ctx)
      assert {:ok, %{journal: nil, run_id: nil}} = UriRepair.scan(workspace_id: ctx.ws)
      refute File.exists?(Path.join(ctx.root, ".system"))
    end
  end

  describe "an interrupted run" do
    for step <- [
          :started,
          :member_files,
          :cross_copies,
          :kept_file_backed_up,
          :kept_file,
          :kept_copies,
          :rows
        ] do
      test "after #{step}, nothing is lost and the next run finishes the job", ctx do
        %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

        # Before the run only the last writer's text is on disk; the others are
        # in the rows. The text on disk must survive a crash anywhere.
        on_disk_before = File.read!(path)

        crash_at(unquote(step))

        assert_raise RuntimeError, ~r/crash at #{unquote(step)}/, fn ->
          UriRepair.run(workspace_id: ctx.ws)
        end

        # Whatever the run had done, the text that was on disk is still there,
        # in a file or in a backup.
        on_disk = Enum.map(Path.wildcard(Path.join(ctx.root, "**/*.md")), &File.read!/1)

        backups =
          Path.wildcard(Path.join([ctx.root, ".system", "uri-repair", "*", "backups", "*"]))

        assert on_disk_before in (on_disk ++ Enum.map(backups, &File.read!/1)),
               "the text on disk is gone after a crash at #{unquote(step)}"

        no_crash()
        assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
        assert report.errors == []

        assert_everyone_has_their_own_file([c1, c2, c3])
        assert row(c1.id).path == path
        assert {:ok, %{groups: 0}} = UriRepair.run(workspace_id: ctx.ws)
      end
    end

    test "a crash after the rows moved leaves a finished repair", ctx do
      %{c1: c1, c2: c2, c3: c3} = seed_collision(ctx)

      Application.put_env(:optimal_engine, :uri_repair_checkpoint, fn
        :rows -> raise "crash after the commit"
        _ -> :ok
      end)

      assert_raise RuntimeError, fn -> UriRepair.run(workspace_id: ctx.ws) end

      assert_everyone_has_their_own_file([c1, c2, c3])
      no_crash()
      assert {:ok, %{groups: 0}} = UriRepair.run(workspace_id: ctx.ws)
    end

    test "a file already at a new address with the right bytes is recognised", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      c2_path = String.replace_suffix(path, ".md", "-#{id8(c2.id)}.md")
      File.write!(c2_path, render_of(c2.id))

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.files_written == 1
      assert_everyone_has_their_own_file([c1, c2, c3])
      assert row(c2.id).path == c2_path
    end

    test "a torn file at a new address is never overwritten; the context takes the next name",
         ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)
      torn = String.replace_suffix(path, ".md", "-#{id8(c2.id)}.md")
      partial = binary_part(render_of(c2.id), 0, 40)
      File.write!(torn, partial)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)

      assert report.errors == []
      assert File.read!(torn) == partial
      assert row(c2.id).path != torn
      assert Path.basename(row(c2.id).path) =~ String.slice(c2.id, 0, 16)
      assert_everyone_has_their_own_file([c1, c2, c3])
    end

    test "a transaction that fails changes no row, and the next run finishes", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      on_exit(fn -> Store.raw_execute("DROP TRIGGER IF EXISTS fail_c3", []) end)

      :ok =
        Store.raw_execute(
          "CREATE TRIGGER fail_c3 BEFORE UPDATE ON contexts WHEN NEW.id = '#{c3.id}' AND NEW.workspace_id = '#{ctx.ws}' BEGIN SELECT RAISE(ABORT, 'boom'); END",
          []
        )

      assert {:ok, failed} = UriRepair.run(workspace_id: ctx.ws)

      assert [%{reason: reason}] = failed.errors
      assert reason =~ "rows_not_updated"
      assert failed.repaired == 0

      # No row moved. The files are all there, and the keeper's address already
      # holds the keeper's own text.
      for c <- [c1, c2, c3], do: assert(row(c.id).uri == OptimalURI.from_path(path))
      assert File.read!(path) == render_of(c1.id)
      assert File.read!(String.replace_suffix(path, ".md", "-#{id8(c2.id)}.md")) == render_of(c2.id)
      assert File.read!(String.replace_suffix(path, ".md", "-#{id8(c3.id)}.md")) == render_of(c3.id)

      :ok = Store.raw_execute("DROP TRIGGER fail_c3", [])

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
      assert report.errors == []
      assert report.repaired == 2
      assert_everyone_has_their_own_file([c1, c2, c3])
    end

    test "a context that changed after the plan is left as it is and reported", ctx do
      %{c1: c1, c2: c2, c3: c3, path: path} = seed_collision(ctx)

      Application.put_env(:optimal_engine, :uri_repair_checkpoint, fn
        :kept_copies ->
          Store.raw_execute("UPDATE contexts SET uri = 'optimal://elsewhere/c3' WHERE id = ?1", [
            c3.id
          ])

          :ok

        _ ->
          :ok
      end)

      assert {:ok, report} = UriRepair.run(workspace_id: ctx.ws)
      no_crash()

      assert report.repaired == 1
      assert [%{id: id, reason: reason}] = report.errors
      assert id == c3.id
      assert reason =~ "changed_while_repairing"
      assert row(c3.id).uri == "optimal://elsewhere/c3"
      assert row(c2.id).uri != OptimalURI.from_path(path)
      assert row(c1.id).uri == OptimalURI.from_path(path)
    end
  end
end
