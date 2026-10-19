# Embedded throughput and latency of the app data layer (OptimalEngine.AppData).
#
# Run against a disposable store only, for example:
#
#   MIX_ENV=test OPTIMAL_ENGINE_DB=/tmp/bench/engine.db OPTIMAL_ENGINE_ROOT=/tmp/bench/root \
#     OPTIMAL_API_ENABLED=false mix run benchmarks/scripts/app_data_bench.exs [records]
#
# Calls the same functions the HTTP routes call, in-process, so the numbers
# exclude HTTP, JSON, and API-key verification. Default size: 100,000 records.

alias OptimalEngine.AppData
alias OptimalEngine.AppData.Scope

records = System.argv() |> List.first() |> then(&if(&1, do: String.to_integer(&1), else: 100_000))
owners = 100
scope = Scope.new(tenant_id: "default", workspace_id: "default:bench-#{System.unique_integer([:positive])}", actor: "bench")

{:ok, _} =
  AppData.create_collection(scope, %{
    "name" => "tasks",
    "fields" => [
      %{"name" => "title", "type" => "string", "required" => true},
      %{"name" => "owner", "type" => "string"},
      %{"name" => "done", "type" => "boolean", "default" => false},
      %{"name" => "due", "type" => "datetime"},
      %{"name" => "priority", "type" => "integer"}
    ],
    "owner_field" => "owner",
    "indexes" => [%{"fields" => ["owner", "done", "due"]}],
    "search" => %{"text" => ["title"]}
  })

words = ~w(report invoice review budget plan call email design draft ship fix test deploy write read)

task = fn i ->
  %{
    "title" => "#{Enum.at(words, rem(i, 15))} #{Enum.at(words, rem(div(i, 15), 15))} item #{i}",
    "owner" => "user-#{rem(i, owners)}",
    "done" => rem(i, 5) == 0,
    "due" => DateTime.add(~U[2026-11-01 00:00:00Z], rem(i * 7919, 1_000_000) * 60, :second) |> DateTime.to_iso8601(),
    "priority" => rem(i, 4)
  }
end

timed = fn fun ->
  t = System.monotonic_time(:microsecond)
  result = fun.()
  {System.monotonic_time(:microsecond) - t, result}
end

stats = fn samples ->
  sorted = Enum.sort(samples)
  n = length(sorted)
  pick = fn p -> Enum.at(sorted, min(n - 1, trunc(p * n))) / 1000 end
  %{p50: pick.(0.50), p95: pick.(0.95), p99: pick.(0.99), mean: Enum.sum(sorted) / n / 1000}
end

line = fn label, s ->
  IO.puts(
    String.pad_trailing(label, 52) <>
      "p50 #{:erlang.float_to_binary(s.p50, decimals: 2)} ms  p95 #{:erlang.float_to_binary(s.p95, decimals: 2)} ms  p99 #{:erlang.float_to_binary(s.p99, decimals: 2)} ms"
  )
end

# Engine boot runs backfills and schedulers against the same Store; wait
# until a trivial Store call is consistently fast before measuring.
settle = fn settle ->
  samples = for _ <- 1..50, do: elem(timed.(fn -> OptimalEngine.Store.raw_query("SELECT 1", []) end), 0)

  if Enum.max(samples) > 2_000 do
    Process.sleep(1_000)
    settle.(settle)
  end
end

{settle_us, _} = timed.(fn -> settle.(settle) end)
IO.puts("records=#{records} owners=#{owners} schedulers=#{System.schedulers_online()} settled_after=#{div(settle_us, 1000)}ms")

# -- single-record writes (each its own transaction) ---------------------------
single = 2_000

{elapsed, latencies} =
  timed.(fn ->
    for i <- 1..single do
      {us, {:ok, _}} = timed.(fn -> AppData.create(scope, "tasks", %{"data" => task.(i)}) end)
      us
    end
  end)

IO.puts("single creates: #{single} in #{div(elapsed, 1000)} ms = #{round(single / (elapsed / 1_000_000))} writes/s")
line.("  create latency", stats.(latencies))

# -- bulk load to the target size ---------------------------------------------
batch = 1_000
remaining = records - single

{elapsed, _} =
  timed.(fn ->
    (single + 1)..records
    |> Enum.chunk_every(batch)
    |> Enum.each(fn chunk ->
      {:ok, _} = AppData.bulk_create(scope, "tasks", Enum.map(chunk, &%{"data" => task.(&1)}))
    end)
  end)

IO.puts("bulk creates: #{remaining} in #{div(elapsed, 1000)} ms = #{round(remaining / (elapsed / 1_000_000))} records/s (batches of #{batch})")

# -- single-record updates with a version check -------------------------------
{:ok, page} = AppData.query(scope, "tasks", %{"limit" => 1_000, "fields" => ["title"]})
targets = page["records"]

{elapsed, latencies} =
  timed.(fn ->
    for r <- targets ++ targets do
      {:ok, current} = AppData.get(scope, "tasks", r["id"])

      {us, {:ok, _}} =
        timed.(fn ->
          AppData.update(scope, "tasks", r["id"], %{"data" => %{"priority" => 9}, "version" => current["version"]})
        end)

      us
    end
  end)

IO.puts("versioned updates: #{length(latencies)} (get + update) in #{div(elapsed, 1000)} ms")
line.("  update latency", stats.(latencies))

# -- concurrent writers ---------------------------------------------------------
writers = 8
per_writer = 250

{elapsed, _} =
  timed.(fn ->
    1..writers
    |> Task.async_stream(
      fn w ->
        for i <- 1..per_writer, do: {:ok, _} = AppData.create(scope, "tasks", %{"data" => task.(records + w * 10_000 + i)})
      end,
      max_concurrency: writers,
      timeout: :infinity
    )
    |> Stream.run()
  end)

total = writers * per_writer
IO.puts("concurrent creates: #{writers} writers x #{per_writer} = #{round(total / (elapsed / 1_000_000))} writes/s aggregate")

# -- queries at size -----------------------------------------------------------
runs = 500

measure = fn label, fun ->
  _warm = for _ <- 1..20, do: fun.()
  latencies = for _ <- 1..runs, do: elem(timed.(fun), 0)
  line.(label, stats.(latencies))
end

{:ok, %{"count" => count}} = AppData.query(scope, "tasks", %{"limit" => 0, "count" => true})
IO.puts("query latency at #{count} records (#{runs} runs each):")

open_spec = fn owner -> %{"where" => %{"owner" => owner, "done" => false}, "sort" => ["due"], "limit" => 50} end
measure.("  open tasks for one owner, sort due, limit 50", fn -> {:ok, _} = AppData.query(scope, "tasks", open_spec.("user-#{:rand.uniform(owners) - 1}")) end)

{:ok, first} = AppData.query(scope, "tasks", open_spec.("user-7"))
measure.("  next page by cursor", fn -> {:ok, _} = AppData.query(scope, "tasks", Map.put(open_spec.("user-7"), "cursor", first["next_cursor"])) end)

measure.("  same query with count", fn ->
  {:ok, _} = AppData.query(scope, "tasks", Map.put(open_spec.("user-#{:rand.uniform(owners) - 1}"), "count", true))
end)

ids = Enum.map(targets, & &1["id"])
measure.("  get by id", fn -> {:ok, _} = AppData.get(scope, "tasks", Enum.random(ids)) end)

measure.("  full-text search one term, limit 20", fn ->
  {:ok, _} = AppData.query(scope, "tasks", %{"search" => Enum.random(words), "limit" => 20})
end)

measure.("  full-text two terms + owner filter, limit 20", fn ->
  {:ok, _} = AppData.query(scope, "tasks", %{"search" => "report review", "where" => %{"owner" => "user-#{:rand.uniform(owners) - 1}"}, "limit" => 20})
end)

measure.("  unindexed filter (priority), limit 50", fn ->
  {:ok, _} = AppData.query(scope, "tasks", %{"where" => %{"priority" => 2}, "sort" => ["-created_at"], "limit" => 50})
end)

{:ok, %{"latest_seq" => latest}} = AppData.changes(scope, %{"since" => "latest"})
measure.("  change feed page of 100", fn -> {:ok, _} = AppData.changes(scope, %{"since" => :rand.uniform(max(latest - 100, 1)), "limit" => 100}) end)

# -- online index build ----------------------------------------------------------
{us, {:ok, _}} = timed.(fn -> AppData.alter_collection(scope, "tasks", [%{"op" => "add_index", "fields" => ["priority", "due"]}]) end)
IO.puts("add index (priority, due) online at #{count} records: #{div(us, 1000)} ms")

db = Application.get_env(:optimal_engine, :db_path)
size =
  Enum.reduce([db, db <> "-wal"], 0, fn p, acc ->
    case File.stat(p) do
      {:ok, %{size: bytes}} -> acc + bytes
      _ -> acc
    end
  end)
IO.puts("database + wal size: #{Float.round(size / 1_048_576, 1)} MiB")
