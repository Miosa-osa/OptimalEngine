defmodule OptimalEngine.API.AppDataRouter do
  @moduledoc """
  HTTP API for app data (`OptimalEngine.AppData`), forwarded from
  `/api/data`. See `docs/guides/app-data-api.md`.

  Every request names its workspace with `workspace` in the query or JSON
  body; `OptimalEngine.API.WorkspaceAuthPlug` has already enforced tenant
  ownership and the key's workspace scope. Operation scopes are enforced by
  `OptimalEngine.API.PermissionPlug`:

  | Route | Scope |
  | --- | --- |
  | `GET` routes, `POST /collections/:name/query` | read |
  | record, file, transaction and embedding writes | write |
  | `POST /collections`, `PATCH`/`DELETE /collections/:name`, `POST /migrations`, `/keys` | data:admin |

  The acting principal, tenant, and any owner, collection, and operation
  limits come from the authenticated key, never from the body.
  """

  use Plug.Router

  alias OptimalEngine.API.Actor
  alias OptimalEngine.API.IntParam
  alias OptimalEngine.AppData
  alias OptimalEngine.AppData.{Changes, Keys, Scope}

  plug(:match)
  plug(:dispatch)

  @stream_wait_ms 15_000

  # -- engine capabilities ------------------------------------------------------

  get "/capabilities" do
    with_scope(conn, fn _scope -> json(conn, 200, AppData.capabilities()) end)
  end

  # -- collections --------------------------------------------------------------

  get "/collections" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.list_collections(scope), &%{"collections" => &1})
    end)
  end

  post "/collections" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.create_collection(scope, Map.drop(body(conn), control_fields())), 201)
    end)
  end

  get "/collections/:name" do
    with_scope(conn, fn scope -> respond(conn, AppData.describe_collection(scope, name)) end)
  end

  patch "/collections/:name" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.alter_collection(scope, name, body(conn)["operations"]))
    end)
  end

  delete "/collections/:name" do
    with_scope(conn, fn scope ->
      confirm = conn.query_params["confirm"] || body(conn)["confirm"]

      case AppData.drop_collection(scope, name, confirm) do
        :ok -> json(conn, 200, %{"dropped" => name})
        error -> respond(conn, error)
      end
    end)
  end

  # -- records ------------------------------------------------------------------

  get "/collections/:name/records" do
    with_scope(conn, fn scope ->
      case query_spec(conn.query_params) do
        {:ok, spec} -> respond(conn, AppData.query(scope, name, spec))
        error -> respond(conn, error)
      end
    end)
  end

  post "/collections/:name/query" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.query(scope, name, Map.drop(body(conn), control_fields())))
    end)
  end

  post "/collections/:name/records" do
    with_scope(conn, fn scope ->
      input = Map.take(body(conn), ["id", "data"])
      respond(conn, AppData.create(scope, name, input), 201, &Map.delete(&1, "op"))
    end)
  end

  post "/collections/:name/records/bulk" do
    with_scope(conn, fn scope ->
      case body(conn)["records"] do
        records when is_list(records) ->
          case AppData.bulk_create(scope, name, records) do
            {:ok, result} ->
              json(conn, 201, %{
                "count" => length(result.results),
                "records" => Enum.map(result.results, &Map.take(&1, ["id", "version"])),
                "txn_id" => result.txn_id,
                "last_seq" => result.last_seq
              })

            error ->
              respond(conn, error)
          end

        _ ->
          respond(conn, {:error, {:validation, ["records must be a list"]}})
      end
    end)
  end

  post "/collections/:name/upsert" do
    with_scope(conn, fn scope ->
      body = body(conn)

      with {:ok, version} <- version(conn, body) do
        input = body |> Map.take(["id", "data", "key"]) |> put_version(version)

        case AppData.upsert(scope, name, input) do
          {:ok, %{"op" => "create"} = record} -> json(conn, 201, record)
          other -> respond(conn, other)
        end
      else
        error -> respond(conn, error)
      end
    end)
  end

  get "/collections/:name/records/:id" do
    with_scope(conn, fn scope ->
      case AppData.get(scope, name, id, read_spec(conn.query_params)) do
        {:ok, record} ->
          conn |> put_resp_header("etag", ~s("#{record["version"]}")) |> json(200, record)

        error ->
          respond(conn, error)
      end
    end)
  end

  patch "/collections/:name/records/:id" do
    with_scope(conn, fn scope ->
      body = body(conn)

      with {:ok, version} <- version(conn, body) do
        input = body |> Map.take(["data"]) |> put_version(version)
        respond(conn, AppData.update(scope, name, id, input), 200, &Map.delete(&1, "op"))
      else
        error -> respond(conn, error)
      end
    end)
  end

  delete "/collections/:name/records/:id" do
    with_scope(conn, fn scope ->
      with {:ok, version} <- version(conn, body(conn)) do
        case AppData.delete(scope, name, id, put_version(%{}, version)) do
          {:ok, result} -> json(conn, 200, Map.put(result, "deleted", true))
          error -> respond(conn, error)
        end
      else
        error -> respond(conn, error)
      end
    end)
  end

  post "/collections/:name/embeddings/rebuild" do
    with_scope(conn, fn scope -> respond(conn, AppData.rebuild_embeddings(scope, name)) end)
  end

  # -- files ----------------------------------------------------------------------

  get "/collections/:name/records/:id/files" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.list_files(scope, name, id), &%{"files" => &1})
    end)
  end

  post "/collections/:name/records/:id/files" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.upload_file(scope, name, id, body(conn)), 201)
    end)
  end

  get "/collections/:name/records/:id/files/:file_id" do
    with_scope(conn, fn scope ->
      case AppData.open_file(scope, name, id, file_id) do
        {:ok, file} -> send_file_range(conn, file)
        error -> respond(conn, error)
      end
    end)
  end

  delete "/collections/:name/records/:id/files/:file_id" do
    with_scope(conn, fn scope ->
      case AppData.delete_file(scope, name, id, file_id) do
        :ok -> json(conn, 200, %{"deleted" => file_id})
        error -> respond(conn, error)
      end
    end)
  end

  # -- transactions -----------------------------------------------------------------

  post "/transactions" do
    with_scope(conn, fn scope ->
      case AppData.transact(scope, body(conn)["operations"]) do
        {:ok, result} ->
          json(conn, 200, %{
            "committed" => true,
            "results" => result.results,
            "txn_id" => result.txn_id,
            "last_seq" => result.last_seq
          })

        error ->
          respond(conn, error)
      end
    end)
  end

  # -- change feed ------------------------------------------------------------------

  get "/changes" do
    with_scope(conn, fn scope ->
      respond(
        conn,
        AppData.changes(scope, Map.take(conn.query_params, ["since", "collection", "limit"]))
      )
    end)
  end

  get "/changes/stream" do
    with_scope(conn, fn scope ->
      since =
        case get_req_header(conn, "last-event-id") do
          [id | _] -> id
          [] -> conn.query_params["since"] || "latest"
        end

      opts = %{"since" => since, "collection" => conn.query_params["collection"], "limit" => 500}
      idle = parse_int(conn.query_params["idle_timeout"], 0) * 1_000

      case AppData.changes(scope, Map.put(opts, "limit", 1)) do
        {:ok, %{"latest_seq" => latest}} ->
          :ok = Changes.subscribe(scope)

          start =
            case since do
              "latest" -> latest
              value -> parse_int(value, 0)
            end

          conn = stream_init(conn)
          conn = sse(conn, "ready", nil, %{"since" => start, "latest_seq" => latest})
          stream_loop(conn, scope, %{opts | "since" => start}, idle, now_ms())

        error ->
          respond(conn, error)
      end
    end)
  end

  # -- migrations -------------------------------------------------------------------

  get "/migrations" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.migrations(scope, conn.query_params["app"]), &%{"migrations" => &1})
    end)
  end

  post "/migrations" do
    with_scope(conn, fn scope ->
      respond(conn, AppData.migrate(scope, Map.take(body(conn), ["app", "migrations"])))
    end)
  end

  # -- data keys --------------------------------------------------------------------

  get "/keys" do
    with_scope(conn, fn scope -> respond(conn, AppData.list_keys(scope), &%{"keys" => &1}) end)
  end

  post "/keys" do
    with_scope(conn, fn scope ->
      attrs = Map.take(body(conn), ["name", "owner", "collections", "operations", "expires_in"])
      respond(conn, AppData.mint_key(scope, conn.assigns[:current_api_key], attrs), 201)
    end)
  end

  delete "/keys/:id" do
    with_scope(conn, fn scope ->
      case AppData.revoke_key(scope, id) do
        :ok -> json(conn, 200, %{"revoked" => id})
        error -> respond(conn, error)
      end
    end)
  end

  match _ do
    json(conn, 404, %{"error" => "not found"})
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  defp with_scope(conn, fun) do
    case scope(conn) do
      {:ok, scope} -> fun.(scope)
      {:error, status, error} -> json(conn, status, %{"error" => error})
    end
  end

  defp scope(conn) do
    key = conn.assigns[:current_api_key]
    access = Keys.data_access(key)
    body = body(conn)

    named =
      [
        conn.query_params["workspace"],
        conn.query_params["workspace_id"],
        body["workspace"],
        body["workspace_id"]
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    cond do
      named == [] ->
        {:error, 400, "workspace_required"}

      length(named) > 1 ->
        {:error, 400, "workspace_mismatch"}

      hd(named) != conn.assigns[:workspace_id] ->
        {:error, 400, "workspace_mismatch"}

      access != nil and access["workspace"] != hd(named) ->
        {:error, 403, "workspace_scope_denied"}

      true ->
        {:ok,
         Scope.new(
           tenant_id: conn.assigns[:current_tenant] || "default",
           workspace_id: hd(named),
           actor: if(key, do: Actor.of(conn), else: Actor.of(conn, body)),
           owner: access && access["owner"],
           collections: (access && access["collections"]) || :all,
           operations: (access && access["operations"]) || :all,
           admin: admin?(key, access),
           keyed: key != nil
         )}
    end
  end

  # Trusted local callers (no key) and keys holding * or data:admin may
  # change schemas and assign rows to other owners. Data keys never may.
  defp admin?(nil, _access), do: true
  defp admin?(_key, %{}), do: false
  defp admin?(key, nil), do: "*" in key.scopes or "data:admin" in key.scopes

  defp control_fields, do: ~w(workspace workspace_id tenant tenant_id actor_id)

  # ---------------------------------------------------------------------------
  # Request parsing
  # ---------------------------------------------------------------------------

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  # GET /records query string: limit, cursor, sort and fields and include
  # (comma separated), count, where (JSON), search, semantic.
  defp query_spec(params) do
    with {:ok, where} <- json_param(params["where"]),
         {:ok, limit} <- int_param(params["limit"]) do
      spec =
        %{}
        |> maybe_put("where", where)
        |> maybe_put("limit", limit)
        |> maybe_put("cursor", params["cursor"])
        |> maybe_put("sort", list_param(params["sort"]))
        |> maybe_put("fields", list_param(params["fields"]))
        |> maybe_put("include", list_param(params["include"]))
        |> maybe_put("count", if(params["count"] in ["true", "1"], do: true))
        |> maybe_put("search", params["search"])
        |> maybe_put("semantic", params["semantic"])

      {:ok, spec}
    end
  end

  defp read_spec(params) do
    %{}
    |> maybe_put("fields", list_param(params["fields"]))
    |> maybe_put("include", list_param(params["include"]))
  end

  defp json_param(nil), do: {:ok, nil}

  defp json_param(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, {:validation, ["where must be JSON"]}}
    end
  end

  defp int_param(nil), do: {:ok, nil}

  defp int_param(value) do
    case IntParam.parse(value, :invalid) do
      :invalid -> {:error, {:validation, ["limit must be an integer"]}}
      n -> {:ok, n}
    end
  end

  defp list_param(nil), do: nil
  defp list_param(value), do: String.split(value, ",", trim: true)

  # The expected version comes from the body or an If-Match header.
  defp version(conn, body) do
    header =
      case get_req_header(conn, "if-match") do
        [value | _] -> parse_etag(value)
        [] -> nil
      end

    query = conn.query_params["version"] && parse_int(conn.query_params["version"], :invalid)

    case Enum.uniq(Enum.reject([body["version"], header, query], &is_nil/1)) do
      [] -> {:ok, nil}
      [v] when is_integer(v) -> {:ok, v}
      [_v] -> {:error, {:validation, ["version must be an integer"]}}
      _ -> {:error, {:validation, ["version, If-Match, and ?version disagree"]}}
    end
  end

  defp parse_etag(value) do
    value |> String.trim() |> String.trim_leading("W/") |> String.trim("\"") |> parse_int(:invalid)
  end

  defp put_version(map, nil), do: map
  defp put_version(map, version), do: Map.put(map, "version", version)

  defp parse_int(value, default), do: IntParam.parse(value, default)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Responses
  # ---------------------------------------------------------------------------

  defp respond(conn, result), do: respond(conn, result, 200, & &1)

  defp respond(conn, result, shape) when is_function(shape, 1),
    do: respond(conn, result, 200, shape)

  defp respond(conn, result, status), do: respond(conn, result, status, & &1)

  defp respond(conn, {:ok, value}, status, shape), do: json(conn, status, shape.(value))
  defp respond(conn, {:error, reason}, _status, _shape), do: error(conn, reason)

  defp error(conn, reason) do
    {status, body} = error_body(reason)
    json(conn, status, body)
  end

  defp error_body({:not_found, code}), do: {404, %{"error" => code}}
  defp error_body({:conflict, code, details}), do: {409, Map.put(details, "error", code)}

  defp error_body({:validation, messages}),
    do: {422, %{"error" => "validation_failed", "details" => messages}}

  defp error_body({:forbidden, code}), do: {403, %{"error" => code}}
  defp error_body({:unavailable, code, message}), do: {503, %{"error" => code, "reason" => message}}

  defp error_body({:operation_failed, index, reason}) do
    {status, body} = error_body(reason)
    {status, Map.merge(body, %{"operation_index" => index, "committed" => false})}
  end

  defp error_body({:migration_failed, version, reason, partial}) do
    {status, body} = error_body(reason)
    {status, Map.merge(body, %{"failed_version" => version, "applied" => partial["applied"]})}
  end

  defp error_body({:storage, _message}), do: {500, %{"error" => "storage_error"}}
  defp error_body(_other), do: {500, %{"error" => "internal_error"}}

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # ---------------------------------------------------------------------------
  # File download with single byte ranges
  # ---------------------------------------------------------------------------

  defp send_file_range(conn, file) do
    conn =
      conn
      |> put_resp_header("content-type", file.content_type)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{safe_filename(file.filename)}")
      )

    case range(get_req_header(conn, "range"), file.size) do
      :full ->
        send_file(conn, 200, file.path)

      {:partial, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{file.size}")
        |> send_file(206, file.path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{file.size}")
        |> send_resp(416, "")
    end
  end

  defp safe_filename(name), do: String.replace(name, ~r/[^A-Za-z0-9._ -]/, "_")

  # One range per request; a multi-range request gets the whole file.
  defp range(["bytes=" <> spec | _], size) do
    cond do
      String.contains?(spec, ",") -> :full
      size == 0 -> :unsatisfiable
      true -> parse_range(String.split(String.trim(spec), "-", parts: 2), size)
    end
  end

  defp range(_header, _size), do: :full

  defp parse_range(["", suffix], size) do
    case Integer.parse(suffix) do
      {n, ""} when n > 0 -> {:partial, max(size - n, 0), size - 1}
      _ -> :unsatisfiable
    end
  end

  defp parse_range([first, last], size) do
    with {f, ""} <- Integer.parse(first),
         {:ok, l} <- range_end(last, size),
         true <- f <= l and f < size do
      {:partial, f, min(l, size - 1)}
    else
      _ -> :unsatisfiable
    end
  end

  defp parse_range(_parts, _size), do: :unsatisfiable

  defp range_end("", size), do: {:ok, size - 1}

  defp range_end(value, _size) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Server-sent change stream
  # ---------------------------------------------------------------------------

  defp stream_init(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  # Sends every change after `since`, then waits for a commit wakeup (or
  # polls after a quiet interval, with a keepalive). With an idle timeout
  # the stream closes after that long without changes; clients reconnect
  # with Last-Event-ID.
  defp stream_loop(conn, scope, opts, idle, last_activity) do
    case drain(conn, scope, opts) do
      {:ok, conn, since, sent} ->
        opts = %{opts | "since" => since}
        last_activity = if sent > 0, do: now_ms(), else: last_activity

        wait =
          if idle > 0,
            do: min(@stream_wait_ms, max(idle - (now_ms() - last_activity), 0)),
            else: @stream_wait_ms

        receive do
          {:app_data_changed, _seq} -> stream_loop(conn, scope, opts, idle, last_activity)
          _other -> stream_loop(conn, scope, opts, idle, last_activity)
        after
          wait ->
            cond do
              idle > 0 and now_ms() - last_activity >= idle ->
                conn

              true ->
                case chunk(conn, ": keepalive\n\n") do
                  {:ok, conn} -> stream_loop(conn, scope, opts, idle, last_activity)
                  {:error, _} -> conn
                end
            end
        end

      {:closed, conn} ->
        conn
    end
  end

  defp drain(conn, scope, opts, sent \\ 0) do
    case Changes.list(scope, opts) do
      {:ok, %{"changes" => []}} ->
        {:ok, conn, opts["since"], sent}

      {:ok, %{"changes" => changes, "next_since" => next}} ->
        result =
          Enum.reduce_while(changes, {:ok, conn}, fn change, {:ok, conn} ->
            case chunk(conn, sse_frame("change", change["seq"], change)) do
              {:ok, conn} -> {:cont, {:ok, conn}}
              {:error, _} -> {:halt, {:closed, conn}}
            end
          end)

        case result do
          {:ok, conn} -> drain(conn, scope, %{opts | "since" => next}, sent + length(changes))
          closed -> closed
        end

      {:error, _} ->
        {:closed, conn}
    end
  end

  defp sse(conn, event, id, data) do
    case chunk(conn, sse_frame(event, id, data)) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp sse_frame(event, nil, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

  defp sse_frame(event, id, data),
    do: "id: #{id}\nevent: #{event}\ndata: #{Jason.encode!(data)}\n\n"

  defp now_ms, do: System.monotonic_time(:millisecond)
end
