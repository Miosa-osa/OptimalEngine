defmodule OptimalEngine.AppData.Replication do
  @moduledoc """
  Applies a peer's app data change to this Engine's copy of the workspace.

  What replicates is the change feed (`data_changes`, captured like any
  replicated table): each change names its collection, the record, the record's
  version after the change and the whole record, or the schema change. The
  receiver never writes a peer's row as it came. It replays the change through
  app data, so the collection tables, their names and their indexes are its own,
  and the change is checked as a write here is:

  * a schema change: a created collection is created again from the schema the
    peer recorded (checked as a definition is, `Schema.restore/2`), and an
    alteration runs its operations again, from the schema version before it;
    the schema that gives must equal the one the peer recorded. A change made by an app migration applies the migration whole
    (its operations and its ledger row in `data_schema_migrations`, checksum
    computed again), so a deploy of the same migrations here skips them.
  * a record change: the record must fit this Engine's copy of the collection
    (every field known, required fields present, every value of its type) and
    the change's base, the version before it, must be the version here. A
    record that does not fit is `schema_invalid`, a base that is not the
    version here is a `version_conflict`; neither is applied, the record here
    stays as it is, and both are recorded as conflicts.

  The change this Engine records of it names the peer's actor and, in
  `origin_replica`, the replica it was made on.
  """

  alias OptimalEngine.AppData.{Collections, Migrations, Records, Schema, Scope, SQL}

  @record_ops ~w(create update delete)

  @typedoc """
  What applying a change came to: applied (with what `Semantic.index_written/1`
  is told), a conflict (kind, the record here, detail) that leaves this Engine
  as it is, or an error.
  """
  @type outcome ::
          {:applied, list()}
          | {:conflict, String.t(), map() | nil, map()}
          | {:error, term()}

  @doc """
  Checks the shape of a change before it is applied: `:ok` or the reason it is
  refused. Only what an Engine records is accepted.
  """
  @spec check(map()) :: :ok | {:error, atom()}
  def check(%{"operation" => "create", "payload" => %{"row" => row}}) do
    cond do
      not Schema.identifier?(row["collection"]) ->
        {:error, :invalid_app_data_change}

      row["op"] not in ["schema", "drop" | @record_ops] ->
        {:error, :invalid_app_data_change}

      row["op"] in @record_ops and not Schema.record_id?(row["record_id"]) ->
        {:error, :invalid_app_data_change}

      row["op"] in @record_ops and not (is_integer(row["version"]) and row["version"] > 0) ->
        {:error, :invalid_app_data_change}

      not (is_nil(row["data"]) or is_binary(row["data"])) ->
        {:error, :invalid_app_data_change}

      not (is_nil(row["actor"]) or is_binary(row["actor"])) ->
        {:error, :invalid_app_data_change}

      true ->
        :ok
    end
  end

  def check(_mutation), do: {:error, :operation_not_supported}

  @doc "The key a conflict of the change is recorded under: `collection/record` or the collection."
  @spec entity_key(map()) :: String.t()
  def entity_key(%{"payload" => %{"row" => %{"record_id" => id, "collection" => c}}})
      when is_binary(id),
      do: c <> "/" <> id

  def entity_key(%{"payload" => %{"row" => %{"collection" => c}}}), do: c

  @doc """
  Applies a change (checked by `check/1`) in the open transaction `txn`, for
  the workspace `workspace_id` of `tenant_id`.
  """
  @spec apply(term(), String.t(), String.t(), map()) :: outcome()
  def apply(txn, tenant_id, workspace_id, %{"payload" => %{"row" => row}} = mutation) do
    scope =
      Scope.new(
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        actor: row["actor"] || "replica:" <> mutation["device_id"],
        origin: mutation["device_id"]
      )

    case decode(row["data"]) do
      {:ok, data} -> apply_change(txn, scope, row, data)
      :error -> {:error, :invalid_app_data_change}
    end
  end

  defp decode(nil), do: {:ok, nil}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  defp apply_change(txn, scope, %{"op" => "schema"}, %{"migration" => %{} = m}),
    do: migration(txn, scope, m)

  defp apply_change(txn, scope, %{"op" => "drop"}, %{"migration" => %{} = m}),
    do: migration(txn, scope, m)

  defp apply_change(
         txn,
         scope,
         %{"op" => "schema", "collection" => name},
         %{"action" => "create"} = data
       ),
       do: create_collection(txn, scope, name, data)

  defp apply_change(
         txn,
         scope,
         %{"op" => "schema", "collection" => name},
         %{"action" => "alter"} = data
       ),
       do: alter_collection(txn, scope, name, data)

  defp apply_change(txn, scope, %{"op" => "drop", "collection" => name}, _data) do
    case Collections.drop_in(txn, scope, name, name) do
      {:ok, _c} -> {:applied, []}
      {:error, {:not_found, _}} -> {:applied, []}
      error -> error
    end
  end

  defp apply_change(txn, scope, %{"op" => op, "collection" => name} = row, data)
       when op in @record_ops do
    case Collections.load(txn, scope, name) do
      {:ok, c} -> record_change(txn, scope, c, row, data)
      {:error, {:not_found, _}} -> {:error, {:collection_not_found, name}}
      error -> error
    end
  end

  defp apply_change(_txn, _scope, _row, _data), do: {:error, :invalid_app_data_change}

  # -- schema ------------------------------------------------------------------

  defp migration(txn, scope, m) do
    case Migrations.replay(txn, scope, m) do
      {:ok, _version} ->
        {:applied, []}

      {:error, {:conflict, "migration_checksum_mismatch", _}} ->
        {:conflict, "migration_conflict", nil,
         %{"app" => m["app"], "version" => m["version"], "checksum" => m["checksum"]}}

      error ->
        error
    end
  end

  defp create_collection(txn, scope, name, %{"schema" => %{} = remote} = data) do
    case Collections.load(txn, scope, name) do
      {:ok, c} ->
        if same?(c.schema, data["schema"]),
          do: {:applied, []},
          else: {:conflict, "schema_conflict", nil, schema_detail(c, data)}

      {:error, {:not_found, _}} ->
        with {:ok, schema} <- Schema.restore(name, remote),
             {:ok, c} <- Collections.create_in(txn, scope, schema),
             :ok <- same_result(c, data),
             :ok <-
               Collections.log_change(
                 txn,
                 scope,
                 c,
                 "schema",
                 nil,
                 nil,
                 nil,
                 c |> Collections.created_detail() |> Map.put("schema_version", 1)
               ) do
          {:applied, []}
        end

      error ->
        error
    end
  end

  defp create_collection(_txn, _scope, _name, _data), do: {:error, :invalid_app_data_change}

  defp alter_collection(
         txn,
         scope,
         name,
         %{"schema_version" => version, "operations" => ops} = data
       )
       when is_integer(version) do
    with {:ok, c} <- loaded(txn, scope, name) do
      cond do
        c.schema_version == version - 1 ->
          with {:ok, altered} <- Collections.alter_in(txn, scope, c, ops),
               :ok <- same_result(altered, data) do
            {:applied, []}
          end

        c.schema_version >= version and same?(c.schema, data["schema"]) ->
          {:applied, []}

        true ->
          {:conflict, "schema_conflict", nil, schema_detail(c, data)}
      end
    end
  end

  defp alter_collection(_txn, _scope, _name, _data), do: {:error, :invalid_app_data_change}

  defp loaded(txn, scope, name) do
    case Collections.load(txn, scope, name) do
      {:error, {:not_found, _}} -> {:error, {:collection_not_found, name}}
      other -> other
    end
  end

  defp schema_detail(c, data),
    do: %{
      "local_schema_version" => c.schema_version,
      "remote_schema_version" => data["schema_version"]
    }

  # The schema the change gave here is the one the peer recorded, or the change
  # is not applied: the two Engines would hold different collections under one name.
  defp same_result(c, data) do
    if same?(c.schema, data["schema"]), do: :ok, else: {:error, :schema_diverged}
  end

  defp same?(schema, remote), do: Jason.decode!(Jason.encode!(schema)) == remote

  # -- records -----------------------------------------------------------------

  defp record_change(
         txn,
         scope,
         c,
         %{"op" => op, "record_id" => id, "version" => version} = row,
         record
       ) do
    local =
      case Records.fetch_visible(txn, scope, c, id) do
        {:ok, {rowid, existing}} -> {rowid, existing}
        {:error, {:not_found, _}} -> nil
      end

    base = version - 1

    case {op, local} do
      {"delete", nil} ->
        {:applied, []}

      {"delete", {rowid, %{"version" => ^base} = existing}} ->
        delete(txn, scope, c, rowid, existing, row)

      {"create", nil} when version == 1 ->
        with {:ok, record, values} <- whole(c, id, version, record) do
          insert(txn, scope, c, record, values, row)
        end

      {"update", {rowid, %{"version" => ^base} = existing}} ->
        with {:ok, record, values} <- whole(c, id, version, record) do
          update(txn, scope, c, rowid, existing, record, values, row)
        end

      {op, {_rowid, existing}} when op != "delete" ->
        if existing["version"] >= version and is_map(record) and existing["data"] == record["data"],
          do: {:applied, []},
          else: version_conflict(existing, base)

      {_op, local} ->
        version_conflict(local && elem(local, 1), base)
    end
  end

  defp version_conflict(existing, base) do
    {:conflict, "version_conflict", existing && %{"record" => existing},
     %{"base_version" => base, "local_version" => existing && existing["version"]}}
  end

  # The whole record a create or an update carries, checked against this
  # Engine's copy of the collection.
  defp whole(c, id, version, %{"id" => id, "version" => version} = record) do
    case Records.whole_record_values(c, record["data"]) do
      {:ok, values} ->
        if is_binary(record["created_at"]) and is_binary(record["updated_at"]),
          do: {:ok, record, values},
          else: {:error, :invalid_app_data_change}

      {:error, {:validation, errors}} ->
        {:conflict, "schema_invalid", nil, %{"errors" => errors}}

      error ->
        error
    end
  end

  defp whole(_c, _id, _version, _record), do: {:error, :invalid_app_data_change}

  defp insert(txn, scope, c, record, values, row) do
    columns = Enum.map(values, fn {field, _} -> Schema.column(field) end)
    marks = Enum.map_join(values, "", fn _ -> ", ?" end)

    sql =
      ~s[INSERT INTO "#{c.table}" ("id", "_version", "_created_at", "_updated_at", "_created_by", "_updated_by"#{Enum.map_join(columns, "", &(", " <> &1))}) VALUES (?, ?, ?, ?, ?, ?#{marks})]

    params =
      [
        record["id"],
        record["version"],
        record["created_at"],
        record["updated_at"],
        text(record["created_by"]),
        text(record["updated_by"])
      ] ++ Enum.map(values, &elem(&1, 1))

    with :ok <- written(SQL.exec(txn, sql, params), c),
         record = Map.put(record, "data", decode_values(c, values)),
         :ok <- log(txn, scope, c, "create", record, row) do
      {:applied, [{c, :written, record}]}
    end
  end

  defp update(txn, scope, c, rowid, existing, record, values, row) do
    sets = Enum.map_join(values, "", fn {field, _} -> ", #{Schema.column(field)} = ?" end)

    sql =
      ~s[UPDATE "#{c.table}" SET "_version" = ?, "_updated_at" = ?, "_updated_by" = ?#{sets} WHERE "_rowid" = ? AND "_version" = ?]

    params =
      [record["version"], record["updated_at"], text(record["updated_by"])] ++
        Enum.map(values, &elem(&1, 1)) ++ [rowid, existing["version"]]

    with :ok <- written(SQL.exec(txn, sql, params), c),
         record = %{
           existing
           | "version" => record["version"],
             "updated_at" => record["updated_at"],
             "updated_by" => text(record["updated_by"]),
             "data" => decode_values(c, values)
         },
         :ok <- log(txn, scope, c, "update", record, row) do
      {:applied, [{c, :written, record}, {c, :forget, existing["id"], existing["data"]}]}
    end
  end

  # The records that pointed at this one were dealt with on the peer, by their
  # own changes before this one: a reference left here is refused by its foreign
  # key, as a delete here would be.
  defp delete(txn, scope, c, rowid, existing, row) do
    with :ok <- written(SQL.exec(txn, ~s[DELETE FROM "#{c.table}" WHERE "_rowid" = ?], [rowid]), c),
         :ok <-
           SQL.exec_all(txn, [
             {"DELETE FROM data_files WHERE collection_id = ? AND record_id = ?",
              [c.id, existing["id"]]},
             {"DELETE FROM data_embeddings WHERE collection_id = ? AND record_id = ?",
              [c.id, existing["id"]]}
           ]),
         :ok <-
           Collections.log_change(
             txn,
             scope,
             c,
             "delete",
             existing["id"],
             row["version"],
             owner_of(c, existing),
             nil,
             row["txn_id"]
           ) do
      {:applied, [{c, :deleted, existing["id"]}, {c, :forget, existing["id"], existing["data"]}]}
    end
  end

  defp log(txn, scope, c, op, record, row),
    do:
      Collections.log_change(
        txn,
        scope,
        c,
        op,
        record["id"],
        record["version"],
        owner_of(c, record),
        record,
        row["txn_id"]
      )

  # A unique value another record here holds is a conflict of data, not a
  # failure; a foreign key keeps its message, so the apply runs the change again
  # once the rest of the page is in (`OptimalEngine.Sync`).
  defp written({:ok, 1}, _c), do: :ok

  defp written({:ok, _n}, _c), do: {:error, :record_changed_during_apply}

  defp written({:error, message}, c) when is_binary(message) do
    if String.contains?(message, "UNIQUE constraint failed") and
         not String.contains?(message, c.table <> ".id"),
       do: {:conflict, "unique_conflict", nil, %{"errors" => [message]}},
       else: {:error, message}
  end

  defp written({:error, reason}, _c), do: {:error, reason}

  defp decode_values(c, values),
    do:
      Map.new(values, fn {name, value} ->
        {name, Schema.decode(Schema.field(c.schema, name), value)}
      end)

  defp owner_of(c, record) do
    case c.schema["owner_field"] do
      nil -> nil
      field -> record["data"][field]
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil
end
