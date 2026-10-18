defmodule OptimalEngine.API.OperatingAPI do
  @moduledoc """
  Handlers for the operating layer routes (boot, brief, loops, rhythm,
  protocol, topology, routing rules), called from `OptimalEngine.API.Router`.

  Workspace authorization has already run (`WorkspaceAuthPlug`), so every
  workspace a request names is one the caller may use. Requests that name
  no workspace act on every workspace the caller's key covers: all of them
  for an unrestricted key or an anonymous local caller.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Operating.{Boot, Brief, Loops, Protocol, Rhythm}
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Topology.Portable

  # -- boot and brief ----------------------------------------------------------

  def boot(conn) do
    conn = fetch_query_params(conn)
    workspace_id = conn.query_params["workspace"] || conn.assigns[:workspace_id] || "default"
    json(conn, 200, Boot.build(tenant(conn), workspace_id, timezone: conn.query_params["timezone"]))
  end

  def brief(conn) do
    conn = fetch_query_params(conn)

    json(
      conn,
      200,
      Brief.build(tenant(conn),
        workspace_ids: workspaces(conn),
        limit: int(conn.query_params["limit"], 25)
      )
    )
  end

  # -- loops -------------------------------------------------------------------

  def list_loops(conn) do
    conn = fetch_query_params(conn)
    q = conn.query_params

    loops =
      Loops.list(tenant(conn),
        workspace_ids: workspaces(conn),
        state: q["state"] || "open",
        owner: q["owner"],
        kind: q["kind"],
        due_before: q["due_before"],
        limit: int(q["limit"], 200)
      )

    json(conn, 200, %{loops: loops, count: length(loops)})
  end

  def create_loop(conn) do
    body = body(conn)

    case Loops.create(
           tenant(conn),
           Map.put_new(body, "workspace_id", body["workspace"] || "default"),
           Actor.of(conn, body)
         ) do
      {:ok, loop} -> json(conn, 201, loop)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def extract_loops(conn) do
    body = body(conn)
    workspace_id = body["workspace"] || body["workspace_id"] || "default"
    opts = if body["since"], do: [since: body["since"]], else: []
    {:ok, found} = Loops.extract(tenant(conn), workspace_id, opts)
    {:ok, closed} = Loops.close_answered(tenant(conn), workspace_id)
    json(conn, 200, %{detected: found, closed_by_reply: closed})
  end

  def transition_loop(conn, id, action) do
    body = body(conn)
    actor = Actor.of(conn, body)

    transition = fn ->
      case action do
        "close" -> Loops.close(tenant(conn), id, actor, body)
        "drop" -> Loops.drop(tenant(conn), id, actor, body)
        "reopen" -> Loops.reopen(tenant(conn), id, actor)
      end
    end

    with {:ok, existing} <- Loops.get(tenant(conn), id),
         :ok <- in_scope(conn, existing.workspace_id),
         {:ok, loop} <- transition.() do
      json(conn, 200, loop)
    else
      {:error, :not_found} -> error(conn, 404, "loop not found")
      {:error, :out_of_scope} -> error(conn, 404, "loop not found")
      {:error, reason} -> error(conn, 409, reason)
    end
  end

  # -- rhythm ------------------------------------------------------------------

  def rhythm_current(conn) do
    conn = fetch_query_params(conn)
    workspace_id = conn.query_params["workspace"] || "default"
    cadence = conn.query_params["cadence"] || "daily"

    case Rhythm.current(tenant(conn), workspace_id, cadence,
           timezone: conn.query_params["timezone"]
         ) do
      {:ok, note} -> json(conn, 200, note)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def rhythm_notes(conn) do
    conn = fetch_query_params(conn)
    workspace_id = conn.query_params["workspace"] || "default"

    notes =
      Rhythm.list(
        tenant(conn),
        workspace_id,
        conn.query_params["cadence"] || "daily",
        int(conn.query_params["limit"], 30)
      )

    json(conn, 200, %{notes: notes})
  end

  def put_rhythm_note(conn, cadence, period) do
    body = body(conn)
    workspace_id = body["workspace"] || "default"

    case Rhythm.put_note(
           tenant(conn),
           workspace_id,
           cadence,
           period,
           body["content"] || "",
           Actor.of(conn, body)
         ) do
      {:ok, note} -> json(conn, 200, note)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def put_rhythm_template(conn, cadence) do
    body = body(conn)
    workspace_id = body["workspace"] || "default"
    timezone = body["timezone"] || Rhythm.timezone(tenant(conn), workspace_id)

    case Rhythm.put_template(
           tenant(conn),
           workspace_id,
           cadence,
           body["content"] || "",
           timezone,
           Actor.of(conn, body)
         ) do
      :ok -> json(conn, 200, %{workspace_id: workspace_id, cadence: cadence, timezone: timezone})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- protocol ----------------------------------------------------------------

  def protocol(conn) do
    conn = fetch_query_params(conn)

    case Protocol.get(
           tenant(conn),
           conn.query_params["workspace"],
           conn.query_params["kind"] || "protocol"
         ) do
      {:ok, document} -> json(conn, 200, document)
      {:error, :not_found} -> error(conn, 404, "document not found")
    end
  end

  def put_protocol(conn) do
    body = body(conn)

    {scope_type, scope_id} =
      if body["workspace"], do: {"workspace", body["workspace"]}, else: {"tenant", tenant(conn)}

    case Protocol.put(
           tenant(conn),
           scope_type,
           scope_id,
           body["kind"] || "protocol",
           body["content"] || "",
           Actor.of(conn, body)
         ) do
      {:ok, document} -> json(conn, 200, document)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- topology ----------------------------------------------------------------

  def export_topology(conn) do
    conn = fetch_query_params(conn)
    document = Portable.export(tenant(conn))

    if conn.query_params["format"] == "yaml",
      do: conn |> put_resp_content_type("application/yaml") |> send_resp(200, to_yaml(document)),
      else: json(conn, 200, document)
  end

  def import_topology(conn) do
    body = body(conn)

    document =
      case body do
        %{"yaml" => yaml} when is_binary(yaml) -> YamlElixir.read_from_string(yaml)
        %{"document" => %{} = document} -> {:ok, document}
        %{} = document -> {:ok, document}
      end

    with {:ok, document} <- document,
         {:ok, summary} <- Portable.import(tenant(conn), document) do
      json(conn, 200, summary)
    else
      {:error, {:invalid_document, errors}} ->
        json(conn, 422, %{error: "invalid_document", details: errors})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  # -- routing rules -----------------------------------------------------------

  def list_rules(conn) do
    allowed = workspaces(conn)

    rules =
      tenant(conn)
      |> RuleStore.list()
      |> Enum.filter(&(is_nil(allowed) or &1.workspace_id in allowed))

    json(conn, 200, %{rules: rules})
  end

  def add_rule(conn) do
    body = body(conn)

    with :ok <- in_scope(conn, body["workspace_id"]),
         {:ok, rule} <- RuleStore.add(tenant(conn), body, Actor.of(conn, body)) do
      json(conn, 201, rule)
    else
      {:error, :out_of_scope} -> error(conn, 403, "workspace_scope_denied")
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def delete_rule(conn, id) do
    rule = tenant(conn) |> RuleStore.list() |> Enum.find(&(&1.id == id))

    with %{} <- rule,
         :ok <- in_scope(conn, rule.workspace_id),
         :ok <- RuleStore.delete(tenant(conn), id) do
      json(conn, 200, %{deleted: id})
    else
      _ -> error(conn, 404, "rule not found")
    end
  end

  def classify(conn) do
    result = RuleStore.classify(tenant(conn), body(conn))
    allowed = workspaces(conn)

    if is_nil(allowed) or is_nil(result.proposed_workspace_id) or
         result.proposed_workspace_id in allowed,
       do: json(conn, 200, result),
       else:
         json(conn, 200, %{
           result
           | workspace_id: nil,
             proposed_workspace_id: nil,
             confidence: :unresolved,
             rules: []
         })
  end

  def feedback(conn) do
    body = body(conn)

    decision =
      case body["decision"] do
        "accept" -> :accept
        "reject" -> :reject
        _ -> nil
      end

    if decision do
      {:ok, count} = RuleStore.feedback(tenant(conn), List.wrap(body["rule_ids"]), decision)
      json(conn, 200, %{updated: count})
    else
      error(conn, 422, "decision must be accept or reject")
    end
  end

  def seed_rules(conn) do
    {:ok, count} = RuleStore.seed_from_routing_file(tenant(conn))
    json(conn, 200, %{seeded: count})
  end

  # ---------------------------------------------------------------------------

  # The workspaces a request covers: the ones it names, else every workspace
  # the key covers (nil means all of them).
  @doc false
  def workspaces(conn) do
    listed =
      if conn.query_params["workspaces"] == "*", do: "", else: conn.query_params["workspaces"] || ""

    named =
      [conn.query_params["workspace"], conn.query_params["workspace_id"]]
      |> Kernel.++(String.split(listed, ",", trim: true))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case {named, conn.assigns[:current_api_key]} do
      {[_ | _], _key} -> named
      {[], nil} -> nil
      {[], key} -> if "*" in (key.workspace_scope || []), do: nil, else: key.workspace_scope
    end
  end

  defp in_scope(_conn, nil), do: {:error, :out_of_scope}

  defp in_scope(conn, workspace_id) do
    case conn.assigns[:current_api_key] do
      nil ->
        :ok

      key ->
        if "*" in key.workspace_scope or workspace_id in key.workspace_scope,
          do: :ok,
          else: {:error, :out_of_scope}
    end
  end

  defp to_yaml(value), do: yaml(value, 0) <> "\n"

  defp yaml(%{} = map, indent) do
    map
    |> Enum.sort_by(fn {key, _} -> yaml_key_order(key) end)
    |> Enum.map_join("\n", fn
      {key, value} when is_map(value) and map_size(value) > 0 ->
        pad(indent) <> "#{key}:\n" <> yaml(value, indent + 2)

      {key, [_ | _] = list} ->
        pad(indent) <> "#{key}:\n" <> yaml_list(list, indent + 2)

      {key, value} ->
        pad(indent) <> "#{key}: " <> scalar(value)
    end)
  end

  defp yaml_list(list, indent) do
    Enum.map_join(list, "\n", fn
      %{} = map ->
        [first | rest] = map |> yaml(indent + 2) |> String.split("\n")
        pad(indent) <> "- " <> String.trim_leading(first) <> Enum.map_join(rest, "", &("\n" <> &1))

      value ->
        pad(indent) <> "- " <> scalar(value)
    end)
  end

  defp scalar([]), do: "[]"
  defp scalar(%{} = map) when map_size(map) == 0, do: "{}"
  defp scalar(nil), do: "null"
  defp scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp scalar(value), do: Jason.encode!(to_string(value))

  defp yaml_key_order(key) do
    {Enum.find_index(~w(schema_version tenant slug id kind name display_name status), &(&1 == key)) ||
       50, if(key in ~w(workspaces), do: 1, else: 0), key}
  end

  defp pad(n), do: String.duplicate(" ", n)

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
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
