defmodule OptimalEngine.Storage.AssetsConfineTest do
  @moduledoc """
  A stored asset path is data: a local asset is read only from under the
  Engine's root, wherever the row says it is. `confine_local/1` is the check
  for code that opens the path itself: under the root once symlinks are
  followed, and a regular file.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.Assets

  test "read and materialize refuse a local path outside the Engine's root" do
    root = Application.get_env(:optimal_engine, :root_path, File.cwd!())
    inside = Path.join(root, "assets-confine-#{System.unique_integer([:positive])}.bin")
    File.mkdir_p!(root)
    File.write!(inside, "bytes")
    on_exit(fn -> File.rm(inside) end)

    assert {:ok, "bytes"} = Assets.read(inside)
    assert {:ok, ^inside} = Assets.materialize(inside)

    for path <- ["/etc/passwd", Path.join(root, "../escape.bin"), inside <> <<0>>] do
      assert {:error, {:asset_outside_root, _}} = Assets.read(path)
      assert {:error, {:asset_outside_root, _}} = Assets.materialize(path)
    end
  end

  describe "confine_local/1" do
    setup do
      previous_root = Application.get_env(:optimal_engine, :root_path)

      base =
        Path.join(System.tmp_dir!(), "assets-confine-local-#{System.unique_integer([:positive])}")

      root = Path.join(base, "root")
      outside = Path.join(base, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      Application.put_env(:optimal_engine, :root_path, root)

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:optimal_engine, :root_path)
          value -> Application.put_env(:optimal_engine, :root_path, value)
        end

        File.rm_rf(base)
      end)

      %{root: root, outside: outside}
    end

    test "a regular file under the root resolves to the file itself", ctx do
      file = Path.join(ctx.root, "asset.bin")
      File.write!(file, "bytes")

      assert {:ok, resolved} = Assets.confine_local(file)
      assert Path.basename(resolved) == "asset.bin"
      assert File.read!(resolved) == "bytes"
    end

    test "a symlink to a file under the root resolves to its target", ctx do
      target = Path.join(ctx.root, "target.bin")
      File.write!(target, "bytes")
      link = Path.join(ctx.root, "link.bin")
      File.ln_s!(target, link)

      assert {:ok, resolved} = Assets.confine_local(link)
      assert Path.basename(resolved) == "target.bin"
    end

    test "a path outside the root, or with a NUL byte, is refused", ctx do
      file = Path.join(ctx.outside, "asset.bin")
      File.write!(file, "bytes")

      for path <- [
            file,
            "/dev/zero",
            Path.join(ctx.root, "../outside/asset.bin"),
            ctx.root <> <<0>>
          ] do
        assert {:error, {:asset_outside_root, _}} = Assets.confine_local(path)
      end
    end

    test "a symlink under the root that leads outside is refused, through a directory too", ctx do
      file = Path.join(ctx.outside, "asset.bin")
      File.write!(file, "bytes")
      link = Path.join(ctx.root, "link.bin")
      File.ln_s!(file, link)
      linked_dir = Path.join(ctx.root, "linked-dir")
      File.ln_s!(ctx.outside, linked_dir)

      assert {:error, {:asset_outside_root, _}} = Assets.confine_local(link)

      assert {:error, {:asset_outside_root, _}} =
               Assets.confine_local(Path.join(linked_dir, "asset.bin"))
    end

    test "a directory and a FIFO are not files, and the FIFO is not opened", ctx do
      fifo = Path.join(ctx.root, "pipe")
      {_output, 0} = System.cmd("mkfifo", [fifo])
      directory = Path.join(ctx.root, "directory")
      File.mkdir_p!(directory)

      assert {:error, {:asset_not_a_file, _}} = Assets.confine_local(fifo)
      assert {:error, {:asset_not_a_file, _}} = Assets.confine_local(directory)
    end

    test "a missing file is unreadable, not outside the root", ctx do
      assert {:error, {:asset_unreadable, _, :enoent}} =
               Assets.confine_local(Path.join(ctx.root, "missing.bin"))
    end

    test "a symlink loop is refused", ctx do
      a = Path.join(ctx.root, "a")
      b = Path.join(ctx.root, "b")
      File.ln_s!(b, a)
      File.ln_s!(a, b)

      assert {:error, {:asset_unreadable, _, :eloop}} = Assets.confine_local(a)
    end
  end
end
