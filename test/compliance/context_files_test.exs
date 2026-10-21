defmodule OptimalEngine.Compliance.ContextFilesTest do
  @moduledoc """
  Erasing a context removes the signal file it was made from, with its sidecars and the
  cross-reference copies, so an index of the directory does not bring it back. Only the
  workspace's own signal files go: not a file a person put in a node's folder, not another
  workspace's, not a link, not anything outside the root.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.{ContextFiles, DerivedData, Erasure, Retention}
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Store

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "context-files-#{n}")
    File.mkdir_p!(root)
    saved = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:optimal_engine, :root_path, saved),
        else: Application.delete_env(:optimal_engine, :root_path)

      Store.raw_query("DELETE FROM workspaces WHERE id LIKE ?1", ["default:cf-%-#{n}"])
      File.rm_rf(root)
    end)

    %{n: n, root: root, email: "jane.doe.#{n}@example.com"}
  end

  describe "erasing a context" do
    test "removes its file, its sidecars and the copies written to other nodes", ctx do
      primary = signal!(ctx, "project-platform-launch", "pricing.md", routed: ["operation-revenue"])
      copy = signal!(ctx, "operation-revenue", "pricing.md")
      sidecars = sidecars!(primary)
      neighbour = signal!(ctx, "project-platform-launch", "other.md")

      id =
        context!(ctx, "primary", primary, routed: ["project-platform-launch", "operation-revenue"])

      copy_id = context!(ctx, "copy", copy)
      neighbour_id = context!(ctx, "neighbour", neighbour)

      assert {:ok, %{contexts: 2}} = DerivedData.erase_contexts("default", [id])

      for file <- [primary, copy | sidecars],
          do: refute(File.exists?(file), "#{file} is still there")

      assert File.exists?(neighbour)
      assert count("contexts", "id", id) == 0
      assert count("contexts", "id", copy_id) == 0
      assert count("contexts", "id", neighbour_id) == 1
    end

    test "erasing a copy removes the file it was copied from too", ctx do
      primary = signal!(ctx, "project-platform-launch", "pricing.md")
      copy = signal!(ctx, "operation-revenue", "pricing.md")
      primary_id = context!(ctx, "primary", primary)

      copy_id =
        context!(ctx, "copy", copy, routed: ["project-platform-launch", "operation-revenue"])

      assert {:ok, _} = DerivedData.erase_contexts("default", [copy_id])

      refute File.exists?(primary)
      refute File.exists?(copy)
      assert count("contexts", "id", primary_id) == 0
    end

    test "leaves a file a person put in a node's folder, and the files of the root", ctx do
      note = file!(ctx.root, "project-platform-launch/notes/meeting.md")
      readme = file!(ctx.root, "README.md")
      hidden = file!(ctx.root, ".optimal/signals/x.md")
      assets = file!(ctx.root, "assets/signals/x.md")
      tenants = file!(ctx.root, "tenants/acme/sales/signals/x.md")

      ids =
        for {label, file} <- [
              note: note,
              readme: readme,
              hidden: hidden,
              assets: assets,
              tenants: tenants
            ] do
          context!(ctx, label, file)
        end

      assert {:ok, %{contexts: 5}} = DerivedData.erase_contexts("default", ids)

      for file <- [note, readme, hidden, assets, tenants], do: assert(File.exists?(file))
    end

    test "leaves another workspace's file, though a row names it", ctx do
      other = "default:cf-other-#{ctx.n}"
      workspace!(other)
      theirs = file!(ctx.root, "cf-other-#{ctx.n}/nodes/sales/signals/deal.md")
      id = context!(ctx, "forged", theirs)

      assert {:ok, %{contexts: 1}} = DerivedData.erase_contexts("default", [id])

      assert File.exists?(theirs)
    end

    test "removes a named workspace's signal inside its own directory, and only there", ctx do
      ws = "default:cf-named-#{ctx.n}"
      workspace!(ws)
      own = file!(ctx.root, "cf-named-#{ctx.n}/nodes/sales/signals/deal.md")
      other = file!(ctx.root, "cf-elsewhere-#{ctx.n}/nodes/sales/signals/deal.md")
      id = context!(ctx, "own", own, workspace: ws)
      stray = context!(ctx, "stray", other, workspace: ws)

      assert {:ok, _} = DerivedData.erase_contexts("default", [id, stray])

      refute File.exists?(own)
      assert File.exists?(other)
    end

    test "does not follow a link, or leave the root", ctx do
      target = file!(Path.dirname(ctx.root), "linked-#{ctx.n}.md")
      outside = file!(Path.dirname(ctx.root), "outside-#{ctx.n}/signals/x.md")

      on_exit(fn ->
        File.rm(target)
        File.rm_rf(Path.dirname(Path.dirname(outside)))
      end)

      link = Path.join(ctx.root, "project-platform-launch/signals/link.md")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(target, link)

      ids = [context!(ctx, "link", link), context!(ctx, "outside", outside)]

      assert {:ok, %{contexts: 2}} = DerivedData.erase_contexts("default", ids)

      assert File.exists?(target)
      assert File.exists?(outside)
    end

    test "a file that cannot be removed leaves the rows", ctx do
      file = signal!(ctx, "project-platform-launch", "stuck.md")
      id = context!(ctx, "stuck", file)

      unless root?() do
        File.chmod!(Path.dirname(file), 0o500)
        on_exit(fn -> File.chmod(Path.dirname(file), 0o700) end)

        assert {:error, {:artifact_not_removed, :context_file, :eacces}} =
                 DerivedData.erase_contexts("default", [id])

        assert File.exists?(file)
        assert count("contexts", "id", id) == 1

        File.chmod!(Path.dirname(file), 0o700)
        assert {:ok, %{contexts: 1}} = DerivedData.erase_contexts("default", [id])
        refute File.exists?(file)
      end
    end

    test "the dry run counts the files and removes none", ctx do
      file = signal!(ctx, "project-platform-launch", "dry.md")
      id = context!(ctx, "dry", file)

      assert {:ok, %{context_files: 1}} = DerivedData.preview("default", [id])

      assert File.exists?(file)
      assert count("contexts", "id", id) == 1
    end
  end

  describe "erasing a principal" do
    test "removes the signal files of their contexts", ctx do
      principal = "user:context-files-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})
      file = signal!(ctx, "project-platform-launch", "subject.md")
      other = signal!(ctx, "project-platform-launch", "bystander.md")
      id = context!(ctx, "subject", file)
      _bystander = context!(ctx, "bystander", other)

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET created_by = ?1 WHERE id = ?2", [principal, id])

      assert {:ok, _} = Erasure.erase(principal)

      refute File.exists?(file)
      assert File.exists?(other)
    end
  end

  describe "a retention sweep" do
    setup ctx do
      tenant = "cf-ret-#{ctx.n}"
      %{tenant: tenant}
    end

    test "that deletes removes the file", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "delete"
        )

      file = signal!(ctx, "project-platform-launch", "expired.md")
      id = context!(ctx, "expired", file, tenant: ctx.tenant, old: true)

      assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

      refute File.exists?(file)
      assert count("contexts", "id", id) == 0
    end

    test "that archives keeps the file", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "archive"
        )

      file = signal!(ctx, "project-platform-launch", "archived.md")
      _id = context!(ctx, "archived", file, tenant: ctx.tenant, old: true)

      assert {:ok, %{actions_taken: 1}} = Retention.sweep(tenant_id: ctx.tenant)

      assert File.exists?(file)
    end

    test "that redacts rewrites the file and its sidecars in place", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "redact"
        )

      file =
        signal!(ctx, "project-platform-launch", "personal.md", text: "Write to #{ctx.email} soon.")

      [abstract, overview] = sidecars!(file, "Summary of #{ctx.email}")
      clean = signal!(ctx, "project-platform-launch", "clean.md", text: "Nothing personal here.")
      before = File.stat!(clean, time: :posix).mtime

      id =
        context!(ctx, "personal", file,
          tenant: ctx.tenant,
          old: true,
          text: "Write to #{ctx.email} soon."
        )

      _clean =
        context!(ctx, "clean", clean, tenant: ctx.tenant, old: true, text: "Nothing personal here.")

      assert {:ok, %{errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

      for path <- [file, abstract, overview] do
        text = File.read!(path)
        refute text =~ ctx.email
        assert text =~ "<REDACTED:email>"
      end

      assert File.read!(clean) =~ "Nothing personal"
      assert File.stat!(clean, time: :posix).mtime == before
      assert count("contexts", "id", id) == 1
    end
  end

  describe "plan/3" do
    test "names the files and the copy contexts, and reads no file", ctx do
      primary = signal!(ctx, "project-platform-launch", "plan.md")
      copy = signal!(ctx, "operation-revenue", "plan.md")
      id = context!(ctx, "plan", primary, routed: ["project-platform-launch", "operation-revenue"])
      copy_id = context!(ctx, "plan-copy", copy)

      assert {:ok, %{files: files, copy_ids: [^copy_id]}} = ContextFiles.plan("default", [id])
      assert Enum.sort(files) == Enum.sort([primary, copy])

      assert {:ok, %{files: [^primary], copy_ids: []}} =
               ContextFiles.plan("default", [id], copies: false)
    end

    test "ignores contexts of another tenant" do
      assert {:ok, %{files: [], copy_ids: []}} = ContextFiles.plan("another-tenant", ["nope"])
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp signal!(ctx, folder, name, opts \\ []) do
    file!(ctx.root, "#{folder}/signals/#{name}", Keyword.get(opts, :text, "text of #{name}"))
  end

  defp sidecars!(file, text \\ "summary") do
    base = Path.rootname(file)

    for suffix <- [".abstract.md", ".overview.md"],
        do: file!(Path.dirname(base), Path.basename(base) <> suffix, text)
  end

  defp file!(dir, relative, text \\ "contents") do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  defp workspace!(id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status) VALUES (?1, 'default', ?2, ?2, 'active')",
        [id, String.replace(id, "default:", "")]
      )
  end

  defp context!(ctx, label, path, opts \\ []) do
    id = "cf-#{label}-#{ctx.n}"
    tenant = Keyword.get(opts, :tenant, "default")
    workspace = Keyword.get(opts, :workspace, "default")
    text = Keyword.get(opts, :text, "text of #{label}")

    created =
      if Keyword.get(opts, :old, false), do: "2020-01-01T00:00:00Z", else: "2026-01-01T00:00:00Z"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, l0_abstract, l1_overview, path, routed_to, genre, node, created_at)
        VALUES (?1, ?2, ?3, ?4, 't', ?5, ?5, ?5, ?6, ?7, 'note', 'person-operator', ?8)
        """,
        [
          id,
          tenant,
          workspace,
          "optimal://context-files/#{id}",
          text,
          path,
          Jason.encode!(Keyword.get(opts, :routed, [])),
          created
        ]
      )

    id
  end

  defp count(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end

  defp root?, do: match?({"0\n", 0}, System.cmd("id", ["-u"]))
end
