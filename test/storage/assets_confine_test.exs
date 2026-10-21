defmodule OptimalEngine.Storage.AssetsConfineTest do
  @moduledoc """
  A stored asset path is data: a local asset is read only from under the
  Engine's root, wherever the row says it is.
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
end
