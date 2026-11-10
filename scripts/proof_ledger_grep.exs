# Counts where an Engine's replication ledger still holds a text, without the
# Engine's application: `sync_mutations` payloads, `sync_capture` rows and
# `sync_conflicts` payloads, limited to the changes of the tables named.
# Prints "<hits>" and nothing of what it found.
#
#   OPTIMAL_PROOF_TOKEN=... OPTIMAL_PROOF_TABLES=memories,ledger_redactions \
#     mix run --no-compile --no-start scripts/proof_ledger_grep.exs
#
# SQLite: OPTIMAL_ENGINE_DB names the database file (opened read-only).
# PostgreSQL (OPTIMAL_STORE=postgres): OPTIMAL_POSTGRES_URL and OPTIMAL_POSTGRES_SCHEMA.
token = System.fetch_env!("OPTIMAL_PROOF_TOKEN")
tables = "OPTIMAL_PROOF_TABLES" |> System.get_env("") |> String.split(",", trim: true)
like = "%" <> token <> "%"

scope = fn column ->
  if tables == [],
    do: "",
    else: " AND #{column} IN (" <> Enum.map_join(tables, ", ", &"'#{String.replace(&1, "'", "")}'") <> ")"
end

queries = [
  "SELECT COUNT(*) FROM sync_mutations WHERE payload LIKE $1" <> scope.("entity_type"),
  "SELECT COUNT(*) FROM sync_capture WHERE row_data LIKE $1" <> scope.("table_name"),
  "SELECT COUNT(*) FROM sync_conflicts WHERE (local_payload LIKE $1 OR remote_payload LIKE $1)" <>
    scope.("table_name")
]

hits =
  if System.get_env("OPTIMAL_STORE") == "postgres" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    {:ok, conn} =
      config
      |> Map.take([:hostname, :port, :database, :username, :password, :ssl])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Postgrex.start_link()

    schema = System.fetch_env!("OPTIMAL_POSTGRES_SCHEMA")
    unless schema =~ ~r/\A[a-z0-9_]+\z/, do: raise("unsafe schema name")
    Postgrex.query!(conn, ~s(SET search_path TO "#{schema}"), [])

    Enum.reduce(queries, 0, fn sql, acc ->
      %{rows: [[n]]} = Postgrex.query!(conn, sql, [like])
      acc + n
    end)
  else
    {:ok, db} = Exqlite.Sqlite3.open(System.fetch_env!("OPTIMAL_ENGINE_DB"), mode: :readonly)

    Enum.reduce(queries, 0, fn sql, acc ->
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, String.replace(sql, "$1", "?1"))
      :ok = Exqlite.Sqlite3.bind(stmt, [like])
      {:row, [n]} = Exqlite.Sqlite3.step(db, stmt)
      acc + n
    end)
  end

IO.puts(hits)
