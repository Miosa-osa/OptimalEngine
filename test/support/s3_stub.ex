defmodule OptimalEngine.TestSupport.S3Stub do
  @moduledoc """
  A local, in-process S3-compatible endpoint for tests and live proofs.

  It implements the small slice of the S3 REST API the engine uses (put, get,
  head, list, delete, multipart) and verifies every request's Signature
  Version 4 authorization header before serving it. The verifier is written
  independently of `OptimalEngine.Storage.S3`: it canonicalizes the request as
  it arrived on the wire, so a client that signs the wrong canonical request,
  the wrong payload hash, or the wrong scope is rejected instead of quietly
  passing.

  No test in this suite talks to a real cloud endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @doc """
  Start a stub listener.

  Options:

    * `:port` - TCP port, 0 picks a free one (default 0)
    * `:bucket` - the single bucket it serves (default "engine-test")
    * `:access_key_id`, `:secret_access_key` - credentials it accepts
    * `:region` - region it expects in the credential scope (default "us-east-1")
    * `:agent` - reuse an existing state agent instead of starting one

  Returns `{:ok, %{port: port, ref: ref, agent: agent}}`.
  """
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    agent = Keyword.get_lazy(opts, :agent, fn -> start_agent(opts) end)
    ref = Keyword.get_lazy(opts, :ref, &ref/0)

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__, [agent: agent],
        port: Keyword.get(opts, :port, 0),
        ref: ref
      )

    port = :ranch.get_port(ref)

    {:ok,
     %{
       port: port,
       ref: ref,
       agent: agent,
       endpoint: "http://127.0.0.1:#{port}",
       bucket: bucket(agent),
       access_key_id: config(agent).access_key_id,
       secret_access_key: config(agent).secret_access_key,
       region: config(agent).region
     }}
  end

  @doc """
  A unique listener reference.

  Callers allocate the reference before starting, so a listener can be shut
  down from test cleanup even when the start itself fails.
  """
  @spec ref() :: atom()
  def ref, do: :"#{__MODULE__}.HTTP#{System.unique_integer([:positive])}"

  @doc "Stop the listener. The state agent keeps its contents for inspection."
  @spec stop(map() | atom()) :: :ok | {:error, :not_found}
  def stop(%{ref: ref}), do: stop(ref)
  def stop(ref) when is_atom(ref), do: Plug.Cowboy.shutdown(ref)

  @doc "Start only the state agent, for a listener that outlives a single test."
  @spec start_agent(keyword()) :: pid()
  def start_agent(opts \\ []) do
    {:ok, agent} =
      Agent.start(fn ->
        %{
          config: %{
            access_key_id: Keyword.get(opts, :access_key_id, "optimal-engine-test"),
            secret_access_key: Keyword.get(opts, :secret_access_key, "optimal-engine-test-secret"),
            region: Keyword.get(opts, :region, "us-east-1"),
            bucket: Keyword.get(opts, :bucket, "engine-test"),
            verify: Keyword.get(opts, :verify, true)
          },
          objects: %{},
          uploads: %{},
          requests: []
        }
      end)

    agent
  end

  @doc "Stop a state agent started with `start_agent/1`."
  @spec stop_agent(pid()) :: :ok
  def stop_agent(agent) do
    Agent.stop(agent)
    :ok
  end

  @doc "Every request the stub has served, newest last: method, path, and signature verdict."
  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @doc "Stored object keys in insertion-independent order."
  @spec object_keys(pid()) :: [String.t()]
  def object_keys(agent) do
    agent |> Agent.get(& &1.objects) |> Map.keys() |> Enum.sort()
  end

  @doc "Stored object body for a key, or nil."
  @spec object_body(pid(), String.t()) :: binary() | nil
  def object_body(agent, key) do
    case Agent.get(agent, &Map.get(&1.objects, key)) do
      nil -> nil
      object -> object.body
    end
  end

  @doc "The configured credentials, so a test can point the engine at the stub."
  @spec credentials(pid()) :: map()
  def credentials(agent) do
    config = config(agent)

    %{
      endpoint: nil,
      bucket: config.bucket,
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      region: config.region
    }
  end

  defp config(agent), do: Agent.get(agent, & &1.config)
  defp bucket(agent), do: config(agent).bucket

  # ─── Plug ───────────────────────────────────────────────────────────────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    dispatch(conn, Keyword.fetch!(opts, :agent))
  end

  defp dispatch(conn, agent) do
    {:ok, body, conn} = read_body(conn, length: 256_000_000, read_length: 1_000_000)

    case verify(conn, body, agent) do
      :ok -> handle(conn, body, agent)
      {:error, reason} -> reject(conn, agent, reason)
    end
  end

  defp reject(conn, agent, reason) do
    record(agent, conn, false, reason)
    send_resp(conn, 403, error_xml("SignatureDoesNotMatch", to_string(reason)))
  end

  # ─── operations ────────────────────────────────────────────────────────────

  # Path-style addressing: the first segment is the bucket. Virtual-hosted
  # requests are refused, which keeps the stub honest about what it accepts.
  defp handle(conn, body, agent) do
    case split_path(conn.request_path) do
      {:ok, bucket, key} ->
        route(conn, body, agent, bucket, key)

      :error ->
        send_resp(conn, 400, error_xml("InvalidRequest", "expected /<bucket>/<key>"))
    end
  end

  defp route(conn, _body, agent, bucket, "") do
    with :ok <- check_bucket(agent, bucket),
         {:ok, query} <- query_params(conn) do
      if Map.get(query, "list-type") == "2" do
        list_bucket(conn, agent, query)
      else
        send_resp(conn, 400, error_xml("InvalidRequest", "unsupported bucket request"))
      end
    else
      {:error, :no_such_bucket} -> send_resp(conn, 404, error_xml("NoSuchBucket", bucket))
      {:error, reason} -> send_resp(conn, 400, error_xml("InvalidRequest", to_string(reason)))
    end
  end

  defp route(conn, body, agent, bucket, key) do
    with :ok <- check_bucket(agent, bucket),
         {:ok, query} <- query_params(conn) do
      case {conn.method, query} do
        {"PUT", %{"uploadId" => upload_id, "partNumber" => number}} ->
          put_part(conn, agent, key, upload_id, number, body)

        {"PUT", _} ->
          put_object(conn, agent, key, body)

        {"GET", _} ->
          get_object(conn, agent, key)

        {"HEAD", _} ->
          head_object(conn, agent, key)

        {"DELETE", %{"uploadId" => upload_id}} ->
          abort_upload(conn, agent, key, upload_id)

        {"DELETE", _} ->
          delete_object(conn, agent, key)

        {"POST", %{"uploads" => _}} ->
          initiate_upload(conn, agent, key)

        {"POST", %{"uploadId" => upload_id}} ->
          complete_upload(conn, agent, key, upload_id, body)

        _ ->
          send_resp(conn, 400, error_xml("InvalidRequest", "unsupported operation"))
      end
    else
      {:error, :no_such_bucket} -> send_resp(conn, 404, error_xml("NoSuchBucket", bucket))
      {:error, reason} -> send_resp(conn, 400, error_xml("InvalidRequest", to_string(reason)))
    end
  end

  defp put_object(conn, agent, key, body) do
    etag = etag_single(body)
    metadata = incoming_metadata(conn)
    content_type = content_type(conn)

    Agent.update(agent, fn state ->
      object = %{
        body: body,
        etag: etag,
        metadata: metadata,
        content_type: content_type
      }

      %{state | objects: Map.put(state.objects, key, object)}
    end)

    record(agent, conn, true, :accepted)

    conn
    |> put_resp_header("etag", etag)
    |> send_resp(200, "")
  end

  defp get_object(conn, agent, key) do
    case Agent.get(agent, &Map.get(&1.objects, key)) do
      nil ->
        record(agent, conn, true, :not_found)
        send_resp(conn, 404, error_xml("NoSuchKey", key))

      object ->
        record(agent, conn, true, :accepted)

        conn
        |> put_resp_header("etag", object.etag)
        |> put_resp_header("content-type", object.content_type || "application/octet-stream")
        |> put_metadata_headers(object.metadata)
        |> send_resp(200, object.body)
    end
  end

  defp head_object(conn, agent, key) do
    case Agent.get(agent, &Map.get(&1.objects, key)) do
      nil ->
        record(agent, conn, true, :not_found)
        send_resp(conn, 404, "")

      object ->
        record(agent, conn, true, :accepted)

        # Cowboy drops the body for a HEAD response while keeping the
        # Content-Length, which is exactly how S3 answers a HEAD.
        conn
        |> put_resp_header("etag", object.etag)
        |> put_resp_header("content-type", object.content_type || "application/octet-stream")
        |> put_metadata_headers(object.metadata)
        |> send_resp(200, object.body)
    end
  end

  defp delete_object(conn, agent, key) do
    Agent.update(agent, fn state -> %{state | objects: Map.delete(state.objects, key)} end)
    record(agent, conn, true, :accepted)
    send_resp(conn, 204, "")
  end

  defp list_bucket(conn, agent, query) do
    prefix = Map.get(query, "prefix", "")
    state = Agent.get(agent, & &1)

    keys =
      state.objects
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    contents =
      Enum.map_join(keys, fn key ->
        object = Map.fetch!(state.objects, key)

        "<Contents><Key>#{escape_xml(key)}</Key>" <>
          "<LastModified>#{DateTime.utc_now() |> DateTime.to_iso8601()}</LastModified>" <>
          "<ETag>#{object.etag}</ETag><Size>#{byte_size(object.body)}</Size>" <>
          "<StorageClass>STANDARD</StorageClass></Contents>"
      end)

    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        "<ListBucketResult>" <>
        "<Name>#{escape_xml(config(agent).bucket)}</Name>" <>
        "<Prefix>#{escape_xml(prefix)}</Prefix>" <>
        "<KeyCount>#{length(keys)}</KeyCount><MaxKeys>1000</MaxKeys>" <>
        "<IsTruncated>false</IsTruncated>" <>
        contents <>
        "</ListBucketResult>"

    record(agent, conn, true, :accepted)

    conn
    |> put_resp_header("content-type", "application/xml")
    |> send_resp(200, body)
  end

  defp initiate_upload(conn, agent, key) do
    upload_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    Agent.update(agent, fn state ->
      uploads = Map.put(state.uploads, upload_id, %{key: key, parts: %{}})
      %{state | uploads: uploads}
    end)

    record(agent, conn, true, :accepted)

    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        "<InitiateMultipartUploadResult>" <>
        "<Bucket>#{escape_xml(config(agent).bucket)}</Bucket>" <>
        "<Key>#{escape_xml(key)}</Key>" <>
        "<UploadId>#{upload_id}</UploadId>" <>
        "</InitiateMultipartUploadResult>"

    conn
    |> put_resp_header("content-type", "application/xml")
    |> send_resp(200, body)
  end

  defp put_part(conn, agent, _key, upload_id, number, body) do
    case Agent.get(agent, &Map.get(&1.uploads, upload_id)) do
      nil ->
        record(agent, conn, true, :not_found)
        send_resp(conn, 404, error_xml("NoSuchUpload", upload_id))

      _upload ->
        etag = etag_single(body)

        Agent.update(agent, fn state ->
          upload = Map.fetch!(state.uploads, upload_id)
          part = %{number: String.to_integer(number), body: body, etag: etag}

          updated = %{upload | parts: Map.put(upload.parts, part.number, part)}
          %{state | uploads: Map.put(state.uploads, upload_id, updated)}
        end)

        record(agent, conn, true, :accepted)

        conn
        |> put_resp_header("etag", etag)
        |> send_resp(200, "")
    end
  end

  defp complete_upload(conn, agent, key, upload_id, _body) do
    case Agent.get(agent, &Map.get(&1.uploads, upload_id)) do
      nil ->
        record(agent, conn, true, :not_found)
        send_resp(conn, 404, error_xml("NoSuchUpload", upload_id))

      %{key: ^key} = upload ->
        parts = upload.parts |> Enum.sort() |> Enum.map(&elem(&1, 1))
        etag = etag_multipart(parts)

        Agent.update(agent, fn state ->
          object = %{
            body: Enum.map_join(parts, & &1.body),
            etag: etag,
            metadata: %{},
            content_type: "application/octet-stream"
          }

          %{
            state
            | objects: Map.put(state.objects, key, object),
              uploads: Map.delete(state.uploads, upload_id)
          }
        end)

        record(agent, conn, true, :accepted)

        body =
          ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
            "<CompleteMultipartUploadResult><Key>#{escape_xml(key)}</Key>" <>
            "<ETag>#{etag}</ETag></CompleteMultipartUploadResult>"

        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("content-type", "application/xml")
        |> send_resp(200, body)

      _ ->
        record(agent, conn, true, :key_mismatch)
        send_resp(conn, 400, error_xml("InvalidRequest", "upload key mismatch"))
    end
  end

  defp abort_upload(conn, agent, _key, upload_id) do
    Agent.update(agent, fn state -> %{state | uploads: Map.delete(state.uploads, upload_id)} end)
    record(agent, conn, true, :accepted)
    send_resp(conn, 204, "")
  end

  # ─── signature verification ────────────────────────────────────────────────

  # Rebuild the canonical request from the bytes that arrived, not from what
  # the client believes it sent.
  defp verify(conn, body, agent) do
    config = config(agent)

    if config.verify do
      do_verify(conn, body, config)
    else
      :ok
    end
  end

  defp do_verify(conn, body, config) do
    with [authorization] <- get_req_header(conn, "authorization"),
         {:ok, credential, signed_names, signature} <- parse_authorization(authorization),
         {:ok, scope} <- parse_credential(credential),
         :ok <- check_scope(scope, config),
         :ok <- check_payload_hash(conn, body),
         :ok <- check_signed_headers(conn, signed_names),
         :ok <- check_signature(conn, signed_names, scope, signature, config) do
      :ok
    else
      [] -> {:error, "missing authorization header"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "malformed authorization header"}
    end
  end

  defp parse_authorization(authorization) do
    with true <- String.starts_with?(authorization, @algorithm),
         [_, credential] <- Regex.run(~r/Credential=([^,]+)/, authorization),
         [_, signed] <- Regex.run(~r/SignedHeaders=([^,]+)/, authorization),
         [_, signature] <- Regex.run(~r/Signature=([0-9a-f]+)/, authorization) do
      {:ok, credential, String.split(signed, ";"), signature}
    else
      _ -> {:error, "malformed authorization header"}
    end
  end

  defp parse_credential(credential) do
    case String.split(credential, "/") do
      [access_key_id, date, region, service, "aws4_request"] ->
        {:ok, %{access_key_id: access_key_id, date: date, region: region, service: service}}

      _ ->
        {:error, "malformed credential scope"}
    end
  end

  defp check_scope(scope, config) do
    cond do
      scope.access_key_id != config.access_key_id -> {:error, "unknown access key id"}
      scope.region != config.region -> {:error, "unexpected region #{scope.region}"}
      scope.service != @service -> {:error, "unexpected service #{scope.service}"}
      true -> :ok
    end
  end

  # The declared payload hash must match the bytes that actually arrived.
  defp check_payload_hash(conn, body) do
    case get_req_header(conn, "x-amz-content-sha256") do
      [declared] ->
        if declared == sha256(body), do: :ok, else: {:error, "payload hash mismatch"}

      _ ->
        {:error, "missing x-amz-content-sha256"}
    end
  end

  defp check_signed_headers(conn, signed_names) do
    missing = Enum.reject(signed_names, fn name -> get_req_header(conn, name) != [] end)

    if missing == [], do: :ok, else: {:error, "unsignable headers: #{Enum.join(missing, ",")}"}
  end

  defp check_signature(conn, signed_names, scope, signature, config) do
    canonical = canonical_request(conn, signed_names)

    string_to_sign =
      Enum.join(
        [
          @algorithm,
          amz_date(conn),
          "#{scope.date}/#{scope.region}/#{scope.service}/aws4_request",
          sha256(canonical)
        ],
        "\n"
      )

    expected =
      ("AWS4" <> config.secret_access_key)
      |> hmac(scope.date)
      |> hmac(scope.region)
      |> hmac(scope.service)
      |> hmac("aws4_request")
      |> hmac(string_to_sign)
      |> Base.encode16(case: :lower)

    if expected == signature, do: :ok, else: {:error, "signature does not match"}
  end

  defp canonical_request(conn, signed_names) do
    headers =
      Enum.map_join(signed_names, fn name ->
        "#{name}:#{conn |> get_req_header(name) |> List.first() |> to_string() |> String.trim()}\n"
      end)

    Enum.join(
      [
        conn.method,
        conn.request_path,
        canonical_query(conn.query_string),
        headers,
        Enum.join(signed_names, ";"),
        get_req_header(conn, "x-amz-content-sha256") |> List.first()
      ],
      "\n"
    )
  end

  defp canonical_query(""), do: ""

  defp canonical_query(query_string) do
    query_string
    |> String.split("&")
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, value] -> {encode(name), encode(value)}
        [name] -> {encode(name), ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp amz_date(conn) do
    conn |> get_req_header("x-amz-date") |> List.first()
  end

  defp encode(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map_join(fn char ->
      if char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?_, ?., ?~] do
        <<char>>
      else
        "%" <> Base.encode16(<<char>>, case: :upper)
      end
    end)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # ─── helpers ───────────────────────────────────────────────────────────────

  defp split_path("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket] when bucket != "" -> {:ok, bucket, ""}
      [bucket, key] when bucket != "" -> {:ok, bucket, URI.decode(key)}
      _ -> :error
    end
  end

  defp split_path(_path), do: :error

  defp check_bucket(agent, bucket) do
    if bucket == config(agent).bucket, do: :ok, else: {:error, :no_such_bucket}
  end

  defp query_params(conn) do
    params =
      conn.query_string
      |> URI.decode_query()
      |> Map.new(fn {name, value} -> {name, value} end)

    {:ok, params}
  rescue
    _ -> {:error, :malformed_query}
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> value
      [] -> "application/octet-stream"
    end
  end

  defp incoming_metadata(conn) do
    conn.req_headers
    |> Enum.filter(fn {name, _value} -> String.starts_with?(name, "x-amz-meta-") end)
    |> Map.new(fn {name, value} -> {String.replace_prefix(name, "x-amz-meta-", ""), value} end)
  end

  defp put_metadata_headers(conn, metadata) do
    Enum.reduce(metadata, conn, fn {name, value}, acc ->
      put_resp_header(acc, "x-amz-meta-#{name}", value)
    end)
  end

  # Single-request uploads are identified by the MD5 of the body, as S3 does.
  defp etag_single(body), do: "\"#{:crypto.hash(:md5, body) |> Base.encode16(case: :lower)}\""

  # Multipart uploads are identified by the MD5 of the concatenated part MD5s
  # followed by the part count, as S3 does.
  defp etag_multipart(parts) do
    digests = Enum.map_join(parts, fn part -> :crypto.hash(:md5, part.body) end)
    md5 = :crypto.hash(:md5, digests) |> Base.encode16(case: :lower)
    "\"#{md5}-#{length(parts)}\""
  end

  defp record(agent, conn, accepted, verdict) do
    entry = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      accepted: accepted,
      verdict: verdict
    }

    Agent.update(agent, fn state -> %{state | requests: state.requests ++ [entry]} end)
  end

  defp error_xml(code, message) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      "<Error><Code>#{escape_xml(to_string(code))}</Code>" <>
      "<Message>#{escape_xml(to_string(message))}</Message></Error>"
  end

  defp escape_xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
