defmodule OptimalEngine.AppData.Query do
  @moduledoc """
  Reads over an app data collection: filters, sort, keyset cursor
  pagination, field selection, counts, full-text and semantic search, and
  joins over declared references.

  A query is a map:

      %{"where" => %{"done" => false, "owner" => "user-a", "due" => %{"lt" => "2026-12-01"}},
        "sort" => ["due", "-priority"],
        "limit" => 50,
        "cursor" => "...",
        "fields" => ["title", "due"],
        "count" => true,
        "include" => ["project"],
        "search" => %{"text" => "quarterly report", "match" => "all", "prefix" => false},
        "semantic" => %{"text" => "things about money", "min_score" => 0.3}}

  `where` maps a field to a value (equality; `null` means `is_null`) or to
  operators: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `nin`, `contains`
  (substring for string and text, membership for json arrays), `is_null`.
  `and`, `or` (lists) and `not` combine conditions. A dotted path such as
  `"project.status"` filters through a reference field. System fields `id`,
  `version`, `created_at`, `updated_at`, `created_by`, `updated_by` can be
  filtered and sorted too. Every value is a bound parameter; field names are
  checked against the schema before they become column names.

  Pages are keyset pages: `next_cursor` encodes the last row's sort values,
  so pages stay stable while rows are written. A cursor is bound to the
  collection, sort, filter and search it was issued for.

  Rows equal in every sort key keep the order they were inserted in: the last
  sort key is the record's `_rowid`, a counter local to the Engine that stored
  it. A copy of a collection made by inserting its records in another order
  pages such rows in that order, so an order that must match across Engines
  has to name a sort key that is unique, such as `id`.
  """

  alias OptimalEngine.AppData.{Collections, Records, Schema, Scope, Semantic, SQL}

  @default_limit 50
  @max_limit 1_000
  @max_sort 4
  @max_in 1_000
  @ops ~w(eq ne gt gte lt lte in nin contains is_null)
  @max_depth 8
  @max_conditions 200

  @doc "Fetches one record, optionally with `fields` and `include`."
  @spec get(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, name, id, spec \\ %{}) do
    with :ok <- Scope.allow(scope, name, "read"),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, {_rowid, record}} <- Records.fetch_visible(:store, scope, c, id),
         {:ok, includes} <- includes(scope, c, spec["include"]),
         {:ok, names} <- selected_fields(c, spec["fields"], includes),
         [record] <- attach_includes(scope, [record], includes) do
      {:ok, select_data(record, names)}
    end
  end

  @doc "Runs a query (see the module documentation)."
  @spec run(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, name, spec) when is_map(spec) do
    with :ok <- Scope.allow(scope, name, "read"),
         {:ok, c} <- Collections.load(:store, scope, name),
         {:ok, limit} <- limit(spec["limit"]),
         {:ok, includes} <- includes(scope, c, spec["include"]),
         {:ok, names} <- selected_fields(c, spec["fields"], includes),
         {:ok, refs} <- reference_targets(scope, c, spec["where"]),
         {:ok, {where_sql, where_params}} <- compile_where(scope, c, refs, spec["where"]),
         {:ok, mode} <- mode(c, spec) do
      plan = %{
        scope: scope,
        c: c,
        names: names,
        limit: limit,
        includes: includes,
        where: {where_sql, where_params},
        spec: spec,
        mode: mode
      }

      case mode do
        {:semantic, _} -> Semantic.query(plan)
        _ -> sql_query(plan)
      end
    end
  catch
    {:bad_query, message} -> {:error, {:validation, [message]}}
  end

  def run(_scope, _name, _spec), do: {:error, {:validation, ["query must be an object"]}}

  # ---------------------------------------------------------------------------
  # SQL plan
  # ---------------------------------------------------------------------------

  defp sql_query(%{c: c, mode: mode} = plan) do
    {join_sql, join_params} = join(c, mode)
    {where_sql, where_params} = with_owner(plan)
    sort = sort_keys(c, plan.spec["sort"], mode)
    hash = cursor_hash(plan, sort)

    {cursor_sql, cursor_params} =
      case decode_cursor(plan.spec["cursor"], hash, length(sort)) do
        nil -> {"1", []}
        {values, rowid} -> keyset(sort, values, rowid)
      end

    key_exprs = Enum.map(sort, &elem(&1, 0))

    select =
      [Records.system_columns() | Records.field_columns(c, plan.names)] ++
        key_exprs ++
        [score_expr(mode)]

    order =
      (sort ++ [{~s[t."_rowid"], :asc}])
      |> Enum.map_join(", ", fn {expr, dir} ->
        "#{expr} #{dir |> Atom.to_string() |> String.upcase()}"
      end)

    sql =
      ~s[#{join_sql} SELECT #{Enum.join(select, ", ")} FROM #{source(c, mode)} WHERE (#{where_sql}) AND (#{cursor_sql}) ORDER BY #{order} LIMIT ?]

    params = join_params ++ where_params ++ cursor_params ++ [plan.limit + 1]

    with {:ok, rows} <- run_sql(plan, sql, params),
         {:ok, count} <- count(plan, join_sql, join_params, where_sql, where_params) do
      {page, more} = Enum.split(rows, plan.limit)
      field_count = 7 + length(plan.names)

      records =
        Enum.map(page, fn row ->
          {record_row, rest} = Enum.split(row, field_count)
          {_rowid, record} = Records.row_record(c, record_row, plan.names)
          score = List.last(rest)
          if score == nil, do: record, else: Map.put(record, "score", -score)
        end)

      next_cursor =
        case {more, List.last(page)} do
          {[_ | _], row} when row != nil ->
            rest = Enum.drop(row, field_count)
            encode_cursor(hash, Enum.take(rest, length(sort)), hd(row))

          _ ->
            nil
        end

      {:ok,
       %{
         "records" => attach_includes(plan.scope, records, plan.includes),
         "next_cursor" => next_cursor,
         "has_more" => next_cursor != nil
       }
       |> maybe_put_count(count)}
    end
  end

  defp run_sql(%{mode: {:text, nil}}, _sql, _params), do: {:ok, []}
  defp run_sql(_plan, sql, params), do: SQL.query(:store, sql, params)

  defp with_owner(%{scope: scope, c: c, where: {sql, params}}),
    do: Records.owner_filter(scope, c, sql, params)

  # Full-text matches are computed once (FTS5 first, materialized), then
  # joined to the collection by primary key. Letting SQLite drive the join
  # from the collection side probes FTS5 once per candidate row instead.
  defp join(c, {:text, query}) when is_binary(query) do
    fts = Collections.fts_table(c)

    {~s[WITH s AS MATERIALIZED (SELECT rowid AS _rid, bm25("#{fts}") AS _score FROM "#{fts}" WHERE "#{fts}" MATCH ?)],
     [query]}
  end

  defp join(_c, _mode), do: {"", []}

  defp source(c, {:text, _}), do: ~s[s CROSS JOIN "#{c.table}" t ON t."_rowid" = s._rid]
  defp source(c, _mode), do: ~s["#{c.table}" t]

  defp score_expr({:text, _}), do: "s._score"
  defp score_expr(_mode), do: "NULL"

  defp count(%{spec: %{"count" => true}, mode: {:text, nil}}, _j, _jp, _w, _wp), do: {:ok, 0}

  defp count(%{spec: %{"count" => true}} = plan, join_sql, join_params, where_sql, where_params) do
    SQL.scalar(
      :store,
      ~s[#{join_sql} SELECT COUNT(*) FROM #{source(plan.c, plan.mode)} WHERE #{where_sql}],
      join_params ++ where_params
    )
  end

  defp count(_plan, _join_sql, _join_params, _where_sql, _where_params), do: {:ok, nil}

  defp maybe_put_count(result, nil), do: result
  defp maybe_put_count(result, count), do: Map.put(result, "count", count)

  defp limit(nil), do: {:ok, @default_limit}
  defp limit(n) when is_integer(n) and n >= 0 and n <= @max_limit, do: {:ok, n}
  defp limit(_n), do: {:error, {:validation, ["limit must be an integer from 0 to #{@max_limit}"]}}

  defp mode(c, spec) do
    cond do
      spec["search"] != nil and spec["semantic"] != nil ->
        {:error, {:validation, ["use search or semantic, not both"]}}

      spec["search"] != nil ->
        text_mode(c, spec["search"])

      spec["semantic"] != nil ->
        semantic_mode(c, spec["semantic"])

      true ->
        {:ok, :plain}
    end
  end

  defp text_mode(c, search) when is_binary(search), do: text_mode(c, %{"text" => search})

  defp text_mode(c, %{"text" => text} = search) when is_binary(text) do
    if Schema.text_fields(c.schema) == [] do
      {:error, {:validation, ["collection #{c.name} has no full-text search fields"]}}
    else
      {:ok, {:text, fts_query(text, search["match"] || "all", search["prefix"] == true)}}
    end
  end

  defp text_mode(_c, _search), do: {:error, {:validation, ["search needs text"]}}

  defp semantic_mode(c, semantic) when is_binary(semantic),
    do: semantic_mode(c, %{"text" => semantic})

  defp semantic_mode(c, %{"text" => text} = semantic) when is_binary(text) and text != "" do
    if Schema.semantic_fields(c.schema) == [],
      do: {:error, {:validation, ["collection #{c.name} has no semantic search fields"]}},
      else: {:ok, {:semantic, semantic}}
  end

  defp semantic_mode(_c, _semantic), do: {:error, {:validation, ["semantic needs text"]}}

  # Free text becomes quoted FTS5 terms, so no input can reach FTS5 syntax.
  # nil means the text has no searchable terms.
  defp fts_query(text, match, prefix) do
    terms = ~r/[\p{L}\p{N}_]+/u |> Regex.scan(text) |> List.flatten() |> Enum.take(32)

    case terms do
      [] ->
        nil

      _ ->
        joiner = if match == "any", do: " OR ", else: " "
        quoted = Enum.map(terms, &~s["#{&1}"])
        quoted = if prefix, do: List.update_at(quoted, -1, &(&1 <> "*")), else: quoted
        Enum.join(quoted, joiner)
    end
  end

  # ---------------------------------------------------------------------------
  # Sort and cursor
  # ---------------------------------------------------------------------------

  # Sort keys as `{sql_expr, :asc | :desc}`; `t._rowid` is always the final
  # tie-breaker (added by the caller).
  defp sort_keys(c, nil, {:text, _}), do: sort_keys(c, ["_score"], {:text, nil})
  defp sort_keys(_c, nil, _mode), do: []

  defp sort_keys(c, sort, mode) when is_list(sort) do
    if length(sort) > @max_sort, do: throw({:bad_query, "sort accepts at most #{@max_sort} keys"})
    Enum.map(sort, &sort_key(c, &1, mode))
  end

  defp sort_keys(c, sort, mode) when is_binary(sort), do: sort_keys(c, [sort], mode)
  defp sort_keys(_c, _sort, _mode), do: throw({:bad_query, "sort must be a list"})

  defp sort_key(c, "-" <> field, mode), do: sort_key(c, %{"field" => field, "dir" => "desc"}, mode)
  defp sort_key(c, field, mode) when is_binary(field), do: sort_key(c, %{"field" => field}, mode)

  defp sort_key(c, %{"field" => field} = key, mode) do
    dir =
      case key["dir"] || "asc" do
        "asc" -> :asc
        "desc" -> :desc
        _ -> throw({:bad_query, "sort dir must be asc or desc"})
      end

    cond do
      field == "_score" and match?({:text, _}, mode) ->
        {"s._score", dir}

      field == "_score" ->
        throw({:bad_query, "_score sorts only search results"})

      true ->
        case resolve(c, field, "t") do
          {expr, %{"type" => type}} when type not in ~w(json) -> {expr, dir}
          {_expr, _field} -> throw({:bad_query, "#{field} cannot be sorted"})
          nil -> throw({:bad_query, "unknown sort field #{field}"})
        end
    end
  end

  defp sort_key(_c, _key, _mode), do: throw({:bad_query, "invalid sort key"})

  # Rows strictly after the cursor row in `ORDER BY keys..., _rowid ASC`.
  # SQLite orders NULL first ascending and last descending; the predicate
  # follows the same order.
  defp keyset(sort, values, rowid) do
    keys = sort ++ [{~s[t."_rowid"], :asc}]
    values = values ++ [rowid]
    pairs = Enum.zip(keys, values)

    clauses =
      for i <- 0..(length(pairs) - 1) do
        {before, [{key, value} | _]} = Enum.split(pairs, i)
        eqs = Enum.map(before, fn {{expr, _dir}, v} -> equal(expr, v) end)
        {after_sql, after_params} = after_key(key, value)
        eq_sql = Enum.map(eqs, &elem(&1, 0))
        eq_params = Enum.flat_map(eqs, &elem(&1, 1))
        {Enum.join(eq_sql ++ [after_sql], " AND "), eq_params ++ after_params}
      end

    {Enum.map_join(clauses, " OR ", &"(#{elem(&1, 0)})"), Enum.flat_map(clauses, &elem(&1, 1))}
  end

  defp equal(expr, nil), do: {"#{expr} IS NULL", []}
  defp equal(expr, value), do: {"#{expr} = ?", [value]}

  defp after_key({expr, :asc}, nil), do: {"#{expr} IS NOT NULL", []}
  defp after_key({expr, :asc}, value), do: {"#{expr} > ?", [value]}
  defp after_key({_expr, :desc}, nil), do: {"0", []}
  defp after_key({expr, :desc}, value), do: {"(#{expr} < ? OR #{expr} IS NULL)", [value]}

  defp cursor_hash(plan, sort) do
    term = {plan.c.id, sort, plan.spec["where"], plan.mode}
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> binary_part(0, 8)
  end

  @doc false
  @spec encode_cursor(binary(), list(), term()) :: String.t()
  def encode_cursor(hash, values, rowid) do
    %{"h" => Base.encode16(hash, case: :lower), "v" => values, "r" => rowid}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec decode_cursor(term(), binary(), non_neg_integer()) :: {list(), term()} | nil
  def decode_cursor(nil, _hash, _arity), do: nil

  def decode_cursor(cursor, hash, arity) when is_binary(cursor) do
    expected = Base.encode16(hash, case: :lower)

    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"h" => ^expected, "v" => values, "r" => rowid}} when is_list(values) <-
           Jason.decode(json),
         true <- length(values) == arity do
      {values, rowid}
    else
      _ -> throw({:bad_query, "invalid cursor for this query"})
    end
  end

  def decode_cursor(_cursor, _hash, _arity), do: throw({:bad_query, "invalid cursor"})

  # ---------------------------------------------------------------------------
  # Filters
  # ---------------------------------------------------------------------------

  @doc false
  @spec compile_where(Scope.t(), map(), map(), term()) :: {:ok, {String.t(), list()}}
  def compile_where(scope, c, refs, where) do
    counter = :counters.new(1, [])
    ctx = %{scope: scope, c: c, refs: refs, alias: "t", counter: counter, depth: 0}
    {:ok, compile(where, ctx)}
  end

  defp compile(nil, _ctx), do: {"1", []}
  defp compile(where, _ctx) when where == %{}, do: {"1", []}

  defp compile(_where, %{depth: depth}) when depth > @max_depth,
    do: throw({:bad_query, "where nests deeper than #{@max_depth} levels"})

  defp compile(%{} = where, ctx) when not is_struct(where) do
    ctx = %{ctx | depth: ctx.depth + 1}

    where
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn
      {"and", list} when is_list(list) ->
        combine(Enum.map(list, &compile(&1, ctx)), "AND")

      {"or", list} when is_list(list) and list != [] ->
        combine(Enum.map(list, &compile(&1, ctx)), "OR")

      {"not", inner} ->
        negate(compile(inner, ctx))

      {key, _} when key in ~w(and or not) ->
        throw({:bad_query, "#{key} needs a list (not: an object)"})

      {field, condition} ->
        :counters.add(ctx.counter, 1, 1)

        if :counters.get(ctx.counter, 1) > @max_conditions,
          do: throw({:bad_query, "where has more than #{@max_conditions} conditions"})

        field_condition(field, condition, ctx)
    end)
    |> combine("AND")
  end

  defp compile(_where, _ctx), do: throw({:bad_query, "where must be an object"})

  defp combine([], _joiner), do: {"1", []}

  defp combine(parts, joiner) do
    {Enum.map_join(parts, " #{joiner} ", &"(#{elem(&1, 0)})"), Enum.flat_map(parts, &elem(&1, 1))}
  end

  defp negate({sql, params}), do: {"NOT (#{sql})", params}

  defp field_condition(path, condition, ctx) do
    case String.split(path, ".", parts: 2) do
      [field] -> local_condition(field, condition, ctx)
      [ref, sub] -> reference_condition(ref, sub, condition, ctx)
    end
  end

  defp local_condition(name, condition, ctx) do
    case resolve(ctx.c, name, ctx.alias) do
      nil -> throw({:bad_query, "unknown field #{name}"})
      {expr, field} -> conditions(expr, field, name, condition)
    end
  end

  # A filter through a reference: the referenced row must exist and match.
  defp reference_condition(ref, sub, condition, ctx) do
    case {Schema.field(ctx.c.schema, ref), Map.get(ctx.refs, ref)} do
      {%{"type" => "reference"}, %{} = target} ->
        if String.contains?(sub, "."), do: throw({:bad_query, "filters follow one reference"})
        :counters.add(ctx.counter, 1, 1)
        alias = "r#{:counters.get(ctx.counter, 1)}"

        {inner_sql, inner_params} =
          local_condition(sub, condition, %{ctx | c: target, alias: alias})

        {owner_sql, owner_params} =
          Records.owner_filter(ctx.scope, target, inner_sql, inner_params, alias)

        {~s[EXISTS (SELECT 1 FROM "#{target.table}" #{alias} WHERE #{alias}."id" = #{ctx.alias}.#{Schema.column(ref)} AND #{owner_sql})],
         owner_params}

      _ ->
        throw({:bad_query, "#{ref} is not a reference field"})
    end
  end

  defp conditions(expr, field, name, %{} = ops) when not is_struct(ops) and map_size(ops) > 0 do
    ops
    |> Enum.sort_by(fn {op, _} -> op end)
    |> Enum.map(fn {op, value} -> condition(expr, field, name, op, value) end)
    |> combine("AND")
  end

  defp conditions(expr, field, name, value), do: condition(expr, field, name, "eq", value)

  defp condition(expr, _field, _name, "eq", nil), do: {"#{expr} IS NULL", []}
  defp condition(expr, _field, _name, "ne", nil), do: {"#{expr} IS NOT NULL", []}
  defp condition(expr, _field, _name, "is_null", true), do: {"#{expr} IS NULL", []}
  defp condition(expr, _field, _name, "is_null", false), do: {"#{expr} IS NOT NULL", []}

  defp condition(_expr, _field, name, "is_null", _value),
    do: throw({:bad_query, "#{name}: is_null takes true or false"})

  defp condition(expr, %{"type" => "json"}, name, "contains", value) do
    {"EXISTS (SELECT 1 FROM json_each(#{expr}) WHERE json_each.value = ?)",
     [json_scalar(name, value)]}
  end

  defp condition(expr, %{"type" => type} = field, name, "contains", value)
       when type in ~w(string text) do
    {"instr(#{expr}, ?) > 0", [filter_value(field, name, value)]}
  end

  defp condition(_expr, _field, name, "contains", _value),
    do: throw({:bad_query, "#{name}: contains needs a string, text, or json field"})

  defp condition(_expr, %{"type" => "json"}, name, _op, _value),
    do: throw({:bad_query, "#{name}: json fields support contains and is_null"})

  defp condition(expr, field, name, op, values) when op in ~w(in nin) do
    cond do
      not is_list(values) or length(values) > @max_in ->
        throw({:bad_query, "#{name}: #{op} needs a list of at most #{@max_in} values"})

      values == [] ->
        {if(op == "in", do: "0", else: "1"), []}

      true ->
        keyword = if op == "in", do: "IN", else: "NOT IN"
        params = Enum.map(values, &filter_value(field, name, &1))
        {"#{expr} #{keyword} (#{SQL.placeholders(length(params))})", params}
    end
  end

  defp condition(expr, field, name, op, value) when op in @ops do
    sql_op = %{
      "eq" => "=",
      "ne" => "IS NOT",
      "gt" => ">",
      "gte" => ">=",
      "lt" => "<",
      "lte" => "<="
    }

    {"#{expr} #{sql_op[op]} ?", [filter_value(field, name, value)]}
  end

  defp condition(_expr, _field, name, op, _value),
    do: throw({:bad_query, "#{name}: unknown operator #{op}; use #{Enum.join(@ops, ", ")}"})

  defp filter_value(_field, name, nil), do: throw({:bad_query, "#{name}: use is_null for null"})

  defp filter_value(%{"type" => type}, name, value) when type in ~w(string text reference) do
    if is_binary(value), do: value, else: throw({:bad_query, "#{name}: expected a string"})
  end

  defp filter_value(%{"type" => "integer"}, name, value) do
    if is_integer(value), do: value, else: throw({:bad_query, "#{name}: expected an integer"})
  end

  defp filter_value(%{"type" => "float"}, name, value) do
    if is_number(value), do: value, else: throw({:bad_query, "#{name}: expected a number"})
  end

  defp filter_value(%{"type" => "boolean"}, _name, true), do: 1
  defp filter_value(%{"type" => "boolean"}, _name, false), do: 0

  defp filter_value(%{"type" => "boolean"}, name, _value),
    do: throw({:bad_query, "#{name}: expected a boolean"})

  defp filter_value(%{"type" => "datetime"}, name, value) do
    case Schema.normalize_datetime(value) do
      {:ok, normalized} -> normalized
      :error -> throw({:bad_query, "#{name}: expected an ISO 8601 datetime"})
    end
  end

  defp json_scalar(_name, true), do: 1
  defp json_scalar(_name, false), do: 0
  defp json_scalar(_name, value) when is_binary(value) or is_number(value), do: value

  defp json_scalar(name, _value),
    do: throw({:bad_query, "#{name}: contains takes a string, number, or boolean"})

  # A field name to its SQL expression and (pseudo) field definition.
  defp resolve(c, name, alias) do
    case Schema.system_field(name) do
      {column, type} ->
        {"#{alias}.#{column}", %{"type" => type}}

      nil ->
        case Schema.field(c.schema, name) do
          nil -> nil
          field -> {"#{alias}.#{Schema.column(name)}", field}
        end
    end
  end

  # Collections referenced by dotted filter paths, readable by the scope.
  defp reference_targets(scope, c, where) do
    where
    |> dotted_refs()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn ref, {:ok, acc} ->
      case target(scope, c, ref) do
        {:ok, target} -> {:cont, {:ok, Map.put(acc, ref, target)}}
        error -> {:halt, error}
      end
    end)
  end

  defp dotted_refs(%{} = where) when not is_struct(where) do
    Enum.flat_map(where, fn
      {key, list} when key in ~w(and or) and is_list(list) -> Enum.flat_map(list, &dotted_refs/1)
      {"not", inner} -> dotted_refs(inner)
      {path, _} -> if String.contains?(path, "."), do: [hd(String.split(path, "."))], else: []
    end)
  end

  defp dotted_refs(_where), do: []

  defp target(scope, c, ref) do
    case Schema.field(c.schema, ref) do
      %{"type" => "reference", "references" => name} ->
        with :ok <- Scope.allow(scope, name, "read") do
          if name == c.name, do: {:ok, c}, else: Collections.load(:store, scope, name)
        end

      _ ->
        {:error, {:validation, ["#{ref} is not a reference field"]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Fields and includes
  # ---------------------------------------------------------------------------

  defp selected_fields(c, nil, _includes), do: {:ok, Schema.field_names(c.schema)}

  defp selected_fields(c, fields, includes) when is_list(fields) do
    all = Schema.field_names(c.schema)

    case Enum.reject(fields, &(&1 in all)) do
      [] ->
        wanted = MapSet.new(fields ++ Enum.map(includes, &elem(&1, 0)))
        {:ok, Enum.filter(all, &MapSet.member?(wanted, &1))}

      unknown ->
        {:error, {:validation, ["unknown fields: #{Enum.join(unknown, ", ")}"]}}
    end
  end

  defp selected_fields(_c, _fields, _includes),
    do: {:error, {:validation, ["fields must be a list"]}}

  defp includes(_scope, _c, nil), do: {:ok, []}

  defp includes(scope, c, include) when is_list(include) and length(include) <= 8 do
    Enum.reduce_while(include, {:ok, []}, fn ref, {:ok, acc} ->
      case target(scope, c, ref) do
        {:ok, target} -> {:cont, {:ok, acc ++ [{ref, target}]}}
        error -> {:halt, error}
      end
    end)
  end

  defp includes(_scope, _c, _include),
    do: {:error, {:validation, ["include must list up to 8 reference fields"]}}

  defp attach_includes(_scope, records, []), do: records

  defp attach_includes(scope, records, includes) do
    Enum.reduce(includes, records, fn {ref, target}, records ->
      ids = records |> Enum.map(& &1["data"][ref]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      found = fetch_many(scope, target, ids)

      Enum.map(records, fn record ->
        included = Map.get(record, "included", %{})
        Map.put(record, "included", Map.put(included, ref, Map.get(found, record["data"][ref])))
      end)
    end)
  end

  @doc false
  # Records by id, as a map, visible to the scope.
  @spec fetch_many(Scope.t(), map(), [String.t()]) :: %{String.t() => map()}
  def fetch_many(_scope, _c, []), do: %{}

  def fetch_many(scope, c, ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      {where, params} =
        Records.owner_filter(scope, c, ~s[t."id" IN (#{SQL.placeholders(length(chunk))})], chunk)

      sql =
        ~s[SELECT #{Records.system_columns()}, #{Enum.join(Records.field_columns(c), ", ")} FROM "#{c.table}" t WHERE #{where}]

      case SQL.query(:store, sql, params) do
        {:ok, rows} -> Enum.map(rows, &elem(Records.row_record(c, &1), 1))
        _ -> []
      end
    end)
    |> Map.new(&{&1["id"], &1})
  end

  defp select_data(record, names) do
    Map.update!(record, "data", &Map.take(&1, names))
  end
end
