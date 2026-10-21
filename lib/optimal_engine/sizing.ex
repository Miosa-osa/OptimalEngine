defmodule OptimalEngine.Sizing do
  @moduledoc """
  Engine size profiles, the tuning each one sets, and usage gauges against
  its limits.

  | Profile | Machine (vCPU / RAM) | Disk | Embedded limits (rule of thumb) | Use |
  | --- | --- | --- | --- | --- |
  | `agent` | 1 / 1 GiB | 2 GiB | 50k vectors, 100k memories | one agent's or one end user's memory; scales to zero |
  | `workspace` | 1 / 2 GiB | 10 GiB | 250k vectors, 500k memories | one client or team workspace; scales to zero |
  | `business` | 2 / 4 GiB | 25 GiB | 1M vectors, 2M memories | a whole company in one brain |
  | `platform` | 4 / 8 GiB | 100 GiB | 5M vectors, 10M memories | a large customer, a product with many end users |
  | `scale` | 8 / 16 GiB or more | 250 GiB or more | beyond embedded limits | vectors move to a vector provider and writers to Postgres |

  The profile comes from `config :optimal_engine, :size_profile` (env
  `OPTIMAL_SIZE_PROFILE`, default `business`). It sets the SQLite page cache
  and memory map, the hot context cache, and the API rate limit; explicitly
  configured values always win.

  `usage/0` measures vectors, memories, pending memory candidates, contexts,
  disk, memory, and the recent write rate against the profile's limits. At 70
  percent of any limit the recommendation names the next profile; on `scale`
  it names the providers to enable instead.

  A memory candidate is a pending claim of type `memory_candidate`: a fact the
  governed memory intake wrote and nobody has reviewed. `Memory.remember/2`
  writes the claim and, when asked to project (`POST /api/memory/remember` and
  `mix optimal.remember` do), a staging row in `memories`; `Memory.create/1`
  writes a memory and stages its claim. A fact can be in both gauges, and a
  fact remembered through the library without the projection is only a
  candidate, so the two are not added. The limit is a tenth of the profile's
  memories: a candidate is a claim, a source package and ledger entries, and a
  backlog that deep is more than anyone reviews.
  """

  alias OptimalEngine.Store

  @gib 1_073_741_824
  @mib 1_048_576
  @watch_percent 70.0

  @profiles [
    %{
      id: "agent",
      label: "Agent memory",
      machine: %{vcpu: 1, memory_mib: 1_024, size: "tiny"},
      disk_gib: 2,
      scale_to_zero: true,
      limits: %{
        vectors: 50_000,
        memories: 100_000,
        memory_candidates: 10_000,
        contexts: 25_000,
        writes_per_minute: 600
      },
      tuning: %{
        sqlite_cache_mib: 16,
        sqlite_mmap_mib: 64,
        context_cache_entries: 200,
        api_per_minute: 300
      },
      use: "One agent's or one end user's memory."
    },
    %{
      id: "workspace",
      label: "Workspace",
      machine: %{vcpu: 1, memory_mib: 2_048, size: "xs"},
      disk_gib: 10,
      scale_to_zero: true,
      limits: %{
        vectors: 250_000,
        memories: 500_000,
        memory_candidates: 50_000,
        contexts: 100_000,
        writes_per_minute: 1_500
      },
      tuning: %{
        sqlite_cache_mib: 64,
        sqlite_mmap_mib: 256,
        context_cache_entries: 500,
        api_per_minute: 600
      },
      use: "One client or one team workspace."
    },
    %{
      id: "business",
      label: "Business",
      machine: %{vcpu: 2, memory_mib: 4_096, size: "small"},
      disk_gib: 25,
      scale_to_zero: false,
      limits: %{
        vectors: 1_000_000,
        memories: 2_000_000,
        memory_candidates: 200_000,
        contexts: 500_000,
        writes_per_minute: 3_000
      },
      tuning: %{
        sqlite_cache_mib: 128,
        sqlite_mmap_mib: 1_024,
        context_cache_entries: 2_000,
        api_per_minute: 1_200
      },
      use: "A whole company in one brain, with many agents."
    },
    %{
      id: "platform",
      label: "Platform",
      machine: %{vcpu: 4, memory_mib: 8_192, size: "medium"},
      disk_gib: 100,
      scale_to_zero: false,
      limits: %{
        vectors: 5_000_000,
        memories: 10_000_000,
        memory_candidates: 1_000_000,
        contexts: 2_000_000,
        writes_per_minute: 6_000
      },
      tuning: %{
        sqlite_cache_mib: 256,
        sqlite_mmap_mib: 4_096,
        context_cache_entries: 5_000,
        api_per_minute: 3_000
      },
      use: "A large customer, or a product with many end users."
    },
    %{
      id: "scale",
      label: "Scale",
      machine: %{vcpu: 8, memory_mib: 16_384, size: "large"},
      disk_gib: 250,
      scale_to_zero: false,
      limits: %{
        vectors: 10_000_000,
        memories: 50_000_000,
        memory_candidates: 5_000_000,
        contexts: 10_000_000,
        writes_per_minute: 12_000
      },
      tuning: %{
        sqlite_cache_mib: 512,
        sqlite_mmap_mib: 8_192,
        context_cache_entries: 10_000,
        api_per_minute: 6_000
      },
      use: "Beyond embedded limits: vectors move to a vector provider and writers to Postgres."
    }
  ]

  @default_profile "business"

  @doc "Every profile, smallest first."
  @spec profiles() :: [map()]
  def profiles, do: Enum.map(@profiles, &with_bytes/1)

  @doc "The active profile."
  @spec profile() :: map()
  def profile do
    id = Application.get_env(:optimal_engine, :size_profile) || @default_profile

    case fetch(id) do
      {:ok, profile} -> profile
      :error -> fetch!(@default_profile)
    end
  end

  @doc "A profile by id."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(id) do
    case Enum.find(@profiles, &(&1.id == to_string(id))) do
      nil -> :error
      profile -> {:ok, with_bytes(profile)}
    end
  end

  defp fetch!(id), do: elem(fetch(id), 1)

  @doc "The profile after `id`, or nil for the largest."
  @spec next(String.t()) :: map() | nil
  def next(id) do
    case Enum.find_index(@profiles, &(&1.id == id)) do
      nil -> nil
      index -> @profiles |> Enum.at(index + 1) |> then(&(&1 && with_bytes(&1)))
    end
  end

  @doc """
  A tuning value for the active profile, unless configured explicitly:
  `:context_cache_entries` (config `:context_cache_entries`),
  `:sqlite_cache_mib`, `:sqlite_mmap_mib`, `:api_per_minute`.
  """
  @spec tuning(atom()) :: non_neg_integer()
  def tuning(key) do
    case Application.get_env(:optimal_engine, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Map.fetch!(profile().tuning, key)
    end
  end

  @doc """
  Usage against the active profile's limits: one gauge per measure, the
  worst percentage, and a recommendation.
  """
  @spec usage() :: map()
  def usage do
    evaluate(profile(), %{
      vectors: count_vectors(),
      memories: count("memories"),
      memory_candidates: memory_candidates(),
      contexts: count("contexts"),
      disk_bytes: disk_bytes(),
      memory_bytes: :erlang.memory(:total),
      writes_per_minute: writes_per_minute()
    })
  end

  @doc "Gauges and a recommendation for `measures` against `profile`."
  @spec evaluate(map(), map()) :: map()
  def evaluate(profile, measures) do
    limits = profile.limits

    gauges = [
      gauge("vectors", measures.vectors, limits.vectors),
      gauge("memories", measures.memories, limits.memories),
      gauge("memory_candidates", measures.memory_candidates, limits.memory_candidates),
      gauge("contexts", measures.contexts, limits.contexts),
      gauge("disk_bytes", measures.disk_bytes, profile.disk_bytes),
      gauge("memory_bytes", measures.memory_bytes, profile.machine.memory_mib * @mib),
      gauge("writes_per_minute", measures.writes_per_minute, limits.writes_per_minute)
    ]

    worst = Enum.max_by(gauges, & &1.percent, fn -> nil end)

    %{
      profile:
        Map.take(profile, [:id, :label, :machine, :disk_gib, :scale_to_zero, :limits, :tuning]),
      gauges: gauges,
      worst: worst && Map.take(worst, [:name, :percent]),
      recommendation: recommendation(profile, worst),
      boot_ms: boot_ms()
    }
  end

  @doc "Records the start of boot (called first in the application start)."
  @spec boot_started() :: :ok
  def boot_started do
    :persistent_term.put({__MODULE__, :boot_started}, System.monotonic_time(:millisecond))
  end

  @doc "Records the end of boot (called once the supervision tree is up)."
  @spec boot_finished() :: :ok
  def boot_finished do
    case :persistent_term.get({__MODULE__, :boot_started}, nil) do
      nil ->
        :ok

      started ->
        :persistent_term.put({__MODULE__, :boot_ms}, System.monotonic_time(:millisecond) - started)
    end
  end

  @doc "Milliseconds the last boot took, or nil."
  @spec boot_ms() :: non_neg_integer() | nil
  def boot_ms, do: :persistent_term.get({__MODULE__, :boot_ms}, nil)

  # ---------------------------------------------------------------------------

  defp recommendation(_profile, nil), do: %{action: "none"}

  defp recommendation(%{id: "scale"}, %{percent: percent} = worst) when percent >= @watch_percent do
    %{
      action: "enable_providers",
      reason: "#{worst.name} is at #{percent} percent of the largest embedded profile.",
      providers: providers_for(worst.name)
    }
  end

  defp recommendation(profile, %{percent: percent} = worst) when percent >= @watch_percent do
    next = next(profile.id)

    %{
      action: "resize",
      to: next.id,
      machine: next.machine,
      disk_gib: next.disk_gib,
      reason: "#{worst.name} is at #{percent} percent of the #{profile.id} limit."
    }
  end

  defp recommendation(_profile, _worst), do: %{action: "none"}

  defp providers_for("vectors"), do: ["qdrant"]
  defp providers_for("disk_bytes"), do: ["s3"]
  defp providers_for("writes_per_minute"), do: ["postgres", "nats_jetstream"]
  defp providers_for(_name), do: ["postgres"]

  defp gauge(name, used, limit) do
    percent = if limit > 0, do: Float.round(used / limit * 100, 1), else: 0.0

    status =
      cond do
        percent >= 100.0 -> "over"
        percent >= @watch_percent -> "watch"
        true -> "ok"
      end

    %{name: name, used: used, limit: limit, percent: percent, status: status}
  end

  defp with_bytes(profile), do: Map.put(profile, :disk_bytes, profile.disk_gib * @gib)

  defp count_vectors do
    ~w(vectors chunk_embeddings memory_embeddings) |> Enum.map(&count/1) |> Enum.sum()
  end

  defp count(table) do
    case Store.raw_query("SELECT COUNT(*) FROM #{table}", []) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  # Contexts and memories written in the last hour, per minute.
  defp writes_per_minute do
    since =
      DateTime.utc_now()
      |> DateTime.add(-3_600)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()

    written =
      [
        "SELECT COUNT(*) FROM contexts WHERE replace(indexed_at, 'T', ' ') >= replace(?1, 'T', ' ')",
        "SELECT COUNT(*) FROM memories WHERE replace(created_at, 'T', ' ') >= replace(?1, 'T', ' ')"
      ]
      |> Enum.map(fn sql ->
        case Store.raw_query(sql, [since]) do
          {:ok, [[n]]} -> n
          _ -> 0
        end
      end)
      |> Enum.sum()

    Float.round(written / 60, 1)
  end

  # Pending claims of type `memory_candidate`. No index covers the two columns,
  # so the count reads the claims table; it is kept for 30 seconds, which
  # bounds the scan however often the gauges are read.
  defp memory_candidates do
    cached(:memory_candidates, 30, fn ->
      case Store.raw_query(
             "SELECT COUNT(*) FROM claims WHERE claim_type = ?1 AND lifecycle_state = ?2",
             ["memory_candidate", "pending"]
           ) do
        {:ok, [[n]]} -> n
        _ -> 0
      end
    end)
  end

  # The database files, the graph, the file root, and the cache. Directory
  # sizes are cached for five minutes; a walk stops after 200,000 entries.
  defp disk_bytes, do: cached(:disk, 300, &measure_disk/0)

  defp cached(key, ttl_seconds, measure) do
    now = System.monotonic_time(:second)

    case :persistent_term.get({__MODULE__, key}, nil) do
      {at, value} when now - at < ttl_seconds ->
        value

      _ ->
        value = measure.()
        :persistent_term.put({__MODULE__, key}, {now, value})
        value
    end
  end

  defp measure_disk do
    db = Application.get_env(:optimal_engine, :db_path)

    files =
      if is_binary(db), do: Enum.map(["", "-wal", "-shm"], &file_size(db <> &1)), else: []

    rocksdb =
      if Keyword.get(Application.get_env(:optimal_engine, :knowledge, []), :backend) in [
           "rocksdb",
           :rocksdb
         ],
         do: Keyword.get(Application.get_env(:optimal_engine, :knowledge, []), :rocksdb_path)

    dirs =
      [
        Application.get_env(:optimal_engine, :root_path),
        Application.get_env(:optimal_engine, :cache_path),
        rocksdb
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&dir_size/1)

    Enum.sum(files) + Enum.sum(dirs)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size, type: :regular}} -> size
      _ -> 0
    end
  end

  defp dir_size(root) do
    {bytes, _left} = walk([root], 0, 200_000)
    bytes
  end

  defp walk([], bytes, left), do: {bytes, left}
  defp walk(_paths, bytes, 0), do: {bytes, 0}

  defp walk([path | rest], bytes, left) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        children =
          case File.ls(path) do
            {:ok, names} -> Enum.map(names, &Path.join(path, &1))
            _ -> []
          end

        walk(children ++ rest, bytes, left - 1)

      {:ok, %{type: :regular, size: size}} ->
        walk(rest, bytes + size, left - 1)

      _ ->
        walk(rest, bytes, left - 1)
    end
  end
end
