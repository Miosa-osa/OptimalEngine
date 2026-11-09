defmodule OptimalEngine.Test.LedgerHold do
  @moduledoc false
  # Holds a ledger writer's transaction open after it drew its sequence, on the
  # PostgreSQL store, so a test can let another writer commit first.
  #
  # A row trigger on `sync_mutations` (installed from a connection of its own,
  # since the store refuses schema statements) runs after the insert, when the
  # sequence is drawn: for an `entity_id` starting `hold-` it waits on an
  # advisory lock the test holds; for one starting `fail-` it raises, so the
  # writer rolls back with its sequence drawn.

  @key "oe_test_ledger_hold"

  def install do
    with_conn(fn conn ->
      Postgrex.query!(
        conn,
        """
        CREATE OR REPLACE FUNCTION oe_test_ledger_hold() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.entity_id LIKE 'hold-%' THEN
            PERFORM pg_advisory_lock(hashtext('#{@key}'), hashtext(NEW.entity_id));
            PERFORM pg_advisory_unlock(hashtext('#{@key}'), hashtext(NEW.entity_id));
          ELSIF NEW.entity_id LIKE 'fail-%' THEN
            RAISE EXCEPTION 'oe_test_ledger_hold: % rolled back', NEW.entity_id;
          END IF;
          RETURN NEW;
        END $$
        """,
        []
      )

      Postgrex.query!(conn, "DROP TRIGGER IF EXISTS oe_test_ledger_hold ON sync_mutations", [])

      Postgrex.query!(
        conn,
        "CREATE TRIGGER oe_test_ledger_hold AFTER INSERT ON sync_mutations FOR EACH ROW EXECUTE FUNCTION oe_test_ledger_hold()",
        []
      )

      # An applied change's row write, held the same way for an id starting
      # `slow-`: the apply is part way through its transaction.
      Postgrex.query!(
        conn,
        """
        CREATE OR REPLACE FUNCTION oe_test_row_hold() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.id LIKE 'slow-%' THEN
            PERFORM pg_advisory_lock(hashtext('#{@key}'), hashtext(NEW.id));
            PERFORM pg_advisory_unlock(hashtext('#{@key}'), hashtext(NEW.id));
          END IF;
          RETURN NEW;
        END $$
        """,
        []
      )

      Postgrex.query!(conn, "DROP TRIGGER IF EXISTS oe_test_row_hold ON contexts", [])

      Postgrex.query!(
        conn,
        "CREATE TRIGGER oe_test_row_hold AFTER INSERT ON contexts FOR EACH ROW EXECUTE FUNCTION oe_test_row_hold()",
        []
      )
    end)

    :ok
  end

  def uninstall do
    with_conn(fn conn ->
      Postgrex.query!(conn, "DROP TRIGGER IF EXISTS oe_test_ledger_hold ON sync_mutations", [])
      Postgrex.query!(conn, "DROP FUNCTION IF EXISTS oe_test_ledger_hold()", [])
      Postgrex.query!(conn, "DROP TRIGGER IF EXISTS oe_test_row_hold ON contexts", [])
      Postgrex.query!(conn, "DROP FUNCTION IF EXISTS oe_test_row_hold()", [])
    end)

    :ok
  end

  @doc "Takes the lock a writer of `entity_id` will wait on; returns the holding connection."
  def hold(entity_id) do
    conn = connect()

    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1), hashtext($2))", [@key, entity_id])

    conn
  end

  @doc "True once a writer of `entity_id` is waiting on the hold: its sequence is drawn."
  def waiting?(conn, entity_id) do
    %{rows: [[n]]} =
      Postgrex.query!(
        conn,
        """
        SELECT COUNT(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted
          AND classid = hashtext($1)::oid AND objid = hashtext($2)::oid
        """,
        [@key, entity_id]
      )

    n > 0
  end

  def release(conn) do
    Postgrex.query!(conn, "SELECT pg_advisory_unlock_all()", [])
    GenServer.stop(conn)
  end

  @doc "Runs `fun` with a connection of its own on the store's schema (or `schema`)."
  def with_conn(fun, schema \\ nil) do
    conn = connect(schema)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp connect(schema \\ nil) do
    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    schema =
      schema ||
        Keyword.get(Application.get_env(:optimal_engine, :postgres_store, []), :schema, "public")

    {:ok, conn} =
      config
      |> Map.take([:hostname, :port, :database, :username, :password, :ssl])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.merge(pool_size: 1, parameters: [search_path: schema])
      |> Postgrex.start_link()

    conn
  end
end
