defmodule OptimalEngine.API.ScopeAPI do
  @moduledoc """
  Handlers for Engine scope, share-up policy, federated search, workspace
  bundles (split, merge, seed), and `optimal://` resolution, called from
  `OptimalEngine.API.Router`.

  Bundles are written to and read from the `bundles` folder of the backup
  directory, so a request can never name an arbitrary path on the host.
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

    path = Path.join(bundle_dir(), name)

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

      {:error, reason} ->
        error(conn, 422, inspect(reason))
    end
  end

  def download_bundle(conn, name) do
    conn = allow_long_request(conn)

    with {:ok, path} <- bundle_path(name),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> send_file(200, path)
    else
      _ -> error(conn, 404, "bundle not found")
    end
  end

  # Body: {"bundle": "<name in the bundles folder>"} or a raw gzip body
  # (content-type application/gzip) with ?mode=&workspace_id=.
  def import_bundle(conn) do
    conn = conn |> allow_long_request() |> fetch_query_params()

    {source, params, conn} =
      case get_req_header(conn, "content-type") do
        ["application/gzip" <> _ | _] ->
          path = Path.join(bundle_dir(), "upload-#{System.unique_integer([:positive])}.tar.gz")

          case write_body(conn, path) do
            {:ok, conn} ->
              {{:ok, path, :temporary}, conn.query_params, conn}

            {:error, reason, conn} ->
              File.rm(path)
              {{:error, {:upload_failed, reason}}, conn.query_params, conn}
          end

        _ ->
          body = body(conn)

          case bundle_path(body["bundle"] || "") do
            {:ok, path} -> {{:ok, path, :kept}, body, conn}
            error -> {error, body, conn}
          end
      end

    with {:ok, path, lifetime} <- source do
      mode = if params["mode"] == "merge", do: :merge, else: :create

      opts = [
        mode: mode,
        workspace_id: params["workspace_id"],
        organization_id: params["organization_id"],
        consume: lifetime == :temporary
      ]

      opts = Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

      try do
        case WorkspaceBundle.import(path, tenant(conn), opts) do
          {:ok, summary} -> json(conn, 201, summary)
          {:error, reason} -> error(conn, 422, inspect(reason))
        end
      after
        if lifetime == :temporary, do: File.rm(path)
      end
    else
      {:error, {:upload_failed, reason}} -> error(conn, 400, "upload failed: #{inspect(reason)}")
      _ -> error(conn, 404, "bundle not found")
    end
  end

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
  # busy for minutes while nothing arrives from the client, and Cowboy closes a
  # connection that receives nothing for its idle timeout (180 s, see
  # OptimalEngine.API.Endpoint), which would cut the request off midway. These
  # routes raise the timeout for their own request only.
  @long_request_ms :timer.hours(1)

  defp allow_long_request(%Plug.Conn{adapter: {Plug.Cowboy.Conn, req}} = conn) do
    :cowboy_req.cast({:set_options, %{idle_timeout: @long_request_ms}}, req)
    conn
  end

  defp allow_long_request(conn), do: conn

  # A raw upload is written to disk as it arrives, so a bundle of any size is
  # never held in memory.
  defp write_body(conn, path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, file} ->
        try do
          copy_body(conn, file)
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp copy_body(conn, file) do
    case read_body(conn, length: 8 * 1024 * 1024) do
      {status, data, conn} when status in [:ok, :more] ->
        case :file.write(file, data) do
          :ok when status == :ok -> {:ok, conn}
          :ok -> copy_body(conn, file)
          {:error, reason} -> {:error, reason, conn}
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp bundle_dir do
    base =
      case Application.get_env(:optimal_engine, :backup_dir) do
        dir when is_binary(dir) and dir != "" ->
          Path.expand(dir)

        _ ->
          Application.get_env(:optimal_engine, :db_path, ".optimal/index.db")
          |> Path.expand()
          |> Path.dirname()
          |> Path.join("backups")
      end

    dir = Path.join(base, "bundles")
    File.mkdir_p!(dir)
    dir
  end

  defp bundle_path(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.tar\.gz\z/, name),
      do: {:ok, Path.join(bundle_dir(), name)},
      else: {:error, :invalid_bundle_name}
  end

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
