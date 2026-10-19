defmodule OptimalEngine.Storage.S3 do
  @moduledoc """
  S3-compatible object storage client.

  Speaks the plain S3 REST API with AWS Signature Version 4, so it works
  against AWS S3, MinIO, Cloudflare R2, and any managed object store that
  implements the same protocol. Only the operations the engine needs are
  implemented: put, get, head, list, delete, and multipart upload for large
  objects.

  Configuration comes from the environment, never from code or the database:

  ```text
  OPTIMAL_S3_ENDPOINT           endpoint base URL, e.g. https://s3.example.com
  OPTIMAL_S3_BUCKET             bucket name
  OPTIMAL_S3_REGION             region for the credential scope (default us-east-1)
  OPTIMAL_S3_ACCESS_KEY_ID      access key id
  OPTIMAL_S3_SECRET_ACCESS_KEY  secret access key
  OPTIMAL_S3_PREFIX             optional key prefix owned by this engine
  OPTIMAL_S3_PATH_STYLE         "false" for virtual-hosted addressing (default path style)
  OPTIMAL_S3_TIMEOUT_MS         per-request timeout (default 30000)
  OPTIMAL_S3_MAX_RETRIES        retries for transport errors and 5xx/429 (default 2)
  ```

  Credentials are read from the environment on every call and are never
  returned by any public function, logged, or placed in an error value.
  """

  require Logger

  @default_region "us-east-1"
  @default_timeout 30_000
  @default_max_retries 2
  @default_part_size 8 * 1_024 * 1_024
  @multipart_threshold 16 * 1_024 * 1_024
  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @type config :: %{
          endpoint: URI.t(),
          bucket: String.t(),
          region: String.t(),
          prefix: String.t(),
          path_style: boolean(),
          timeout: pos_integer(),
          max_retries: non_neg_integer(),
          access_key_id: String.t(),
          secret_access_key: String.t()
        }

  @doc "True when every required environment variable is present and non-empty."
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, config())
  end

  @doc """
  Resolved connection settings, or `{:error, :not_configured}`.

  The returned map contains the access key id and secret because signing
  needs them. It is for internal callers (the adapter and the offsite backup
  path) and must never be serialized into an API response.
  """
  @spec config() :: {:ok, config()} | {:error, :not_configured | :invalid_endpoint}
  def config do
    with {:ok, endpoint} <- endpoint(),
         {:ok, bucket} <- required("OPTIMAL_S3_BUCKET"),
         {:ok, key_id} <- required("OPTIMAL_S3_ACCESS_KEY_ID"),
         {:ok, secret} <- required("OPTIMAL_S3_SECRET_ACCESS_KEY") do
      {:ok,
       %{
         endpoint: endpoint,
         bucket: bucket,
         region: optional("OPTIMAL_S3_REGION", @default_region),
         prefix: prefix(),
         path_style: path_style?(endpoint),
         timeout: positive_int("OPTIMAL_S3_TIMEOUT_MS", @default_timeout),
         max_retries: non_neg_int("OPTIMAL_S3_MAX_RETRIES", @default_max_retries),
         access_key_id: key_id,
         secret_access_key: secret
       }}
    end
  end

  @doc """
  A bucket/prefix path joined from segments, with empty segments dropped.

  `object_key/1` is the authority on how the engine names objects: the
  configured prefix first, then the caller's segments.
  """
  @spec object_key([String.t() | nil]) :: String.t()
  def object_key(segments) do
    case config() do
      {:ok, %{prefix: prefix}} -> join_key([prefix | segments])
      _ -> join_key(segments)
    end
  end

  @doc "The `s3://bucket/key` URI for a key, the engine's portable object reference."
  @spec uri(String.t()) :: String.t()
  def uri(key) do
    case config() do
      {:ok, %{bucket: bucket}} -> "s3://#{bucket}/#{key}"
      _ -> "s3:///#{key}"
    end
  end

  @doc "True when a storage reference names an object in a bucket."
  @spec uri?(term()) :: boolean()
  def uri?(value), do: is_binary(value) and String.starts_with?(value, "s3://")

  @doc """
  Split an `s3://bucket/key` URI into `{:ok, bucket, key}`.

  A URI without a bucket (`s3:///key`) is refused.
  """
  @spec parse_uri(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_uri}
  def parse_uri("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, bucket, key}
      _ -> {:error, :invalid_uri}
    end
  end

  def parse_uri(_value), do: {:error, :invalid_uri}

  @doc "Store bytes under a key. Payloads above the multipart threshold are uploaded in parts."
  @spec put_object(String.t(), iodata(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put_object(key, body, opts \\ []) when is_binary(key) do
    body = IO.iodata_to_binary(body)

    if byte_size(body) > Keyword.get(opts, :multipart_threshold, @multipart_threshold) do
      multipart_put(key, body, opts)
    else
      put_single(key, body, opts)
    end
  end

  @doc "Store a file under a key without loading it into memory when it fits in one request."
  @spec put_file(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_file(key, path, opts \\ []) when is_binary(key) and is_binary(path) do
    with {:ok, %{size: size}} <- stat_file(path) do
      if size > Keyword.get(opts, :multipart_threshold, @multipart_threshold) do
        multipart_put_file(key, path, size, opts)
      else
        with {:ok, body} <- read_file(path), do: put_single(key, body, opts)
      end
    end
  end

  @doc "Fetch an object body."
  @spec get_object(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_object(key, opts \\ []) when is_binary(key) do
    with {:ok, config} <- config(),
         request = request(:get, key, opts),
         {:ok, response} <- send_request(config, request, opts),
         {:ok, response} <- expect_success(response) do
      {:ok,
       %{
         body: response.body,
         size_bytes: byte_size(response.body),
         checksum_sha256: sha256(response.body),
         etag: header(response, "etag"),
         content_type: header(response, "content-type")
       }}
    end
  end

  @doc "Fetch an object straight into a file, creating parent directories."
  @spec get_object_to_file(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_object_to_file(key, path, opts \\ []) when is_binary(key) and is_binary(path) do
    with {:ok, %{body: body} = object} <- get_object(key, opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_file(path, body) do
      {:ok, Map.put(object, :path, path)}
    end
  end

  @doc "Object metadata without transferring the body."
  @spec head_object(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def head_object(key, opts \\ []) when is_binary(key) do
    with {:ok, config} <- config(),
         request = request(:head, key, opts),
         {:ok, response} <- send_request(config, request, opts),
         {:ok, response} <- expect_success(response) do
      {:ok,
       %{
         size_bytes: parse_int(header(response, "content-length")),
         etag: header(response, "etag"),
         content_type: header(response, "content-type"),
         metadata: response_metadata(response)
       }}
    end
  end

  @doc """
  List keys under a prefix.

  Follows at most `:max_pages` continuation pages (default 1) and returns the
  keys it saw plus the token for the next page, so a caller decides how far to
  walk a bucket.
  """
  @spec list_objects(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def list_objects(prefix \\ nil, opts \\ []) do
    with {:ok, config} <- config() do
      list_page(config, prefix, Keyword.get(opts, :continuation_token), opts, [])
    end
  end

  @doc "Delete an object. Deleting a missing key succeeds, as S3 does."
  @spec delete_object(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_object(key, opts \\ []) when is_binary(key) do
    with {:ok, config} <- config(),
         request = request(:delete, key, opts),
         {:ok, response} <- send_request(config, request, opts) do
      if response.status in [200, 204] do
        :ok
      else
        expect_success(response)
      end
    end
  end

  @doc """
  Round-trip self-check used as the provider health probe and by the store
  proof: write small bytes, read them back, verify the checksum, list the key,
  and delete it. Every failed step is reported, not raised.
  """
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    key = object_key(["health", "#{System.unique_integer([:positive])}.txt"])
    body = "s3 health check #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    with {:ok, put} <- put_object(key, body, opts),
         {:ok, fetched} <- get_object(key, opts),
         :ok <- compare_checksum(body, fetched.body),
         {:ok, head} <- head_object(key, opts),
         {:ok, listed} <- list_objects(nil, Keyword.put(opts, :max_pages, 1)),
         :ok <- ensure_listed(listed, key),
         :ok <- delete_object(key, opts) do
      {:ok,
       %{
         key: key,
         size_bytes: put.size_bytes,
         checksum_sha256: put.checksum_sha256,
         etag: head.etag,
         listed: true,
         deleted: true
       }}
    end
  end

  # ─── request building ──────────────────────────────────────────────────────

  # An operation is a method, a key, and query parameters. Building it once and
  # signing it in one place keeps every call path on the same signing code.
  defp request(method, key, opts) do
    %{
      method: method,
      key: key,
      query: Keyword.get(opts, :query, []),
      headers: Keyword.get(opts, :headers, []),
      body: Keyword.get(opts, :body, "")
    }
  end

  defp put_single(key, body, opts) do
    checksum = sha256(body)

    headers = [{"x-amz-meta-sha256", checksum}] ++ Keyword.get(opts, :headers, [])

    request =
      request(:put, key, opts)
      |> Map.put(:body, body)
      |> Map.put(:headers, headers)

    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    with {:ok, config} <- config(),
         {:ok, response} <-
           send_request(config, request, Keyword.put(opts, :content_type, content_type)),
         {:ok, _} <- expect_success(response) do
      {:ok,
       %{
         key: key,
         uri: uri(key),
         size_bytes: byte_size(body),
         checksum_sha256: checksum,
         etag: header(response, "etag"),
         multipart: false
       }}
    end
  end

  # Multipart upload: initiate, send parts, complete. A failure aborts the
  # upload so no half-written object and no dangling parts are left behind.
  defp multipart_put(key, body, opts) do
    part_size = Keyword.get(opts, :part_size, @default_part_size)

    with {:ok, config} <- config(),
         {:ok, upload_id} <- initiate_multipart(config, key, opts) do
      parts = chunk_binary(body, part_size)

      case upload_parts(config, key, upload_id, parts, opts) do
        {:ok, uploaded} ->
          complete_multipart(config, key, upload_id, uploaded, body, opts)

        {:error, reason} ->
          abort_multipart(config, key, upload_id, opts)
          {:error, reason}
      end
    end
  end

  defp multipart_put_file(key, path, size, opts) do
    part_size = Keyword.get(opts, :part_size, @default_part_size)

    with {:ok, config} <- config(),
         {:ok, upload_id} <- initiate_multipart(config, key, opts),
         chunks = chunk_file(path, part_size) do
      case stream_parts(config, key, upload_id, chunks, opts) do
        {:ok, uploaded} ->
          complete_multipart_file(config, key, upload_id, uploaded, path, size, opts)

        {:error, reason} ->
          abort_multipart(config, key, upload_id, opts)
          {:error, reason}
      end
    end
  end

  defp initiate_multipart(config, key, opts) do
    request =
      request(:post, key, opts)
      |> Map.put(:query, [{"uploads", ""}])

    with {:ok, response} <- send_request(config, request, opts),
         {:ok, _} <- expect_success(response),
         upload_id when is_binary(upload_id) and upload_id != "" <-
           xml_text(response.body, "UploadId") do
      {:ok, upload_id}
    else
      nil -> {:error, :multipart_initiate_missing_upload_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_multipart(config, key, upload_id, uploaded, body, opts) do
    payload = complete_payload(uploaded)

    request =
      request(:post, key, opts)
      |> Map.put(:query, [{"uploadId", upload_id}])
      |> Map.put(:body, payload)
      |> Map.put(:headers, [])

    with {:ok, response} <-
           send_request(config, request, Keyword.put(opts, :content_type, "application/xml")),
         {:ok, _} <- expect_success(response) do
      {:ok,
       %{
         key: key,
         uri: uri(key),
         size_bytes: byte_size(body),
         checksum_sha256: sha256(body),
         etag: header(response, "etag") || xml_text(response.body, "ETag"),
         multipart: true,
         parts: length(uploaded)
       }}
    end
  end

  defp complete_multipart_file(config, key, upload_id, uploaded, path, size, opts) do
    payload = complete_payload(uploaded)

    request =
      request(:post, key, opts)
      |> Map.put(:query, [{"uploadId", upload_id}])
      |> Map.put(:body, payload)
      |> Map.put(:headers, [])

    with {:ok, response} <-
           send_request(config, request, Keyword.put(opts, :content_type, "application/xml")),
         {:ok, _} <- expect_success(response),
         {:ok, checksum} <- file_sha256(path) do
      {:ok,
       %{
         key: key,
         uri: uri(key),
         size_bytes: size,
         checksum_sha256: checksum,
         etag: header(response, "etag") || xml_text(response.body, "ETag"),
         multipart: true,
         parts: length(uploaded)
       }}
    end
  end

  defp upload_parts(config, key, upload_id, parts, opts) do
    parts
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {body, number}, {:ok, acc} ->
      case upload_part(config, key, upload_id, number, body, opts) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp stream_parts(config, key, upload_id, chunks, opts) do
    chunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {path_range, number}, {:ok, acc} ->
      with {:ok, body} <- read_range(path_range),
           {:ok, part} <- upload_part(config, key, upload_id, number, body, opts) do
        {:cont, {:ok, [part | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp upload_part(config, key, upload_id, number, body, opts) do
    request =
      request(:put, key, opts)
      |> Map.put(:query, [{"partNumber", Integer.to_string(number)}, {"uploadId", upload_id}])
      |> Map.put(:body, body)
      |> Map.put(:headers, [])

    with {:ok, response} <- send_request(config, request, opts),
         {:ok, _} <- expect_success(response),
         etag when is_binary(etag) <- header(response, "etag") do
      {:ok, %{number: number, etag: etag, size_bytes: byte_size(body)}}
    else
      nil -> {:error, {:multipart_part_missing_etag, number}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp abort_multipart(config, key, upload_id, opts) do
    request =
      request(:delete, key, opts)
      |> Map.put(:query, [{"uploadId", upload_id}])

    case send_request(config, request, opts) do
      {:ok, _response} -> :ok
      {:error, reason} -> Logger.warning("s3 multipart abort failed: #{inspect(reason)}")
    end
  end

  defp complete_payload(parts) do
    body =
      Enum.map_join(parts, fn %{number: number, etag: etag} ->
        "<Part><PartNumber>#{number}</PartNumber><ETag>#{escape_xml(etag)}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>#{body}</CompleteMultipartUpload>"
  end

  defp chunk_binary(body, part_size) do
    for <<chunk::binary-size(part_size) <- body>> do
      chunk
    end
    |> append_remainder(body, part_size)
  end

  defp append_remainder(chunks, body, part_size) do
    remainder = rem(byte_size(body), part_size)

    if remainder == 0 do
      case chunks do
        [] -> [body]
        list -> list
      end
    else
      whole = div(byte_size(body), part_size) * part_size
      chunks ++ [binary_part(body, whole, remainder)]
    end
  end

  defp chunk_file(path, part_size) do
    size = File.stat!(path).size
    count = max(div(size + part_size - 1, part_size), 1)

    for index <- 0..(count - 1) do
      offset = index * part_size
      length = min(part_size, size - offset)
      {path, offset, length}
    end
  end

  defp read_range({path, offset, length}) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]) do
      try do
        case :file.pread(file, offset, length) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:read_failed, path, reason}}
        end
      after
        :file.close(file)
      end
    end
  end

  # ─── HTTP + signing ────────────────────────────────────────────────────────

  defp send_request(config, request, opts, attempt \\ 0) do
    case perform(config, request, opts) do
      {:ok, response} ->
        if retryable_status?(response.status) and attempt < config.max_retries do
          backoff(attempt)
          send_request(config, request, opts, attempt + 1)
        else
          {:ok, response}
        end

      {:error, reason} ->
        if attempt < config.max_retries do
          backoff(attempt)
          send_request(config, request, opts, attempt + 1)
        else
          {:error, {:transport, reason}}
        end
    end
  end

  # Exponential backoff, deterministic so a retry sequence is reproducible in
  # a test. Attempt 0 waits 100 ms, attempt 1 waits 200 ms, and so on.
  defp backoff(attempt), do: Process.sleep(100 * Integer.pow(2, attempt))

  defp ensure_http_started do
    case Application.ensure_all_started(:inets) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end

    case Application.ensure_all_started(:ssl) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp retryable_status?(status), do: status == 429 or status == 408 or status >= 500

  defp perform(config, request, opts) do
    # A Mix task that loads configuration without starting the application still
    # has to be able to reach the bucket, so the HTTP client stack is started here
    # rather than assumed.
    ensure_http_started()

    now = DateTime.utc_now()
    payload_hash = sha256(request.body)
    headers = signed_headers(config, request, payload_hash, now)
    url = url(config, request)
    timeout = Keyword.get(opts, :timeout, config.timeout)
    http_opts = [timeout: timeout, connect_timeout: min(timeout, 5_000), ssl: ssl_opts(config)]

    body_format = if request.method == :head, do: [], else: [body_format: :binary]

    # :httpc is strict about the shape of a request: a body-carrying method
    # needs the four-element form, and its content type must be a string
    # (charlist), not a binary. Both mistakes surface only as :invalid_request.
    http_request =
      if request.method in [:put, :post] do
        {String.to_charlist(url), charlist_headers(headers),
         String.to_charlist(Keyword.get(opts, :content_type, "application/octet-stream")),
         request.body}
      else
        {String.to_charlist(url), charlist_headers(headers)}
      end

    case :httpc.request(request.method, http_request, http_opts, body_format) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok,
         %{status: status, headers: normalize_headers(response_headers), body: to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The signature covers the canonical request; x-amz-date, the payload hash,
  # and the host header must all be present before signing.
  defp signed_headers(config, request, payload_hash, now) do
    amz_date = format_amz_date(now)
    date = String.slice(amz_date, 0, 8)
    host = request_host(config)

    base = [
      {"host", host},
      {"x-amz-content-sha256", payload_hash},
      {"x-amz-date", amz_date}
    ]

    headers = merge_headers(base, request.headers)
    signed_names = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    canonical_headers = Enum.map_join(headers, fn {name, value} -> "#{name}:#{trim(value)}\n" end)

    canonical_request =
      Enum.join(
        [
          request.method |> to_string() |> String.upcase(),
          address_path(config, request.key),
          canonical_query(request.query),
          canonical_headers,
          Enum.join(signed_names, ";"),
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{config.region}/#{@service}/aws4_request"

    string_to_sign =
      Enum.join(
        [@algorithm, amz_date, scope, sha256(canonical_request)],
        "\n"
      )

    signature = signature(config, date, string_to_sign)

    # A rejected signature is otherwise opaque. With OPTIMAL_S3_TRACE=1 the
    # canonical request and the string to sign are logged; neither contains the
    # secret access key, so this is safe to enable while diagnosing a 403.
    trace(config, canonical_request, string_to_sign, signature)

    authorization =
      "#{@algorithm} Credential=#{config.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{Enum.join(signed_names, ";")}, Signature=#{signature}"

    [{"authorization", authorization} | headers]
  end

  defp signature(config, date, string_to_sign) do
    key =
      ("AWS4" <> config.secret_access_key)
      |> hmac(date)
      |> hmac(config.region)
      |> hmac(@service)
      |> hmac("aws4_request")

    hmac(key, string_to_sign) |> Base.encode16(case: :lower)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp trace(config, canonical_request, string_to_sign, signature) do
    if optional("OPTIMAL_S3_TRACE", "") == "1" do
      Logger.debug(fn ->
        """
        s3 sign trace (endpoint #{config.endpoint.scheme}://#{config.endpoint.authority}, bucket #{config.bucket})
        canonical request:
        #{canonical_request}
        string to sign:
        #{string_to_sign}
        signature: #{signature}
        """
      end)
    end
  end

  defp merge_headers(base, extra) do
    extra
    |> Enum.reduce(base, fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      List.keystore(acc, name, 0, {name, to_string(value)})
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp url(config, request) do
    endpoint = config.endpoint
    base = "#{endpoint.scheme}://#{endpoint.authority}"
    path = address_path(config, request.key)
    query = canonical_query(request.query)
    if query == "", do: base <> path, else: base <> path <> "?" <> query
  end

  # The request URI, and therefore the canonical URI that is signed, is
  # "/<bucket>/<key>" in path style and "/<key>" in virtual-hosted style. The
  # two must be derived in one place or the signature covers a path that was
  # never sent.
  defp address_path(%{path_style: true} = config, key) do
    "/" <> encode_segment(config.bucket) <> canonical_uri(config, key)
  end

  defp address_path(config, key), do: canonical_uri(config, key)

  defp request_host(%{path_style: true} = config), do: config.endpoint.authority

  defp request_host(config) do
    case config.endpoint do
      %URI{host: host, port: port, scheme: scheme} ->
        if default_port?(scheme, port),
          do: "#{config.bucket}.#{host}",
          else: "#{config.bucket}.#{host}:#{port}"
    end
  end

  defp default_port?("https", 443), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_scheme, _port), do: false

  # Path segments are URI-encoded individually; slashes between them are kept.
  defp canonical_uri(_config, key) do
    key
    |> to_string()
    |> String.split("/")
    |> Enum.map_join("/", &encode_segment/1)
    |> then(&("/" <> &1))
    |> String.replace_prefix("//", "/")
  end

  defp canonical_query(query) do
    query
    |> Enum.map(fn {name, value} -> {encode_segment(name), encode_segment(to_string(value))} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  # Signature Version 4 requires RFC 3986 percent encoding: unreserved
  # characters stay literal, everything else is encoded in uppercase hex.
  defp encode_segment(segment) do
    segment
    |> to_string()
    |> :binary.bin_to_list()
    |> Enum.map_join(&encode_byte/1)
  end

  defp encode_byte(char)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?_, ?., ?~],
       do: <<char>>

  defp encode_byte(char), do: "%" <> Base.encode16(<<char>>, case: :upper)

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp header(%{headers: headers}, name), do: Map.get(headers, name)

  defp response_metadata(%{headers: headers}) do
    headers
    |> Enum.filter(fn {name, _value} -> String.starts_with?(name, "x-amz-meta-") end)
    |> Map.new(fn {name, value} -> {String.replace_prefix(name, "x-amz-meta-", ""), value} end)
  end

  defp ssl_opts(%{endpoint: %URI{scheme: "https"}}) do
    [verify: :verify_peer, depth: 3, customize_hostname_check: [match_fun: match_fun()]] ++
      cacerts()
  end

  defp ssl_opts(_config), do: []

  defp match_fun do
    :public_key.pkix_verify_hostname_match_fun(:https)
  end

  defp cacerts do
    [cacerts: :public_key.cacerts_get()]
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ─── configuration helpers ─────────────────────────────────────────────────

  defp endpoint do
    case optional("OPTIMAL_S3_ENDPOINT", "") do
      "" ->
        {:error, :not_configured}

      value ->
        uri = URI.parse(value)

        if is_binary(uri.host) and uri.host != "" do
          {:ok, %{uri | path: nil, query: nil, fragment: nil}}
        else
          {:error, :not_configured}
        end
    end
  end

  defp required(name) do
    case optional(name, "") do
      "" -> {:error, :not_configured}
      value -> {:ok, value}
    end
  end

  defp optional(name, default) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp positive_int(name, default) do
    case Integer.parse(optional(name, "")) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp non_neg_int(name, default) do
    case Integer.parse(optional(name, "")) do
      {value, ""} when value >= 0 -> value
      _ -> default
    end
  end

  defp prefix do
    case optional("OPTIMAL_S3_PREFIX", "") do
      "" -> ""
      value -> value |> String.trim("/") |> String.replace(~r|/+|, "/")
    end
  end

  # Path-style addressing works against every S3-compatible endpoint; hosted
  # AWS prefers virtual-hosted addressing, which callers opt into explicitly.
  defp path_style?(_endpoint) do
    case optional("OPTIMAL_S3_PATH_STYLE", "true") do
      value when value in ["false", "0", "no", "off"] -> false
      _ -> true
    end
  end

  defp join_key(segments) do
    segments
    |> Enum.reject(&(is_nil(&1) or to_string(&1) == ""))
    |> Enum.map_join("/", &(to_string(&1) |> String.trim("/")))
  end

  defp format_amz_date(now) do
    compact =
      now
      |> DateTime.to_iso8601()
      |> String.replace("-", "")
      |> String.replace(":", "")
      |> String.slice(0, 15)

    compact <> "Z"
  end

  defp trim(value), do: value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  # ─── listing ───────────────────────────────────────────────────────────────

  defp list_page(config, prefix, token, opts, acc) do
    query =
      [{"list-type", "2"}, {"prefix", list_prefix(prefix, opts)}, {"max-keys", "1000"}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    request = request(:get, "", []) |> Map.put(:query, query)

    with {:ok, response} <- send_request(config, request, opts),
         {:ok, _} <- expect_success(response) do
      keys = xml_all(response.body, "Key")
      page = length(acc) + 1
      next = xml_text(response.body, "NextContinuationToken")
      truncated = xml_text(response.body, "IsTruncated") == "true"

      acc = acc ++ keys

      if truncated and is_binary(next) and page < Keyword.get(opts, :max_pages, 1) do
        list_page(config, prefix, next, opts, acc)
      else
        {:ok,
         %{
           keys: acc,
           count: length(acc),
           truncated: truncated,
           next_continuation_token: if(truncated, do: next, else: nil),
           pages: page
         }}
      end
    end
  end

  # A caller-supplied prefix is relative to the engine prefix, except when it
  # already is an absolute key or URI.
  defp list_prefix(nil, _opts), do: prefix_value()
  defp list_prefix("", _opts), do: prefix_value()

  defp list_prefix(prefix, _opts) do
    with {:ok, _config} <- config() do
      if prefix_value() == "" do
        prefix
      else
        join_key([prefix_value(), prefix])
      end
    else
      _ -> prefix
    end
  end

  defp prefix_value do
    case config() do
      {:ok, %{prefix: prefix}} -> prefix
      _ -> ""
    end
  end

  # ─── response helpers ──────────────────────────────────────────────────────

  defp expect_success(%{status: status} = response) when status in 200..299, do: {:ok, response}

  defp expect_success(%{status: 404}), do: {:error, :not_found}

  defp expect_success(%{status: 403}), do: {:error, :access_denied}

  defp expect_success(%{status: status} = response) do
    {:error, {:http_error, status, error_detail(response.body)}}
  end

  # Error bodies carry a code and a message, never credentials. Truncate so a
  # misconfigured endpoint that returns a full HTML page does not flood a log.
  defp error_detail(body) do
    case xml_text(body, "Message") do
      nil -> body |> to_string() |> String.slice(0, 200)
      message -> "#{xml_text(body, "Code") || "error"}: #{message}"
    end
  end

  defp ensure_listed(%{keys: keys}, key) do
    if key in keys, do: :ok, else: {:error, {:list_missing_key, key}}
  end

  defp compare_checksum(expected, actual) do
    if sha256(expected) == sha256(actual),
      do: :ok,
      else: {:error, :checksum_mismatch}
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp to_binary(nil), do: ""

  defp stat_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: type}} -> {:error, {:not_a_file, type}}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp write_file(path, body) do
    case File.write(path, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  @doc "Hex SHA-256 of a binary."
  @spec sha256(iodata()) :: String.t()
  def sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc "Hex SHA-256 of a file, streamed so a large file is never fully in memory."
  @spec file_sha256(String.t()) :: {:ok, String.t()} | {:error, term()}
  def file_sha256(path) do
    digest =
      path
      |> File.stream!([], 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, Base.encode16(digest, case: :lower)}
  rescue
    error -> {:error, {:checksum_failed, Exception.message(error)}}
  end

  @doc "Hex SHA-256 of the empty payload, the hash S3 expects for a bodyless request."
  @spec empty_sha256() :: String.t()
  def empty_sha256, do: @empty_sha256

  # ─── minimal XML reading ────────────────────────────────────────────────────

  # S3 responses are machine-generated XML with simple shapes. Reading text out
  # of a named element is all the engine needs, and it avoids an XML dependency.
  defp xml_text(body, tag) do
    body = to_binary(body)

    case Regex.run(~r|<#{tag}>([^<]*)</#{tag}>|s, body) do
      [_, value] -> unescape_xml(value)
      _ -> nil
    end
  end

  defp xml_all(body, tag) do
    body = to_binary(body)

    Regex.scan(~r|<#{tag}>([^<]*)</#{tag}>|s, body)
    |> Enum.map(fn [_, value] -> unescape_xml(value) end)
  end

  defp unescape_xml(value) do
    value
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp escape_xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
