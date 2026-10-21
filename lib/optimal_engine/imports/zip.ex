defmodule OptimalEngine.Imports.Zip do
  @moduledoc """
  Reads a zip archive from disk without trusting it.

  The central directory is parsed here rather than by `:zip`, so every limit
  is checked before a byte is inflated, names are read as the raw bytes the
  archive holds, and an entry is inflated with a hard cap: an entry that
  inflates past the size its header declares is refused as a bomb, whatever
  the header claims. Nothing is ever written outside the caller's chosen
  destination, because entries are read by name into memory or into one file
  the caller names; an entry's name never becomes a path on disk.

  The whole archive is refused when it has no end of central directory record
  (`:invalid_zip`), uses ZIP64 or spans disks (`:zip64_unsupported`), holds
  more entries than `:max_entries` (`:too_many_entries`), declares more
  uncompressed bytes in total than `:max_total_bytes` (`:archive_too_large`),
  or names a path that is absolute, has a drive letter, a `..`, `.` or empty
  segment, a backslash or a NUL (`{:unsafe_path, name}`).

  Reading one entry fails with `{:encrypted_entry, name}`,
  `{:unsupported_compression, name}`, `{:entry_too_large, name}` (declared
  size over the caller's cap), `{:entry_size_mismatch, name}` (inflated size
  differs from the header: a bomb or a corrupt entry), `{:crc_mismatch, name}`
  or `{:corrupt_entry, name}`.

  A name that is not valid UTF-8 is kept with `name: nil` and its raw bytes,
  so the caller can report it instead of guessing an encoding.
  """

  import Bitwise

  @eocd_sig <<0x50, 0x4B, 0x05, 0x06>>
  @zip64_locator_sig <<0x50, 0x4B, 0x06, 0x07>>
  @max_comment 65_535
  @eocd_min 22
  @chunk 1_048_576

  @default_limits %{
    max_entries: 50_000,
    max_total_bytes: 4 * 1024 * 1024 * 1024
  }

  @type entry :: %{
          name: String.t() | nil,
          raw_name: binary(),
          dir?: boolean(),
          encrypted?: boolean(),
          method: non_neg_integer(),
          crc: non_neg_integer(),
          comp_size: non_neg_integer(),
          size: non_neg_integer(),
          offset: non_neg_integer()
        }

  @type archive :: %{path: Path.t(), size: non_neg_integer(), entries: [entry()]}

  @doc "The default archive limits."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @doc """
  Opens `path` and reads its central directory. `limits` may set
  `:max_entries` and `:max_total_bytes`.
  """
  @spec open(Path.t(), map()) :: {:ok, archive()} | {:error, term()}
  def open(path, limits \\ %{}) do
    limits = Map.merge(@default_limits, limits)

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          with {:ok, size} <- file_size(path),
               {:ok, eocd} <- read_eocd(fd, size),
               :ok <- within(eocd.count, limits.max_entries, :too_many_entries),
               {:ok, cd} <- pread(fd, eocd.cd_offset, eocd.cd_size, size),
               {:ok, entries} <- parse_central(cd, eocd.count, []),
               :ok <- check_entries(entries, size, limits) do
            {:ok, %{path: path, size: size, entries: entries}}
          end
        after
          File.close(fd)
        end

      {:error, _} ->
        {:error, :source_missing}
    end
  end

  @doc """
  Inflates one entry into memory. Refuses an entry whose declared size is over
  `max_bytes`.
  """
  @spec read(archive(), entry(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def read(archive, entry, max_bytes) do
    with {:ok, chunks} <- stream(archive, entry, max_bytes, [], fn chunk, acc -> [acc | chunk] end) do
      {:ok, IO.iodata_to_binary(chunks)}
    end
  end

  @doc """
  Inflates one entry into the file `dest`, without holding it in memory.
  Refuses an entry whose declared size is over `max_bytes`.
  """
  @spec extract(archive(), entry(), Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def extract(archive, entry, dest, max_bytes) do
    {:ok, out} = File.open(dest, [:write, :binary, :raw])

    result =
      try do
        stream(archive, entry, max_bytes, :ok, fn chunk, :ok -> :ok = IO.binwrite(out, chunk) end)
      after
        File.close(out)
      end

    case result do
      {:ok, :ok} ->
        :ok

      {:error, _} = error ->
        File.rm(dest)
        error
    end
  end

  # ── central directory ──────────────────────────────────────────────────

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _} -> {:error, :source_missing}
    end
  end

  # The end record sits in the last 22 bytes plus a comment of up to 64 KiB.
  # The last signature whose comment length reaches exactly to the end of the
  # file is the record; a signature inside the comment does not qualify.
  defp read_eocd(_fd, size) when size < @eocd_min, do: {:error, :invalid_zip}

  defp read_eocd(fd, size) do
    tail_len = min(size, @eocd_min + @max_comment)

    with {:ok, tail} <- pread(fd, size - tail_len, tail_len, size) do
      tail
      |> :binary.matches(@eocd_sig)
      |> Enum.reverse()
      |> Enum.find_value(fn {pos, _} -> eocd_at(tail, pos) end)
      |> case do
        nil ->
          {:error, :invalid_zip}

        %{pos: pos} = eocd ->
          zip64_locator? =
            pos >= 20 and binary_part(tail, pos - 20, 4) == @zip64_locator_sig

          if zip64_locator?, do: {:error, :zip64_unsupported}, else: classify_eocd(eocd, size)
      end
    end
  end

  defp eocd_at(tail, pos) do
    case binary_part(tail, pos, byte_size(tail) - pos) do
      <<@eocd_sig::binary, disk::little-16, cd_disk::little-16, disk_count::little-16,
        count::little-16, cd_size::little-32, cd_offset::little-32, comment_len::little-16,
        comment::binary>>
      when byte_size(comment) == comment_len ->
        %{
          pos: pos,
          disk: disk,
          cd_disk: cd_disk,
          disk_count: disk_count,
          count: count,
          cd_size: cd_size,
          cd_offset: cd_offset
        }

      _ ->
        nil
    end
  end

  defp classify_eocd(eocd, size) do
    cond do
      eocd.count == 0xFFFF or eocd.cd_size == 0xFFFFFFFF or eocd.cd_offset == 0xFFFFFFFF ->
        {:error, :zip64_unsupported}

      eocd.disk != 0 or eocd.cd_disk != 0 or eocd.disk_count != eocd.count ->
        {:error, :invalid_zip}

      eocd.cd_offset + eocd.cd_size > size ->
        {:error, :invalid_zip}

      true ->
        {:ok, eocd}
    end
  end

  defp parse_central(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp parse_central(_rest, 0, _acc), do: {:error, :invalid_zip}

  defp parse_central(
         <<0x50, 0x4B, 0x01, 0x02, _made::little-16, _needed::little-16, flags::little-16,
           method::little-16, _time::little-16, _date::little-16, crc::little-32,
           comp_size::little-32, size::little-32, name_len::little-16, extra_len::little-16,
           comment_len::little-16, _disk::little-16, _int::little-16, _ext::little-32,
           offset::little-32, name::binary-size(name_len), _extra::binary-size(extra_len),
           _comment::binary-size(comment_len), rest::binary>>,
         left,
         acc
       ) do
    if comp_size == 0xFFFFFFFF or size == 0xFFFFFFFF or offset == 0xFFFFFFFF do
      {:error, :zip64_unsupported}
    else
      entry = %{
        name: if(String.valid?(name), do: name, else: nil),
        raw_name: name,
        dir?: String.ends_with?(name, "/"),
        encrypted?: (flags &&& 0x1) == 1,
        method: method,
        crc: crc,
        comp_size: comp_size,
        size: size,
        offset: offset
      }

      parse_central(rest, left - 1, [entry | acc])
    end
  end

  defp parse_central(_cd, _left, _acc), do: {:error, :invalid_zip}

  defp check_entries(entries, archive_size, limits) do
    Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, total} ->
      total = total + entry.size

      cond do
        not safe_path?(entry.raw_name) ->
          {:halt, {:error, {:unsafe_path, display(entry)}}}

        entry.offset + entry.comp_size > archive_size ->
          {:halt, {:error, :invalid_zip}}

        total > limits.max_total_bytes ->
          {:halt, {:error, :archive_too_large}}

        true ->
          {:cont, {:ok, total}}
      end
    end)
    |> case do
      {:ok, _total} -> :ok
      error -> error
    end
  end

  @doc """
  True when `name` (raw bytes) is a relative path that stays inside the
  archive: no leading slash, drive letter, backslash, NUL, or `..`, `.` or
  empty segment.
  """
  @spec safe_path?(binary()) :: boolean()
  def safe_path?(name) when is_binary(name) do
    segments = name |> String.trim_trailing("/") |> :binary.split("/", [:global])

    name != "" and not String.contains?(name, [<<0>>, "\\"]) and
      not String.starts_with?(name, "/") and not Regex.match?(~r/\A[A-Za-z]:/, name) and
      not Enum.any?(segments, &(&1 in ["", ".", ".."]))
  end

  @doc "A printable form of an entry's name, for reports."
  @spec display(entry()) :: String.t()
  def display(%{name: name}) when is_binary(name), do: name

  def display(%{raw_name: raw}) do
    raw
    |> String.replace_invalid("?")
    |> String.slice(0, 300)
  end

  # ── one entry ──────────────────────────────────────────────────────────

  defp stream(archive, entry, max_bytes, acc, fun) do
    cond do
      entry.encrypted? ->
        {:error, {:encrypted_entry, display(entry)}}

      entry.method not in [0, 8] ->
        {:error, {:unsupported_compression, display(entry)}}

      entry.size > max_bytes ->
        {:error, {:entry_too_large, display(entry)}}

      entry.method == 0 and entry.comp_size != entry.size ->
        {:error, {:entry_size_mismatch, display(entry)}}

      true ->
        stream_data(archive, entry, acc, fun)
    end
  end

  defp stream_data(archive, entry, acc, fun) do
    {:ok, fd} = File.open(archive.path, [:read, :binary, :raw])

    try do
      with {:ok, start} <- data_start(fd, entry, archive.size) do
        if entry.method == 0,
          do: copy(fd, start, entry, acc, fun),
          else: inflate(fd, start, entry, acc, fun)
      end
    after
      File.close(fd)
    end
  end

  defp data_start(fd, entry, archive_size) do
    case pread(fd, entry.offset, 30, archive_size) do
      {:ok,
       <<0x50, 0x4B, 0x03, 0x04, _ver::little-16, _flags::little-16, _method::little-16,
         _time::little-16, _date::little-16, _crc::little-32, _csize::little-32, _size::little-32,
         name_len::little-16, extra_len::little-16>>} ->
        start = entry.offset + 30 + name_len + extra_len

        if start + entry.comp_size <= archive_size,
          do: {:ok, start},
          else: {:error, {:corrupt_entry, display(entry)}}

      _ ->
        {:error, {:corrupt_entry, display(entry)}}
    end
  end

  defp copy(fd, start, entry, acc, fun) do
    result =
      chunks(fd, start, entry.comp_size)
      |> Enum.reduce_while({:ok, acc, 0}, fn
        {:ok, chunk}, {:ok, acc, crc} ->
          {:cont, {:ok, fun.(chunk, acc), :erlang.crc32(crc, chunk)}}

        {:error, _}, _ ->
          {:halt, {:error, {:corrupt_entry, display(entry)}}}
      end)

    with {:ok, acc, crc} <- result do
      if crc == entry.crc, do: {:ok, acc}, else: {:error, {:crc_mismatch, display(entry)}}
    end
  end

  # Raw deflate, inflated through zlib:safeInflate/2 so no single call
  # produces more than a small bounded amount; the running total is checked
  # against the declared size after every piece.
  defp inflate(fd, start, entry, acc, fun) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      state = %{acc: acc, out: 0, crc: 0}

      result =
        chunks(fd, start, entry.comp_size)
        |> Enum.reduce_while({:ok, state}, fn
          {:ok, chunk}, {:ok, state} ->
            case drain(z, :zlib.safeInflate(z, chunk), state, entry, fun) do
              {:ok, state} -> {:cont, {:ok, state}}
              error -> {:halt, error}
            end

          {:error, _}, _ ->
            {:halt, {:error, {:corrupt_entry, display(entry)}}}
        end)

      with {:ok, state} <- result do
        cond do
          state.out != entry.size -> {:error, {:entry_size_mismatch, display(entry)}}
          state.crc != entry.crc -> {:error, {:crc_mismatch, display(entry)}}
          true -> {:ok, state.acc}
        end
      end
    rescue
      ErlangError -> {:error, {:corrupt_entry, display(entry)}}
    catch
      _kind, _reason -> {:error, {:corrupt_entry, display(entry)}}
    after
      :zlib.close(z)
    end
  end

  defp drain(z, {status, output}, state, entry, fun) when status in [:continue, :finished] do
    data = IO.iodata_to_binary(output)
    out = state.out + byte_size(data)

    if out > entry.size do
      {:error, {:entry_size_mismatch, display(entry)}}
    else
      state = %{
        state
        | acc: if(data == "", do: state.acc, else: fun.(data, state.acc)),
          out: out,
          crc: :erlang.crc32(state.crc, data)
      }

      case status do
        :continue -> drain(z, :zlib.safeInflate(z, []), state, entry, fun)
        :finished -> {:ok, state}
      end
    end
  end

  defp drain(_z, _other, _state, entry, _fun), do: {:error, {:corrupt_entry, display(entry)}}

  defp chunks(fd, start, length) do
    Stream.unfold(0, fn
      done when done >= length ->
        nil

      done ->
        size = min(@chunk, length - done)

        case :file.pread(fd, start + done, size) do
          {:ok, data} when byte_size(data) == size -> {{:ok, data}, done + size}
          _ -> {{:error, :short_read}, length}
        end
    end)
  end

  defp pread(_fd, _offset, 0, _archive_size), do: {:ok, <<>>}

  defp pread(fd, offset, length, archive_size) do
    if offset < 0 or offset + length > archive_size do
      {:error, :invalid_zip}
    else
      case :file.pread(fd, offset, length) do
        {:ok, data} when byte_size(data) == length -> {:ok, data}
        _ -> {:error, :invalid_zip}
      end
    end
  end

  defp within(value, max, _reason) when value <= max, do: :ok
  defp within(_value, _max, reason), do: {:error, reason}
end
