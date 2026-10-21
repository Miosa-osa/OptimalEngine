defmodule OptimalEngine.Imports.ZipTest do
  @moduledoc """
  `OptimalEngine.Imports.Zip`: the central directory is read without trusting
  it, paths that leave the archive refuse the whole archive, and an entry is
  never inflated past the size its header declares.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Imports.Zip
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  @moduletag :tmp_dir

  defp write(ctx, bytes),
    do: Fixture.write!(ctx.tmp_dir, bytes, "a-#{System.unique_integer([:positive])}.zip")

  defp entry(archive, name), do: Enum.find(archive.entries, &(&1.name == name))

  test "reads every entry of a zip written by :zip, deflated and checked", ctx do
    path =
      write(ctx, Fixture.zip([{"a.md", "alpha"}, {"dir/b.md", String.duplicate("beta ", 2_000)}]))

    assert {:ok, archive} = Zip.open(path)
    assert archive.entries |> Enum.map(& &1.name) |> Enum.sort() == ["a.md", "dir/b.md"]
    assert {:ok, "alpha"} = Zip.read(archive, entry(archive, "a.md"), 1_000)
    assert {:ok, body} = Zip.read(archive, entry(archive, "dir/b.md"), 100_000)
    assert body == String.duplicate("beta ", 2_000)
  end

  test "reads a stored entry and extracts an entry to a file", ctx do
    path = write(ctx, Fixture.raw_zip([%{name: "s.md", data: "stored text", method: 0}]))
    {:ok, archive} = Zip.open(path)

    assert {:ok, "stored text"} = Zip.read(archive, entry(archive, "s.md"), 100)

    dest = Path.join(ctx.tmp_dir, "out.bin")
    assert :ok = Zip.extract(archive, entry(archive, "s.md"), dest, 100)
    assert File.read!(dest) == "stored text"
  end

  test "a path that leaves the archive refuses the whole archive", ctx do
    for name <- [
          "../escape.md",
          "a/../../escape.md",
          "/etc/passwd",
          "C:/x.md",
          "a\\b.md",
          "a//b.md",
          "./a.md"
        ] do
      path = write(ctx, Fixture.raw_zip([%{name: "ok.md", data: "x"}, %{name: name, data: "y"}]))
      assert {:error, {:unsafe_path, ^name}} = Zip.open(path), "accepted #{inspect(name)}"
    end
  end

  test "entry count and declared total size are limited before anything is inflated", ctx do
    files = for n <- 1..5, do: %{name: "p#{n}.md", data: "x"}
    path = write(ctx, Fixture.raw_zip(files))
    assert {:error, :too_many_entries} = Zip.open(path, %{max_entries: 4})

    path = write(ctx, Fixture.raw_zip([%{name: "big.md", data: "x", declared_size: 10_000_000}]))
    assert {:error, :archive_too_large} = Zip.open(path, %{max_total_bytes: 1_000_000})
  end

  test "an entry that inflates past its declared size is refused as a bomb", ctx do
    bomb = String.duplicate("0", 5_000_000)
    path = write(ctx, Fixture.raw_zip([%{name: "bomb.md", data: bomb, declared_size: 1_000}]))
    {:ok, archive} = Zip.open(path)

    assert {:error, {:entry_size_mismatch, "bomb.md"}} =
             Zip.read(archive, entry(archive, "bomb.md"), 10_000)
  end

  test "a declared size over the caller's cap is refused without inflating", ctx do
    path = write(ctx, Fixture.raw_zip([%{name: "big.md", data: String.duplicate("a", 5_000)}]))
    {:ok, archive} = Zip.open(path)

    assert {:error, {:entry_too_large, "big.md"}} =
             Zip.read(archive, entry(archive, "big.md"), 1_000)
  end

  test "a CRC mismatch and an encrypted entry are refused", ctx do
    path =
      write(
        ctx,
        Fixture.raw_zip([
          %{name: "crc.md", data: "hello", declared_crc: 12_345},
          %{name: "secret.md", data: "hidden", flags: 0x801}
        ])
      )

    {:ok, archive} = Zip.open(path)
    assert {:error, {:crc_mismatch, "crc.md"}} = Zip.read(archive, entry(archive, "crc.md"), 100)

    assert {:error, {:encrypted_entry, "secret.md"}} =
             Zip.read(archive, entry(archive, "secret.md"), 100)
  end

  test "a name that is not UTF-8 is kept with its raw bytes and no name", ctx do
    raw = <<"caf", 0xE9, ".md">>
    path = write(ctx, Fixture.raw_zip([%{name: raw, data: "x"}]))

    assert {:ok, %{entries: [entry]}} = Zip.open(path)
    assert entry.name == nil
    assert entry.raw_name == raw
    assert Zip.display(entry) == "caf?.md"
  end

  test "garbage, a truncated archive and a ZIP64 marker are refused", ctx do
    assert {:error, :invalid_zip} = Zip.open(write(ctx, "not a zip at all, not even close"))

    full = Fixture.zip([{"a.md", "alpha"}])
    assert {:error, :invalid_zip} = Zip.open(write(ctx, binary_part(full, 0, byte_size(full) - 30)))

    zip64 =
      <<0x50, 0x4B, 0x05, 0x06, 0::little-16, 0::little-16, 0xFFFF::little-16, 0xFFFF::little-16,
        0::little-32, 0::little-32, 0::little-16>>

    assert {:error, :zip64_unsupported} = Zip.open(write(ctx, zip64))
    assert {:error, :source_missing} = Zip.open(Path.join(ctx.tmp_dir, "absent.zip"))
  end
end
