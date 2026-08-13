alias OptimalEngine.Store

count =
  System.get_env("BENCHMARK_RECORDS", "10000")
  |> String.to_integer()
  |> max(1)

table = "benchmark_capacity_#{System.unique_integer([:positive])}"

:ok =
  Store.raw_execute(
    "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, workspace_id TEXT NOT NULL, content TEXT NOT NULL)"
  )

:ok = Store.raw_execute("CREATE INDEX #{table}_workspace ON #{table}(workspace_id, id)")

{:ok, [[page_size]]} = Store.raw_query("PRAGMA page_size")
{:ok, [[pages_before]]} = Store.raw_query("PRAGMA page_count")
insert_started = System.monotonic_time(:microsecond)

{:ok, ^count} =
  Store.transaction(
    fn transaction ->
      Enum.reduce_while(1..count, {:ok, 0}, fn index, {:ok, inserted} ->
        case Store.txn_execute(
               transaction,
               "INSERT INTO #{table} (id, workspace_id, content) VALUES (?1, ?2, ?3)",
               [
                 index,
                 "capacity:#{rem(index, 10)}",
                 "record #{index} deterministic benchmark payload"
               ]
             ) do
          {:ok, 1} -> {:cont, {:ok, inserted + 1}}
          error -> {:halt, error}
        end
      end)
    end,
    120_000
  )

insert_ms = (System.monotonic_time(:microsecond) - insert_started) / 1_000

latencies =
  Enum.map(1..1_000, fn index ->
    started = System.monotonic_time(:microsecond)
    id = rem(index * 7919, count) + 1

    {:ok, [[^id]]} =
      Store.raw_query("SELECT id FROM #{table} WHERE workspace_id = ?1 AND id = ?2", [
        "capacity:#{rem(id, 10)}",
        id
      ])

    System.monotonic_time(:microsecond) - started
  end)
  |> Enum.sort()

{:ok, [[pages_after]]} = Store.raw_query("PRAGMA page_count")
:ok = Store.raw_execute("DROP TABLE #{table}")

percentile = fn values, quantile ->
  Enum.at(values, max(ceil(length(values) * quantile) - 1, 0)) / 1_000
end

result = %{
  benchmark_version: "storage-capacity-v1",
  records: count,
  insert_ms: Float.round(insert_ms, 3),
  inserts_per_second: Float.round(count / (insert_ms / 1_000), 1),
  lookup_p50_ms: Float.round(percentile.(latencies, 0.50), 3),
  lookup_p95_ms: Float.round(percentile.(latencies, 0.95), 3),
  lookup_p99_ms: Float.round(percentile.(latencies, 0.99), 3),
  database_growth_bytes: (pages_after - pages_before) * page_size,
  passed: percentile.(latencies, 0.95) <= 10.0
}

rendered = Jason.encode!(result)
IO.puts(rendered)

if output = System.get_env("BENCHMARK_OUT") do
  output |> Path.dirname() |> File.mkdir_p!()
  File.write!(output, Jason.Formatter.pretty_print(rendered) <> "\n")
end

if not result.passed, do: System.halt(2)
