defmodule OptimalEngine.Storage.Qdrant.Projection do
  @moduledoc """
  The embeddings the Engine writes, projected into Qdrant.

  When `OPTIMAL_QDRANT_URL` is set (and `OPTIMAL_QDRANT_SERVING` is not `off`),
  every row the search reads from the three embedding stores is mirrored to
  Qdrant after the canonical write succeeds:

  | Kind | Rows | Point payload |
  | --- | --- | --- |
  | `contexts` | `vectors` joined to their context | `context_id`, `tenant_id`, `workspace_id` |
  | `chunks` | `chunk_embeddings` joined to their chunk | `chunk_id`, `context_id`, `scale`, `model`, `tenant_id`, `workspace_id` |
  | `memories` | `memory_embeddings` of latest, unforgotten memories | `memory_id`, `model`, `tenant_id`, `workspace_id` |

  Every payload also carries `engine_id`, this Engine's replica id
  (`sync_identity.replica_id`), and every count, search, sweep and delete
  filters on it, so Engines that share a Qdrant, even under one prefix, never
  read or remove each other's points.

  A collection holds one kind at one dimension, `<prefix>_<kind>_<dims>`. The
  prefix is `OPTIMAL_QDRANT_COLLECTION_PREFIX` when set, which must be lower
  case letters, digits, `_` and `-` (an invalid one stops the Engine at boot
  and is never replaced), and otherwise `oe_` and the hex of the replica id, so
  two Engines never share a collection by default. A point's id is a UUID from
  SHA-256 of the kind and the Engine row's key (and the model for a memory),
  so the same row always lands on the same point and a rebuild is idempotent.

  Mirrors leave the write path: they are queued to this process, which applies
  them in order, reading the row as it is then (a later write of the same row
  wins), and upserts it. Past the queue limit (`:max_queue`, 10,000) a mirror
  is dropped and its workspace marked dirty. A mirror that fails (Qdrant down,
  or answering an error) never fails the canonical write: it marks the
  workspace dirty and queues a `maintenance.qdrant_sync` job, and a dirty
  workspace, or one with a sync queued or running, is never searched through
  Qdrant until the sync has repaired it (`OptimalEngine.Storage.Qdrant.Gate`).

  Removals are recorded durably and applied by this process in the same order
  (`OptimalEngine.Storage.Qdrant.Removals`), whenever a Qdrant URL is
  configured, serving or not. A row in an archived workspace is not
  searchable, so it is neither mirrored nor counted, and the sync removes its
  points. Rows that leave by a cascade elsewhere are caught by the count
  comparison, and a point that outlives its row is never served: every
  candidate is read back from SQLite before it is scored
  (`OptimalEngine.Storage.Qdrant.Search`).

  The process owns an ETS table of identity, health, collections known to
  exist, count comparisons, dirty marks and counters. Without it (the
  application not started) mirrors run in the caller and nothing is cached.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.Qdrant
  alias OptimalEngine.Storage.Qdrant.{Gate, Removals}
  alias OptimalEngine.Store

  @table :optimal_qdrant_projection
  @kinds [:contexts, :chunks, :memories]
  @upsert_batch 128
  @key_batch 500
  @max_queue 10_000
  @default_timeout 5_000
  @call_timeout 120_000
  @off ~w(0 false off no disabled)
  @prefix_env "OPTIMAL_QDRANT_COLLECTION_PREFIX"
  @serving_env "OPTIMAL_QDRANT_SERVING"

  @type kind :: :contexts | :chunks | :memories

  # ── process ─────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    case validate_config() do
      :ok ->
        :ok

      {:error, {:invalid_prefix, _}} ->
        raise ArgumentError,
              "#{@prefix_env} must be lower case letters, digits, _ and - (at most 64, " <>
                "starting with a letter or digit); unset it to use this Engine's own prefix"
    end

    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Removals recorded before a restart are retried once the Engine is up.
    {:ok, %{retry: Process.send_after(self(), :retry_pending, Removals.retry_interval())}}
  end

  @impl GenServer
  def handle_cast({:mirror, kind, keys}, state) do
    apply_mirror(kind, keys)
    {:noreply, state}
  end

  def handle_cast({:removal, id}, state) do
    Removals.apply_one(id)
    {:noreply, state}
  end

  def handle_cast(:schedule_retry, state), do: {:noreply, arm(state)}

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info(:retry_pending, state) do
    state = %{state | retry: nil}

    if configured?() and Removals.pending_count() > 0 and Removals.retry_pending() != :ok,
      do: {:noreply, arm(state)},
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A timer already due within the interval stays; a later one is brought forward.
  defp arm(%{retry: ref} = state) do
    interval = Removals.retry_interval()

    case is_reference(ref) && Process.read_timer(ref) do
      left when is_integer(left) and left <= interval ->
        state

      _ ->
        if is_reference(ref), do: Process.cancel_timer(ref)
        %{state | retry: Process.send_after(self(), :retry_pending, interval)}
    end
  end

  @doc false
  # Hands a removal record to the process; applied in the caller without it.
  def enqueue({:removal, id} = message) do
    case GenServer.whereis(__MODULE__) do
      nil -> Removals.apply_one(id)
      pid -> GenServer.cast(pid, message)
    end

    :ok
  end

  @doc false
  # Arms the retry timer (a removal Qdrant refused).
  def schedule_retry do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :schedule_retry)
    end
  end

  @doc "Waits until every mirror and removal queued before it has been applied."
  @spec flush() :: :ok
  def flush do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, @call_timeout)
    end
  end

  # ── switches and identity ───────────────────────────────────────────────

  @doc "The projected kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The environment variable that turns serving and mirroring off (`off`, `false`, `0`)."
  @spec serving_env_name() :: String.t()
  def serving_env_name, do: @serving_env

  @doc "The environment variable that names the collection prefix."
  @spec prefix_env_name() :: String.t()
  def prefix_env_name, do: @prefix_env

  @doc """
  `:ok`, or `{:error, {:invalid_prefix, value}}` when
  `OPTIMAL_QDRANT_COLLECTION_PREFIX` (or the `:collection_prefix` setting) is
  set to something that is not a valid prefix.
  """
  @spec validate_config() :: :ok | {:error, {:invalid_prefix, String.t()}}
  def validate_config do
    case explicit_prefix() do
      nil -> :ok
      prefix -> if valid_prefix?(prefix), do: :ok, else: {:error, {:invalid_prefix, prefix}}
    end
  end

  @doc """
  Whether a Qdrant URL is configured with a valid prefix and this Engine has
  an identity. Removals (erasure, forget, delete) run whenever this holds,
  serving or not.
  """
  @spec configured?() :: boolean()
  def configured? do
    Qdrant.configured?() and validate_config() == :ok and engine_id() != nil
  end

  @doc """
  Whether the Engine mirrors embeddings to Qdrant and may read from it:
  configured, `OPTIMAL_QDRANT_SERVING` is not `off`, and
  `config :optimal_engine, :qdrant_projection, enabled: false` is not set.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(settings(), :enabled, true) != false and not serving_off?() and configured?()
  end

  @doc "This Engine's id in every payload and filter: its replica id, or nil when the store has none."
  @spec engine_id() :: String.t() | nil
  def engine_id do
    case lookup(:engine_id) do
      {_, id} ->
        id

      nil ->
        id =
          case Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", []) do
            {:ok, [[id]]} when is_binary(id) and id != "" -> id
            _ -> nil
          end

        if id, do: store(:engine_id, :infinity, id)
        id
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  The collection prefix: `OPTIMAL_QDRANT_COLLECTION_PREFIX` when set and
  valid, otherwise `oe_` and the hex of this Engine's replica id. Nil when the
  prefix set is invalid or the Engine has no identity.
  """
  @spec prefix() :: String.t() | nil
  def prefix do
    case explicit_prefix() do
      nil ->
        case engine_id() do
          nil -> nil
          id -> "oe_" <> (id |> String.replace_prefix("rep_", "") |> String.downcase())
        end

      explicit ->
        if valid_prefix?(explicit), do: explicit
    end
  end

  defp explicit_prefix do
    value = System.get_env(@prefix_env) || Keyword.get(settings(), :collection_prefix)

    case value && String.trim(to_string(value)) do
      nil -> nil
      "" -> nil
      prefix -> prefix
    end
  end

  defp valid_prefix?(prefix), do: Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, prefix)

  @doc "The collection that holds `kind` at `dims` dimensions."
  @spec collection(kind(), pos_integer()) :: String.t()
  def collection(kind, dims) when kind in @kinds and is_integer(dims),
    do: "#{prefix()}_#{kind}_#{dims}"

  @doc "The payload field that carries the Engine id of a kind's row."
  @spec id_field(kind()) :: String.t()
  def id_field(:contexts), do: "context_id"
  def id_field(:chunks), do: "chunk_id"
  def id_field(:memories), do: "memory_id"

  @doc false
  def timeout, do: Keyword.get(settings(), :timeout, @default_timeout)

  defp settings, do: Application.get_env(:optimal_engine, :qdrant_projection, [])

  defp serving_off? do
    case System.get_env(@serving_env) do
      nil -> false
      value -> String.downcase(String.trim(value)) in @off
    end
  end

  # ── ids ─────────────────────────────────────────────────────────────────

  @doc """
  The Qdrant point id of an Engine row: a UUID from SHA-256 of the kind and
  the key. A memory's key is `{memory_id, model}`.
  """
  @spec point_id(kind(), String.t() | {String.t(), String.t()}) :: String.t()
  def point_id(:memories, {memory_id, model}), do: uuid("memories\0#{memory_id}\0#{model}")
  def point_id(kind, key) when kind in @kinds and is_binary(key), do: uuid("#{kind}\0#{key}")

  defp uuid(text) do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6, _::binary>> =
      :crypto.hash(:sha256, text)

    [a, b, c, d, e] |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.join("-")
  end

  # ── writes ──────────────────────────────────────────────────────────────

  @doc """
  Queues a mirror of the rows of `keys` (context ids, chunk ids, or
  `{memory_id, model}`) and returns at once. `:workspace_id` names the
  workspace, which is marked dirty if the mirror has to be dropped (past
  `:max_queue` queued); without it every active workspace is. `:ok` and
  nothing queued when the projection is off.
  """
  @spec mirror(kind(), [term()], keyword()) :: :ok
  def mirror(kind, keys, opts \\ [])
  def mirror(_kind, [], _opts), do: :ok

  def mirror(kind, keys, opts) when kind in @kinds and is_list(keys) do
    if enabled?() do
      case GenServer.whereis(__MODULE__) do
        nil ->
          apply_mirror(kind, keys)

        pid ->
          if queue_length(pid) < Keyword.get(settings(), :max_queue, @max_queue) do
            GenServer.cast(pid, {:mirror, kind, keys})
          else
            count(:dropped, length(keys))
            Gate.mark_dirty(Keyword.get(opts, :workspace_id) || :all)
          end
      end
    end

    :ok
  end

  defp queue_length(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  defp apply_mirror(kind, keys) do
    if enabled?() do
      case rows_for_keys(kind, keys) do
        {:ok, rows} -> upsert_rows(kind, rows)
        {:error, reason} -> failed(:mirror, reason, [:all])
      end
    else
      :ok
    end
  rescue
    error -> failed(:mirror, {:raised, Exception.message(error)}, [:all])
  end

  @doc """
  Upserts store rows (as `rows_for_keys/2` and the sync read them) to their
  collections. Returns `:ok` or the first failure, which marks the rows'
  workspaces dirty.
  """
  @spec upsert_rows(kind(), [list()]) :: :ok | {:error, term()}
  def upsert_rows(_kind, []), do: :ok

  def upsert_rows(kind, rows) do
    points = Enum.flat_map(rows, &point(kind, &1))
    workspaces = points |> Enum.map(fn {_dims, p} -> p.payload["workspace_id"] end) |> Enum.uniq()

    if Gate.healthy?() do
      result =
        points
        |> Enum.group_by(fn {dims, _} -> dims end, fn {_, p} -> p end)
        |> Enum.reduce_while(:ok, fn {dims, group}, :ok ->
          case upsert(collection(kind, dims), dims, group) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case result do
        :ok ->
          count(:upserted, length(points))
          :ok

        {:error, reason} ->
          failed(:upsert, reason, workspaces)
      end
    else
      failed(:upsert, :qdrant_unhealthy, workspaces)
    end
  end

  @doc """
  Records the durable removal of this Engine's points of `kind` whose payload
  `field` is one of `values` (`OptimalEngine.Storage.Qdrant.Removals.remove/4`).
  """
  defdelegate remove(kind, field, values, opts \\ []), to: Removals

  @doc """
  The durable removal of a memory's points, of every model: recorded, applied
  in order, retried until Qdrant takes it. For a memory forgotten, superseded,
  deleted or erased; call it after its rows are gone or no longer searchable.
  """
  @spec remove_memory(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_memory(memory_id, opts \\ []) when is_binary(memory_id),
    do: Removals.remove(:memories, "memory_id", [memory_id], opts)

  @doc "The durable removal of this Engine's points of a workspace, of every kind, serving or not."
  @spec remove_workspace(String.t()) :: :ok | {:error, term()}
  def remove_workspace(workspace_id) when is_binary(workspace_id) do
    Gate.invalidate(workspace_id)

    Enum.reduce(@kinds, :ok, fn kind, acc ->
      case Removals.remove(kind, "workspace_id", [workspace_id], workspace_id: workspace_id) do
        :ok -> acc
        error -> error
      end
    end)
  end

  defdelegate erase_contexts(context_ids, tenant_id), to: Removals
  defdelegate erased_contexts(context_ids, tenant_id), to: Removals
  defdelegate retry_pending(), to: Removals

  @doc "Deletes points by id from one collection."
  @spec delete_points(String.t(), [String.t()]) :: :ok | {:error, term()}
  def delete_points(_collection, []), do: :ok

  def delete_points(collection, ids) do
    case request(:post, "/collections/#{collection}/points/delete?wait=true", %{points: ids}) do
      {:ok, status, _} when status in [200, 404] ->
        count(:deleted, length(ids))
        :ok

      other ->
        {:error, failure(other)}
    end
  end

  @doc false
  # Deletes this Engine's points of a kind matching every condition, in every
  # collection of the kind.
  @spec delete_where(kind(), [map()]) :: :ok | {:error, term()}
  def delete_where(kind, conditions) do
    filter = owned(conditions)

    with {:ok, names} <- collections(kind) do
      Enum.reduce(names, :ok, fn name, acc ->
        case request(:post, "/collections/#{name}/points/delete?wait=true", %{filter: filter}) do
          {:ok, status, _} when status in [200, 404] ->
            acc

          other ->
            reason = failure(other)
            Logger.warning("[Qdrant] delete in #{name} failed: #{inspect(reason)}")
            {:error, reason}
        end
      end)
    end
  end

  # Every filter this Engine sends is limited to its own points.
  defp owned(conditions),
    do: %{must: [%{key: "engine_id", match: %{value: engine_id()}} | conditions]}

  @doc "The collections of a kind under this Engine's prefix, sorted."
  @spec collections(kind()) :: {:ok, [String.t()]} | {:error, term()}
  def collections(kind) do
    lead = "#{prefix()}_#{kind}_"

    case request(:get, "/collections", nil) do
      {:ok, 200, %{"result" => %{"collections" => list}}} ->
        names =
          for %{"name" => name} <- list,
              String.starts_with?(name, lead),
              dims_of(name, lead) != nil,
              do: name

        {:ok, Enum.sort(names)}

      other ->
        {:error, failure(other)}
    end
  end

  @doc "The dimension a collection name carries, or nil."
  @spec dims(String.t()) :: pos_integer() | nil
  def dims(collection) do
    case collection |> String.split("_") |> List.last() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp dims_of(name, lead) do
    case name |> String.replace_prefix(lead, "") |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp upsert(collection, dims, points) do
    with :ok <- ensure_collection(collection, dims) do
      points
      |> Enum.chunk_every(@upsert_batch)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        case put_points(collection, dims, batch, true) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp put_points(collection, dims, batch, retry?) do
    body = %{points: Enum.map(batch, &%{id: &1.id, vector: &1.vector, payload: &1.payload})}

    case request(:put, "/collections/#{collection}/points?wait=true", body) do
      {:ok, 200, _} ->
        :ok

      # The collection went away under us (deleted by hand): create it again once.
      {:ok, 404, _} when retry? ->
        forget(collection)

        with :ok <- ensure_collection(collection, dims),
             do: put_points(collection, dims, batch, false)

      other ->
        {:error, failure(other)}
    end
  end

  @doc false
  @spec ensure_collection(String.t(), pos_integer()) :: :ok | {:error, term()}
  def ensure_collection(collection, dims) do
    if known?(collection) do
      :ok
    else
      result =
        case request(:get, "/collections/#{collection}", nil) do
          {:ok, 200, _} -> :ok
          {:ok, 404, _} -> create(collection, dims)
          other -> {:error, failure(other)}
        end

      if result == :ok, do: remember(collection)
      result
    end
  end

  defp create(collection, dims) do
    case request(:put, "/collections/#{collection}", %{
           vectors: %{size: dims, distance: "Cosine"}
         }) do
      # 409: another writer created it first.
      {:ok, status, _} when status in [200, 409] ->
        index_fields(collection)

      other ->
        {:error, failure(other)}
    end
  end

  # The filters stay fast on a large collection with a keyword index on each
  # field they read. An index that cannot be made is logged, not fatal: the
  # filter still answers, only slower.
  defp index_fields(collection) do
    for field <- ~w(engine_id workspace_id tenant_id context_id chunk_id memory_id model) do
      case request(:put, "/collections/#{collection}/index?wait=true", %{
             field_name: field,
             field_schema: "keyword"
           }) do
        {:ok, 200, _} -> :ok
        other -> Logger.info("[Qdrant] index #{field} on #{collection}: #{inspect(failure(other))}")
      end
    end

    :ok
  end

  # ── store rows ──────────────────────────────────────────────────────────

  @doc """
  The rows of a kind that search can read, in the column order `point/2`
  reads: `[key, blob, tenant_id, workspace_id | extra]`. A vector without its
  context, a chunk embedding without its chunk, the embedding of a memory that
  is superseded or forgotten, and every row of an archived workspace are not
  among them (`from_sql/1`), so they are neither mirrored nor counted, and the
  sync removes their points.
  """
  @spec select_sql(kind()) :: String.t()
  def select_sql(:contexts),
    do: "SELECT v.context_id, v.embedding, v.tenant_id, c.workspace_id " <> from_sql(:contexts)

  def select_sql(:chunks),
    do:
      "SELECT ce.chunk_id, ce.vector, ce.tenant_id, ce.workspace_id, ce.model, ch.signal_id, ch.scale " <>
        from_sql(:chunks)

  def select_sql(:memories),
    do:
      "SELECT me.memory_id, me.embedding, me.tenant_id, me.workspace_id, me.model " <>
        from_sql(:memories)

  @doc false
  # The searchable rows of a kind, with no WHERE clause, so a caller can add one.
  @spec from_sql(kind()) :: String.t()
  def from_sql(:contexts),
    do:
      "FROM vectors v JOIN contexts c ON c.id = v.context_id AND " <> not_archived("c.workspace_id")

  def from_sql(:chunks),
    do:
      "FROM chunk_embeddings ce JOIN chunks ch ON ch.id = ce.chunk_id AND " <>
        not_archived("ce.workspace_id")

  def from_sql(:memories),
    do:
      "FROM memory_embeddings me JOIN memories m " <>
        "ON m.id = me.memory_id AND m.is_latest = 1 AND m.is_forgotten = 0 AND " <>
        not_archived("me.workspace_id")

  defp not_archived(column),
    do: "NOT EXISTS (SELECT 1 FROM workspaces w WHERE w.id = #{column} AND w.status = 'archived')"

  @doc false
  @spec key_column(kind()) :: String.t()
  def key_column(:contexts), do: "v.context_id"
  def key_column(:chunks), do: "ce.chunk_id"
  def key_column(:memories), do: "me.memory_id"

  @doc false
  @spec workspace_column(kind()) :: String.t()
  def workspace_column(:contexts), do: "c.workspace_id"
  def workspace_column(:chunks), do: "ce.workspace_id"
  def workspace_column(:memories), do: "me.workspace_id"

  @doc "The searchable rows of `keys` (`select_sql/1`)."
  @spec rows_for_keys(kind(), [term()]) :: {:ok, [list()]} | {:error, term()}
  def rows_for_keys(:memories, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn {memory_id, model}, {:ok, acc} ->
      case Store.raw_query(
             select_sql(:memories) <> " WHERE me.memory_id = ?1 AND me.model = ?2",
             [memory_id, model]
           ) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def rows_for_keys(kind, keys) when kind in [:contexts, :chunks] do
    keys
    |> Enum.uniq()
    |> Enum.chunk_every(@key_batch)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"?#{&1}")
      sql = select_sql(kind) <> " WHERE #{key_column(kind)} IN (#{placeholders})"

      case Store.raw_query(sql, batch) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The point a store row becomes, with its dimension: `[{dims, point}]`, or
  `[]` for a row with no workspace or whose vector is empty or not whole
  float32 values. Such a row is not counted either (`in_sync?/2` counts by
  workspace).
  """
  @spec point(kind(), list()) :: [{pos_integer(), map()}]
  def point(kind, [key, blob, tenant, workspace | extra])
      when is_binary(blob) and is_binary(workspace) do
    case decode(blob) do
      [] ->
        []

      vector ->
        payload =
          %{
            "engine_id" => engine_id(),
            "tenant_id" => tenant || "default",
            "workspace_id" => workspace
          }
          |> Map.merge(payload(kind, key, extra))

        [
          {length(vector),
           %{id: point_id(kind, point_key(kind, key, extra)), vector: vector, payload: payload}}
        ]
    end
  end

  def point(_kind, _row), do: []

  defp point_key(:memories, memory_id, [model]), do: {memory_id, model}
  defp point_key(_kind, key, _extra), do: key

  defp payload(:contexts, id, _), do: %{"context_id" => id}

  defp payload(:chunks, id, [model, context_id, scale]),
    do: %{"chunk_id" => id, "model" => model, "context_id" => context_id, "scale" => scale}

  defp payload(:memories, id, [model]), do: %{"memory_id" => id, "model" => model}

  defp decode(blob) when rem(byte_size(blob), 4) == 0 do
    for <<value::float-little-32 <- blob>>, do: value
  rescue
    _ -> []
  end

  defp decode(_blob), do: []

  # ── health, dirt and the count comparison (OptimalEngine.Storage.Qdrant.Gate) ──

  defdelegate healthy?(), to: Gate
  defdelegate mark_unhealthy(reason), to: Gate
  defdelegate reset_health(), to: Gate
  defdelegate stamp(), to: Gate
  defdelegate dirty?(workspace_id), to: Gate
  defdelegate mark_dirty(workspace_id), to: Gate
  defdelegate clear_dirty(workspace_id, started), to: Gate
  defdelegate in_sync?(kind, scope), to: Gate
  defdelegate invalidate(workspace_id), to: Gate
  defdelegate invalidate_all(), to: Gate
  defdelegate remote_count(collection, scope), to: Gate

  @doc "A Qdrant filter for this Engine's points that match every field of `scope`."
  @spec filter(map()) :: map()
  def filter(scope) do
    scope
    |> Enum.sort()
    |> Enum.map(fn {field, value} -> %{key: to_string(field), match: %{value: value}} end)
    |> owned()
  end

  # ── status ──────────────────────────────────────────────────────────────

  @doc """
  What the projection is doing, for the provider inventory: whether it is
  enabled, the collection prefix, a configuration error, the cached health
  (`unknown` before the first check), the workspaces marked dirty, the
  counters since boot, and the class of the last error. Nothing here carries
  the URL or the key.
  """
  @spec status() :: map()
  def status do
    health =
      case lookup(:health) do
        {_expires, true} -> "healthy"
        {_expires, false} -> "unreachable"
        _ -> "unknown"
      end

    %{
      enabled: enabled?(),
      collection_prefix: prefix(),
      config_error:
        case validate_config() do
          :ok -> if engine_id(), do: nil, else: "no_engine_identity"
          {:error, {reason, _}} -> Atom.to_string(reason)
        end,
      reads: "vector search (contexts) and durable memory search, verified against SQLite",
      health: health,
      dirty_workspaces: Gate.dirty_count(),
      pending_removals: Removals.pending_count(),
      counters:
        Map.new(
          ~w(upserted deleted dropped write_failures searches_served searches_fallback drift)a,
          &{&1, counter(&1)}
        ),
      last_error:
        case lookup(:last_error) do
          {_, value} -> value
          _ -> nil
        end
    }
  end

  @doc false
  def count(name, by) do
    if table?(), do: :ets.update_counter(@table, {:counter, name}, by, {{:counter, name}, 0})
    :ok
  rescue
    _ -> :ok
  end

  defp counter(name) do
    case table?() && :ets.lookup(@table, {:counter, name}) do
      [{_, n}] -> n
      _ -> 0
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  @doc false
  def request(method, path, body),
    do: Qdrant.request(method, path, body, timeout: timeout())

  defp failed(stage, reason, workspaces) do
    count(:write_failures, 1)
    store(:last_error, :infinity, error_class(reason))
    if reason != :qdrant_unhealthy, do: Gate.mark_unhealthy(reason)
    Enum.each(workspaces, &Gate.mark_dirty/1)
    Logger.warning("[Qdrant] #{stage} failed: #{inspect(error_class(reason))}")
    {:error, reason}
  end

  @doc false
  def failure({:ok, status, body}), do: {:status, status, summary(body)}
  def failure({:error, reason}), do: reason
  def failure(other), do: other

  defp summary(%{"status" => %{"error" => error}}) when is_binary(error),
    do: String.slice(error, 0, 120)

  defp summary(_), do: nil

  @doc false
  def error_class({:status, status, _}), do: "status_#{status}"
  def error_class({:unreachable, class}) when is_atom(class), do: "unreachable_#{class}"
  def error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  def error_class(_), do: "error"

  defp known?(collection), do: lookup({:collection, collection}) != nil
  defp remember(collection), do: store({:collection, collection}, :infinity, true)

  defp forget(collection) do
    if table?(), do: :ets.delete(@table, {:collection, collection})
    :ok
  end

  @doc false
  def reset do
    flush()
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  def lookup(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{^key, expires, value}] -> {expires, value}
        _ -> nil
      end
    end
  end

  @doc false
  def store(key, expires, value) do
    if table?(), do: :ets.insert(@table, {key, expires, value})
    :ok
  end

  @doc false
  def delete_key(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc false
  def match(pattern), do: if(table?(), do: :ets.match_object(@table, pattern), else: [])

  @doc false
  def match_delete(pattern) do
    if table?(), do: :ets.match_delete(@table, pattern)
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end
