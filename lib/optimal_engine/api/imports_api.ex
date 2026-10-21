defmodule OptimalEngine.API.ImportsAPI do
  @moduledoc """
  Handlers for import jobs, called from `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `POST /api/import/notion?workspace=` with a zip body, or `{workspace, source_url}` | write |
  | `GET /api/import/notion/:job_id?workspace=` | read |
  | `GET /api/import/notion/tree?workspace=&parent=` | read |

  An upload (`Content-Type: application/zip`) is streamed to the import's
  staging folder in pieces, never held whole in memory, and refused past
  `OptimalEngine.Imports.max_bytes/0`. A `source_url` is checked here and
  downloaded by the job (`OptimalEngine.Imports.Fetch`). Either way the
  answer is `202` with the job id; the job runs in the background. An
  `Idempotency-Key` header (or `idempotency_key`, at most 128 printable
  characters) makes a retried request return the first job instead of
  importing twice; it is checked before the body is read. A workspace with
  `OptimalEngine.Imports.max_outstanding/0` imports queued or running gets
  `429 too_many_imports`.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.API.IntParam
  alias OptimalEngine.Imports
  alias OptimalEngine.Imports.{Fetch, Notion}
  alias OptimalEngine.Workspace

  @zip_types ["application/zip", "application/x-zip-compressed"]
  @read_length 1_048_576
  @read_chunk 8 * 1_048_576
  @page_id ~r/\A[A-Za-z0-9-]{1,128}\z/
  @idempotency_key ~r/\A[\x21-\x7E]{1,128}\z/

  @doc "POST /api/import/notion"
  def notion(conn) do
    conn = fetch_query_params(conn)
    workspace = workspace(conn)

    with :ok <- active_workspace(conn, workspace),
         {:ok, key} <- idempotency_key(conn, body(conn)) do
      # A repeated key is answered before anything is read or staged.
      case Imports.existing(workspace, key, tenant_id: tenant(conn)) do
        {:ok, job} ->
          conn |> put_resp_header("connection", "close") |> accepted(workspace, job, :duplicate)

        :none ->
          start(conn, workspace, key)
      end
    else
      {:error, :not_found} -> error(conn, 404, "workspace not found")
      {:error, :invalid_idempotency_key} -> error(conn, 400, "invalid_idempotency_key")
    end
  end

  defp start(conn, workspace, key) do
    # A full workspace is refused before the body is read; enqueue checks
    # again under a lock, so the cap holds for requests that race.
    with :ok <- Imports.admit(workspace) do
      case content_type(conn) do
        "application/json" -> notion_url(conn, workspace, key)
        type when type in @zip_types -> notion_upload(conn, workspace, key)
        _ -> error(conn, 400, "source_required")
      end
    else
      {:error, :too_many_imports} -> too_many(conn)
    end
  end

  defp too_many(conn) do
    conn
    |> put_resp_header("connection", "close")
    |> json(429, %{error: "too_many_imports", max_outstanding: Imports.max_outstanding()})
  end

  @doc "GET /api/import/notion/:job_id"
  def notion_status(conn, job_id) do
    conn = fetch_query_params(conn)

    case Imports.status(job_id, workspace(conn)) do
      {:ok, view} -> json(conn, 200, view)
      {:error, :not_found} -> error(conn, 404, "import not found")
      {:error, _reason} -> error(conn, 500, "status_unavailable")
    end
  end

  @doc "GET /api/import/notion/tree"
  def notion_tree(conn) do
    conn = fetch_query_params(conn)
    q = conn.query_params

    parent =
      case q["parent"] do
        value when value in [nil, ""] -> nil
        value -> value
      end

    if parent && not Regex.match?(@page_id, parent) do
      error(conn, 400, "invalid_parent")
    else
      opts = [limit: int(q["limit"], 500), offset: int(q["offset"], 0), tenant_id: tenant(conn)]

      case Notion.tree(workspace(conn), parent, opts) do
        {:ok, tree} -> json(conn, 200, tree)
        {:error, :not_found} -> error(conn, 404, "page not found")
        {:error, _reason} -> error(conn, 500, "tree_unavailable")
      end
    end
  end

  # ── sources ────────────────────────────────────────────────────────────

  defp notion_upload(conn, workspace, key) do
    max = Imports.max_bytes()

    if declared_length(conn) > max do
      too_large(conn, max)
    else
      staged = Imports.stage()

      case stream_body(conn, staged.source, max) do
        {:ok, 0, conn} ->
          Imports.discard(staged)
          error(conn, 400, "empty_upload")

        {:ok, bytes, conn} ->
          source = %{"kind" => "upload", "bytes" => bytes}
          enqueue(conn, workspace, staged, source, key)

        {:too_large, conn} ->
          Imports.discard(staged)
          too_large(conn, max)

        {:error, _reason, conn} ->
          Imports.discard(staged)
          error(conn, 400, "upload_failed")
      end
    end
  end

  defp notion_url(conn, workspace, key) do
    case body(conn)["source_url"] do
      url when is_binary(url) and url != "" ->
        case Fetch.check(url) do
          :ok ->
            source = %{"kind" => "url", "url" => url}
            enqueue(conn, workspace, Imports.stage(), source, key)

          {:error, reason} ->
            error(conn, 400, Atom.to_string(reason))
        end

      _ ->
        error(conn, 400, "source_required")
    end
  end

  defp enqueue(conn, workspace, staged, source, key) do
    opts = [actor_id: Actor.of(conn, body(conn)), idempotency_key: key]

    case Imports.enqueue_notion(workspace, staged, source, opts) do
      {:ok, job, outcome} -> accepted(conn, workspace, job, outcome)
      {:error, :workspace_not_found} -> error(conn, 404, "workspace not found")
      {:error, :too_many_imports} -> too_many(conn)
      {:error, _reason} -> error(conn, 500, "import_unavailable")
    end
  end

  defp accepted(conn, workspace, job, outcome) do
    status =
      case outcome do
        :queued -> "queued"
        :duplicate -> existing_status(job, workspace)
      end

    json(conn, 202, %{
      job_id: job.id,
      kind: job.kind,
      workspace_id: workspace,
      status: status,
      duplicate: outcome == :duplicate,
      status_url: "/api/import/notion/#{job.id}?" <> URI.encode_query(%{"workspace" => workspace})
    })
  end

  defp existing_status(job, workspace) do
    case Imports.status(job.id, workspace) do
      {:ok, view} -> view.status
      _ -> job.status
    end
  end

  # The body is written to disk as it arrives; the request is refused the
  # moment it passes the cap, whatever Content-Length said.
  defp stream_body(conn, path, max) do
    {:ok, out} = File.open(path, [:write, :binary, :raw])
    :ok = File.chmod(path, 0o600)

    try do
      write_body(conn, out, 0, max)
    after
      File.close(out)
    end
  end

  defp write_body(conn, out, bytes, max) do
    case read_body(conn, length: @read_chunk, read_length: @read_length, read_timeout: 60_000) do
      {status, data, conn} when status in [:ok, :more] ->
        bytes = bytes + byte_size(data)

        cond do
          bytes > max ->
            {:too_large, conn}

          status == :ok ->
            :ok = IO.binwrite(out, data)
            {:ok, bytes, conn}

          true ->
            :ok = IO.binwrite(out, data)
            write_body(conn, out, bytes, max)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp declared_length(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> 0
    end
  end

  defp too_large(conn, max) do
    conn
    |> put_resp_header("connection", "close")
    |> json(413, %{error: "import_too_large", max_bytes: max})
  end

  # ── request helpers ────────────────────────────────────────────────────

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp active_workspace(conn, workspace) do
    tenant = tenant(conn)

    case Workspace.get(workspace) do
      {:ok, %{status: :active, tenant_id: ^tenant}} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp idempotency_key(conn, body) do
    key =
      case get_req_header(conn, "idempotency-key") do
        [key | _] when key != "" -> key
        _ -> body["idempotency_key"] || conn.query_params["idempotency_key"]
      end

    cond do
      key in [nil, ""] -> {:ok, nil}
      is_binary(key) and Regex.match?(@idempotency_key, key) -> {:ok, key}
      true -> {:error, :invalid_idempotency_key}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp workspace(conn),
    do: conn.assigns[:workspace_id] || conn.query_params["workspace"] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp int(value, default), do: IntParam.parse(value, default)

  defp error(conn, status, reason), do: json(conn, status, %{error: reason})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
