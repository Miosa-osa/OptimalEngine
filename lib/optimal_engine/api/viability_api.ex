defmodule OptimalEngine.API.ViabilityAPI do
  @moduledoc """
  Handlers for viability, Signal events, and agent action chains, called
  from `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `GET /api/viability?workspace=` (or `workspaces=*` for the org) | read |
  | `GET /api/viability/history?workspace=&days=` | read |
  | `GET /api/viability/metrics?workspace=&from=&to=` | read |
  | `POST /api/viability/snapshot {workspace or workspaces: "*", days}` | admin |
  | `GET /api/viability/audit?workspace=&state=` | read |
  | `POST /api/viability/audit/run {workspace, size}` | admin |
  | `POST /api/viability/audit/:id/review {workspace, decision, note}` | write |
  | `GET /api/signal-events?workspace=&kind=`, `POST /api/signal-events` | read, write |
  | `POST /api/signals/check {draft, receiver, genre, type, workspace}` (pre-send check) | write |
  | `GET /api/signals/classification?workspace=&plan=` (counts by genre and mode) | read |
  | `GET /api/agent-actions?workspace=`, `GET /api/agent-actions/:id?workspace=` | read |
  | `POST /api/agent-actions` (stages approval and denial need `authority:enforce`) | write |

  The org view covers the workspaces the caller's key may read; the org's
  stored history needs a key scoped to every workspace.
  """

  import Plug.Conn

  alias OptimalEngine.API.{Actor, OperatingAPI}
  alias OptimalEngine.Authority.ActionChain
  alias OptimalEngine.Signal.{PreSend, Reclassifier}
  alias OptimalEngine.Store
  alias OptimalEngine.Viability
  alias OptimalEngine.Viability.{Audit, Metrics, SignalEvents}

  # -- viability ---------------------------------------------------------------

  def report(conn) do
    conn = fetch_query_params(conn)

    if org?(conn) do
      json(
        conn,
        200,
        Viability.report(tenant(conn), scope: :org, workspace_ids: OperatingAPI.workspaces(conn))
      )
    else
      json(conn, 200, Viability.report(tenant(conn), workspace_ids: [workspace(conn)]))
    end
  end

  def history(conn) do
    conn = fetch_query_params(conn)
    days = int(conn.query_params["days"], 30)

    cond do
      org?(conn) and not full_scope?(conn) ->
        error(conn, 403, "org_history_needs_full_scope")

      org?(conn) ->
        json(conn, 200, Viability.history(tenant(conn), Viability.org(), days))

      true ->
        json(conn, 200, Viability.history(tenant(conn), workspace(conn), days))
    end
  end

  def metrics(conn) do
    conn = fetch_query_params(conn)
    today = Date.utc_today()

    with {:ok, from} <- date(conn.query_params["from"], Date.add(today, -6)),
         {:ok, to} <- date(conn.query_params["to"], today),
         true <- Date.compare(from, to) != :gt || {:error, :invalid_window},
         true <- Date.diff(to, from) <= 366 || {:error, :window_too_long} do
      ids = if org?(conn), do: org_ids(conn), else: [workspace(conn)]
      json(conn, 200, Metrics.compute(tenant(conn), ids, %{from: from, to: Date.add(to, 1)}))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def snapshot(conn) do
    body = body(conn)
    days = int(body["days"], 30)

    scope_key =
      if body["workspaces"] == "*", do: Viability.org(), else: body["workspace"] || "default"

    {:ok, written} = Viability.catch_up(tenant(conn), scope_key, days: days)
    json(conn, 200, %{scope: scope_key, written: written})
  end

  # -- System 3* audit -----------------------------------------------------------

  def audit_list(conn) do
    conn = fetch_query_params(conn)
    ids = if org?(conn), do: org_ids(conn), else: [workspace(conn)]

    json(conn, 200, %{
      samples:
        Audit.list(tenant(conn), ids,
          state: conn.query_params["state"],
          limit: int(conn.query_params["limit"], 50)
        )
    })
  end

  def audit_run(conn) do
    body = body(conn)

    {:ok, result} =
      Audit.run(tenant(conn), body["workspace"] || "default", size: int(body["size"], 10))

    json(conn, 200, result)
  end

  def audit_review(conn, id) do
    body = body(conn)
    workspace_id = body["workspace"] || "default"

    with :ok <- sample_in(tenant(conn), id, workspace_id),
         {:ok, state} <-
           Audit.review(tenant(conn), id, body["decision"], Actor.of(conn, body), body["note"]) do
      json(conn, 200, %{id: id, state: state})
    else
      {:error, :not_found} -> error(conn, 404, "audit sample not found")
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- Signal events -------------------------------------------------------------

  def events_create(conn) do
    body = body(conn)

    case SignalEvents.record(
           tenant(conn),
           Map.put_new(body, "workspace_id", body["workspace"]),
           Actor.of(conn, body)
         ) do
      {:ok, event} -> json(conn, 201, event)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def events_list(conn) do
    conn = fetch_query_params(conn)

    json(conn, 200, %{
      events:
        SignalEvents.list(tenant(conn), [workspace(conn)],
          kind: conn.query_params["kind"],
          limit: int(conn.query_params["limit"], 100)
        )
    })
  end

  # -- pre-send check ------------------------------------------------------------

  def pre_send(conn) do
    body = body(conn)

    case body["draft"] do
      draft when is_binary(draft) and draft != "" ->
        json(
          conn,
          200,
          PreSend.check(draft, body["receiver"] || %{},
            genre: body["genre"],
            type: body["type"],
            tenant_id: tenant(conn),
            workspace_id: body["workspace"],
            actor: Actor.of(conn, body)
          )
        )

      _ ->
        error(conn, 400, "draft is required")
    end
  end

  # -- classification ------------------------------------------------------------

  # Counts only: how the workspace's stored Signals are classified by genre
  # and mode, and with plan=true how re-running classification would
  # classify them (`OptimalEngine.Signal.Reclassifier.plan/1`), without
  # writing. No content, title, or id leaves the Engine.
  def classification(conn) do
    conn = fetch_query_params(conn)
    workspace_id = workspace(conn)
    scope = [tenant_id: tenant(conn)]
    plan? = conn.query_params["plan"] in ["true", "1"]

    with {:ok, stored} <- Reclassifier.distribution(workspace_id, scope),
         {:ok, scan} <- if(plan?, do: Reclassifier.plan(workspace_id, scope), else: {:ok, nil}) do
      classification_result(conn, workspace_id, stored, scan)
    else
      {:error, reason} -> store_error(conn, reason)
    end
  end

  defp classification_result(conn, workspace_id, stored, nil),
    do: json(conn, 200, %{workspace_id: workspace_id, signals: total(stored), stored: stored})

  defp classification_result(conn, workspace_id, stored, %{scanned: scanned, changes: changes}) do
    result = %{workspace_id: workspace_id, signals: total(stored), stored: stored}
    summary = Reclassifier.summarize(changes)

    plan = %{
      scanned: scanned,
      changes: length(changes),
      planned: Reclassifier.apply_to_distribution(stored, changes),
      planned_modes_by_stored_genre:
        Reclassifier.apply_to_distribution(stored, changes, keep_genre: true),
      mode_transitions: transitions(summary.mode),
      genre_transitions: transitions(summary.genre)
    }

    json(conn, 200, Map.put(result, :plan, plan))
  end

  # The Store did not answer: a busy Store is retryable, anything else is
  # reported without the exception.
  defp store_error(conn, reason) do
    if busy?(reason) do
      conn
      |> put_resp_header("retry-after", "1")
      |> json(503, %{error: "busy", detail: "the Engine's store is busy; retry shortly"})
    else
      json(conn, 500, %{error: "store_error"})
    end
  end

  defp busy?(:busy), do: true
  defp busy?(:timeout), do: true
  defp busy?(%{message: message}) when is_binary(message), do: message =~ ~r/busy|locked/i
  defp busy?(_reason), do: false

  defp total(distribution) do
    distribution |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.sum()
  end

  defp transitions(counts) do
    counts
    |> Enum.map(fn {{from, to}, count} -> %{from: from, to: to, count: count} end)
    |> Enum.sort_by(&(-&1.count))
  end

  # -- agent action chains -------------------------------------------------------

  def actions_record(conn) do
    body = body(conn)
    attrs = Map.put_new(body, "workspace_id", body["workspace"])

    case ActionChain.record(tenant(conn), attrs, Actor.of(conn, body)) do
      {:ok, step} ->
        json(conn, 201, step)

      {:error, {:evidence_failed, reason}} ->
        json(conn, 503, %{error: "evidence_failed", reason: inspect(reason)})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def actions_trace(conn, id) do
    conn = fetch_query_params(conn)

    case ActionChain.trace(tenant(conn), id) do
      {:ok, %{workspace_id: workspace_id} = chain} ->
        if workspace_id == workspace(conn),
          do: json(conn, 200, chain),
          else: error(conn, 404, "action chain not found")

      {:error, :not_found} ->
        error(conn, 404, "action chain not found")
    end
  end

  def actions_list(conn) do
    conn = fetch_query_params(conn)

    json(conn, 200, %{
      chains:
        ActionChain.list(tenant(conn), [workspace(conn)],
          limit: int(conn.query_params["limit"], 50)
        )
    })
  end

  # ---------------------------------------------------------------------------

  defp org?(conn), do: conn.query_params["workspaces"] == "*"

  defp org_ids(conn) do
    {:ok, workspaces} =
      OptimalEngine.Workspace.list(tenant_id: tenant(conn), status: :active, limit: 10_000)

    ids = Enum.map(workspaces, & &1.id)

    case OperatingAPI.workspaces(conn) do
      nil -> ids
      allowed -> Enum.filter(ids, &(&1 in allowed))
    end
  end

  defp full_scope?(conn) do
    case conn.assigns[:current_api_key] do
      nil -> true
      key -> "*" in (key.workspace_scope || [])
    end
  end

  defp sample_in(tenant_id, id, workspace_id) do
    case Store.raw_query(
           "SELECT 1 FROM audit_samples WHERE tenant_id = ?1 AND id = ?2 AND workspace_id = ?3",
           [tenant_id, id, workspace_id]
         ) do
      {:ok, [_]} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp workspace(conn),
    do:
      conn.query_params["workspace"] || conn.query_params["workspace_id"] ||
        conn.assigns[:workspace_id] || "default"

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp date(nil, default), do: {:ok, default}

  defp date(value, _default) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp int(nil, default), do: default

  defp int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> default
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
