defmodule OptimalEngine.API.BundleJobsAPI do
  @moduledoc """
  The bundle job routes: an export or an import of a workspace bundle as a
  durable job (`OptimalEngine.Portability.BundleJobs`).

      POST /api/bundles/jobs/export   {"workspace_id", "for_move"?}
      POST /api/bundles/jobs/import   {"workspace_id", "mode"?, "organization_id"?,
                                       "cross_tenant"?, "bundle" | "source_url" + "sha256"}
      GET  /api/bundles/jobs          ?workspace_id=&status=&kind=&limit=
      GET  /api/bundles/jobs/:id
      POST /api/bundles/jobs/:id/cancel

  Every route needs the admin grant (`PermissionPlug`, `/api/bundles`). A job
  belongs to the tenant that started it: another tenant's job is not found.
  The key's workspace scope must cover the job's workspace (the export's
  source, the import's target): 403 `workspace_scope_denied` otherwise. An
  import of a stored `bundle` also needs a scope that covers the workspace the
  bundle was exported from: 404 `bundle_not_found` otherwise, as for the
  download. A start answers 202 with the job and its status URL in `Location`; the same
  `Idempotency-Key` with the same request answers 200 with that job and
  `"duplicate": true`.
  """

  import Plug.Conn

  alias OptimalEngine.API.{Actor, WorkspaceAuthPlug}
  alias OptimalEngine.Portability.{BundleJobs, WorkspaceBundle}

  def export(conn) do
    body = body(conn)

    with {:ok, workspace_id} <- workspace_param(body),
         :ok <- in_scope(conn, workspace_id) do
      conn
      |> started(
        BundleJobs.submit_export(tenant(conn), workspace_id, body,
          idempotency_key: idempotency_key(conn, body)
        )
      )
    else
      {:error, code, message} -> error(conn, status_of(code), code, message)
    end
  end

  def import(conn) do
    body = body(conn)

    with {:ok, workspace_id} <- workspace_param(body),
         :ok <- in_scope(conn, workspace_id),
         :ok <- bundle_in_scope(conn, body) do
      conn
      |> started(
        BundleJobs.submit_import(tenant(conn), body,
          idempotency_key: idempotency_key(conn, body),
          operator: Actor.engine_operator?(conn)
        )
      )
    else
      {:error, code, message} -> error(conn, status_of(code), code, message)
    end
  end

  def list(conn) do
    conn = fetch_query_params(conn)
    filters = Map.take(conn.query_params, ["workspace_id", "status", "kind", "limit"])

    jobs =
      conn
      |> tenant()
      |> BundleJobs.list(filters)
      |> Enum.filter(&WorkspaceAuthPlug.key_holds?(conn.assigns[:current_api_key], &1.workspace_id))

    json(conn, 200, %{jobs: jobs, count: length(jobs)})
  end

  def status(conn, job_id) do
    with {:ok, view} <- BundleJobs.status(tenant(conn), job_id),
         :ok <- in_scope(conn, view.workspace_id) do
      json(conn, 200, view)
    else
      {:error, :not_found} -> error(conn, 404, :job_not_found, "job not found")
      {:error, code, message} -> error(conn, status_of(code), code, message)
    end
  end

  def cancel(conn, job_id) do
    with {:ok, view} <- BundleJobs.status(tenant(conn), job_id),
         :ok <- in_scope(conn, view.workspace_id) do
      case BundleJobs.cancel(tenant(conn), job_id) do
        {:ok, view, :cancelled} -> json(conn, 200, view)
        {:ok, view, :requested} -> json(conn, 202, %{view | cancel_requested: true})
        {:error, :job_finished, view} -> json(conn, 409, %{error: "job_finished", job: view})
        {:error, :not_found} -> error(conn, 404, :job_not_found, "job not found")
      end
    else
      {:error, :not_found} -> error(conn, 404, :job_not_found, "job not found")
      {:error, code, message} -> error(conn, status_of(code), code, message)
    end
  end

  defp started(conn, {:ok, view, :queued}) do
    conn
    |> put_resp_header("location", "/api/bundles/jobs/" <> view.job_id)
    |> json(202, view)
  end

  defp started(conn, {:ok, view, :duplicate}) do
    conn
    |> put_resp_header("location", "/api/bundles/jobs/" <> view.job_id)
    |> json(200, %{view | duplicate: true})
  end

  defp started(conn, {:error, code, %{id: job_id}})
       when code in [:bundle_job_active, :idempotency_key_reused] do
    json(conn, 409, %{error: to_string(code), job_id: job_id})
  end

  defp started(conn, {:error, code, message}), do: error(conn, status_of(code), code, message)

  defp status_of(code) do
    case code do
      code when code in [:invalid_request, :invalid_idempotency_key, :source_url_not_allowed] -> 400
      code when code in [:forbidden, :operator_only, :workspace_scope_denied] -> 403
      code when code in [:workspace_not_found, :bundle_not_found, :job_not_found] -> 404
      code when code in [:workspace_exists, :bundle_job_active, :idempotency_key_reused] -> 409
      :bundle_too_large -> 413
      :insufficient_storage -> 507
      _ -> 500
    end
  end

  defp workspace_param(body) do
    case body["workspace_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_request, "workspace_id is required"}
    end
  end

  defp in_scope(conn, workspace_id) do
    if WorkspaceAuthPlug.key_holds?(conn.assigns[:current_api_key], workspace_id),
      do: :ok,
      else:
        {:error, :workspace_scope_denied,
         "the key's workspace scope does not cover #{workspace_id}"}
  end

  # A stored bundle holds the workspace it was exported from, so the key's
  # scope must cover that one as well as the target, as for the download: a
  # bundle it may not reach is not found. A name that is no bundle of the
  # tenant, or a source_url, is the job's to refuse.
  defp bundle_in_scope(conn, %{"bundle" => name}) when is_binary(name) do
    with {:ok, path} <- WorkspaceBundle.bundle_path(tenant(conn), name),
         true <- File.regular?(path) do
      case WorkspaceBundle.source_workspace(path) do
        {:ok, source} ->
          if WorkspaceAuthPlug.key_holds?(conn.assigns[:current_api_key], source),
            do: :ok,
            else: {:error, :bundle_not_found, "bundle not found"}

        {:error, _reason} ->
          {:error, :bundle_not_found, "bundle not found"}
      end
    else
      _ -> :ok
    end
  end

  defp bundle_in_scope(_conn, _body), do: :ok

  defp idempotency_key(conn, body) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] -> key
      [] -> body["idempotency_key"]
    end
  end

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp error(conn, status, code, message),
    do: json(conn, status, %{error: to_string(code), message: message})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
