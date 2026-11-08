defmodule OptimalEngine.Store.Postgres.FullText do
  @moduledoc """
  The full-text indexes of the PostgreSQL store, which hold what SQLite's FTS5
  tables hold and rank as FTS5's `bm25()` does (`OptimalEngine.Store.FullText`).

  ## Objects

  These are not derived from the SQLite migrations (the FTS5 tables are
  skipped there); `ensure/1` creates them, every time the store starts:

  | Object | Holds |
  | --- | --- |
  | `optimal_fts_docs` | one row per indexed row: its key and its token count |
  | `optimal_fts_postings` | one row per term of an indexed row, with its positions |
  | `optimal_fts_totals` | per index, the number of rows and of tokens |
  | `optimal_fts_queue` | the keys of indexed rows written since they were last indexed |
  | `optimal_fts_enqueue()` | the trigger function that appends to the queue |
  | `optimal_fts_match(index, query)` | the rows a query matches, with their BM25 score |
  | views `contexts_fts`, `memories_fts` | the indexed keys, as `id`, for counts and joins |

  ## Keeping an index current

  A row trigger on each indexed table appends the key of every inserted,
  deleted, or updated row (an update of its key or an indexed column) to the
  queue, in the writer's transaction, so no write path, cascade, or other
  engine can change a row without queueing it. `refresh/3` takes the queued
  keys in order, reads the rows as they are now, tokenizes them with SQLite's
  tokenizer, rewrites their postings and the index totals, and deletes exactly
  the queue entries it read, in one transaction per batch. A key queued by a
  writer that commits meanwhile stays queued for the next refresh.

  The store refreshes an index before every statement that reads it, so a
  search sees every write committed before it began, as on SQLite, and a
  timer in the store refreshes in the background so that a search rarely
  has to.

  The index is a rebuildable projection: `rebuild/2` empties it and queues
  every row again.
  """

  alias OptimalEngine.Store.FullText
  alias OptimalEngine.Store.Postgres.Connection

  @batch 200

  @doc "Creates or updates the full-text objects, and queues the rows of a new index."
  @spec ensure(GenServer.server()) :: :ok | {:error, term()}
  def ensure(pool) do
    result =
      Connection.transaction(
        pool,
        fn txn ->
          with :ok <- run(txn, "SELECT pg_advisory_xact_lock(hashtext('optimal_engine.fts'))"),
               :ok <- run_all(txn, ddl()),
               :ok <- run_all(txn, Enum.flat_map(Map.values(FullText.indexes()), &index_ddl/1)) do
            {:ok, :ensured}
          end
        end,
        120_000
      )

    with {:ok, _} <- result, do: :ok
  end

  @doc "Empties `name` and queues every row of its table again."
  @spec rebuild(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def rebuild(pool, name) do
    index = FullText.index!(name)

    result =
      Connection.transaction(
        pool,
        fn txn ->
          run_all(txn, [
            {"DELETE FROM optimal_fts_postings WHERE index_name = $1", [name]},
            {"DELETE FROM optimal_fts_docs WHERE index_name = $1", [name]},
            {"DELETE FROM optimal_fts_queue WHERE index_name = $1", [name]},
            {"UPDATE optimal_fts_totals SET docs = 0, tokens = 0 WHERE index_name = $1", [name]},
            {enqueue_all(index), [name]}
          ])
          |> then(&with(:ok <- &1, do: {:ok, :rebuilt}))
        end,
        120_000
      )

    with {:ok, _} <- result, do: :ok
  end

  @doc """
  Indexes the queued rows of each named index, in batches, until its queue is
  empty. Returns how many queued keys were indexed.
  """
  @spec refresh(GenServer.server(), [String.t()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh(pool, names, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    Enum.reduce_while(names, {:ok, 0}, fn name, {:ok, total} ->
      case refresh_index(pool, name, timeout, 0) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Every index: the engine's own and those created at runtime (app data collections)."
  @spec names(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def names(pool) do
    with {:ok, %{rows: rows}} <-
           Connection.query(pool, "SELECT name FROM optimal_fts_indexes ORDER BY name", [],
             dialect: :postgres
           ) do
      {:ok, Map.keys(FullText.indexes()) ++ Enum.map(rows, &hd/1)}
    end
  end

  defp refresh_index(pool, name, timeout, done) do
    case Connection.transaction(pool, &index_batch(&1, name), timeout) do
      {:ok, 0} -> {:ok, done}
      {:ok, count} -> refresh_index(pool, name, timeout, done + count)
      {:error, _} = error -> error
    end
  end

  # An index created at runtime is read from the registry inside the batch's
  # own transaction; one dropped meanwhile has nothing left to index.
  defp index_batch(txn, name) do
    case index_def(txn, name) do
      {:ok, nil} -> {:ok, 0}
      {:ok, index} -> queued_batch(txn, index)
      {:error, _} = error -> error
    end
  end

  defp index_def(txn, name) do
    case Map.fetch(FullText.indexes(), name) do
      {:ok, index} ->
        {:ok, Map.put(index, :key_type, "text")}

      :error ->
        with {:ok, %{rows: rows}} <-
               native(
                 txn,
                 "SELECT table_name, key_column, key_type, columns, tokenize FROM optimal_fts_indexes WHERE name = $1",
                 [name]
               ) do
          case rows do
            [[table, key, key_type, columns, tokenize]] ->
              {:ok,
               %{
                 name: name,
                 table: table,
                 key: key,
                 key_type: key_type,
                 columns: columns,
                 tokenize: tokenize
               }}

            [] ->
              {:ok, nil}
          end
        end
    end
  end

  @doc """
  Creates a full-text index on `table` inside the caller's transaction: its
  registry row, its trigger and its totals, with every row the table holds
  queued. `index` has `:name`, `:table`, `:key` (a text or bigint column),
  `:key_type` (`"text"` or `"bigint"`), `:columns` and `:tokenize`, FTS5's
  option.
  """
  @spec create_index(term(), map()) :: :ok | {:error, term()}
  def create_index(txn, %{key_type: key_type} = index) when key_type in ["text", "bigint"] do
    run_all(txn, [
      {"""
       INSERT INTO optimal_fts_indexes (name, table_name, key_column, key_type, columns, tokenize)
       VALUES ($1, $2, $3, $4, $5, $6)
       """, [index.name, index.table, index.key, key_type, index.columns, index.tokenize]}
      | index_ddl(index)
    ])
  end

  @doc "Drops a full-text index created with `create_index/2`, inside the caller's transaction."
  @spec drop_index(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def drop_index(txn, name, table) do
    run_all(txn, [
      "DROP TRIGGER IF EXISTS #{quote_name(name <> "_enqueue")} ON #{quote_name(table)}",
      "DROP VIEW IF EXISTS #{quote_name(name)}",
      {"DELETE FROM optimal_fts_postings WHERE index_name = $1", [name]},
      {"DELETE FROM optimal_fts_docs WHERE index_name = $1", [name]},
      {"DELETE FROM optimal_fts_queue WHERE index_name = $1", [name]},
      {"DELETE FROM optimal_fts_totals WHERE index_name = $1", [name]},
      {"DELETE FROM optimal_fts_indexes WHERE name = $1", [name]}
    ])
  end

  defp queued_batch(txn, index) do
    with {:ok, %{rows: queued}} <-
           native(
             txn,
             "SELECT seq, doc_key FROM optimal_fts_queue WHERE index_name = $1 ORDER BY seq LIMIT $2",
             [index.name, @batch]
           ) do
      case queued do
        [] -> {:ok, 0}
        _ -> reindex(txn, index, queued)
      end
    end
  end

  defp reindex(txn, index, queued) do
    seqs = Enum.map(queued, &hd/1)
    keys = queued |> Enum.map(&List.last/1) |> Enum.uniq()
    columns = Enum.map_join(index.columns, ", ", &quote_name/1)

    current =
      "SELECT #{quote_name(index.key)}::text, #{columns} FROM #{quote_name(index.table)} " <>
        "WHERE #{quote_name(index.key)} = ANY($1::text[]::#{index.key_type}[])"

    with {:ok, %{rows: rows}} <- native(txn, current, [keys]),
         tokenized =
           FullText.tokenize(index.tokenize, Enum.map(rows, fn [key | cols] -> {key, cols} end)),
         {:ok, %{rows: [[old_docs, old_tokens]]}} <-
           native(
             txn,
             """
             WITH gone AS (
               DELETE FROM optimal_fts_docs WHERE index_name = $1 AND doc_key = ANY($2::text[])
               RETURNING size
             )
             SELECT count(*), COALESCE(sum(size), 0)::bigint FROM gone
             """,
             [index.name, keys]
           ),
         {:ok, _} <-
           native(
             txn,
             "DELETE FROM optimal_fts_postings WHERE index_name = $1 AND doc_key = ANY($2::text[])",
             [index.name, keys]
           ),
         :ok <- insert_docs(txn, index.name, tokenized),
         :ok <- insert_postings(txn, index.name, tokenized),
         {:ok, _} <-
           native(
             txn,
             "UPDATE optimal_fts_totals SET docs = docs + $2, tokens = tokens + $3 WHERE index_name = $1",
             [
               index.name,
               length(tokenized) - old_docs,
               Enum.sum(Enum.map(tokenized, &elem(&1, 1))) - old_tokens
             ]
           ),
         {:ok, _} <-
           native(txn, "DELETE FROM optimal_fts_queue WHERE seq = ANY($1::bigint[])", [seqs]) do
      {:ok, length(seqs)}
    end
  end

  defp insert_docs(_txn, _name, []), do: :ok

  defp insert_docs(txn, name, tokenized) do
    with {:ok, _} <-
           native(
             txn,
             """
             INSERT INTO optimal_fts_docs (index_name, doc_key, size)
             SELECT $1, k, s FROM unnest($2::text[], $3::bigint[]) AS u(k, s)
             """,
             [name, Enum.map(tokenized, &elem(&1, 0)), Enum.map(tokenized, &elem(&1, 1))]
           ),
         do: :ok
  end

  defp insert_postings(txn, name, tokenized) do
    postings =
      for {key, _size, terms} <- tokenized, {term, positions} <- terms do
        {term, key, "{" <> Enum.map_join(positions, ",", &Integer.to_string/1) <> "}"}
      end

    postings
    |> Enum.chunk_every(5_000)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      {terms, keys, positions} = unzip3(chunk)

      case native(
             txn,
             """
             INSERT INTO optimal_fts_postings (index_name, term, doc_key, positions)
             SELECT $1, t, k, p::bigint[] FROM unnest($2::text[], $3::text[], $4::text[]) AS u(t, k, p)
             """,
             [name, terms, keys, positions]
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp unzip3(triples) do
    {a, b, c} =
      Enum.reduce(triples, {[], [], []}, fn {x, y, z}, {a, b, c} -> {[x | a], [y | b], [z | c]} end)

    {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)}
  end

  # ---------------------------------------------------------------------------
  # DDL
  # ---------------------------------------------------------------------------

  @doc false
  def ddl do
    [
      """
      CREATE TABLE IF NOT EXISTS optimal_fts_docs (
        index_name TEXT COLLATE "C" NOT NULL,
        doc_key TEXT COLLATE "C" NOT NULL,
        size BIGINT NOT NULL,
        PRIMARY KEY (index_name, doc_key)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS optimal_fts_postings (
        index_name TEXT COLLATE "C" NOT NULL,
        term TEXT COLLATE "C" NOT NULL,
        doc_key TEXT COLLATE "C" NOT NULL,
        positions BIGINT[] NOT NULL,
        PRIMARY KEY (index_name, term, doc_key)
      )
      """,
      "CREATE INDEX IF NOT EXISTS optimal_fts_postings_doc ON optimal_fts_postings (index_name, doc_key)",
      """
      CREATE TABLE IF NOT EXISTS optimal_fts_totals (
        index_name TEXT COLLATE "C" PRIMARY KEY,
        docs BIGINT NOT NULL,
        tokens BIGINT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS optimal_fts_queue (
        seq BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        index_name TEXT COLLATE "C" NOT NULL,
        doc_key TEXT COLLATE "C" NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS optimal_fts_queue_index ON optimal_fts_queue (index_name, seq)",
      """
      CREATE TABLE IF NOT EXISTS optimal_fts_indexes (
        name TEXT COLLATE "C" PRIMARY KEY,
        table_name TEXT COLLATE "C" NOT NULL,
        key_column TEXT COLLATE "C" NOT NULL,
        key_type TEXT COLLATE "C" NOT NULL,
        columns TEXT[] NOT NULL,
        tokenize TEXT
      )
      """,
      enqueue_function(),
      match_function()
    ]
  end

  # The key of the old row on an update or delete, the key of the new row on
  # an insert or an update that changed it. TG_ARGV: the index, the key column.
  defp enqueue_function do
    """
    CREATE OR REPLACE FUNCTION optimal_fts_enqueue() RETURNS trigger
    LANGUAGE plpgsql SET search_path FROM CURRENT AS $fn$
    DECLARE
      old_key text;
      new_key text;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        old_key := to_jsonb(OLD) ->> TG_ARGV[1];
        INSERT INTO optimal_fts_queue (index_name, doc_key) VALUES (TG_ARGV[0], old_key);
      END IF;
      IF TG_OP <> 'DELETE' THEN
        new_key := to_jsonb(NEW) ->> TG_ARGV[1];
        IF new_key IS DISTINCT FROM old_key THEN
          INSERT INTO optimal_fts_queue (index_name, doc_key) VALUES (TG_ARGV[0], new_key);
        END IF;
      END IF;
      RETURN NULL;
    END
    $fn$
    """
  end

  # FTS5's bm25() (fts5_aux.c), term for term. Each phrase's hits are a
  # materialized CTE over the whole index; its IDF uses the number of rows it
  # matched. The score adds the phrases in query order, in double precision,
  # with the operations in the order FTS5's C expression has them.
  defp match_function do
    ~S"""
    CREATE OR REPLACE FUNCTION optimal_fts_match(p_index text, p_query text)
    RETURNS TABLE (doc_key text, score double precision)
    LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $fn$
    DECLARE
      q jsonb := p_query::jsonb;
      phrases jsonb := q -> 'phrases';
      any_of boolean := COALESCE((q ->> 'any')::boolean, false);
      n_phrases int := COALESCE(jsonb_array_length(q -> 'phrases'), 0);
      n_row bigint;
      n_token bigint;
      avgdl double precision;
      terms jsonb;
      n_terms int;
      is_prefix boolean;
      term text;
      cond text;
      hit text;
      ctes text := '';
      counts text := '';
      matched text := '';
      joins text := '';
      score_sql text := '0::float8';
      f text;
      idf text;
      i int;
      t int;
    BEGIN
      SELECT docs, tokens INTO n_row, n_token FROM optimal_fts_totals WHERE index_name = p_index;
      IF n_phrases = 0 OR COALESCE(n_row, 0) = 0 THEN
        RETURN;
      END IF;
      avgdl := n_token::float8 / n_row::float8;

      FOR i IN 0 .. n_phrases - 1 LOOP
        terms := phrases -> i -> 'terms';
        n_terms := jsonb_array_length(terms);
        is_prefix := COALESCE((phrases -> i ->> 'prefix')::boolean, false);

        IF n_terms = 0 THEN
          hit := 'SELECT NULL::text AS doc_key, 0::float8 AS f WHERE false';
        ELSE
          FOR t IN 0 .. n_terms - 1 LOOP
            term := terms ->> t;
            IF is_prefix AND t = n_terms - 1 THEN
              cond := format('p%s.term >= %L AND p%s.term < %L AND starts_with(p%s.term, %L)',
                             t, term, t, term || chr(1114111), t, term);
            ELSE
              cond := format('p%s.term = %L', t, term);
            END IF;

            IF t = 0 THEN
              IF n_terms = 1 THEN
                hit := 'SELECT p0.doc_key, sum(cardinality(p0.positions))::float8 AS f ' ||
                       'FROM optimal_fts_postings p0';
              ELSE
                hit := 'SELECT p0.doc_key, count(*)::float8 AS f FROM optimal_fts_postings p0 ' ||
                       'CROSS JOIN LATERAL unnest(p0.positions) AS x(pos)';
              END IF;
              hit := hit || format(' WHERE p0.index_name = %L AND %s', p_index, cond);
            ELSE
              hit := hit || format(
                ' AND EXISTS (SELECT 1 FROM optimal_fts_postings p%s WHERE p%s.index_name = p0.index_name ' ||
                'AND p%s.doc_key = p0.doc_key AND %s AND (x.pos + %s) = ANY (p%s.positions))',
                t, t, t, cond, t, t);
            END IF;
          END LOOP;
          hit := hit || ' GROUP BY p0.doc_key';
        END IF;

        ctes := ctes || CASE WHEN i = 0 THEN 'WITH ' ELSE ', ' END ||
                format('h%s AS MATERIALIZED (%s)', i, hit);
        counts := counts || CASE WHEN i = 0 THEN '' ELSE ', ' END ||
                  format('(SELECT count(*) FROM h%s) AS n%s', i, i);

        IF i = 0 THEN
          matched := 'SELECT h0.doc_key FROM h0';
        ELSIF any_of THEN
          matched := matched || format(' UNION SELECT h%s.doc_key FROM h%s', i, i);
        ELSE
          matched := matched || format(' JOIN h%s ON h%s.doc_key = h0.doc_key', i, i);
        END IF;

        joins := joins || format(' LEFT JOIN h%s r%s ON r%s.doc_key = m.doc_key', i, i, i);

        f := format('COALESCE(r%s.f, 0::float8)', i);
        idf := format('(CASE WHEN ln(((%s - n.n%s)::float8 + 0.5::float8) / (n.n%s::float8 + 0.5::float8)) <= 0::float8 ' ||
                      'THEN 1e-6::float8 ELSE ln(((%s - n.n%s)::float8 + 0.5::float8) / (n.n%s::float8 + 0.5::float8)) END)',
                      n_row, i, i, n_row, i, i);
        score_sql := format('(%s + %s * ((%s * (1.2::float8 + 1.0::float8)) / (%s + 1.2::float8 * ((1::float8 - 0.75::float8) + (0.75::float8 * d.size::float8) / $1))))',
                            score_sql, idf, f, f);
      END LOOP;

      RETURN QUERY EXECUTE
        ctes || format(', n AS (SELECT %s), m AS (%s) ', counts, matched) ||
        format('SELECT m.doc_key::text, %s AS score FROM m ', score_sql) ||
        format('JOIN optimal_fts_docs d ON d.index_name = %L AND d.doc_key = m.doc_key ', p_index) ||
        'CROSS JOIN n' || joins
      USING avgdl;
    END
    $fn$
    """
  end

  # The trigger of one index, the view of its keys, and its totals row; a new
  # index queues every row its table already has.
  defp index_ddl(%{name: name, table: table, key: key, columns: columns}) do
    trigger = "#{name}_enqueue"
    watched = Enum.map_join([key | columns], ", ", &quote_name/1)

    [
      "DROP TRIGGER IF EXISTS #{quote_name(trigger)} ON #{quote_name(table)}",
      """
      CREATE TRIGGER #{quote_name(trigger)}
      AFTER INSERT OR DELETE OR UPDATE OF #{watched} ON #{quote_name(table)}
      FOR EACH ROW EXECUTE FUNCTION optimal_fts_enqueue('#{name}', '#{key}')
      """,
      """
      CREATE OR REPLACE VIEW #{quote_name(name)} AS
      SELECT doc_key AS id FROM optimal_fts_docs WHERE index_name = '#{name}'
      """,
      {"""
       WITH added AS (
         INSERT INTO optimal_fts_totals (index_name, docs, tokens) VALUES ($1, 0, 0)
         ON CONFLICT (index_name) DO NOTHING RETURNING index_name
       )
       INSERT INTO optimal_fts_queue (index_name, doc_key)
       SELECT added.index_name, t.#{quote_name(key)}::text FROM added CROSS JOIN #{quote_name(table)} t
       ORDER BY t.#{quote_name(key)}
       """, [name]}
    ]
  end

  defp enqueue_all(%{table: table, key: key}) do
    "INSERT INTO optimal_fts_queue (index_name, doc_key) " <>
      "SELECT $1, #{quote_name(key)} FROM #{quote_name(table)} ORDER BY #{quote_name(key)}"
  end

  defp run_all(txn, statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      {sql, params} = if is_tuple(statement), do: statement, else: {statement, []}

      case native(txn, sql, params) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp run(txn, sql) do
    with {:ok, _} <- native(txn, sql, []), do: :ok
  end

  defp native(txn, sql, params), do: Connection.txn_query(txn, sql, params, dialect: :postgres)

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
