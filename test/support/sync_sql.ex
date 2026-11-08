defmodule OptimalEngine.Test.SyncSql do
  @moduledoc false
  # SQL the sync tests write rows with, for the store the build runs: SQLite's
  # JSON functions there, PostgreSQL's jsonb on a PostgreSQL build. The tests
  # only need the JSON that results; the statements under test are the
  # Engine's own.

  alias OptimalEngine.Store

  defp postgres?, do: Store.selected?(OptimalEngine.Store.Postgres)

  @doc """
  `column` with the member `key` set to `value`: `{:json, sql}` is JSON text
  (`json(sql)` on SQLite), `{:text, sql}` a string. `key` is a plain key, or
  `{:param, "?n"}` for a key bound as text.
  """
  def json_set(column, key, value) do
    if postgres?() do
      path =
        case key do
          {:param, param} -> "ARRAY[CAST(#{param} AS text)]"
          key -> "'{#{key}}'"
        end

      value =
        case value do
          {:json, sql} -> "CAST(#{sql} AS text)::jsonb"
          {:text, sql} -> "to_jsonb(CAST(#{sql} AS text))"
        end

      "jsonb_set(CAST(#{column} AS text)::jsonb, #{path}, #{value})::text"
    else
      path =
        case key do
          {:param, param} -> "'$.' || #{param}"
          key -> "'$.#{key}'"
        end

      value =
        case value do
          {:json, sql} -> "json(#{sql})"
          {:text, sql} -> sql
        end

      "json_set(#{column}, #{path}, #{value})"
    end
  end

  @doc "The JSON text `sql` as a JSON value, as `json(sql)` gives it on SQLite."
  def json(sql), do: if(postgres?(), do: "CAST(#{sql} AS text)::json", else: "json(#{sql})")

  @doc "A JSON object of `pairs` (`{key, sql}`), as text."
  def json_object(pairs) do
    args = Enum.map_join(pairs, ", ", fn {key, sql} -> "'#{key}', #{sql}" end)
    if postgres?(), do: "json_build_object(#{args})::text", else: "json_object(#{args})"
  end

  @doc "The `seq` the next captured change will have."
  def next_capture_sequence do
    sql =
      if postgres?(),
        do:
          "SELECT COALESCE(pg_sequence_last_value(pg_get_serial_sequence('sync_capture', 'seq')), 0) + 1",
        else:
          "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_capture'), 0) + 1"

    {:ok, [[next]]} = Store.raw_query(sql, [])
    next
  end
end
