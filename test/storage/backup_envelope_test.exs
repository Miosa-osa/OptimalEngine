defmodule OptimalEngine.Storage.BackupEnvelopeTest do
  @moduledoc """
  The offsite encryption format: a backup is sealed with a per-backup data key
  under AES-256-GCM in fixed-size chunks, and the data key is wrapped by the
  operator's backup key. Opening it must reproduce the plaintext exactly, and
  any wrong key, changed byte, missing chunk, or appended byte must fail
  without leaving a partial plaintext behind.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Backup.Envelope

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    key = :crypto.strong_rand_bytes(32)
    source = Path.join(tmp, "plain.db")
    # Not a multiple of the chunk size, so the final chunk is short.
    plaintext =
      :crypto.strong_rand_bytes(10_000) <> "SQLite format 3\0" <> String.duplicate("x", 333)

    File.write!(source, plaintext)

    %{key: key, source: source, plaintext: plaintext, tmp: tmp}
  end

  defp seal(ctx, opts \\ []) do
    sealed = Path.join(ctx.tmp, "sealed-#{System.unique_integer([:positive])}.enc")
    opts = Keyword.merge([chunk_bytes: 4_096, backup_id: "backup_test"], opts)
    assert {:ok, info} = Envelope.seal_file(ctx.source, sealed, ctx.key, opts)
    {sealed, info}
  end

  test "a sealed file opens to the exact plaintext across several chunks", ctx do
    {sealed, info} = seal(ctx)

    assert info.cipher == "AES-256-GCM"
    assert info.plaintext_bytes == byte_size(ctx.plaintext)
    assert info.plaintext_sha256 == sha256(ctx.plaintext)
    assert info.ciphertext_sha256 == sha256(File.read!(sealed))
    assert info.ciphertext_bytes == File.stat!(sealed).size
    assert info.key_id == Envelope.key_id(ctx.key)

    opened = Path.join(ctx.tmp, "opened.db")
    assert {:ok, result} = Envelope.open_file(sealed, opened, ctx.key)
    assert File.read!(opened) == ctx.plaintext
    assert result.plaintext_sha256 == sha256(ctx.plaintext)
    assert result.header["backup_id"] == "backup_test"
    assert result.header["chunk_bytes"] == 4_096
  end

  test "the sealed bytes carry no plaintext and are not a SQLite file", ctx do
    {sealed, _info} = seal(ctx)
    bytes = File.read!(sealed)

    refute String.starts_with?(bytes, "SQLite format 3")
    assert :binary.match(bytes, "SQLite format 3") == :nomatch
    assert :binary.match(bytes, binary_part(ctx.plaintext, 0, 64)) == :nomatch
    assert Envelope.sealed?(sealed)
    refute Envelope.sealed?(ctx.source)
  end

  test "two seals of the same file differ, because each uses a fresh data key", ctx do
    {first, _} = seal(ctx)
    {second, _} = seal(ctx)
    refute File.read!(first) == File.read!(second)
  end

  test "empty files and exact chunk multiples round trip", ctx do
    for size <- [0, 4_096, 8_192] do
      plaintext = :crypto.strong_rand_bytes(size)
      File.write!(ctx.source, plaintext)
      {sealed, info} = seal(ctx)
      assert info.plaintext_bytes == size

      opened = Path.join(ctx.tmp, "opened-#{size}.db")
      assert {:ok, _} = Envelope.open_file(sealed, opened, ctx.key)
      assert File.read!(opened) == plaintext
    end
  end

  test "the wrong key is refused before any plaintext is written", ctx do
    {sealed, info} = seal(ctx)
    opened = Path.join(ctx.tmp, "wrong-key.db")
    other = :crypto.strong_rand_bytes(32)

    assert {:error, {:backup_key_mismatch, key_id}} = Envelope.open_file(sealed, opened, other)
    assert key_id == info.key_id
    refute File.exists?(opened)
  end

  test "a header claiming the right key id still fails when the key is wrong", ctx do
    {sealed, _info} = seal(ctx)
    other = :crypto.strong_rand_bytes(32)
    forged = rewrite_header(sealed, &Map.put(&1, "key_id", Envelope.key_id(other)))
    opened = Path.join(ctx.tmp, "forged.db")

    assert {:error, {:backup_decrypt_failed, :wrapped_key}} =
             Envelope.open_file(forged, opened, other)

    refute File.exists?(opened)
  end

  test "a changed ciphertext byte fails and removes the partial plaintext", ctx do
    {sealed, _info} = seal(ctx)
    bytes = File.read!(sealed)
    # Flip a byte in the last chunk so earlier chunks decrypt before the failure.
    position = byte_size(bytes) - 20
    <<head::binary-size(position), byte, rest::binary>> = bytes
    File.write!(sealed, head <> <<Bitwise.bxor(byte, 1)>> <> rest)

    opened = Path.join(ctx.tmp, "tampered.db")

    assert {:error, {:backup_decrypt_failed, {:chunk, _index}}} =
             Envelope.open_file(sealed, opened, ctx.key)

    refute File.exists?(opened)
  end

  test "a changed header field fails every chunk", ctx do
    {sealed, _info} = seal(ctx)
    forged = rewrite_header(sealed, &Map.put(&1, "backup_id", "backup_other"))

    assert {:error, {:backup_decrypt_failed, {:chunk, 0}}} =
             Envelope.open_file(forged, Path.join(ctx.tmp, "header.db"), ctx.key)
  end

  test "a truncated or extended file is refused", ctx do
    {sealed, _info} = seal(ctx)
    bytes = File.read!(sealed)

    truncated = Path.join(ctx.tmp, "truncated.enc")
    File.write!(truncated, binary_part(bytes, 0, byte_size(bytes) - 4_112))

    assert {:error, :backup_truncated} =
             Envelope.open_file(truncated, Path.join(ctx.tmp, "t.db"), ctx.key)

    extended = Path.join(ctx.tmp, "extended.enc")
    File.write!(extended, bytes <> "more")

    assert {:error, :backup_trailing_bytes} =
             Envelope.open_file(extended, Path.join(ctx.tmp, "e.db"), ctx.key)

    refute File.exists?(Path.join(ctx.tmp, "t.db"))
    refute File.exists?(Path.join(ctx.tmp, "e.db"))
  end

  test "a file that is not a sealed backup is refused", ctx do
    assert {:error, :not_a_sealed_backup} =
             Envelope.open_file(ctx.source, Path.join(ctx.tmp, "x.db"), ctx.key)
  end

  test "a source that changes while it is sealed is refused", ctx do
    assert {:error, {:plaintext_checksum_mismatch, _, _}} =
             Envelope.seal_file(
               ctx.source,
               Path.join(ctx.tmp, "claimed.enc"),
               ctx.key,
               plaintext_sha256: String.duplicate("0", 64)
             )

    refute File.exists?(Path.join(ctx.tmp, "claimed.enc"))
  end

  describe "backup_key/0" do
    setup do
      previous = System.get_env("OPTIMAL_BACKUP_KEY")

      on_exit(fn ->
        if previous,
          do: System.put_env("OPTIMAL_BACKUP_KEY", previous),
          else: System.delete_env("OPTIMAL_BACKUP_KEY")
      end)
    end

    test "reads 64 hex characters from OPTIMAL_BACKUP_KEY" do
      key = :crypto.strong_rand_bytes(32)
      System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(key, case: :lower))
      assert {:ok, ^key} = Envelope.backup_key()
    end

    test "reports a missing or malformed key without echoing it" do
      System.delete_env("OPTIMAL_BACKUP_KEY")
      assert {:error, :backup_key_missing} = Envelope.backup_key()

      System.put_env("OPTIMAL_BACKUP_KEY", "   ")
      assert {:error, :backup_key_missing} = Envelope.backup_key()

      System.put_env("OPTIMAL_BACKUP_KEY", "not-hex-and-too-short")
      assert {:error, :backup_key_invalid} = Envelope.backup_key()

      System.put_env("OPTIMAL_BACKUP_KEY", String.duplicate("ab", 31))
      assert {:error, :backup_key_invalid} = Envelope.backup_key()
    end
  end

  defp rewrite_header(path, fun) do
    <<"OEBACKUP", version, length::32, rest::binary>> = File.read!(path)
    <<header::binary-size(length), frames::binary>> = rest
    header = header |> Jason.decode!() |> fun.() |> Jason.encode!()
    forged = path <> ".forged"
    File.write!(forged, ["OEBACKUP", version, <<byte_size(header)::32>>, header, frames])
    forged
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
