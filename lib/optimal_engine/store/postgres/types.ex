# The type module the PostgreSQL store connects with. The extensions listed
# here take priority over Postgrex's own for the types they match; every other
# type keeps the Postgrex default. See OptimalEngine.Store.Postgres.Affinity.
Postgrex.Types.define(
  OptimalEngine.Store.Postgres.Types,
  [
    OptimalEngine.Store.Postgres.Extensions.Text,
    OptimalEngine.Store.Postgres.Extensions.Int8,
    OptimalEngine.Store.Postgres.Extensions.Int4,
    OptimalEngine.Store.Postgres.Extensions.Int2,
    OptimalEngine.Store.Postgres.Extensions.Float8,
    OptimalEngine.Store.Postgres.Extensions.Float4,
    OptimalEngine.Store.Postgres.Extensions.Bytea,
    OptimalEngine.Store.Postgres.Extensions.Bool,
    OptimalEngine.Store.Postgres.Extensions.Json,
    OptimalEngine.Store.Postgres.Extensions.Jsonb
  ],
  moduledoc: """
  The Postgrex type module of the PostgreSQL store: parameters are encoded with
  SQLite's type affinity and results decode as SQLite returns them.
  """
)
