defmodule OptimalEngine.AppData.Changes do
  @moduledoc """
  The durable app-data change feed.

  Every committed record change and schema change appends one row to
  `data_changes` inside the same transaction, so the feed never shows a
  change that was rolled back and never misses one that committed. `seq`
  is a strictly increasing integer (SQLite `AUTOINCREMENT`, never reused),
  so a consumer resumes by asking for changes after the last `seq` it
  processed. Changes written by one transaction share a `txn_id`.

  Live consumers subscribe per workspace; `notify/3` wakes them after a
  commit and they read the feed from their last `seq`.
  """

  alias OptimalEngine.API.IntParam
  alias OptimalEngine.AppData.{Collections, Scope, SQL}

  @registry OptimalEngine.AppData.Registry
  @default_limit 100
  @max_limit 1_000

  @doc """
  Changes after `since` visible to the scope. Options: `since` (integer,
  default 0, or `"latest"`), `collection`, `limit` (default 100, max 1000).
  Returns `%{"changes" => [...], "next_since" => seq, "latest_seq" => seq}`.
  """
  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, opts) do
    with {:ok, latest} <- latest_seq(scope),
         {:ok, since} <- since(opts["since"], latest),
         {:ok, limit} <- limit(opts["limit"]),
         {:ok, {filter_sql, filter_params}} <- visibility(scope, opts["collection"]) do
      sql = """
      SELECT seq, collection, record_id, op, version, owner, actor, data, txn_id, at
      FROM data_changes
      WHERE tenant_id = ? AND workspace_id = ? AND seq > ? AND #{filter_sql}
      ORDER BY seq
      LIMIT ?
      """

      params = [scope.tenant_id, scope.workspace_id, since] ++ filter_params ++ [limit]

      with {:ok, rows} <- SQL.query(:store, sql, params) do
        changes = Enum.map(rows, &to_change/1)
        next = if changes == [], do: since, else: List.last(changes)["seq"]
        {:ok, %{"changes" => changes, "next_since" => next, "latest_seq" => latest}}
      end
    end
  end

  @doc "The newest change sequence number in the scope's workspace (0 when empty)."
  @spec latest_seq(Scope.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def latest_seq(%Scope{} = scope) do
    case SQL.scalar(
           :store,
           "SELECT MAX(seq) FROM data_changes WHERE tenant_id = ? AND workspace_id = ?",
           [scope.tenant_id, scope.workspace_id]
         ) do
      {:ok, nil} -> {:ok, 0}
      other -> other
    end
  end

  @doc "Subscribes the calling process to change wakeups for a workspace."
  @spec subscribe(Scope.t()) :: :ok
  def subscribe(%Scope{} = scope) do
    {:ok, _} = Registry.register(@registry, {scope.tenant_id, scope.workspace_id}, nil)
    :ok
  end

  @doc "Wakes every subscriber of a workspace with `{:app_data_changed, seq}`."
  @spec notify(String.t(), String.t(), integer() | nil) :: :ok
  def notify(_tenant_id, _workspace_id, nil), do: :ok

  def notify(tenant_id, workspace_id, seq) do
    Registry.dispatch(@registry, {tenant_id, workspace_id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:app_data_changed, seq})
    end)

    :ok
  catch
    :error, _ -> :ok
  end

  defp since(nil, _latest), do: {:ok, 0}
  defp since("latest", latest), do: {:ok, latest}
  defp since(n, _latest) when is_integer(n) and n >= 0, do: {:ok, n}

  # A number outside 64 bits raises `IntParam.OutOfRange`, which the router
  # answers as 400; SQLite binds 64 bits.
  defp since(value, latest) when is_binary(value) do
    case IntParam.parse(value, :invalid) do
      :invalid -> {:error, {:validation, ["since must be a sequence number or latest"]}}
      n -> since(n, latest)
    end
  end

  defp since(_value, _latest),
    do: {:error, {:validation, ["since must be a sequence number or latest"]}}

  defp limit(nil), do: {:ok, @default_limit}
  defp limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: {:ok, n}

  defp limit(value) when is_binary(value) do
    case IntParam.parse(value, :invalid) do
      :invalid -> limit(:invalid)
      n -> limit(n)
    end
  end

  defp limit(_value), do: {:error, {:validation, ["limit must be 1 to #{@max_limit}"]}}

  # Collection restrictions and owner rows follow the same rules as reads:
  # an owner-bound scope sees other owners' changes only in collections
  # without an owner field.
  defp visibility(scope, collection) do
    with :ok <- collection_allowed(scope, collection),
         {:ok, all} <- Collections.load_all(:store, scope) do
      {coll_sql, coll_params} = collection_filter(scope, collection)
      {owner_sql, owner_params} = owner_filter(scope, all)
      {:ok, {"#{coll_sql} AND #{owner_sql}", coll_params ++ owner_params}}
    end
  end

  defp collection_allowed(_scope, nil), do: :ok
  defp collection_allowed(scope, name), do: Scope.allow(scope, name, "read")

  defp collection_filter(_scope, name) when is_binary(name), do: {"collection = ?", [name]}
  defp collection_filter(%Scope{collections: :all}, nil), do: {"1", []}

  defp collection_filter(%Scope{collections: names}, nil) do
    if "*" in names,
      do: {"1", []},
      else: {"collection IN (#{SQL.placeholders(length(names))})", names}
  end

  # Rows of owner-field collections carry their owner; rows of other
  # collections and schema events carry none. A row whose collection was
  # dropped keeps its owner, so it stays hidden from other owners.
  defp owner_filter(scope, all) do
    if Scope.owner_bound?(scope) do
      owned = for c <- all, c.schema["owner_field"] != nil, do: c.id

      {"(owner = ? OR op IN ('schema', 'drop') OR (owner IS NULL AND collection_id NOT IN (#{SQL.placeholders(length(owned))})))",
       [scope.owner | owned]}
    else
      {"1", []}
    end
  end

  defp to_change([seq, collection, record_id, op, version, owner, actor, data, txn_id, at]) do
    %{
      "seq" => seq,
      "collection" => collection,
      "record_id" => record_id,
      "op" => op,
      "version" => version,
      "owner" => owner,
      "actor" => actor,
      "data" => data && Jason.decode!(data),
      "txn_id" => txn_id,
      "at" => at
    }
  end
end
