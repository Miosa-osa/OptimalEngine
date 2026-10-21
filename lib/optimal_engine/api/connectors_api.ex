defmodule OptimalEngine.API.ConnectorsAPI do
  @moduledoc """
  Handlers for the connector routes, called from `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `GET /api/connectors?workspace=` | read |
  | `GET /api/connectors/:id` | read |
  | `POST /api/connectors {id, kind, workspace, config, credentials, enabled}` | `connectors:write` or `admin` |
  | `PATCH /api/connectors/:id {enabled, cadence, interval_ms, config, credentials, workspace}` | `connectors:write` or `admin` |
  | `DELETE /api/connectors/:id` | `connectors:write` or `admin` |
  | `POST /api/connectors/:id/run {wait, max_retries}` | write |

  Credentials are write-only: they arrive under `credentials` (sealed with
  `CONNECTOR_KEY`) or come from the broker (`config.credential_source:
  "broker"`), and a response only ever says `"stored"`, `"broker"` or
  `"none"`. A `config.broker_reference` is sealed the same way and answered
  as `"[redacted]"`. Without a named workspace, the list holds the connectors of every
  workspace the caller's key covers. A connector outside the key's workspaces
  is `404` on every `:id` route (`OptimalEngine.API.ConnectorScopePlug`).
  Registration, changes, deletion and runs asked for here are recorded in the
  authority evidence chain (`OptimalEngine.Connectors.Rows`).

  `POST /api/connectors/:id/run` waits for the run and answers with its
  result; with `{"wait": false}` it starts the run in the scheduler's task
  pool and answers `202`, and the connector's `last_run` shows the outcome.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{PullScheduler, Registry, Rows}
  alias OptimalEngine.Scope

  @patchable ~w(enabled cadence interval_ms config credentials workspace workspace_id)

  @statuses %{
    workspace_required: 400,
    invalid_id: 400,
    invalid_config: 400,
    invalid_enabled: 400,
    invalid_credentials: 400,
    workspace_not_found: 404,
    not_found: 404,
    connector_exists: 409,
    workspace_archived: 409,
    already_running: 409,
    connector_disabled: 409,
    unknown_kind: 422,
    credentials_outside_envelope: 422,
    broker_credentials_must_not_be_stored: 422,
    broker_url_not_allowed: 422,
    invalid_credential_source: 422,
    invalid_cadence: 422,
    invalid_outward_topic: 422,
    invalid_walled_workspaces: 422,
    invalid_review_workspace: 422,
    no_intake_workspace: 422,
    connector_key_missing: 503,
    scheduler_unavailable: 503
  }

  def list(conn) do
    conn = fetch_query_params(conn)

    workspace_ids =
      case conn.query_params["workspace"] || conn.query_params["workspace_id"] do
        # Named: WorkspaceAuthPlug has authorized it for this key.
        workspace_id when is_binary(workspace_id) and workspace_id != "" -> [workspace_id]
        _none -> visible_workspaces(conn)
      end

    json(conn, 200, %{
      connectors: Rows.list(tenant(conn), workspace_ids: workspace_ids),
      scheduler: scheduler(conn, workspace_ids)
    })
  end

  def show(conn, _id), do: json(conn, 200, conn.assigns.connector)

  def create(conn) do
    body = body(conn)

    attrs = %{
      id: body["id"],
      kind: body["kind"],
      tenant_id: tenant(conn),
      workspace_id: body["workspace"] || body["workspace_id"],
      config: Map.get(body, "config") || %{},
      credentials: body["credentials"],
      enabled: Map.get(body, "enabled", true)
    }

    case Rows.register(attrs, actor: Actor.of(conn)) do
      {:ok, view} -> json(conn, 201, view)
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, id) do
    changes = conn |> body() |> Map.take(@patchable)

    case Rows.update(tenant(conn), id, changes, actor: Actor.of(conn)) do
      {:ok, view} -> json(conn, 200, view)
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, id) do
    case Rows.delete(tenant(conn), id, actor: Actor.of(conn)) do
      :ok -> json(conn, 200, %{deleted: id})
      {:error, reason} -> error(conn, reason)
    end
  end

  def run(conn, _id) do
    body = body(conn)
    view = conn.assigns.connector

    cond do
      not view.enabled -> error(conn, :connector_disabled)
      body["wait"] == false -> start_run(conn, view)
      true -> run_now(conn, view, body)
    end
  end

  @doc """
  Connector status for `GET /api/metrics`, limited to the workspaces the
  caller's key covers. Never fails the metrics response.
  """
  @spec metrics(Plug.Conn.t()) :: map()
  def metrics(conn) do
    Rows.summary(tenant(conn), workspace_ids: visible_workspaces(conn))
  rescue
    _ -> %{}
  catch
    :exit, _reason -> %{}
  end

  @doc """
  The workspaces whose connectors the caller may see: `:all`, or the
  workspaces in the key's `workspace_scope`, narrowed to the one workspace a
  workspace-scoped Engine serves.
  """
  @spec visible_workspaces(Plug.Conn.t()) :: :all | [String.t()]
  def visible_workspaces(conn) do
    key_scope =
      case conn.assigns[:current_api_key] do
        nil -> :all
        key -> if "*" in (key.workspace_scope || []), do: :all, else: key.workspace_scope || []
      end

    case {Scope.engine_scope(), key_scope} do
      {%{mode: "workspace", workspace_id: served}, :all} -> [served]
      {%{mode: "workspace", workspace_id: served}, scope} -> Enum.filter(scope, &(&1 == served))
      {_org, scope} -> scope
    end
  end

  # ---------------------------------------------------------------------------

  defp run_now(conn, view, body) do
    opts =
      [signal_sink: PullScheduler.intake_sink()]
      |> maybe_put(:max_retries, positive_int(body["max_retries"]))

    case Connectors.run(view.id, opts) do
      {:ok, result} ->
        Rows.record_run(tenant(conn), view, [actor: Actor.of(conn)], %{
          "wait" => true,
          "status" => to_string(result.status),
          "signals" => result.signals
        })

        json(conn, 200, run_result(result))

      {:error, :disabled} ->
        error(conn, :connector_disabled)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp start_run(conn, view) do
    case PullScheduler.start_run(view.id, tenant_id: tenant(conn)) do
      {:ok, :started} ->
        Rows.record_run(tenant(conn), view, [actor: Actor.of(conn)], %{"wait" => false})

        json(conn, 202, %{status: "started", connector_id: view.id, workspace_id: view.workspace_id})

      {:error, reason} ->
        error(conn, reason)
    end
  catch
    :exit, _reason -> error(conn, :scheduler_unavailable)
  end

  defp run_result(result) do
    %{
      connector_id: result.connector_id,
      workspace_id: result.workspace_id,
      status: to_string(result.status),
      signals: result.signals,
      errors: result.errors,
      assets: Map.get(result, :assets, 0),
      reason: reason(result.reason)
    }
  end

  # The scheduler's settings, and the running connectors this caller may see.
  defp scheduler(conn, workspace_ids) do
    status = PullScheduler.status()

    running =
      for run <- status.running,
          workspace_ids == :all or run.workspace_id in workspace_ids,
          do: run.connector_id

    %{
      enabled: status.enabled,
      tenant_id: status.tenant_id,
      tick_ms: status.tick_ms,
      interval_ms: status.interval_ms,
      max_concurrency: status.max_concurrency,
      last_tick_at: status.last_run_at,
      running: if(status.tenant_id == tenant(conn), do: running, else: [])
    }
  catch
    :exit, _reason -> %{enabled: false, running: []}
  end

  defp error(conn, :unknown_kind),
    do: json(conn, 422, %{error: "unknown_kind", kinds: Registry.kinds()})

  defp error(conn, :not_found), do: json(conn, 404, %{error: "connector not found"})

  defp error(conn, reason) when is_atom(reason) do
    json(conn, Map.get(@statuses, reason, 422), %{error: Atom.to_string(reason)})
  end

  defp error(conn, reason), do: json(conn, 422, %{error: inspect(reason)})

  defp reason(nil), do: nil
  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  defp positive_int(value) when is_integer(value) and value >= 0, do: value
  defp positive_int(_value), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
