defmodule OptimalEngine.Backup.Envelope do
  @moduledoc """
  Client-side encryption for offsite backup copies.

  A backup is sealed before it leaves the machine, so an object store only ever
  holds ciphertext. Each sealed file has its own random 256-bit data key; the
  data key is wrapped with AES-256-GCM under the operator's backup key, read
  from `OPTIMAL_BACKUP_KEY` (64 hex characters), and the backup is encrypted
  with AES-256-GCM in fixed-size chunks so a multi-gigabyte database is never
  held in memory.

  ## Format

  ```text
  "OEBACKUP"      8 bytes, magic
  version         1 byte, currently 1
  header length   4 bytes, big endian
  header          JSON: cipher, chunk_bytes, key_id, wrapped_key,
                  plaintext_bytes, plaintext_sha256, backup_id, sealed_at
  frames          one per chunk: ciphertext (chunk_bytes, the last may be
                  shorter) followed by its 16-byte GCM tag
  ```

  Chunk `i` uses the nonce `<<0::32, i::64>>`, which is safe because every
  file has a fresh data key. Its additional authenticated data is the SHA-256
  of everything before the first frame, the chunk index, and a final-chunk
  flag, so a changed header, a reordered or dropped chunk, a truncated file,
  or appended bytes all fail authentication.

  The header records the plaintext checksum and the key id (a hash of the
  backup key, not the key), so a sealed object can be checked and restored
  without the catalog row that describes it, which is exactly the situation
  after losing the machine.

  Losing the backup key means losing every copy sealed with it: there is no
  recovery path, by design.
  """

  @magic "OEBACKUP"
  @version 1
  @cipher "AES-256-GCM"
  @format "optimal-engine-backup/1"
  @default_chunk_bytes 1_048_576
  @max_chunk_bytes 16 * 1_048_576
  @max_header_bytes 65_536
  @tag_bytes 16
  @iv_bytes 12
  @key_wrap_aad "optimal-engine-backup-key/1:"

  @type seal_result :: %{
          format: String.t(),
          cipher: String.t(),
          key_id: String.t(),
          chunk_bytes: pos_integer(),
          plaintext_bytes: non_neg_integer(),
          plaintext_sha256: String.t(),
          ciphertext_bytes: non_neg_integer(),
          ciphertext_sha256: String.t()
        }

  @doc "The cipher name recorded in headers and catalog rows."
  @spec cipher() :: String.t()
  def cipher, do: @cipher

  @doc "The format name recorded in catalog rows."
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  The backup key from `OPTIMAL_BACKUP_KEY`.

  Returns `{:error, :backup_key_missing}` when the variable is unset or blank
  and `{:error, :backup_key_invalid}` when it is not 64 hex characters. The
  value itself never appears in an error.
  """
  @spec backup_key() :: {:ok, binary()} | {:error, :backup_key_missing | :backup_key_invalid}
  def backup_key do
    case System.get_env("OPTIMAL_BACKUP_KEY") do
      nil ->
        {:error, :backup_key_missing}

      value ->
        case String.trim(value) do
          "" -> {:error, :backup_key_missing}
          hex -> decode_key(hex)
        end
    end
  end

  defp decode_key(hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :backup_key_invalid}
    end
  end

  defp decode_key(_hex), do: {:error, :backup_key_invalid}

  @doc """
  A short, stable identifier for a backup key: the first 16 hex characters of
  a domain-separated SHA-256. It names which key sealed a copy without
  revealing anything usable about the key.
  """
  @spec key_id(binary()) :: String.t()
  def key_id(key) when byte_size(key) == 32 do
    :crypto.hash(:sha256, "optimal-engine-backup-key-id:" <> key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "True when `path` starts with the sealed-backup magic bytes."
  @spec sealed?(String.t()) :: boolean()
  def sealed?(path) do
    case File.open(path, [:read, :binary, :raw], &:file.read(&1, byte_size(@magic))) do
      {:ok, {:ok, @magic}} -> true
      _ -> false
    end
  end

  @doc """
  Seal `source` into `dest` under `key`.

  Options:

    * `:plaintext_sha256` - the checksum the source is expected to have (for
      a cataloged backup, the catalog checksum). It is written into the header
      and checked against the bytes actually read; a mismatch removes `dest`.
      Computed with an extra pass when omitted.
    * `:backup_id` - recorded in the header
    * `:chunk_bytes` - plaintext bytes per chunk (default 1 MiB)

  `dest` must not exist. On any failure it is removed.
  """
  @spec seal_file(String.t(), String.t(), binary(), keyword()) ::
          {:ok, seal_result()} | {:error, term()}
  def seal_file(source, dest, key, opts \\ []) when byte_size(key) == 32 do
    chunk_bytes = Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)

    with :ok <- valid_chunk_bytes(chunk_bytes),
         {:ok, %{size: size}} <- regular_file(source),
         {:ok, expected} <- expected_plaintext_checksum(source, opts) do
      data_key = :crypto.strong_rand_bytes(32)

      header = %{
        "format" => @format,
        "cipher" => @cipher,
        "chunk_bytes" => chunk_bytes,
        "key_id" => key_id(key),
        "wrapped_key" => Base.encode64(wrap(key, data_key)),
        "plaintext_bytes" => size,
        "plaintext_sha256" => expected,
        "backup_id" => Keyword.get(opts, :backup_id),
        "sealed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      with {:ok, sealed} <-
             with_files(source, dest, &seal_stream(&1, &2, header, data_key)) do
        {:ok,
         Map.merge(sealed, %{
           format: @format,
           cipher: @cipher,
           key_id: header["key_id"],
           chunk_bytes: chunk_bytes
         })}
      end
    end
  end

  @doc """
  Open the sealed file `source` into `dest` under `key`.

  Every chunk is authenticated before its plaintext is written, and the
  plaintext checksum must match the header. A wrong key is reported as
  `{:backup_key_mismatch, key_id}` with the id of the key that sealed the file;
  any other failure removes `dest`, so a partial plaintext is never left behind.
  """
  @spec open_file(String.t(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def open_file(source, dest, key) when byte_size(key) == 32 do
    with_files(source, dest, fn input, output ->
      with {:ok, header, digest} <- read_prefix(input),
           {:ok, data_key} <- unwrap(key, header) do
        open_stream(input, output, header, digest, data_key)
      end
    end)
  end

  @doc """
  Read and validate the header of a sealed file without decrypting anything.
  The header is authenticated only when the file is opened with the key.
  """
  @spec read_header(String.t()) :: {:ok, map()} | {:error, term()}
  def read_header(path) do
    case File.open(path, [:read, :binary, :raw], &read_prefix/1) do
      {:ok, {:ok, header, _digest}} -> {:ok, header}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  # ─── sealing ─────────────────────────────────────────────────────────────

  defp seal_stream(input, output, header, data_key) do
    prefix = encode_prefix(header)
    digest = :crypto.hash(:sha256, prefix)
    chunks = chunk_count(header["plaintext_bytes"], header["chunk_bytes"])

    state = %{
      plain: :crypto.hash_init(:sha256),
      cipher: :crypto.hash_update(:crypto.hash_init(:sha256), prefix),
      bytes: byte_size(prefix)
    }

    with :ok <- write(output, prefix),
         {:ok, state} <- seal_chunks(input, output, header, digest, data_key, chunks, state),
         :ok <- expect_eof(input, :source_changed) do
      actual = hex(:crypto.hash_final(state.plain))

      if actual == header["plaintext_sha256"] do
        {:ok,
         %{
           plaintext_bytes: header["plaintext_bytes"],
           plaintext_sha256: actual,
           ciphertext_bytes: state.bytes,
           ciphertext_sha256: hex(:crypto.hash_final(state.cipher))
         }}
      else
        {:error, {:plaintext_checksum_mismatch, header["plaintext_sha256"], actual}}
      end
    end
  end

  defp seal_chunks(input, output, header, digest, data_key, chunks, state) do
    Enum.reduce_while(0..(chunks - 1)//1, {:ok, state}, fn index, {:ok, state} ->
      length = chunk_length(header, index)

      with {:ok, plain} <- read_exact(input, length, :source_changed),
           {ciphertext, tag} <-
             :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               data_key,
               nonce(index),
               plain,
               chunk_aad(digest, index, index == chunks - 1),
               true
             ),
           :ok <- write(output, [ciphertext, tag]) do
        {:cont,
         {:ok,
          %{
            plain: :crypto.hash_update(state.plain, plain),
            cipher: state.cipher |> :crypto.hash_update(ciphertext) |> :crypto.hash_update(tag),
            bytes: state.bytes + byte_size(ciphertext) + @tag_bytes
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp wrap(key, data_key) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, data_key, wrap_aad(key), true)

    iv <> tag <> ciphertext
  end

  defp wrap_aad(key), do: @key_wrap_aad <> key_id(key)

  # ─── opening ─────────────────────────────────────────────────────────────

  defp unwrap(key, %{"key_id" => sealed_with} = header) do
    with :ok <- same_key(key, sealed_with),
         {:ok, wrapped} <- decode_wrapped(header["wrapped_key"]),
         <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> <-
           wrapped,
         data_key when is_binary(data_key) and byte_size(data_key) == 32 <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             wrap_aad(key),
             tag,
             false
           ) do
      {:ok, data_key}
    else
      {:error, {:backup_key_mismatch, _} = reason} -> {:error, reason}
      _ -> {:error, {:backup_decrypt_failed, :wrapped_key}}
    end
  end

  defp same_key(key, sealed_with) do
    if key_id(key) == sealed_with, do: :ok, else: {:error, {:backup_key_mismatch, sealed_with}}
  end

  defp decode_wrapped(value) when is_binary(value), do: Base.decode64(value)
  defp decode_wrapped(_value), do: :error

  defp open_stream(input, output, header, digest, data_key) do
    chunks = chunk_count(header["plaintext_bytes"], header["chunk_bytes"])

    result =
      Enum.reduce_while(0..(chunks - 1)//1, {:ok, :crypto.hash_init(:sha256)}, fn index,
                                                                                  {:ok, hash} ->
        length = chunk_length(header, index)

        with {:ok, frame} <- read_exact(input, length + @tag_bytes, :backup_truncated),
             <<ciphertext::binary-size(length), tag::binary-size(@tag_bytes)>> <- frame,
             plain when is_binary(plain) <-
               :crypto.crypto_one_time_aead(
                 :aes_256_gcm,
                 data_key,
                 nonce(index),
                 ciphertext,
                 chunk_aad(digest, index, index == chunks - 1),
                 tag,
                 false
               ),
             :ok <- write(output, plain) do
          {:cont, {:ok, :crypto.hash_update(hash, plain)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, {:backup_decrypt_failed, {:chunk, index}}}}
        end
      end)

    with {:ok, hash} <- result,
         :ok <- expect_eof(input, :backup_trailing_bytes) do
      actual = hex(:crypto.hash_final(hash))

      if actual == header["plaintext_sha256"] do
        {:ok,
         %{
           plaintext_bytes: header["plaintext_bytes"],
           plaintext_sha256: actual,
           key_id: header["key_id"],
           header: header
         }}
      else
        {:error, {:plaintext_checksum_mismatch, header["plaintext_sha256"], actual}}
      end
    end
  end

  # ─── header ──────────────────────────────────────────────────────────────

  defp encode_prefix(header) do
    json = Jason.encode!(header)
    @magic <> <<@version, byte_size(json)::32>> <> json
  end

  defp read_prefix(input) do
    with {:ok, version, length} <- read_magic(input),
         :ok <- supported_version(version),
         :ok <- header_size(length),
         {:ok, json} <- read_exact(input, length, :backup_truncated),
         {:ok, header} <- decode_header(json),
         :ok <- valid_header(header) do
      prefix = @magic <> <<version, length::32>> <> json
      {:ok, header, :crypto.hash(:sha256, prefix)}
    end
  end

  defp read_magic(input) do
    case :file.read(input, byte_size(@magic) + 5) do
      {:ok, <<@magic, version, length::32>>} -> {:ok, version, length}
      {:error, reason} -> {:error, {:read_failed, reason}}
      _ -> {:error, :not_a_sealed_backup}
    end
  end

  defp supported_version(@version), do: :ok
  defp supported_version(version), do: {:error, {:unsupported_backup_version, version}}

  defp header_size(length) when length > 0 and length <= @max_header_bytes, do: :ok
  defp header_size(_length), do: {:error, :invalid_backup_header}

  defp decode_header(json) do
    case Jason.decode(json) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :invalid_backup_header}
    end
  end

  # The header is not authenticated until the first chunk decrypts, so its
  # sizes are bounded before they are used to size any read.
  defp valid_header(%{
         "cipher" => @cipher,
         "chunk_bytes" => chunk_bytes,
         "plaintext_bytes" => plaintext_bytes,
         "plaintext_sha256" => checksum,
         "key_id" => key_id,
         "wrapped_key" => wrapped
       })
       when is_integer(chunk_bytes) and chunk_bytes > 0 and chunk_bytes <= @max_chunk_bytes and
              is_integer(plaintext_bytes) and plaintext_bytes >= 0 and is_binary(checksum) and
              is_binary(key_id) and is_binary(wrapped),
       do: :ok

  defp valid_header(_header), do: {:error, :invalid_backup_header}

  # ─── helpers ─────────────────────────────────────────────────────────────

  # `dest` is created exclusively, so an existing file is never touched, and a
  # failure after it was created removes it: a half-written ciphertext or a
  # partial plaintext is never left where a later step could trust it.
  defp with_files(source, dest, fun) do
    with {:ok, input} <- open(source, [:read, :binary, :raw]) do
      try do
        with {:ok, output} <- open(dest, [:write, :exclusive, :binary, :raw]) do
          result =
            try do
              fun.(input, output)
            rescue
              error -> {:error, {:raised, Exception.message(error)}}
            after
              :file.close(output)
            end

          case result do
            {:ok, _} ->
              result

            error ->
              File.rm(dest)
              error
          end
        end
      after
        :file.close(input)
      end
    end
  end

  defp open(path, modes) do
    case :file.open(String.to_charlist(path), modes) do
      {:ok, fd} -> {:ok, fd}
      {:error, :eexist} -> {:error, {:target_exists, path}}
      {:error, reason} -> {:error, {:open_failed, path, reason}}
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: type}} -> {:error, {:not_a_file, type}}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  defp expected_plaintext_checksum(source, opts) do
    case Keyword.get(opts, :plaintext_sha256) do
      checksum when is_binary(checksum) ->
        {:ok, String.downcase(checksum)}

      nil ->
        digest =
          source
          |> File.stream!([], @default_chunk_bytes)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()

        {:ok, hex(digest)}
    end
  end

  defp valid_chunk_bytes(bytes)
       when is_integer(bytes) and bytes > 0 and bytes <= @max_chunk_bytes,
       do: :ok

  defp valid_chunk_bytes(_bytes), do: {:error, :invalid_chunk_bytes}

  # An empty file still has one (empty) chunk, so every sealed file carries at
  # least one authenticated frame marked final.
  defp chunk_count(0, _chunk_bytes), do: 1
  defp chunk_count(size, chunk_bytes), do: div(size + chunk_bytes - 1, chunk_bytes)

  defp chunk_length(%{"plaintext_bytes" => size, "chunk_bytes" => chunk_bytes}, index) do
    min(chunk_bytes, size - index * chunk_bytes)
  end

  defp nonce(index), do: <<0::32, index::64>>

  defp chunk_aad(digest, index, final?) do
    digest <> <<index::64, if(final?, do: 1, else: 0)::8>>
  end

  defp read_exact(_fd, 0, _short_reason), do: {:ok, ""}

  defp read_exact(fd, bytes, short_reason) do
    case :file.read(fd, bytes) do
      {:ok, data} when byte_size(data) == bytes -> {:ok, data}
      {:ok, _short} -> {:error, short_reason}
      :eof -> {:error, short_reason}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp expect_eof(fd, extra_reason) do
    case :file.read(fd, 1) do
      :eof -> :ok
      {:ok, _} -> {:error, extra_reason}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp write(fd, data) do
    case :file.write(fd, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp hex(binary), do: Base.encode16(binary, case: :lower)
end
