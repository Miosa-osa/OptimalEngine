defmodule OptimalEngine.API.SyncAPI do
  @moduledoc """
  Handlers for replication routes, called from `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `GET /api/sync/changes?workspace=&since=` | sync |
  | `GET /api/sync/tables` (the replicated and local tables of this Engine) | sync |
  | `POST /api/sync/changes` (apply a batch from a peer, with its `base_seq` and `base_replica_id`) | sync |
  | `POST /api/sync/enable`, `POST /api/sync/peers`, `POST /api/sync/run`, `POST /api/sync/conflicts/:id/resolve` | admin |
  | `GET /api/sync/status?workspace=`, `GET /api/sync/conflicts?workspace=` | read |
  """

  import Plug.Conn

  require Logger

  alias OptimalEngine.API.{Actor, Reader}
  alias OptimalEngine.ReadScope
  alias OptimalEngine.Sync

  def changes(conn) do
    conn = fetch_query_params(conn)
    q = conn.query_params
    workspace_id = q["workspace"] || q["workspace_id"]

    cond do
      is_nil(workspace_id) ->
        error(conn, 400, "workspace is required")

      not Sync.enabled?(workspace_id) ->
        error(conn, 409, "sync_not_enabled")

      true ->
        requester = conn |> get_req_header("x-optimal-replica") |> List.first()
        since = int(q["since"], 0)

        json(
          conn,
          200,
          Sync.changes(tenant(conn), workspace_id,
            since: since,
            limit: int(q["limit"], 500),
            requester: requester
          )
        )
    end
  end

  def apply(conn) do
    body = body(conn)
    workspace_id = body["workspace"] || body["workspace_id"]

    with true <- is_binary(workspace_id) || {:error, :workspace_required},
         true <- Sync.enabled?(workspace_id) || {:error, :sync_not_enabled},
         :ok <- Sync.compatible(body["engine"] || %{}),
         mutations when is_list(mutations) <- body["mutations"] || {:error, :mutations_required},
         {:ok, base} <- base_opts(body),
         {:ok, result} <- Sync.apply_changes(tenant(conn), workspace_id, mutations, base) do
      json(conn, 200, Map.put(result, :engine, Sync.engine_info()))
    else
      {:error, {:version_mismatch, message}} ->
        json(conn, 409, %{error: "version_mismatch", message: message})

      {:error, :sync_not_enabled} ->
        error(conn, 409, "sync_not_enabled")

      {:error, reason} ->
        error(conn, 422, reason)

      # `mutations` was sent but is not a list.
      _not_a_list ->
        error(conn, 422, :mutations_required)
    end
  end

  @doc """
  `GET /api/sync/tables`: the tables this Engine replicates and the ones it
  keeps local, with its schema migration. Static for a given build, so it
  names no workspace.
  """
  def tables(conn), do: json(conn, 200, Sync.tables())

  def enable(conn) do
    body = body(conn)
    workspace_id = body["workspace"] || body["workspace_id"]

    if is_binary(workspace_id) do
      case Sync.enable(tenant(conn), workspace_id, Actor.of(conn, body)) do
        {:ok, result} -> json(conn, 200, result)
        {:error, {:unsupported, message}} -> error(conn, 501, message)
      end
    else
      error(conn, 400, "workspace is required")
    end
  end

  def add_peer(conn) do
    body = body(conn)
    attrs = Map.put_new(body, "workspace_id", body["workspace"])

    case Sync.add_peer(tenant(conn), attrs, Actor.of(conn, body)) do
      {:ok, peer} -> json(conn, 201, peer)
      {:error, {:unsupported, message}} -> error(conn, 501, message)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def run(conn), do: json(conn, 200, %{results: Enum.map(Sync.run_all(), &plain/1)})

  def status(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["workspace"] do
      nil -> error(conn, 400, "workspace is required")
      workspace_id -> json(conn, 200, Sync.status(tenant(conn), workspace_id))
    end
  end

  def conflicts(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["workspace"] do
      nil ->
        error(conn, 400, "workspace is required")

      workspace_id ->
        # A conflict holds both versions of a row. A keyed reader sees the
        # versions its label and partition grants cover (see ReadScope).
        try do
          {conflicts, note} =
            tenant(conn)
            |> Sync.conflicts(workspace_id, conn.query_params["state"] || "open")
            |> then(
              &ReadScope.redact_conflicts(Reader.scope(conn, ceiling: true), workspace_id, &1)
            )

          json(conn, 200, %{
            conflicts: conflicts,
            withheld: note.withheld,
            complete: note.withheld == 0 and note.redacted == 0
          })
        rescue
          # The gate could not read the Store: refused whole, never part of it.
          Sync.Gate.StoreError ->
            conn
            |> put_resp_header("retry-after", "1")
            |> error(503, "store_unavailable")
        end
    end
  end

  def resolve(conn, id) do
    case Sync.resolve_conflict(tenant(conn), id, Actor.of(conn)) do
      :ok -> json(conn, 200, %{resolved: id})
      {:error, :not_found} -> error(conn, 404, "conflict not found")
    end
  end

  # ---------------------------------------------------------------------------

  # Peer results carry {:ok, _} and {:error, _} tuples; JSON gets plain maps.
  defp plain({:ok, value}), do: %{ok: plain(value)}
  defp plain({:error, reason}), do: %{error: inspect(reason)}
  defp plain(%{} = map) when not is_struct(map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value) when is_tuple(value), do: inspect(value)
  defp plain(value), do: value

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  # What the sender had seen of this Engine: `base_seq`, a sequence of this
  # Engine's ledger (an integer, zero or more; null or absent means none was
  # sent), `base_replica_id`, the replica it believed that ledger belonged to,
  # and `replica_id`, the sender itself. A sender that sends no base gets the
  # conservative check (`unknown_base`), and so does one whose base cannot be
  # this Engine's ledger; the reply says which base was used (`base`).
  defp base_opts(body) do
    with {:ok, seq} <- base_seq(body["base_seq"]),
         {:ok, replica} <- text_opt(body["base_replica_id"], :base_replica_id),
         {:ok, sender} <- text_opt(body["replica_id"], :sender) do
      {:ok, seq ++ replica ++ sender}
    end
  end

  defp base_seq(nil), do: {:ok, []}
  defp base_seq(seq) when is_integer(seq) and seq >= 0, do: {:ok, [base_seq: seq]}
  defp base_seq(_seq), do: {:error, :invalid_base_seq}

  defp text_opt(nil, _name), do: {:ok, []}
  defp text_opt(text, name) when is_binary(text), do: {:ok, [{name, text}]}
  defp text_opt(_text, :base_replica_id), do: {:error, :invalid_base_replica_id}
  defp text_opt(_text, :sender), do: {:error, :invalid_replica_id}

  defp int(nil, default), do: default

  defp int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp error(conn, status, reason) when is_atom(reason),
    do: error(conn, status, Atom.to_string(reason))

  defp error(conn, status, reason) when is_binary(reason), do: json(conn, status, %{error: reason})

  # A reason that is a term, not a name (a failed commit) can quote stored values,
  # so the response says only that the batch was not applied; the term is logged.
  defp error(conn, status, reason) do
    Logger.warning("[SyncAPI] batch not applied: #{inspect(reason)}")
    json(conn, status, %{error: "batch_not_applied"})
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
