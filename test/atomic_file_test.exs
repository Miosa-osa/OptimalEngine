defmodule OptimalEngine.AtomicFileTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.AtomicFile

  setup do
    dir = Path.join(System.tmp_dir!(), "optimal_atomic_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp entries(dir), do: dir |> File.ls!() |> Enum.sort()

  describe "write/2" do
    test "replaces the text and leaves no temporary file", %{dir: dir} do
      path = Path.join(dir, "note.md")
      File.write!(path, "old")

      assert :ok = AtomicFile.write(path, "new text")

      assert File.read!(path) == "new text"
      assert entries(dir) == ["note.md"]
    end

    test "makes the folder when it is missing", %{dir: dir} do
      path = Path.join([dir, "a", "b", "note.md"])

      assert :ok = AtomicFile.write(path, "text")
      assert File.read!(path) == "text"
    end

    test "a write that cannot finish leaves the old text and no temporary file", %{dir: dir} do
      path = Path.join(dir, "taken")
      File.mkdir_p!(path)

      assert {:error, _reason} = AtomicFile.write(path, "text")

      assert File.dir?(path)
      assert entries(dir) == ["taken"]
    end
  end

  describe "create/2" do
    test "writes a file that is not there", %{dir: dir} do
      path = Path.join(dir, "note.md")

      assert :ok = AtomicFile.create(path, "text")
      assert File.read!(path) == "text"
      assert entries(dir) == ["note.md"]
    end

    test "never replaces a file that is there", %{dir: dir} do
      path = Path.join(dir, "note.md")
      File.write!(path, "someone else's")

      assert {:error, :eexist} = AtomicFile.create(path, "text")

      assert File.read!(path) == "someone else's"
      assert entries(dir) == ["note.md"]
    end
  end

  test "sha256/1 is the lowercase hex digest" do
    assert AtomicFile.sha256("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
