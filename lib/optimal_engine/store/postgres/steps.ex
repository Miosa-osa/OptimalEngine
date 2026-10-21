defmodule OptimalEngine.Store.Postgres.Steps do
  @moduledoc """
  The PostgreSQL work a migration's data statements need on a database that
  already exists.

  The schema of the PostgreSQL store is derived from what the SQLite
  migrations produce (`OptimalEngine.Store.Postgres.Schema`), so a migration
  that only creates a table, a column, an index, a view or a trigger needs
  nothing here. A migration that moves or changes data (`UPDATE`, `DELETE`,
  `INSERT`, `DROP TABLE`, a column drop, a rename, a table rebuild) does: the
  derived schema has the final shape, but the rows already in a PostgreSQL
  database have not been through the statement.

  Every migration above `baseline/0` whose statements include a data statement
  must declare its PostgreSQL steps here, either as a list of
  `{label, postgres_sql}` statements or as `{:none, reason}` when the data
  statement has nothing to do on PostgreSQL (it only writes a full-text table,
  for example). `check/1` fails when one is missing, and the schema derivation
  runs it, so such a migration breaks the build rather than a database.

  The steps run once, when a database first reaches the version: after the new
  tables and columns exist and before the indexes and constraints are created.
  A fresh database runs none, because it is created in the final shape with the
  rows the migrations leave.

  ## The baseline

  No PostgreSQL store exists below `baseline/0`: a database is always created
  at or above it, so older migrations never run on PostgreSQL. Until the first
  PostgreSQL store is deployed the baseline is the newest migration, so a new
  migration needs no step and a database an older build created is refused as
  drift. The release that deploys the first PostgreSQL store sets
  `@frozen_baseline` to the newest migration version
  (docs/guides/versioning-and-releases.md). From then on the baseline stays
  there, and every new data statement needs its step.
  """

  alias OptimalEngine.Store.Migrations

  # nil until the first PostgreSQL store is deployed; then the newest
  # migration version of that release, never changed again.
  @frozen_baseline nil

  # {version, [{label, postgres_sql}] | {:none, reason}}, in version order.
  @steps []

  @typedoc "A declared step: statements to run, or the reason none are needed."
  @type step :: [{String.t(), String.t()}] | {:none, String.t()}

  @schema_statement ~r/\A(CREATE\s+(TEMP\s+|TEMPORARY\s+)?(TABLE|VIEW|TRIGGER)\b|CREATE\s+(UNIQUE\s+)?INDEX\b|CREATE\s+VIRTUAL\s+TABLE\b|DROP\s+(INDEX|VIEW|TRIGGER)\b|ALTER\s+TABLE\s+\S+\s+ADD\b(?!\s+CONSTRAINT))/i

  @doc "The newest migration version no PostgreSQL store predates."
  @spec baseline() :: pos_integer()
  def baseline, do: @frozen_baseline || newest(Migrations.all())

  @doc "Whether the baseline is fixed (a PostgreSQL store has been deployed)."
  @spec frozen?() :: boolean()
  def frozen?, do: not is_nil(@frozen_baseline)

  defp newest(migrations), do: migrations |> Enum.map(&elem(&1, 0)) |> Enum.max()

  @doc "The declared steps by version."
  @spec declared() :: %{pos_integer() => step()}
  def declared, do: Map.new(@steps)

  @doc "The declared step for one version, or `:undeclared`."
  @spec for_version(pos_integer()) :: step() | :undeclared
  def for_version(version) do
    case List.keyfind(@steps, version, 0) do
      {^version, step} -> step
      nil -> :undeclared
    end
  end

  @doc """
  Checks that every migration above the baseline that has a data statement
  declares its step, and that every declaration names a migration above the
  baseline.

  Options: `:baseline` and `:steps`, for testing the rule itself.
  """
  @spec check([Migrations.migration()], keyword()) :: :ok | {:error, term()}
  def check(migrations \\ Migrations.all(), opts \\ []) do
    baseline = Keyword.get_lazy(opts, :baseline, &baseline/0)
    steps = Keyword.get_lazy(opts, :steps, &declared/0)
    versions = MapSet.new(migrations, &elem(&1, 0))

    undeclared =
      for {version, _description, statements} <- migrations,
          version > baseline,
          not Map.has_key?(steps, version),
          data = data_statements(statements),
          data != [] do
        {version, data}
      end

    stray =
      for version <- Map.keys(steps),
          version <= baseline or not MapSet.member?(versions, version),
          do: version

    cond do
      undeclared != [] -> {:error, {:undeclared_postgres_steps, undeclared}}
      stray != [] -> {:error, {:stray_postgres_steps, Enum.sort(stray)}}
      true -> :ok
    end
  end

  @doc """
  The data statements among a migration's statements, as `{label, kind}`.

  A statement is a schema statement when it creates a table, view, trigger or
  index, drops an index, view or trigger, or adds a column; the derivation
  carries those. Anything else is a data statement, including a statement this
  function does not recognise.
  """
  @spec data_statements([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def data_statements(statements) do
    for {label, sql} <- statements,
        statement <- split(sql),
        not schema_statement?(statement) do
      {label, kind(statement)}
    end
  end

  # CREATE TABLE ... AS SELECT copies rows, so it is a data statement.
  defp schema_statement?(statement) do
    Regex.match?(@schema_statement, statement) and
      not Regex.match?(~r/\ACREATE\s+\S*\s*TABLE\b[^(]*\bAS\s+SELECT\b/is, statement)
  end

  defp kind(statement) do
    cond do
      Regex.match?(~r/\AALTER\s+TABLE\s+\S+\s+RENAME\b/i, statement) -> "ALTER TABLE RENAME"
      Regex.match?(~r/\AALTER\s+TABLE\s+\S+\s+DROP\b/i, statement) -> "ALTER TABLE DROP"
      Regex.match?(~r/\ADROP\s+TABLE\b/i, statement) -> "DROP TABLE"
      Regex.match?(~r/\ACREATE\b/i, statement) -> "CREATE TABLE ... AS SELECT"
      Regex.match?(~r/\AINSERT\b[^;]*\bSELECT\b/is, statement) -> "INSERT ... SELECT"
      true -> statement |> String.split(~r/\s+/, parts: 2) |> hd() |> String.upcase()
    end
  end

  # The statements of one migration entry, without comments, trimmed. A
  # trigger's body has semicolons of its own, so an entry that creates a
  # trigger is one statement.
  defp split(sql) do
    stripped =
      sql
      |> String.replace(~r/--[^\n]*/, "")
      |> String.replace(~r|/\*.*?\*/|s, "")
      |> String.trim()

    if Regex.match?(~r/\ACREATE\s+(TEMP\s+|TEMPORARY\s+)?TRIGGER\b/i, stripped) do
      [stripped]
    else
      stripped
      |> split_outside_literals()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp split_outside_literals(sql), do: split_outside_literals(sql, false, [], [])

  defp split_outside_literals(<<>>, _quoted?, current, done),
    do: Enum.reverse([current |> Enum.reverse() |> IO.iodata_to_binary() | done])

  defp split_outside_literals(<<?', rest::binary>>, quoted?, current, done),
    do: split_outside_literals(rest, not quoted?, [?' | current], done)

  defp split_outside_literals(<<?;, rest::binary>>, false, current, done),
    do:
      split_outside_literals(rest, false, [], [
        current |> Enum.reverse() |> IO.iodata_to_binary() | done
      ])

  defp split_outside_literals(<<char, rest::binary>>, quoted?, current, done),
    do: split_outside_literals(rest, quoted?, [char | current], done)
end
