defmodule OptimalEngine.Sync.Postgres do
  @moduledoc """
  Change capture for replication on the PostgreSQL store, with the ledger shape
  of `OptimalEngine.Sync.Capture` on SQLite.

  On SQLite each replicated table gets three triggers whose bodies are written
  out per table. PostgreSQL triggers call a function, so one PL/pgSQL function,
  `optimal_sync_capture()`, does what those bodies do, told by the trigger's
  arguments which columns are the row's key, which hold bytes, and whether the
  table is append-only:

  * it captures nothing while replicated changes are applied
    (`sync_identity.applying`) or for a workspace that does not sync;
  * an insert is captured with the whole row, an update with the whole new row,
    a delete with the key columns of the old row, as JSON objects in
    `sync_capture.row_data`;
  * a `BYTEA` value goes to `blob_data` as upper-case hex and is `null` in the
    row, as a SQLite BLOB does;
  * `entity_key` is the key column as text, or the key columns as a compact JSON
    array, as `Capture.key_expr/3` gives it; NULL for an append-only table;
  * an append-only table (one identity key) and a table without a key get the
    insert trigger only.

  A row encodes as `to_jsonb` encodes it, which decodes to the values SQLite's
  `json_object` gives: text as strings, integers and reals as numbers, NULL as
  `null`. A real that is a whole number is `1` where SQLite writes `1.0`; both
  decode to a number equal to it, and the peer stores it in its own column's
  type.

  ## Ledger sequences commit in order

  A reader of the ledger (`Sync.changes/3`, which a peer pulls and the NATS
  ledger publisher reads) follows it by sequence: it keeps the last sequence it
  read and next asks for the rows after it. PostgreSQL draws a `sync_mutations`
  sequence when a row is inserted, before the writer commits, so without more
  a writer that drew 10 could commit after one that drew 11: a reader that saw
  11 would move past 10, and the row would never be read. Every writer of the
  ledger (sealing, an applied change, a storage mutation entry) therefore takes
  one transaction-scoped advisory lock (`lock_ledger_sql/0`, keyed on the
  store's schema, so Engines sharing a database and a schema share it) before it
  inserts, and holds it until it commits or rolls back. An apply takes it once,
  at the end of its transaction, where it writes its ledger rows, so a long page
  holds it only for those inserts. The sequence caches no values
  (`ensure_ledger_sequence/0`): a session's cached values would be drawn out
  of order whatever the lock does. Sequences become visible
  in the order they were drawn, so every snapshot sees a prefix of the ledger.
  A writer that rolls back leaves a gap no row will ever fill, and readers go
  past it as they always did.

  ## The local stamp

  The gate cache keys an entry on the write sequences of the capture, the
  ledger and the local stamp (`OptimalEngine.Sync.GateCache`). SQLite keeps
  them in `sqlite_sequence`, which a transaction moves only when it commits.
  PostgreSQL's sequences move when a value is drawn, before the writer commits,
  so a gate that read the stamp then could cache what it saw before the write.
  Here the stamp is the largest key a committed row holds: `MAX(seq)` of
  `sync_capture` and of `sync_local_stamp`, `MAX(sequence)` of
  `sync_mutations`. Sealing empties `sync_capture` but moves the ledger, and
  `sync_local_stamp` keeps its newest row, so a committed write always changes
  the stamp.

  Each table the gate scans that does not replicate gets a stamp function of
  its own, `sync_stamp_fn_<table>()`, with the conditions of SQLite's stamp
  triggers (`Capture`): an insert or a delete of a row of a workspace that
  syncs and may name a class, or an update that changes a column the gate
  reads, to or from such a row. The conditions are SQLite's own
  (`Lineage.may_name_class_sql/2`) translated by the store's dialect.
  """

  require Logger

  alias OptimalEngine.Store.Postgres.Connection

  @pool OptimalEngine.Store.Postgres.Pool

  # `current_schema()` is NULL when no schema of the search path exists, and
  # hashtext(NULL) would make the lock call take no lock at all.
  @ledger_lock "SELECT pg_advisory_xact_lock(hashtext('optimal_engine.sync.ledger'), hashtext(coalesce(current_schema(), '')))"

  # A seal's ledger rows (`Capture.seal/0`); a mutation id is the capture key,
  # so a row sealed already is ignored.
  @ledger_insert """
  INSERT INTO sync_mutations
    (id, tenant_id, organization_id, workspace_id, device_id, entity_type, entity_id, operation,
     payload, payload_hash, idempotency_key, occurred_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
  ON CONFLICT DO NOTHING
  """

  @doc """
  The statement every ledger writer runs in its transaction before it inserts
  into `sync_mutations` (see "Ledger sequences commit in order").
  """
  @spec lock_ledger_sql() :: String.t()
  def lock_ledger_sql, do: @ledger_lock

  @doc """
  Takes the ledger lock in a Store transaction on PostgreSQL; nothing on SQLite,
  whose one writer commits in sequence order already.
  """
  @spec lock_ledger(term()) :: :ok | {:error, term()}
  def lock_ledger(txn) do
    if active?() do
      with {:ok, _} <- OptimalEngine.Store.Postgres.txn_query_native(txn, @ledger_lock, []), do: :ok
    else
      :ok
    end
  end

  @doc "True when this build's store is PostgreSQL."
  @spec active?() :: boolean()
  def active?, do: OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres)

  @doc "Creates or replaces the capture and stamp functions and the stamp table."
  @spec ensure() :: :ok
  def ensure do
    run_in_transaction(["SELECT pg_advisory_xact_lock(hashtext('optimal_engine.sync'))" | ddl()])
    ensure_ledger_sequence()
  end

  @doc """
  The cache of the ledger's sequence, which must be 1: a session that caches
  values hands out sequences in an order of its own, so two sessions could
  draw 11 and then 10, and the ledger lock would order their commits but not
  their sequences. The identity column is made with no cache (1); one found
  with a larger cache is set back to 1, and the boot says so.
  """
  @spec ensure_ledger_sequence() :: :ok
  def ensure_ledger_sequence do
    case ledger_sequence_cache() do
      1 ->
        :ok

      cache ->
        Logger.warning(
          "[Sync] the ledger sequence cached #{cache} values a session; set back to 1 so sequences are drawn in order"
        )

        run_in_transaction([
          "SELECT pg_advisory_xact_lock(hashtext('optimal_engine.sync.ddl'))",
          "ALTER TABLE sync_mutations ALTER COLUMN sequence SET CACHE 1"
        ])
    end
  end

  @doc "The cache size of the `sync_mutations.sequence` identity."
  @spec ledger_sequence_cache() :: pos_integer()
  def ledger_sequence_cache do
    {:ok, [[cache]]} =
      native(
        "SELECT s.seqcache FROM pg_sequence s " <>
          "WHERE s.seqrelid = pg_get_serial_sequence('sync_mutations', 'sequence')::regclass",
        []
      )

    cache
  end

  @doc false
  def ddl do
    [
      """
      CREATE TABLE IF NOT EXISTS sync_local_stamp (
        seq BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
      )
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION optimal_sync_capture() RETURNS trigger
      LANGUAGE plpgsql SET search_path FROM CURRENT AS $fn$
      DECLARE
        keys jsonb := TG_ARGV[0]::jsonb;
        blob_columns jsonb := TG_ARGV[1]::jsonb;
        append_only boolean := TG_ARGV[2]::boolean;
        r jsonb;
        workspace text;
        op text;
        row_data jsonb;
        blob_data jsonb := '{}'::jsonb;
        key_text text;
        col text;
      BEGIN
        IF TG_OP = 'DELETE' THEN r := to_jsonb(OLD); ELSE r := to_jsonb(NEW); END IF;
        workspace := r ->> 'workspace_id';

        IF (SELECT applying FROM sync_identity WHERE id = 1) IS DISTINCT FROM 0
           OR NOT EXISTS (SELECT 1 FROM sync_workspaces w WHERE w.workspace_id = workspace) THEN
          RETURN NULL;
        END IF;

        FOR col IN SELECT jsonb_array_elements_text(blob_columns) LOOP
          IF r ->> col IS NOT NULL THEN
            blob_data := blob_data || jsonb_build_object(col, upper(substr(r ->> col, 3)));
          END IF;
          r := jsonb_set(r, ARRAY[col], 'null'::jsonb);
        END LOOP;

        IF TG_OP = 'DELETE' THEN
          op := 'delete';
          SELECT COALESCE(jsonb_object_agg(k, r -> k), '{}'::jsonb) INTO row_data
          FROM jsonb_array_elements_text(keys) AS k;
        ELSE
          op := CASE TG_OP WHEN 'INSERT' THEN 'create' ELSE 'update' END;
          row_data := r;
        END IF;

        IF append_only OR jsonb_array_length(keys) = 0 THEN
          key_text := NULL;
        ELSIF jsonb_array_length(keys) = 1 THEN
          key_text := r ->> (keys ->> 0);
        ELSE
          SELECT '[' || string_agg((r -> k.key)::text, ',' ORDER BY k.n) || ']' INTO key_text
          FROM jsonb_array_elements_text(keys) WITH ORDINALITY AS k(key, n);
        END IF;

        INSERT INTO sync_capture (table_name, operation, workspace_id, entity_key, row_data, blob_data)
        VALUES (TG_TABLE_NAME, op, workspace, key_text, row_data::text, blob_data::text);
        RETURN NULL;
      END
      $fn$
      """
    ]
  end

  @doc """
  The columns of `table` in the store's schema, in `Capture.columns/1`'s shape:
  an identity column is `INTEGER` (SQLite's rowid key), any other column its
  PostgreSQL type, and `pk` its position in the primary key (0 outside it).
  """
  @spec columns(String.t()) :: [%{name: String.t(), type: String.t(), pk: non_neg_integer()}]
  def columns(table) do
    {:ok, rows} =
      native(
        """
        SELECT a.attname::text,
               CASE WHEN a.attidentity <> '' THEN 'INTEGER'
                    ELSE upper(format_type(a.atttypid, NULL)) END,
               COALESCE(array_position(p.conkey, a.attnum), 0)
        FROM pg_attribute a
        JOIN pg_class t ON t.oid = a.attrelid AND t.relkind IN ('r', 'p')
        JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = current_schema()
        LEFT JOIN pg_constraint p ON p.conrelid = t.oid AND p.contype = 'p'
        WHERE t.relname = $1 AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """,
        [table]
      )

    Enum.map(rows, fn [name, type, pk] -> %{name: name, type: type, pk: pk} end)
  end

  @doc "The base tables of the store's schema."
  @spec tables() :: [String.t()]
  def tables do
    {:ok, rows} =
      native(
        "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1",
        []
      )

    List.flatten(rows)
  end

  @doc """
  The capture triggers of `table`: the insert trigger, and the update and delete
  triggers unless the table is append-only or has no key. Names follow
  SQLite's (`sync_capture_ai_<table>` and so on).
  """
  @spec capture_triggers(String.t(), [String.t()], [String.t()], boolean()) :: [
          {String.t(), String.t(), [String.t()]}
        ]
  def capture_triggers(table, keys, blob_columns, append_only) do
    args = [Jason.encode!(keys), Jason.encode!(blob_columns), to_string(append_only)]
    insert = {"sync_capture_ai_#{table}", "AFTER INSERT", args}

    if append_only or keys == [] do
      [insert]
    else
      [
        insert,
        {"sync_capture_au_#{table}", "AFTER UPDATE", args},
        {"sync_capture_ad_#{table}", "AFTER DELETE", args}
      ]
    end
  end

  @doc """
  The stamp function of `table` and its triggers, which watch the columns the
  gate reads. `matters` gives the SQLite condition that a row (`NEW` or `OLD`)
  may name a class.
  """
  @spec stamp_triggers(String.t(), [String.t()], (String.t() -> String.t())) ::
          {String.t(), [{String.t(), String.t(), [String.t()]}]}
  def stamp_triggers(table, read, matters) do
    updated = Enum.map_join(read, ", ", &quote_name/1)
    function = "sync_stamp_fn_#{table}"

    changed =
      Enum.map_join(read, " OR ", &"OLD.#{quote_name(&1)} IS DISTINCT FROM NEW.#{quote_name(&1)}")

    syncing = fn row ->
      "EXISTS (SELECT 1 FROM sync_workspaces w WHERE w.workspace_id = #{row}.\"workspace_id\")"
    end

    condition = fn row -> translate(matters.(row)) end

    :ok =
      run_in_transaction([
        """
        CREATE OR REPLACE FUNCTION #{quote_name(function)}() RETURNS trigger
        LANGUAGE plpgsql SET search_path FROM CURRENT AS $fn$
        DECLARE
          stamp bigint;
        BEGIN
          IF (TG_OP = 'INSERT' AND #{syncing.("NEW")} AND (#{condition.("NEW")}))
             OR (TG_OP = 'DELETE' AND #{syncing.("OLD")} AND (#{condition.("OLD")}))
             OR (TG_OP = 'UPDATE' AND (#{changed}) AND (#{syncing.("NEW")} OR #{syncing.("OLD")})
                 AND ((#{condition.("NEW")}) OR (#{condition.("OLD")}))) THEN
            INSERT INTO sync_local_stamp DEFAULT VALUES RETURNING seq INTO stamp;
            DELETE FROM sync_local_stamp WHERE seq < stamp;
          END IF;
          RETURN NULL;
        END
        $fn$
        """
      ])

    {function,
     [
       {"sync_stamp_ai_#{table}", "AFTER INSERT", []},
       {"sync_stamp_au_#{table}", "AFTER UPDATE OF #{updated}", []},
       {"sync_stamp_ad_#{table}", "AFTER DELETE", []}
     ]}
  end

  # A condition written for SQLite, as the dialect translates it for a
  # statement.
  defp translate(condition) do
    {:ok, sql} = OptimalEngine.Store.Dialect.to_postgres("SELECT " <> condition)
    String.replace_prefix(sql, "SELECT ", "")
  end

  @doc """
  Puts `triggers` (name, timing, arguments) on `table` calling `function`, and
  removes the other triggers of `table` whose names start with `prefix`.
  Triggers already in place with the same definition are left alone, so a
  restart does no DDL.
  """
  @spec ensure_triggers(String.t(), String.t(), String.t(), [{String.t(), String.t(), [String.t()]}]) ::
          :ok
  def ensure_triggers(table, prefix, function, triggers) do
    wanted =
      Map.new(triggers, fn {name, timing, args} ->
        {name, trigger_sql(table, name, timing, function, args)}
      end)

    if installed(table, prefix) == wanted do
      :ok
    else
      creates =
        Enum.map(
          Map.values(wanted),
          &String.replace_prefix(&1, "CREATE TRIGGER", "CREATE OR REPLACE TRIGGER")
        )

      # Only the triggers no longer wanted are dropped; the others are
      # replaced, so an install that runs beside another (the boot install and
      # an enable) does not find a trigger the other created.
      stale =
        for name <- Map.keys(installed(table, prefix)), not Map.has_key?(wanted, name) do
          "DROP TRIGGER IF EXISTS #{quote_name(name)} ON #{quote_name(table)}"
        end

      run_in_transaction(stale ++ creates)
    end
  end

  @doc "Drops every trigger whose name starts with `prefix`, on `table` or on every table."
  @spec drop_triggers(String.t(), String.t() | :all, (String.t() -> boolean())) :: :ok
  def drop_triggers(prefix, table, keep? \\ fn _table -> false end) do
    drops =
      for [name, on] <- trigger_rows(prefix, table), not keep?.(on) do
        "DROP TRIGGER IF EXISTS #{quote_name(name)} ON #{quote_name(on)}"
      end

    if drops == [], do: :ok, else: run_in_transaction(drops)
  end

  @doc "The tables that carry a trigger whose name starts with `prefix`."
  @spec triggered_tables(String.t()) :: [String.t()]
  def triggered_tables(prefix),
    do: prefix |> trigger_rows(:all) |> Enum.map(&List.last/1) |> Enum.uniq()

  @doc """
  The write sequences the gate cache keys on, as `[name, seq]` rows like
  `sqlite_sequence` gives them: a table with no committed row is absent.
  """
  @spec stamp() :: [[term()]]
  def stamp do
    {:ok, rows} =
      native(
        """
        SELECT name, seq FROM (
          SELECT 'sync_capture' AS name, (SELECT MAX(seq) FROM sync_capture) AS seq
          UNION ALL SELECT 'sync_local_stamp', (SELECT MAX(seq) FROM sync_local_stamp)
          UNION ALL SELECT 'sync_mutations', (SELECT MAX(sequence) FROM sync_mutations)
        ) s WHERE seq IS NOT NULL ORDER BY name
        """,
        []
      )

    rows
  end

  # The trigger's definition as pg_get_triggerdef gives it back, so what is in
  # place compares with what is wanted.
  defp trigger_sql(table, name, timing, function, args) do
    arguments = Enum.map_join(args, ", ", &quote_literal/1)

    "CREATE TRIGGER #{quote_name(name)} #{timing} ON #{quote_name(table)} " <>
      "FOR EACH ROW EXECUTE FUNCTION #{function}(#{arguments})"
  end

  defp installed(table, prefix) do
    {:ok, rows} =
      native(
        """
        SELECT g.tgname::text, c.relname::text, g.tgtype, g.tgargs, g.tgnargs, g.tgattr::int2[], p.proname::text
        FROM pg_trigger g
        JOIN pg_class c ON c.oid = g.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = current_schema()
        JOIN pg_proc p ON p.oid = g.tgfoid
        WHERE NOT g.tgisinternal AND c.relname = $1 AND starts_with(g.tgname::text, $2)
        """,
        [table, prefix]
      )

    attnames = attnames(table)

    Map.new(rows, fn [name, on, type, args, nargs, attrs, function] ->
      {name,
       trigger_sql(on, name, timing(type, attrs, attnames), function, split_args(args, nargs))}
    end)
  end

  defp attnames(table) do
    {:ok, rows} =
      native(
        """
        SELECT a.attnum, a.attname::text FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = current_schema()
        WHERE c.relname = $1 AND a.attnum > 0
        """,
        [table]
      )

    Map.new(rows, &List.to_tuple/1)
  end

  # tgtype bits: 4 insert, 8 delete, 16 update (an AFTER row trigger has 1 set).
  defp timing(type, attrs, attnames) do
    import Bitwise

    cond do
      (type &&& 4) != 0 ->
        "AFTER INSERT"

      (type &&& 8) != 0 ->
        "AFTER DELETE"

      attrs in [nil, []] ->
        "AFTER UPDATE"

      true ->
        "AFTER UPDATE OF " <> Enum.map_join(attrs, ", ", &quote_name(Map.fetch!(attnames, &1)))
    end
  end

  defp split_args(_args, 0), do: []

  defp split_args(args, _nargs) do
    args |> String.split(<<0>>) |> Enum.drop(-1)
  end

  defp trigger_rows(prefix, table) do
    {filter, params} =
      case table do
        :all -> {"", [prefix]}
        name -> {" AND c.relname = $2", [prefix, name]}
      end

    {:ok, rows} =
      native(
        """
        SELECT g.tgname::text, c.relname::text FROM pg_trigger g
        JOIN pg_class c ON c.oid = g.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = current_schema()
        WHERE NOT g.tgisinternal AND starts_with(g.tgname::text, $1)#{filter}
        ORDER BY 2, 1
        """,
        params
      )

    rows
  end

  @doc """
  Writes a seal's ledger rows (`Capture.seal/0`'s entries) and deletes the
  captured rows up to `max_seq`, in one READ COMMITTED transaction
  (`Capture.seal/0` says why), under the ledger lock. Returns how many entries
  were offered. An Engine sharing the database seals through this too.
  """
  @spec write_ledger([[term()]], integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write_ledger(entries, max_seq) do
    Postgrex.transaction(
      @pool,
      fn conn ->
        Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED", [])
        if entries != [], do: Postgrex.query!(conn, @ledger_lock, [])
        Enum.each(entries, &Postgrex.query!(conn, @ledger_insert, &1))
        Postgrex.query!(conn, "DELETE FROM sync_capture WHERE seq <= $1", [max_seq])
        length(entries)
      end,
      timeout: 120_000
    )
  end

  defp run_in_transaction(statements) do
    {:ok, _} =
      Connection.transaction(
        @pool,
        fn txn ->
          # One Engine's installs, and those of Engines sharing the database,
          # change triggers one at a time.
          lock = "SELECT pg_advisory_xact_lock(hashtext('optimal_engine.sync.ddl'))"

          Enum.reduce_while([lock | statements], {:ok, :done}, fn sql, ok ->
            case Connection.txn_query(txn, sql, [], dialect: :postgres) do
              {:ok, _} -> {:cont, ok}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end,
        120_000
      )

    :ok
  end

  defp native(sql, params) do
    with {:ok, %{rows: rows}} <- Connection.query(@pool, sql, params, dialect: :postgres) do
      {:ok, rows}
    end
  end

  defp quote_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end
end
