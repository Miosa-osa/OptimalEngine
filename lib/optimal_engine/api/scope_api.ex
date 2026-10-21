defmodule OptimalEngine.API.ScopeAPI do
  @moduledoc """
  Handlers for Engine scope, share-up policy, federated search, workspace
  bundles (split, merge, seed), and `optimal://` resolution, called from
  `OptimalEngine.API.Router`.

  Bundles are written to and read from the caller's tenant folder,
  `<backup dir>/bundles/<tenant>/` (`WorkspaceBundle.bundle_dir/1`), so a
  request can never name an arbitrary path on the host or reach another
  tenant's bundles. A bundle whose manifest names another tenant is refused as
  well, unless the Engine operator asks for it with `cross_tenant: true`.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.{Federation, Scope}
  alias OptimalEngine.Portability.WorkspaceBundle

  def scope(conn) do
    json(conn, 200, Map.put(Scope.engine_scope(), :tenant_id, tenant(conn)))
  end

  def set_share(conn, workspace_id) do
    body = body(conn)

    case Scope.set_share_up(
           tenant(conn),
           URI.decode(workspace_id),
           body["share_up"],
           Actor.of(conn, body),
           visibility: body["visibility"]
         ) do
      {:ok, result} -> json(conn, 200, result)
      {:error, :not_found} -> error(conn, 404, "workspace not found")
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def federated_search(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params["q"] || ""

    if String.trim(query) == "" do
      error(conn, 400, "q is required")
    else
      allowed =
        case conn.assigns[:current_api_key] do
          nil -> nil
          key -> if "*" in key.workspace_scope, do: nil, else: key.workspace_scope
        end

      limit =
        case Integer.parse(conn.query_params["limit"] || "10") do
          {n, ""} -> n
          _ -> 10
        end

      json(conn, 200, Federation.search(tenant(conn), query, allowed: allowed, limit: limit))
    end
  end

  def list_peers(conn), do: json(conn, 200, %{peers: Federation.peers(tenant(conn))})

  def add_peer(conn) do
    body = body(conn)

    case Federation.add_peer(tenant(conn), body, Actor.of(conn, body)) do
      {:ok, peer} -> json(conn, 201, peer)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def remove_peer(conn, workspace_id) do
    :ok = Federation.remove_peer(tenant(conn), URI.decode(workspace_id))
    json(conn, 200, %{removed: URI.decode(workspace_id)})
  end

  def export_bundle(conn, workspace_id) do
    conn = allow_long_request(conn)
    workspace_id = URI.decode(workspace_id)
    body = body(conn)

    name =
      "#{String.replace(workspace_id, ~r/[^A-Za-z0-9_-]+/, "-")}-#{System.os_time(:second)}.tar.gz"

    path = Path.join(WorkspaceBundle.bundle_dir(tenant(conn)), name)

    with :ok <- if(body["for_move"] == true, do: WorkspaceBundle.movable(workspace_id), else: :ok),
         {:ok, manifest} <- WorkspaceBundle.export(tenant(conn), workspace_id, path) do
      if body["for_move"] == true,
        do: WorkspaceBundle.prepare_move(tenant(conn), workspace_id, manifest["bundle_sha256"])

      json(conn, 201, %{
        bundle: name,
        bundle_sha256: manifest["bundle_sha256"],
        tables: length(manifest["tables"]),
        rows: Enum.sum(Enum.map(manifest["tables"], & &1["rows"])),
        files: length(manifest["files"]),
        for_move: body["for_move"] == true,
        # A replica seeded from this bundle pulls from this ledger mark.
        ledger_sequence: manifest["ledger_sequence"]
      })
    else
      {:error, :workspace_directory_shared} ->
        error(conn, 409, :workspace_directory_shared)

      {:error, :not_found} ->
        error(conn, 404, "workspace not found")

      {:error, :writes_in_progress} ->
        conn
        |> put_resp_header("retry-after", "5")
        |> error(
          503,
          "writes_in_progress: the workspace kept receiving writes while the export started; retry, or pause them"
        )

      {:error, reason} ->
        error(conn, 422, inspect(reason))
    end
  end

  def download_bundle(conn, name) do
    conn = conn |> allow_long_request() |> fetch_query_params()
    tenant = tenant(conn)

    with {:ok, path} <- WorkspaceBundle.bundle_path(tenant, name),
         true <- File.regular?(path) || {:error, :not_found},
         {:ok, cross_tenant} <- cross_tenant(conn, conn.query_params),
         :ok <- from_tenant(path, tenant, cross_tenant) do
      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> send_file(200, path)
    else
      {:error, :operator_only} -> operator_only(conn)
      _ -> error(conn, 404, "bundle not found")
    end
  end

  # Body: {"bundle": "<name in the tenant's bundles folder>", "mode"?,
  # "workspace_id"?, "organization_id"?, "cross_tenant"?}, or the raw gzip file
  # (content-type application/gzip) with the same options as query parameters
  # and an optional x-bundle-sha256 header.
  def import_bundle(conn) do
    conn = fetch_query_params(conn)

    case get_req_header(conn, "content-type") do
      ["application/gzip" <> _ | _] -> import_upload(conn)
      _ -> conn |> allow_long_request() |> import_by_name()
    end
  end

  # A bundle already in the tenant's folder (placed there by an export, or by a
  # control plane that uploaded and checked it). The file is left in place.
  defp import_by_name(conn) do
    body = body(conn)

    with {:ok, path} <- WorkspaceBundle.bundle_path(tenant(conn), body["bundle"]),
         true <- File.regular?(path) do
      run_import(conn, path, body, consume: false, foreign: :not_found)
    else
      _ -> error(conn, 404, "bundle not found")
    end
  end

  # The raw file is streamed to `bundle.part` in an owner-only folder of its
  # own, `.upload-N` in the tenant's folder, a chunk at a time, hashed as it
  # arrives, refused past the size limit and the upload deadline, so a bundle
  # of any size is never held in memory. Complete and checked, it is renamed
  # `bundle.tar.gz` and imported. The leading dot keeps the folder apart from
  # every bundle name (WorkspaceBundle.bundle_path/2).
  #
  # The body is read under the HTTP server's own idle limits: a client that
  # goes silent is closed. Only the import that follows is kept open as long as
  # it runs (allow_long_request/1). A process watching the request removes the
  # folder when it ends, also when the connection kills it, which runs no
  # `after`; an Engine that stopped mid-upload removes it at its next boot
  # (WorkspaceBundle.sweep_leftovers/0).
  defp import_upload(conn) do
    upload =
      Path.join(
        WorkspaceBundle.bundle_dir(tenant(conn)),
        ".upload-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(upload)
    File.chmod!(upload, 0o700)
    part = Path.join(upload, "bundle.part")
    path = Path.join(upload, "bundle.tar.gz")
    remove_when_done(upload)

    try do
      with {:ok, expected} <- declared_sha256(conn),
           :ok <- declared_size_allowed(conn),
           {:ok, conn, digest} <- receive_upload(conn, part),
           :ok <- digest_matches(digest, expected),
           :ok <- File.rename(part, path) do
        conn
        |> allow_long_request()
        |> run_import(path, conn.query_params, consume: true, foreign: :refused)
      else
        {:error, :invalid_sha256} ->
          error(conn, 400, "x-bundle-sha256 must be 64 hexadecimal characters")

        {:error, :too_large} ->
          error(conn, 413, "the bundle is larger than #{max_upload_bytes()} bytes")

        {:error, :too_large, conn} ->
          error(conn, 413, "the bundle is larger than #{max_upload_bytes()} bytes")

        {:error, :insufficient_storage} ->
          insufficient_storage(conn)

        # The disk filled while the bundle arrived.
        {:error, :enospc, conn} ->
          insufficient_storage(conn)

        {:error, {:sha256_mismatch, actual}} ->
          json(conn, 422, %{error: "bundle_sha256_mismatch", received_sha256: actual})

        {:error, :upload_timeout, conn} ->
          error(
            conn,
            408,
            "upload_timeout: the bundle did not arrive within #{div(upload_deadline_ms(), 1_000)} s"
          )

        {:error, reason, conn} ->
          error(conn, 400, "upload failed: #{inspect(reason)}")

        {:error, reason} ->
          error(conn, 500, "upload failed: #{inspect(reason)}")
      end
    after
      File.rm_rf(upload)
    end
  end

  defp remove_when_done(folder) do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> File.rm_rf(folder)
      end
    end)
  end

  defp insufficient_storage(conn) do
    error(
      conn,
      507,
      "insufficient_storage: the disk cannot hold this bundle and what it unpacks to"
    )
  end

  defp run_import(conn, path, params, extra) do
    with {:ok, cross_tenant} <- cross_tenant(conn, params) do
      mode = if params["mode"] == "merge", do: :merge, else: :create

      opts =
        [
          mode: mode,
          workspace_id: params["workspace_id"],
          organization_id: params["organization_id"],
          consume: Keyword.fetch!(extra, :consume),
          cross_tenant: cross_tenant
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      foreign = Keyword.fetch!(extra, :foreign)

      case WorkspaceBundle.import(path, tenant(conn), opts) do
        {:ok, summary} ->
          json(conn, 201, summary)

        # By name, another tenant's bundle is answered as absent; the uploader
        # of a raw file already holds it, so it is told why.
        {:error, :bundle_from_another_tenant} when foreign == :not_found ->
          error(conn, 404, "bundle not found")

        {:error, :bundle_from_another_tenant} ->
          error(
            conn,
            403,
            "bundle_from_another_tenant: only the Engine operator imports another tenant's bundle, with cross_tenant=true"
          )

        {:error, :insufficient_storage} ->
          insufficient_storage(conn)

        {:error, :bundle_too_large} ->
          error(conn, 413, "bundle_too_large: the bundle unpacks to more than this Engine accepts")

        {:error, reason} ->
          error(conn, 422, inspect(reason))
      end
    else
      {:error, :operator_only} -> operator_only(conn)
    end
  end

  # cross_tenant (body or query, true or "true") is honored for the Engine
  # operator alone; anyone else asking for it is refused.
  defp cross_tenant(conn, params) do
    requested = params["cross_tenant"] in [true, "true"]

    cond do
      not requested -> {:ok, false}
      Actor.engine_operator?(conn) -> {:ok, true}
      true -> {:error, :operator_only}
    end
  end

  defp from_tenant(_path, _tenant, true), do: :ok

  defp from_tenant(path, tenant, false) do
    case WorkspaceBundle.source_tenant(path) do
      {:ok, ^tenant} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp operator_only(conn),
    do: error(conn, 403, "operator_only: cross_tenant needs the Engine operator's key")

  def finalize_move(conn, workspace_id) do
    body = body(conn)

    case WorkspaceBundle.finalize_move(
           tenant(conn),
           URI.decode(workspace_id),
           body["bundle_sha256"],
           body
         ) do
      {:ok, result} -> json(conn, 200, result)
      {:error, :workspace_directory_shared} -> error(conn, 409, :workspace_directory_shared)
      {:error, reason} -> error(conn, 409, inspect(reason))
    end
  end

  def resolve(conn) do
    conn = fetch_query_params(conn)

    case WorkspaceBundle.resolve(tenant(conn), conn.query_params["uri"] || "") do
      {:local, uri} -> json(conn, 200, %{status: "local", uri: uri})
      {:moved, location} -> json(conn, 200, Map.put(location, "status", "moved"))
      {:error, reason} -> error(conn, 404, reason)
    end
  end

  # ---------------------------------------------------------------------------

  # Exporting, importing, or downloading a large workspace keeps one request
  # busy for minutes while nothing arrives from the client. Cowboy closes such a
  # connection twice over: after its idle timeout with no data received (180 s,
  # OptimalEngine.API.Endpoint) and after its inactivity timeout with no message
  # at all reaching the connection process (300 s). For these routes a watcher
  # raises the idle timeout for this request and messages the connection every
  # minute until the request process ends, so neither cuts the request off.
  @long_request_idle_ms :timer.minutes(10)

  defp allow_long_request(%Plug.Conn{adapter: {Plug.Cowboy.Conn, req}} = conn) do
    owner = self()
    :cowboy_req.cast({:set_options, %{idle_timeout: @long_request_idle_ms}}, req)

    spawn(fn ->
      ref = Process.monitor(owner)
      keep_connection_open(req, ref)
    end)

    conn
  end

  defp allow_long_request(conn), do: conn

  defp keep_connection_open(req, ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      long_request_tick_ms() ->
        :cowboy_req.cast({:set_options, %{idle_timeout: @long_request_idle_ms}}, req)
        keep_connection_open(req, ref)
    end
  end

  # How often the watcher messages the connection (`config :optimal_engine,
  # :bundle_long_request_tick_ms`, a minute by default).
  defp long_request_tick_ms,
    do: Application.get_env(:optimal_engine, :bundle_long_request_tick_ms, :timer.minutes(1))

  @default_max_upload_bytes 5 * 1024 * 1024 * 1024
  @default_upload_chunk_bytes 8 * 1024 * 1024

  # OPTIMAL_BUNDLE_MAX_BYTES (config :optimal_engine, :bundle_max_bytes).
  defp max_upload_bytes,
    do: Application.get_env(:optimal_engine, :bundle_max_bytes, @default_max_upload_bytes)

  defp upload_chunk_bytes,
    do:
      Application.get_env(:optimal_engine, :bundle_upload_chunk_bytes, @default_upload_chunk_bytes)

  # How long a raw upload may take from its first byte to its last
  # (`config :optimal_engine, :bundle_upload_deadline_ms`, one hour by default),
  # so a client that trickles bytes cannot hold the request forever.
  defp upload_deadline_ms,
    do: Application.get_env(:optimal_engine, :bundle_upload_deadline_ms, :timer.hours(1))

  defp declared_sha256(conn) do
    case get_req_header(conn, "x-bundle-sha256") do
      [] ->
        {:ok, nil}

      [value | _] ->
        value = value |> String.trim() |> String.downcase()

        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
          do: {:ok, value},
          else: {:error, :invalid_sha256}
    end
  end

  # A Content-Length past the limit, or more than the disk has free, is
  # refused before a byte is read. Whether the disk also holds what the
  # bundle unpacks to is checked once it is here (WorkspaceBundle.import/3).
  defp declared_size_allowed(conn) do
    max = max_upload_bytes()

    case get_req_header(conn, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {declared, ""} when declared > max -> {:error, :too_large}
          {declared, ""} -> room_for(WorkspaceBundle.bundle_dir(tenant(conn)), declared)
          _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp room_for(dir, bytes) do
    case WorkspaceBundle.free_bytes(dir) do
      free when is_integer(free) and free < bytes -> {:error, :insufficient_storage}
      _ -> :ok
    end
  end

  defp receive_upload(conn, path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, file} ->
        try do
          deadline = System.monotonic_time(:millisecond) + upload_deadline_ms()
          copy_body(conn, file, 0, :crypto.hash_init(:sha256), deadline)
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  # Each chunk is counted, hashed and written before the next is read, and
  # reported as [:optimal_engine, :bundle, :upload_chunk] with its byte size.
  defp copy_body(conn, file, received, hash, deadline) do
    case read_body(conn, upload_read_opts(conn, deadline)) do
      {status, data, conn} when status in [:ok, :more] ->
        received = received + byte_size(data)

        :telemetry.execute(
          [:optimal_engine, :bundle, :upload_chunk],
          %{bytes: byte_size(data)},
          %{}
        )

        cond do
          received > max_upload_bytes() ->
            {:error, :too_large, conn}

          status == :more and System.monotonic_time(:millisecond) >= deadline ->
            {:error, :upload_timeout, conn}

          true ->
            write_chunk(conn, file, data, status, received, hash, deadline)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp write_chunk(conn, file, data, status, received, hash, deadline) do
    hash = :crypto.hash_update(hash, data)

    case :file.write(file, data) do
      :ok when status == :ok ->
        {:ok, conn, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      :ok ->
        copy_body(conn, file, received, hash, deadline)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  # Under Cowboy, `length: 0` returns after the first read that brings data:
  # a read takes at most a chunk and waits at most 15 s, never past the
  # deadline. The deadline is therefore checked at least every 15 s, also
  # against a client that sends a byte now and then (with a whole chunk as
  # the length, Plug.Cowboy would keep reading such a client until the chunk
  # filled). A client that sends nothing is closed by Cowboy's idle timeout.
  # Plug.Test reads a chunk at a time.
  defp upload_read_opts(%Plug.Conn{adapter: {Plug.Cowboy.Conn, _req}}, deadline),
    do: [length: 0, read_length: upload_chunk_bytes(), read_timeout: upload_read_timeout(deadline)]

  defp upload_read_opts(_conn, _deadline), do: [length: upload_chunk_bytes()]

  # One read waits at most 15 s for data, and never past the deadline.
  defp upload_read_timeout(deadline),
    do: deadline |> Kernel.-(System.monotonic_time(:millisecond)) |> max(1) |> min(15_000)

  defp digest_matches(_digest, nil), do: :ok
  defp digest_matches(digest, digest), do: :ok
  defp digest_matches(digest, _expected), do: {:error, {:sha256_mismatch, digest}}

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp error(conn, status, reason) when is_atom(reason),
    do: error(conn, status, Atom.to_string(reason))

  defp error(conn, status, reason), do: json(conn, status, %{error: reason})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
