defmodule OptimalEngine.AppData.Records do
  @moduledoc """
  Record writes for app data collections.

  Every write runs inside one `OptimalEngine.Store.transaction/2`, so a
  single write, a bulk insert, or a batch of operations commits or rolls
  back as a whole. Each written record gets a monotonically increasing
  `version`; an update or delete that names a stale version is rejected
  with a version conflict. Every committed change appends one row to the
  durable change feed (`data_changes`) in the same transaction.

  Operations (single, bulk, or inside `transact/2`):

      %{"op" => "create", "collection" => c, "id" => id?, "data" => %{}}
      %{"op" => "update", "collection" => c, "id" => id, "data" => %{}, "version" => v?}
      %{"op" => "delete", "collection" => c, "id" => id, "version" => v?}
      %{"op" => "upsert", "collection" => c, "key" => "field" | [fields] | "id", "data" => %{}, "id" => id?}
  """

  alias OptimalEngine.AppData.{Collections, Schema, Scope, SQL}
  alias OptimalEngine.Store

  @max_batch 5_000
  @max_cascade_depth 8

  @system_columns ~s[t."_rowid", t."id", t."_version", t."_created_at", t."_updated_at", t."_created_by", t."_updated_by"]

  @doc "Upper bound on operations in one bulk insert or transaction."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc """
  Runs `operations` in one transaction. Returns
  `{:ok, %{results: [...], txn_id: id, last_seq: seq, written: [...]}}` or
  `{:error, {:operation_failed, index, reason}}` with nothing committed.
  """
  @spec transact(Scope.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def transact(%Scope{} = scope, operations) when is_list(operations) do
    cond do
      operations == [] ->
        {:error, {:validation, ["operations must be a non-empty list"]}}

      length(operations) > @max_batch ->
        {:error, {:validation, ["at most #{@max_batch} operations per transaction"]}}

      true ->
        Store.transaction(fn txn -> run(txn, scope, operations) end, 120_000)
    end
  end

  def transact(_scope, _operations),
    do: {:error, {:validation, ["operations must be a non-empty list"]}}

  defp run(txn, scope, operations) do
    ctx = new_ctx()

    result =
      operations
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], ctx}, fn {op, index}, {:ok, acc, ctx} ->
        case apply_op(txn, scope, op, ctx) do
          {:ok, result, ctx} -> {:cont, {:ok, [result | acc], ctx}}
          {:error, reason} -> {:halt, {:error, {:operation_failed, index, reason}}}
        end
      end)

    with {:ok, results, ctx} <- result,
         {:ok, last_seq} <- SQL.scalar(txn, "SELECT MAX(seq) FROM data_changes", []) do
      {:ok,
       %{
         results: Enum.reverse(results),
         txn_id: ctx.txn_id,
         last_seq: last_seq,
         written: Enum.reverse(ctx.written)
       }}
    end
  end

  defp new_ctx do
    %{
      now: Schema.now(),
      txn_id: "txn_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      collections: %{},
      all: nil,
      written: [],
      visited: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # Operation dispatch
  # ---------------------------------------------------------------------------

  defp apply_op(txn, scope, %{"op" => op, "collection" => name} = input, ctx)
       when op in ~w(create update delete upsert) and is_binary(name) do
    with {:ok, c, ctx} <- collection(txn, scope, name, ctx) do
      case op do
        "create" -> create(txn, scope, c, input, ctx)
        "update" -> update(txn, scope, c, input, ctx)
        "delete" -> delete(txn, scope, c, input, ctx)
        "upsert" -> upsert(txn, scope, c, input, ctx)
      end
    end
  end

  defp apply_op(_txn, _scope, _input, _ctx) do
    {:error,
     {:validation, ["each operation needs op (create, update, delete, upsert) and collection"]}}
  end

  defp collection(txn, scope, name, ctx) do
    case Map.fetch(ctx.collections, name) do
      {:ok, c} ->
        {:ok, c, ctx}

      :error ->
        with {:ok, c} <- Collections.load(txn, scope, name) do
          {:ok, c, %{ctx | collections: Map.put(ctx.collections, name, c)}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  defp create(txn, scope, c, input, ctx) do
    with :ok <- Scope.allow(scope, c.name, "create"),
         {:ok, id} <- new_id(input["id"]),
         {:ok, data} <- data_map(input["data"]),
         :ok <- known_fields(c, data),
         data = apply_defaults(c, data, ctx.now),
         {:ok, data} <- assign_owner(scope, c, data, :create),
         {:ok, values} <- coerce_all(c, data, :create),
         {:ok, ctx} <- check_references(txn, scope, c, values, id, ctx),
         :ok <- insert(txn, c, id, values, scope.actor, ctx.now) do
      record = %{
        "id" => id,
        "version" => 1,
        "created_at" => ctx.now,
        "updated_at" => ctx.now,
        "created_by" => scope.actor,
        "updated_by" => scope.actor,
        "data" => decode_values(c, values)
      }

      written(txn, scope, c, "create", record, ctx)
    end
  end

  defp new_id(nil), do: {:ok, Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}

  defp new_id(id) do
    if Schema.record_id?(id),
      do: {:ok, id},
      else: {:error, {:validation, ["id must match [A-Za-z0-9][A-Za-z0-9_.:-]{0,127}"]}}
  end

  defp insert(txn, c, id, values, actor, now) do
    columns = Enum.map(values, fn {field, _} -> Schema.column(field) end)

    sql =
      ~s[INSERT INTO "#{c.table}" ("id", "_version", "_created_at", "_updated_at", "_created_by", "_updated_by"#{prefix_join(columns)}) VALUES (?, 1, ?, ?, ?, ?#{prefix_join(Enum.map(values, fn _ -> "?" end))})]

    params = [id, now, now, actor, actor | Enum.map(values, &elem(&1, 1))]

    case SQL.exec(txn, sql, params) do
      {:ok, 1} -> :ok
      {:error, reason} -> {:error, constraint_error(c, reason)}
    end
  end

  defp prefix_join([]), do: ""
  defp prefix_join(items), do: ", " <> Enum.join(items, ", ")

  # ---------------------------------------------------------------------------
  # Update
  # ---------------------------------------------------------------------------

  defp update(txn, scope, c, input, ctx) do
    with :ok <- Scope.allow(scope, c.name, "update"),
         {:ok, data} <- data_map(input["data"]),
         :ok <- non_empty(data),
         :ok <- known_fields(c, data),
         {:ok, {rowid, existing}} <- fetch_visible(txn, scope, c, input["id"]),
         :ok <- check_version(existing, input["version"]) do
      update_existing(txn, scope, c, rowid, existing, data, ctx)
    end
  end

  defp update_existing(txn, scope, c, rowid, existing, data, ctx) do
    with {:ok, data} <- assign_owner(scope, c, data, :update),
         {:ok, values} <- coerce_all(c, data, :update),
         {:ok, ctx} <- check_references(txn, scope, c, values, existing["id"], ctx),
         :ok <- write_update(txn, c, rowid, existing["version"], values, scope.actor, ctx.now) do
      record = %{
        existing
        | "version" => existing["version"] + 1,
          "updated_at" => ctx.now,
          "updated_by" => scope.actor,
          "data" => Map.merge(existing["data"], decode_values(c, values))
      }

      with {:ok, result, ctx} <- written(txn, scope, c, "update", record, ctx) do
        # An update that rewrites the semantic text leaves the old text's cached
        # embedding behind unless it is named here.
        {:ok, result,
         %{ctx | written: [{c, :forget, existing["id"], existing["data"]} | ctx.written]}}
      end
    end
  end

  defp write_update(txn, c, rowid, version, values, actor, now) do
    sets = Enum.map(values, fn {field, _} -> "#{Schema.column(field)} = ?" end)

    sql =
      ~s[UPDATE "#{c.table}" SET "_version" = "_version" + 1, "_updated_at" = ?, "_updated_by" = ?#{prefix_join(sets)} WHERE "_rowid" = ? AND "_version" = ?]

    params = [now, actor] ++ Enum.map(values, &elem(&1, 1)) ++ [rowid, version]

    case SQL.exec(txn, sql, params) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, {:conflict, "version_conflict", %{}}}
      {:error, reason} -> {:error, constraint_error(c, reason)}
    end
  end

  defp non_empty(data) when map_size(data) > 0, do: :ok
  defp non_empty(_data), do: {:error, {:validation, ["data must name at least one field"]}}

  defp check_version(_existing, nil), do: :ok

  defp check_version(%{"version" => current}, version) when is_integer(version) do
    if version == current,
      do: :ok,
      else: {:error, {:conflict, "version_conflict", %{"current_version" => current}}}
  end

  defp check_version(_existing, _version),
    do: {:error, {:validation, ["version must be an integer"]}}

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  defp delete(txn, scope, c, input, ctx) do
    with :ok <- Scope.allow(scope, c.name, "delete"),
         {:ok, {rowid, existing}} <- fetch_visible(txn, scope, c, input["id"]),
         :ok <- check_version(existing, input["version"]),
         {:ok, ctx} <- delete_row(txn, scope, c, rowid, existing, ctx, 0) do
      {:ok, %{"op" => "delete", "id" => existing["id"], "version" => existing["version"] + 1}, ctx}
    end
  end

  defp delete_row(txn, scope, c, rowid, existing, ctx, depth) do
    ctx = %{ctx | visited: MapSet.put(ctx.visited, {c.id, rowid})}

    with {:ok, ctx} <- handle_referrers(txn, scope, c, existing, ctx, depth),
         {:ok, 1} <- SQL.exec(txn, ~s[DELETE FROM "#{c.table}" WHERE "_rowid" = ?], [rowid]),
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
             existing["version"] + 1,
             owner_of(c, existing),
             nil,
             ctx.txn_id
           ) do
      # The text is at hand now and gone after: the embedding cached from it goes with
      # the record (`Semantic.index_written/1`).
      {:ok,
       %{
         ctx
         | written: [
             {c, :deleted, existing["id"]},
             {c, :forget, existing["id"], existing["data"]} | ctx.written
           ]
       }}
    else
      {:ok, 0} -> {:error, {:not_found, "record_not_found"}}
      {:error, {:foreign_key, _}} -> {:error, {:conflict, "reference_restrict", %{}}}
      {:error, reason} -> {:error, constraint_error(c, reason)}
    end
  end

  # Rows in other collections (or this one) that reference the record being
  # deleted follow their field's on_delete rule: restrict refuses, set_null
  # clears the reference, cascade deletes the row. Every affected row is a
  # logged change. An owner-bound caller may only affect rows it owns.
  defp handle_referrers(txn, scope, c, existing, ctx, depth) do
    with {:ok, all, ctx} <- all_collections(txn, scope, ctx) do
      refs =
        for rc <- all,
            field <- rc.schema["fields"],
            field["type"] == "reference" and field["references"] == c.name,
            do: {rc, field}

      Enum.reduce_while(refs, {:ok, ctx}, fn {rc, field}, {:ok, ctx} ->
        case referrer_rows(txn, rc, field, existing["id"]) do
          {:ok, rows} ->
            rows =
              Enum.reject(rows, fn {rowid, _} -> MapSet.member?(ctx.visited, {rc.id, rowid}) end)

            case follow_rule(txn, scope, rc, field, rows, ctx, depth) do
              {:ok, ctx} -> {:cont, {:ok, ctx}}
              error -> {:halt, error}
            end

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp referrer_rows(txn, rc, field, id) do
    sql =
      ~s[SELECT #{@system_columns}#{prefix_join(field_columns(rc))} FROM "#{rc.table}" t WHERE t.#{Schema.column(field["name"])} = ?]

    with {:ok, rows} <- SQL.query(txn, sql, [id]) do
      {:ok, Enum.map(rows, &row_record(rc, &1))}
    end
  end

  defp follow_rule(_txn, _scope, _rc, _field, [], ctx, _depth), do: {:ok, ctx}

  defp follow_rule(_txn, _scope, rc, %{"on_delete" => "restrict"} = field, _rows, _ctx, _depth) do
    {:error,
     {:conflict, "reference_restrict", %{"collection" => rc.name, "field" => field["name"]}}}
  end

  defp follow_rule(txn, scope, rc, %{"on_delete" => "set_null"} = field, rows, ctx, _depth) do
    Enum.reduce_while(rows, {:ok, ctx}, fn {rowid, record}, {:ok, ctx} ->
      with :ok <- owns(scope, rc, record),
           :ok <-
             write_update(
               txn,
               rc,
               rowid,
               record["version"],
               [{field["name"], nil}],
               scope.actor,
               ctx.now
             ) do
        updated = %{
          record
          | "version" => record["version"] + 1,
            "updated_at" => ctx.now,
            "updated_by" => scope.actor,
            "data" => Map.put(record["data"], field["name"], nil)
        }

        case written(txn, scope, rc, "update", updated, ctx) do
          {:ok, _result, ctx} -> {:cont, {:ok, ctx}}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp follow_rule(txn, scope, rc, %{"on_delete" => "cascade"}, rows, ctx, depth) do
    if depth >= @max_cascade_depth do
      {:error, {:validation, ["cascade deeper than #{@max_cascade_depth} levels"]}}
    else
      Enum.reduce_while(rows, {:ok, ctx}, fn {rowid, record}, {:ok, ctx} ->
        with :ok <- owns(scope, rc, record),
             {:ok, ctx} <- delete_row(txn, scope, rc, rowid, record, ctx, depth + 1) do
          {:cont, {:ok, ctx}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp owns(scope, rc, record) do
    owner_field = rc.schema["owner_field"]

    if Scope.owner_bound?(scope) and owner_field != nil and
         record["data"][owner_field] != scope.owner,
       do: {:error, {:forbidden, "owner_scope_cascade"}},
       else: :ok
  end

  defp all_collections(txn, scope, %{all: nil} = ctx) do
    with {:ok, all} <- Collections.load_all(txn, scope) do
      {:ok, all, %{ctx | all: all}}
    end
  end

  defp all_collections(_txn, _scope, ctx), do: {:ok, ctx.all, ctx}

  # ---------------------------------------------------------------------------
  # Upsert
  # ---------------------------------------------------------------------------

  defp upsert(txn, scope, c, input, ctx) do
    with :ok <- Scope.allow(scope, c.name, "create"),
         :ok <- Scope.allow(scope, c.name, "update"),
         {:ok, data} <- data_map(input["data"]),
         :ok <- known_fields(c, data),
         {:ok, key} <- upsert_key(c, input["key"]),
         {:ok, found} <- find_by_key(txn, c, key, input, data) do
      case found do
        nil ->
          create(txn, scope, c, input, ctx)

        {rowid, existing} ->
          with :ok <- visible(scope, c, existing),
               :ok <- check_version(existing, input["version"]) do
            data = Map.drop(data, if(key == ["id"], do: [], else: key))

            if map_size(data) == 0,
              do: {:ok, Map.put(existing, "op", "unchanged"), ctx},
              else: update_existing(txn, scope, c, rowid, existing, data, ctx)
          end
      end
    end
  end

  defp upsert_key(_c, "id"), do: {:ok, ["id"]}
  defp upsert_key(c, key) when is_binary(key), do: upsert_key(c, [key])

  defp upsert_key(c, key) when is_list(key) and key != [] do
    if Enum.any?(
         c.schema["indexes"],
         &(&1["unique"] and Enum.sort(&1["fields"]) == Enum.sort(key))
       ),
       do: {:ok, key},
       else: {:error, {:validation, ["upsert key must be id or the fields of a unique index"]}}
  end

  defp upsert_key(_c, _key), do: {:error, {:validation, ["upsert needs a key"]}}

  defp find_by_key(txn, c, ["id"], input, _data) do
    case input["id"] do
      id when is_binary(id) -> fetch_row(txn, c, ~s[t."id" = ?], [id])
      _ -> {:error, {:validation, ["upsert by id needs an id"]}}
    end
  end

  defp find_by_key(txn, c, key, _input, data) do
    values =
      Enum.map(key, fn name ->
        field = Schema.field(c.schema, name)

        case Map.get(data, name) do
          nil -> :missing
          value -> Schema.coerce(field, value)
        end
      end)

    cond do
      :missing in values ->
        {:error, {:validation, ["upsert data must include every key field"]}}

      Enum.any?(values, &match?({:error, _}, &1)) ->
        {:error, {:validation, ["upsert key values do not match their field types"]}}

      true ->
        where = Enum.map_join(key, " AND ", &"t.#{Schema.column(&1)} = ?")
        fetch_row(txn, c, where, Enum.map(values, &elem(&1, 1)))
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  @doc false
  # The record visible to the scope, as `{rowid, record}`. Owner-bound
  # scopes cannot see other owners' rows: those are reported as not found.
  @spec fetch_visible(:store | term(), Scope.t(), map(), term()) ::
          {:ok, {integer(), map()}} | {:error, term()}
  def fetch_visible(conn, scope, c, id) when is_binary(id) do
    {where, params} = owner_filter(scope, c, ~s[t."id" = ?], [id])

    case fetch_row(conn, c, where, params) do
      {:ok, nil} -> {:error, {:not_found, "record_not_found"}}
      other -> other
    end
  end

  def fetch_visible(_conn, _scope, _c, _id), do: {:error, {:not_found, "record_not_found"}}

  @doc false
  @spec owner_filter(Scope.t(), map(), String.t(), list(), String.t()) :: {String.t(), list()}
  def owner_filter(scope, c, where, params, alias \\ "t") do
    owner_field = c.schema["owner_field"]

    if Scope.owner_bound?(scope) and owner_field != nil,
      do: {"(#{where}) AND #{alias}.#{Schema.column(owner_field)} = ?", params ++ [scope.owner]},
      else: {where, params}
  end

  defp visible(scope, c, record) do
    owner_field = c.schema["owner_field"]

    if Scope.owner_bound?(scope) and owner_field != nil and
         record["data"][owner_field] != scope.owner,
       do: {:error, {:conflict, "unique_violation", %{}}},
       else: :ok
  end

  defp fetch_row(conn, c, where, params) do
    sql =
      ~s[SELECT #{@system_columns}#{prefix_join(field_columns(c))} FROM "#{c.table}" t WHERE #{where} LIMIT 1]

    case SQL.query(conn, sql, params) do
      {:ok, [row]} -> {:ok, row_record(c, row)}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec field_columns(map(), [String.t()] | nil) :: [String.t()]
  def field_columns(c, names \\ nil) do
    names = names || Schema.field_names(c.schema)
    Enum.map(names, &("t." <> Schema.column(&1)))
  end

  @doc false
  # A selected row (system columns, then the given fields) as `{rowid, record}`.
  @spec row_record(map(), list(), [String.t()] | nil) :: {integer(), map()}
  def row_record(c, row, names \\ nil) do
    names = names || Schema.field_names(c.schema)
    [rowid, id, version, created_at, updated_at, created_by, updated_by | values] = row

    data =
      names
      |> Enum.zip(values)
      |> Map.new(fn {name, value} -> {name, Schema.decode(Schema.field(c.schema, name), value)} end)

    {rowid,
     %{
       "id" => id,
       "version" => version,
       "created_at" => created_at,
       "updated_at" => updated_at,
       "created_by" => created_by,
       "updated_by" => updated_by,
       "data" => data
     }}
  end

  @doc false
  @spec system_columns() :: String.t()
  def system_columns, do: @system_columns

  defp data_map(nil), do: {:ok, %{}}
  defp data_map(%{} = data) when not is_struct(data), do: {:ok, data}
  defp data_map(_data), do: {:error, {:validation, ["data must be an object"]}}

  defp known_fields(c, data) do
    names = MapSet.new(Schema.field_names(c.schema))

    case Enum.reject(Map.keys(data), &MapSet.member?(names, &1)) do
      [] -> :ok
      unknown -> {:error, {:validation, ["unknown fields: #{Enum.join(unknown, ", ")}"]}}
    end
  end

  defp apply_defaults(c, data, now) do
    Enum.reduce(c.schema["fields"], data, fn field, acc ->
      cond do
        Map.has_key?(acc, field["name"]) ->
          acc

        not Map.has_key?(field, "default") ->
          acc

        field["type"] == "datetime" and field["default"] == "now" ->
          Map.put(acc, field["name"], now)

        true ->
          Map.put(acc, field["name"], field["default"])
      end
    end)
  end

  # The owner field is never taken on trust from a keyed caller. An
  # owner-bound credential owns what it creates and may not name another
  # owner; another keyed caller defaults to itself and may name someone else
  # only with data:admin; a trusted local caller may name any owner.
  defp assign_owner(scope, c, data, mode) do
    case c.schema["owner_field"] do
      nil -> {:ok, data}
      field -> assign_owner(scope, field, Map.fetch(data, field), data, mode)
    end
  end

  defp assign_owner(%Scope{owner: owner}, field, supplied, data, mode) when is_binary(owner) do
    case supplied do
      :error when mode == :create -> {:ok, Map.put(data, field, owner)}
      :error -> {:ok, data}
      {:ok, ^owner} -> {:ok, data}
      {:ok, _other} -> {:error, {:forbidden, "owner_mismatch"}}
    end
  end

  defp assign_owner(%Scope{} = scope, field, supplied, data, mode) do
    case supplied do
      :error when mode == :create -> {:ok, Map.put(data, field, scope.actor)}
      :error -> {:ok, data}
      {:ok, value} when value == scope.actor -> {:ok, data}
      {:ok, _other} when scope.admin -> {:ok, data}
      {:ok, _other} -> {:error, {:forbidden, "owner_mismatch"}}
    end
  end

  # Coerces data to column values. On create every declared field is
  # written (missing ones as null); on update only the named fields.
  defp coerce_all(c, data, mode) do
    fields =
      case mode do
        :create -> c.schema["fields"]
        :update -> Enum.filter(c.schema["fields"], &Map.has_key?(data, &1["name"]))
      end

    {values, errors} =
      Enum.reduce(fields, {[], []}, fn field, {values, errors} ->
        name = field["name"]
        value = Map.get(data, name)

        cond do
          is_nil(value) and field["required"] ->
            {values, ["#{name} is required" | errors]}

          true ->
            case Schema.coerce(field, value) do
              {:ok, db_value} -> {[{name, db_value} | values], errors}
              {:error, message} -> {values, ["#{name} #{message}" | errors]}
            end
        end
      end)

    if errors == [],
      do: {:ok, Enum.reverse(values)},
      else: {:error, {:validation, Enum.reverse(errors)}}
  end

  defp decode_values(c, values) do
    Map.new(values, fn {name, value} ->
      {name, Schema.decode(Schema.field(c.schema, name), value)}
    end)
  end

  # A reference must point at an existing record the caller can see.
  defp check_references(txn, scope, c, values, own_id, ctx) do
    refs =
      for {name, value} <- values,
          value != nil,
          field = Schema.field(c.schema, name),
          field["type"] == "reference",
          do: {field, value}

    Enum.reduce_while(refs, {:ok, ctx}, fn {field, value}, {:ok, ctx} ->
      target = field["references"]

      cond do
        target == c.name and value == own_id ->
          {:cont, {:ok, ctx}}

        true ->
          with {:ok, tc, ctx} <- collection(txn, scope, target, ctx),
               {where, params} = owner_filter(scope, tc, ~s[t."id" = ?], [value]),
               {:ok, rows} <-
                 SQL.query(txn, ~s[SELECT 1 FROM "#{tc.table}" t WHERE #{where} LIMIT 1], params) do
            if rows == [],
              do:
                {:halt,
                 {:error,
                  {:validation, ["#{field["name"]} references a record that does not exist"]}}},
              else: {:cont, {:ok, ctx}}
          else
            {:error, {:not_found, _}} ->
              {:halt, {:error, {:validation, ["#{field["name"]} references a missing collection"]}}}

            error ->
              {:halt, error}
          end
      end
    end)
  end

  defp written(txn, scope, c, op, record, ctx) do
    case Collections.log_change(
           txn,
           scope,
           c,
           op,
           record["id"],
           record["version"],
           owner_of(c, record),
           record,
           ctx.txn_id
         ) do
      :ok ->
        result = Map.put(record, "op", op)
        {:ok, result, %{ctx | written: [{c, :written, record} | ctx.written]}}

      error ->
        error
    end
  end

  defp owner_of(c, record) do
    case c.schema["owner_field"] do
      nil -> nil
      field -> record["data"][field]
    end
  end

  # SQLite constraint messages carry the table and columns, never values.
  defp constraint_error(c, message) when is_binary(message) do
    cond do
      String.contains?(message, "UNIQUE constraint failed: #{c.table}.id") ->
        {:conflict, "record_exists", %{}}

      String.contains?(message, "UNIQUE constraint failed") ->
        fields =
          Regex.scan(~r/#{c.table}\.f_([a-z0-9_]+)/, message)
          |> Enum.map(fn [_, field] -> field end)

        {:conflict, "unique_violation", %{"fields" => fields}}

      String.contains?(message, "FOREIGN KEY constraint failed") ->
        {:conflict, "reference_violation", %{}}

      true ->
        {:storage, message}
    end
  end

  defp constraint_error(_c, reason), do: reason
end
