defmodule OptimalEngine.Pipeline.ReservedWorkspaceDirTest do
  @moduledoc """
  A workspace id that names no workspace still names a directory. The intake
  writer sanitizes it to a directory name, and the sanitized name of `nodes!`,
  `cache.`, `(assets)` or `Default` is a directory the Engine root uses for
  itself (or the root, for `default`). Those ids get a `ws-<hash>` directory
  instead, whoever calls: the API, the Mix tasks, batch import, connectors.
  The asset store keeps an unregistered id as its directory key and does the
  same for a key that is not a directory of its own.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Signal

  @spellings [
    "nodes!",
    "nodes.",
    "cache.",
    "(assets)",
    "tenants?",
    "architectures~",
    "NODES",
    "..nodes..",
    "default!",
    "Default",
    "(default)"
  ]

  @occurred ~U[2026-03-01 10:00:00Z]

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "optimal_reserved_dir_#{n}")
    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      if original_root,
        do: Application.put_env(:optimal_engine, :root_path, original_root),
        else: Application.delete_env(:optimal_engine, :root_path)

      File.rm_rf!(root)
    end)

    %{n: n, root: root}
  end

  defp signal(id, title) do
    %Signal{
      id: id,
      title: title,
      mode: :linguistic,
      genre: "note",
      type: :inform,
      format: :markdown,
      created_at: @occurred,
      modified_at: @occurred,
      node: "team",
      sn_ratio: 0.7,
      entities: [],
      l0_summary: "NOTE | team | #{title}",
      l1_description: "Test signal: #{title}",
      content: "Raw content #{id} for #{title}",
      routed_to: []
    }
  end

  defp top_directory(root, path) do
    path |> Path.relative_to(root) |> Path.split() |> hd()
  end

  describe "the intake writer" do
    test "files no spelling in a directory the root uses", %{root: root, n: n} do
      for {id, i} <- Enum.with_index(@spellings) do
        s = signal("aa#{n}bb#{i}cc00dd11", "A note #{i}")

        assert {:ok, path} = Writer.write_signal(s, workspace_id: id)
        assert top_directory(root, path) =~ ~r/\Aws-[0-9a-f]{12}\z/, "#{id}: #{path}"
      end
    end

    test "gives spellings that sanitize alike their own directories", %{root: root, n: n} do
      dirs =
        for id <- ["nodes!", "nodes.", "NODES", "..nodes.."] do
          assert {:ok, path} =
                   Writer.write_signal(signal("bb#{n}cc00dd11ee22", "Same"), workspace_id: id)

          top_directory(root, path)
        end

      assert dirs |> Enum.uniq() |> length() == 4
    end

    test "keeps the directory of an id every time", %{root: root, n: n} do
      first = signal("cc#{n}dd00ee11ff22", "Again")

      assert {:ok, a} = Writer.write_signal(first, workspace_id: "tenants?")
      assert {:ok, b} = Writer.write_signal(first, workspace_id: "tenants?")
      assert top_directory(root, a) == top_directory(root, b)
    end

    test "leaves an ordinary unregistered id where it was", %{root: root, n: n} do
      assert {:ok, path} =
               Writer.write_signal(signal("dd#{n}ee00ff11aa22", "Plain"),
                 workspace_id: "Plain Folder #{n}"
               )

      assert top_directory(root, path) == "plain-folder-#{n}"
    end

    test "is the same for an intake call, which every non-HTTP caller goes through", ctx do
      for {id, i} <- Enum.with_index(@spellings) do
        assert {:ok, result} =
                 Intake.process("A note on the weekly plan, spelling #{i} of #{ctx.n}.",
                   workspace_id: id,
                   node: "team",
                   title: "Weekly plan #{i} #{ctx.n}",
                   occurred_at: @occurred
                 )

        assert [_ | _] = result.files_written

        for file <- result.files_written do
          assert top_directory(ctx.root, Path.join(ctx.root, file)) =~ ~r/\Aws-[0-9a-f]{12}\z/,
                 "#{id}: #{file}"
        end
      end

      reserved = ~w(nodes assets architectures tenants cache default)
      assert Enum.filter(reserved, &File.exists?(Path.join(ctx.root, &1))) == []
    end
  end

  describe "the asset store" do
    defp store(ctx, id, label) do
      source = Path.join(ctx.root, "input-#{label}.png")
      File.write!(source, "\x89PNG\r\n\x1a\nreserved-dir-#{ctx.n}-#{label}")

      MemoryCore.store_asset_file(source,
        workspace_id: id,
        actor_id: "user:asset-reviewer",
        trust_label: "unreviewed"
      )
    end

    test "keeps no asset in a directory the root uses", ctx do
      for {id, i} <-
            Enum.with_index(
              ~w(nodes assets architectures tenants cache default:nodes default:tenants default:default)
            ) do
        assert {:ok, %{asset: asset}} = store(ctx, id, i)
        assert top_directory(ctx.root, asset.storage_path) =~ ~r/\Aws-[0-9a-f]{12}\z/, id
      end
    end

    test "leaves the default workspace and an ordinary unregistered id where they were", ctx do
      assert {:ok, %{asset: asset}} = store(ctx, "default", "d")
      assert top_directory(ctx.root, asset.storage_path) == "assets"

      assert {:ok, %{asset: asset}} = store(ctx, "plain-#{ctx.n}", "p")
      assert top_directory(ctx.root, asset.storage_path) == "plain-#{ctx.n}"
    end
  end
end
