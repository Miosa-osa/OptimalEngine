defmodule OptimalEngine.Sync.Gate.StoreError do
  @moduledoc """
  The gate could not read the Store while classifying. It is raised, never
  turned into an answer: a push sends nothing, and a request that filters by
  the gate is refused with 503 (`plug_status`).
  """
  defexception [:message, plug_status: 503]
end

defmodule OptimalEngine.Sync.Gate do
  @moduledoc """
  What leaves this Engine, and what a reader may see, when the row it comes
  from is classified by more than its own columns.

  Classification is not only a row's own `security_labels`: a row copied or
  derived from a labelled row carries its source's labels (see
  `OptimalEngine.Sync.Lineage`), so a versioned memory staged from a
  restricted source package, the chunks and vectors of a restricted
  document, and a wiki page citing either are as classified as the source.
  The gate walks that lineage and collects every label and partition a row
  carries, itself or through its sources, as a set of tokens. Two decisions
  are made from the tokens.

  ## Replication (`open/3`)

  A peer is cleared up to a `max_class` (`public`, `internal`,
  `confidential`, `restricted`). A change whose tokens name a class above it
  is not sent. Sending is fail-closed. A row stays home when

    * its own labels, or those of any row it derives from, are above the
      peer's class;
    * a row it must derive from (a source package, a claim) cannot be found,
      or its lineage is deeper than 40 hops;
    * its table is not in the lineage map;
    * it is an aggregate (`analysis_reports`) and the workspace holds
      anything above the peer's class.

  A change is held at the higher of the row as the ledger recorded it and the
  row as it is stored now, so an older version of a row that has labels today
  stays home with it.

  A Store error while classifying is not an answer: it raises, the push
  cycle sends nothing and its cursor stays where it was, so the next cycle
  classifies the same rows again. A workspace whose data class is not one of
  the four is treated as `restricted`.

  Receiving reads only what a row carries (labels, metadata labels,
  classification level, BLOB columns included): the sender's rows arrive in
  batches, so their sources may not be here yet. Sender and receiver gate
  the same way on what they can see.

  Classification is read when a row is sent. A source package that arrives
  after the rows derived from it, or a label lowered on the source, does not
  release rows already held: those rows were never sent and stay home until
  a change to them (or to what they derive from) is captured again.

  Deleting is the exception to fail-closed: a delete carries only the row's
  key, so it is held only when the row's earlier changes in the local ledger
  were classified above the class (the peer never had it).

  ## Reading (`open_reader/3`)

  A reader holds grants: the labels it may see and the partitions it may see
  (`SecurityLabels.grants/2`). It sees a row by the rule governed retrieval
  applies to Memory Core objects (`SecurityLabels.permits?/2`): every label the
  row carries must be granted, so with no grants only what carries nothing is
  seen; with partitions granted only rows that share one are seen, and rows
  with none are not. A row drawn from other rows must share a partition with
  each of them that has any, not just with one of them. A row that cannot be resolved carries the `unresolved`
  token, which no grant names, so it is read by no one; a grant of `"*"` is
  the exception. An aggregate carries every label in its workspace and needs
  every partition of it.

  The rows a reader asks about are read a chunk of 500 at a time
  (`readable_ids/3`), with the rows they link to, instead of one by one.

  Reading what a row derives from has a budget: a row that reaches more than
  10,000 rows that the gate has not read before (a dense mesh of links that
  cycles back on itself, where the result of a row cannot be kept because it
  depends on the path that led to it) is `unresolved`, so it is held from a
  peer and read by no one, instead of being walked path by path.

  A gate is opened for one pass (one push cycle, one served page, one
  export) and closed: it caches what it reads from the Store for the pass
  and builds, on first use, an index of the documents, memories and entities
  derived from labelled sources.
  """

  require Logger

  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.{GateCache, Lineage}

  @internal 1
  @restricted 3
  @max_depth 40
  @chunk 500
  @node_budget 10_000

  defstruct [:tenant_id, :workspace_id, :rank, :memo, :mode, :allowed]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          workspace_id: String.t(),
          rank: non_neg_integer(),
          memo: :ets.tid(),
          mode: :class | :grants,
          allowed: SecurityLabels.grants() | nil
        }

  @typep tokens :: MapSet.t(SecurityLabels.token()) | nil

  # -- opening ------------------------------------------------------------------

  @doc "Opens a gate for a workspace and the highest class a peer may hold."
  @spec open(String.t(), String.t(), String.t()) :: t()
  def open(tenant_id, workspace_id, max_class) do
    %__MODULE__{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      rank: class_rank(max_class),
      memo: :ets.new(:sync_gate, [:set, :private]),
      mode: :class
    }
  end

  @doc """
  Opens a gate for a reader of a workspace. `allowed` is the reader's grants
  (`SecurityLabels.grants/2`).
  """
  @spec open_reader(String.t(), String.t(), SecurityLabels.grants(), SecurityLabels.rank() | nil) ::
          t()
  def open_reader(tenant_id, workspace_id, %{labels: _, partitions: _} = allowed, ceiling \\ nil) do
    %__MODULE__{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      rank: ceiling || @restricted,
      memo: :ets.new(:sync_gate, [:set, :private]),
      mode: :grants,
      allowed: allowed
    }
  end

  @doc "Closes a gate and drops what it cached."
  @spec close(t()) :: :ok
  def close(%__MODULE__{memo: memo}) do
    :ets.delete(memo)
    :ok
  end

  @doc "Runs `fun` with a gate, closing it after."
  @spec with_gate(String.t(), String.t(), String.t(), (t() -> result)) :: result
        when result: var
  def with_gate(tenant_id, workspace_id, max_class, fun) do
    run(open(tenant_id, workspace_id, max_class), fun)
  end

  @doc """
  Runs `fun` with a reader's gate, closing it after. A `ceiling` (a class rank)
  is the highest class the reader is shown, unless its grants include every
  label.
  """
  @spec with_reader(
          String.t(),
          String.t(),
          SecurityLabels.grants(),
          SecurityLabels.rank() | nil,
          (t() -> result)
        ) :: result
        when result: var
  def with_reader(tenant_id, workspace_id, allowed, ceiling \\ nil, fun) do
    run(open_reader(tenant_id, workspace_id, allowed, ceiling), fun)
  end

  defp run(gate, fun) do
    fun.(gate)
  after
    close(gate)
  end

  @doc "The rank of a class name; a name that is no class ranks as `internal`."
  @spec class_rank(term()) :: non_neg_integer()
  def class_rank(class), do: SecurityLabels.class_rank(class) || 1

  @doc """
  The class rank of a workspace's own data: its `data_class`; `internal` when
  it names none or the workspace is not there; `restricted` when it names a
  class this Engine does not know. A Store error is raised: a workspace that
  cannot be read is not assumed to be open.
  """
  @spec workspace_rank(String.t()) :: SecurityLabels.rank()
  def workspace_rank(workspace_id) do
    case OptimalEngine.Workspace.get(workspace_id) do
      {:ok, %{metadata: %{"data_class" => class}}} when class in [nil, ""] ->
        @internal

      {:ok, %{metadata: %{"data_class" => class}}} ->
        SecurityLabels.class_rank(class) || @restricted

      {:ok, _workspace} ->
        @internal

      {:error, :not_found} ->
        @internal

      other ->
        raise OptimalEngine.Sync.Gate.StoreError,
          message: "the sync gate could not read the workspace: #{inspect(other)}"
    end
  end

  @doc "True when the workspace's own data class is above the gate."
  @spec workspace_above?(t()) :: boolean()
  def workspace_above?(%__MODULE__{workspace_id: workspace_id, rank: rank}),
    do: workspace_rank(workspace_id) > rank

  # -- sending ------------------------------------------------------------------

  @doc "True when the mutation must stay on this Engine."
  @spec hold?(t(), map()) :: boolean()
  def hold?(%__MODULE__{mode: :class, rank: rank}, _mutation) when rank >= @restricted, do: false

  def hold?(%__MODULE__{mode: :class, rank: gate_rank} = gate, mutation) do
    case mutation_rank(gate, mutation) do
      nil -> false
      rank -> rank > gate_rank
    end
  end

  @doc """
  `hold?/2` for a ledger that callers may also append to
  (`OptimalEngine.Storage.PolicyStore`): a mutation of an entity type that
  is not a replicated table has no lineage (no row of ours is behind it), so
  it is held only by the labels of the row it carries itself, if it carries
  one.
  """
  @spec hold_known?(t(), map()) :: boolean()
  def hold_known?(%__MODULE__{} = gate, mutation) do
    case Lineage.spec(mutation["entity_type"]) do
      nil -> unknown_held?(gate, mutation)
      _spec -> hold?(gate, mutation)
    end
  end

  @doc """
  The class rank a mutation is held at: nil when nothing classifies it,
  otherwise 0..3. For tests and audits; `hold?/2` is the gate.
  """
  @spec mutation_rank(t(), map()) :: SecurityLabels.rank() | nil
  def mutation_rank(%__MODULE__{} = gate, mutation),
    do: gate |> mutation_tokens(mutation) |> SecurityLabels.token_rank()

  # -- receiving ----------------------------------------------------------------

  @doc """
  True when a received mutation carries a class above `max_class`: its own
  labels, its metadata labels or its classification level. Sources are not
  looked up (see the moduledoc).
  """
  @spec held_on_receive?(map(), String.t()) :: boolean()
  def held_on_receive?(mutation, max_class) do
    row = mutation_row(mutation)

    rank =
      case Lineage.spec(mutation["entity_type"]) do
        nil -> SecurityLabels.rank(row["security_labels"])
        spec -> Lineage.own_rank(spec, row)
      end

    rank != nil and rank > class_rank(max_class)
  end

  # -- reading ------------------------------------------------------------------

  @doc """
  True when the reader may see a row of `table` given as a map with string
  keys (the columns of the row, as a replicated change carries them).
  """
  @spec readable_row?(t(), String.t(), map()) :: boolean()
  def readable_row?(%__MODULE__{mode: :grants} = gate, table, row) do
    case Lineage.spec(table) do
      nil -> false
      spec -> readable?(gate, top_tokens(gate, table, spec, row, true))
    end
  end

  @doc "True when the reader may see the row of `table` with this id."
  @spec readable_id?(t(), String.t(), String.t() | nil) :: boolean()
  def readable_id?(%__MODULE__{mode: :grants}, _table, nil), do: false

  def readable_id?(%__MODULE__{mode: :grants} = gate, table, id) do
    reset_budget(gate)
    readable?(gate, ref_tokens(gate, {:row, table, id}, MapSet.new(), true))
  end

  @doc """
  The ids among `ids` of rows the reader may see, when the table of each is
  not known (a search result is a document or a memory). The tables are found
  a chunk at a time; an id that is in none of them is read by no one.
  """
  @spec readable_any_ids(t(), [String.t() | nil]) :: MapSet.t(String.t())
  def readable_any_ids(%__MODULE__{mode: :grants} = gate, ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      tables = resolve_any(gate, chunk)

      prefetch(
        gate,
        tables |> Enum.group_by(&elem(&1, 1), &elem(&1, 0)) |> Enum.to_list(),
        0
      )

      for {id, table} <- tables, readable_id?(gate, table, id), do: id
    end)
    |> MapSet.new()
  end

  @doc """
  True when the row of `table` with this id is gone, or the reader may see it.
  A record of a change to a row that has since been deleted is judged by the
  record alone; one whose row is still there needs the row as well.
  """
  @spec readable_or_gone?(t(), String.t(), String.t() | nil) :: boolean()
  def readable_or_gone?(%__MODULE__{mode: :grants} = gate, table, id) do
    case Lineage.spec(table) do
      %{key: key} = spec when is_binary(key) and is_binary(id) ->
        load(gate, table, spec, id) == nil or readable_id?(gate, table, id)

      _ ->
        readable_id?(gate, table, id)
    end
  end

  @doc """
  The ids among `ids` of rows of `table` the reader may see. The rows, and
  every row they link to, are read a chunk of 500 at a time (`WHERE key IN`)
  before they are classified, instead of one query per row.
  """
  @spec readable_ids(t(), String.t(), [String.t() | nil]) :: MapSet.t(String.t())
  def readable_ids(%__MODULE__{mode: :grants} = gate, table, ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      prefetch(gate, [{table, chunk}], 0)
      Enum.filter(chunk, &readable_id?(gate, table, &1))
    end)
    |> MapSet.new()
  end

  @doc """
  True when the reader may see what a change carries: a row as a replicated
  change holds it (`entity_type`, `entity_id`, `operation`, `payload`).
  """
  @spec readable_mutation?(t(), map()) :: boolean()
  def readable_mutation?(%__MODULE__{mode: :grants} = gate, mutation),
    do: readable?(gate, mutation_tokens(gate, mutation))

  @doc """
  `readable_mutation?/2` for a ledger that callers may also append to: a change
  of an entity type that is not a replicated table is not governed by lineage
  (no row of ours is behind it), but a row it carries names its own labels and
  partitions, and those are judged.
  """
  @spec readable_known?(t(), map()) :: boolean()
  def readable_known?(%__MODULE__{mode: :grants} = gate, mutation) do
    case Lineage.spec(mutation["entity_type"]) do
      nil ->
        case unknown_tokens(mutation) do
          [] -> true
          tokens -> readable?(gate, MapSet.new(tokens))
        end

      _spec ->
        readable_mutation?(gate, mutation)
    end
  end

  # The labels and partitions of the row an entry of an unknown entity type
  # carries, in its own columns or its metadata; none for an entry that carries
  # no row.
  defp unknown_tokens(%{"payload" => %{"row" => %{} = row}}) do
    [
      Map.has_key?(row, "security_labels") && SecurityLabels.tokens(row["security_labels"]),
      Map.has_key?(row, "partition_ids") && SecurityLabels.partition_tokens(row["partition_ids"]),
      Map.has_key?(row, "metadata") && SecurityLabels.metadata_tokens(row["metadata"])
    ]
    |> Enum.flat_map(&(&1 || []))
  end

  defp unknown_tokens(_mutation), do: []

  defp unknown_held?(%__MODULE__{mode: :class, rank: rank}, _mutation) when rank >= @restricted,
    do: false

  defp unknown_held?(%__MODULE__{rank: gate_rank}, mutation) do
    case mutation |> unknown_tokens() |> MapSet.new() |> SecurityLabels.token_rank() do
      nil -> false
      rank -> rank > gate_rank
    end
  end

  @doc """
  Reads what these rows of `table` (maps with string keys, the columns of the
  row) link to, a chunk of 500 at a time, so that classifying them one by one
  finds each of those rows in the gate's cache instead of reading it with a
  query of its own. A wiki page also has its citations read for a chunk of
  pages at once.
  """
  @spec prefetch_rows(t(), String.t(), [map()]) :: :ok
  def prefetch_rows(%__MODULE__{mode: :grants} = gate, table, rows) do
    case Lineage.spec(table) do
      nil ->
        :ok

      spec ->
        rows
        |> Enum.chunk_every(@chunk)
        |> Enum.each(fn chunk ->
          if :wiki_page in spec.special, do: load_citations(gate, chunk)

          chunk
          |> Enum.flat_map(fn row ->
            Lineage.refs(spec, row) ++
              if(:wiki_page in spec.special, do: wiki_refs(gate, row), else: [])
          end)
          |> prefetch_refs(gate, 0)
        end)
    end
  end

  @doc """
  `prefetch_rows/3` for the changes of a ledger (`entity_type`, `operation`,
  `payload`): the rows they carry, by table.
  """
  @spec prefetch_mutations(t(), [map()]) :: :ok
  def prefetch_mutations(%__MODULE__{mode: :grants} = gate, mutations) do
    mutations
    |> Enum.filter(&(&1["operation"] != "delete"))
    |> Enum.group_by(& &1["entity_type"], &mutation_row/1)
    |> Enum.each(fn {table, rows} ->
      if is_binary(table), do: prefetch_rows(gate, table, Enum.reject(rows, &(&1 == %{})))
    end)
  end

  defp readable?(%__MODULE__{allowed: allowed, rank: ceiling}, tokens) do
    SecurityLabels.permits?(allowed, tokens) and
      (allowed.all_labels? or ceiling >= @restricted or
         SecurityLabels.token_rank(tokens) in [nil | Enum.to_list(0..ceiling)])
  end

  # -- classifying a row --------------------------------------------------------

  @spec mutation_tokens(t(), map()) :: tokens()
  defp mutation_tokens(gate, mutation) do
    table = mutation["entity_type"]

    case Lineage.spec(table) do
      nil ->
        unclassified(gate, table)
        unresolved()

      spec ->
        cond do
          mutation["operation"] == "delete" ->
            history_tokens(gate, table, spec, mutation)

          # A reader is not shown what cannot be read as a row.
          gate.mode == :grants and not match?(%{"payload" => %{"row" => %{}}}, mutation) ->
            unresolved()

          true ->
            change_tokens(gate, table, spec, mutation_row(mutation))
        end
    end
  end

  # A change in the ledger is a snapshot of the row as it was written, and the
  # row may carry labels it did not have then (labelled afterwards, or a
  # version that arrived unlabelled). The change carries the tokens of the
  # snapshot and of the row as it is stored now. A row that is gone is read as
  # the ledger last recorded it (every version it has there), so a version
  # written before the row was labelled and then deleted stays home with the
  # versions that were labelled.
  defp change_tokens(gate, table, spec, row) do
    union(top_tokens(gate, table, spec, row, true), current_tokens(gate, table, spec, row))
  end

  defp current_tokens(_gate, _table, %{key: nil}, _row), do: nil

  defp current_tokens(gate, table, spec, row) do
    case row[spec.key] do
      id when is_binary(id) ->
        memoized(gate, {:current, table, id}, fn ->
          case load(gate, table, spec, id) do
            nil ->
              case ledger_tokens(gate, table, spec, id) do
                :none -> nil
                tokens -> tokens
              end

            current ->
              row_tokens(gate, spec, current, MapSet.new([{table, id}]), true)
          end
        end)

      _ ->
        nil
    end
  end

  # The row being classified is on the path from the start, so a link back to
  # itself (the root of a version chain is the row itself) is not followed.
  defp top_tokens(gate, table, spec, row, strict) do
    reset_budget(gate)
    classify(gate, table, spec, row, strict)
  end

  # `top_tokens/5` without a new budget: a row read from the ledger in the
  # middle of a classification spends the budget of that classification.
  defp classify(gate, table, spec, row, strict) do
    visiting =
      case row[spec.key] do
        id when is_binary(id) -> MapSet.new([{table, id}])
        _ -> MapSet.new()
      end

    row_tokens(gate, spec, row, visiting, strict)
  end

  # `strict` is false only while reading the earlier changes of a deleted row:
  # a link to a row that is gone is then not doubt, the row is being removed.
  defp row_tokens(gate, spec, row, visiting, strict, skip \\ []) do
    start = Lineage.own_tokens(spec, row)
    self = {:row, spec.table, row[spec.key]}

    # A link to the row itself adds nothing (its own labels are counted) and
    # is no cut: the row does not depend on the path that led to it.
    carried =
      spec
      |> Lineage.refs(row)
      |> Enum.reject(&(&1 == self))
      |> fold_union(gate, start, &ref_tokens(gate, &1, visiting, strict))

    carried =
      if spec.kind == :aggregate,
        do: union(carried, aggregate_tokens(gate)),
        else: carried

    fold_union(
      spec.special -- skip,
      gate,
      carried,
      &special_tokens(gate, &1, row, visiting, strict)
    )
  end

  defp ref_tokens(gate, {:row, table, id}, visiting, strict) do
    cond do
      # A link back onto the path being read is not followed, and neither is
      # one past the depth limit: what is read from here on depends on the
      # path (see `settled/3`).
      MapSet.member?(visiting, {table, id}) ->
        cut(gate)
        nil

      MapSet.size(visiting) >= @max_depth ->
        cut(gate)
        unresolved(strict)

      true ->
        settled(gate, {strict, table, id}, fn ->
          if spend(gate) do
            row_ref(gate, table, id, visiting, strict)
          else
            cut(gate)
            unresolved(strict)
          end
        end)
    end
  end

  # More references than can be followed: not trusted.
  defp ref_tokens(_gate, :overflow, _visiting, strict), do: unresolved(strict)

  defp ref_tokens(gate, {:any, id}, visiting, strict) do
    table = memoized(gate, {:table_of, id}, fn -> find_table(id) end)

    cond do
      is_binary(table) -> ref_tokens(gate, {:row, table, id}, visiting, strict)
      strict -> gone_tokens(gate, id)
      true -> nil
    end
  end

  # An untyped link to an id that is in no table. It may be a row that was
  # deleted (a link outlives the row it names), and the ledger remembers what
  # that row carried; an id the ledger never saw is only text that looks like
  # an id, and names nothing.
  defp gone_tokens(gate, id) do
    settled(gate, {:gone, id}, fn ->
      gate
      |> gone_types(id)
      |> Enum.reduce(nil, fn type, acc ->
        case ledger_tokens(gate, type, Lineage.spec(type), id) do
          :none -> acc
          tokens -> union(acc, tokens)
        end
      end)
    end)
  end

  # The tables the ledger recorded `id` in (among those a link of no stated
  # type can name), read a chunk of ids at a time by `resolve_any/2`. Only
  # changes of a row count, as in `ledger_tokens/4`.
  defp gone_types(gate, id) do
    memoized(gate, {:gone_types, id}, fn ->
      gone_types_of(gate, [id]) |> Map.get(id, [])
    end)
  end

  defp gone_types_of(gate, ids) do
    types = Lineage.any_tables()

    sql =
      "SELECT entity_id, entity_type FROM sync_mutations " <>
        "WHERE tenant_id = ?1 AND workspace_id = ?2 AND operation != 'delete' " <>
        "AND #{OptimalEngine.Sync.change_row_sql()} " <>
        "AND entity_type IN (#{marks(3, length(types))}) " <>
        "AND entity_id IN (#{marks(3 + length(types), length(ids))}) " <>
        "GROUP BY entity_id, entity_type"

    sql
    |> query!([gate.tenant_id, gate.workspace_id] ++ types ++ ids)
    |> Enum.group_by(&hd/1, &List.last/1)
  end

  defp marks(first, count), do: Enum.map_join(first..(first + count - 1), ", ", &"?#{&1}")

  defp row_ref(gate, table, id, visiting, strict) do
    case Lineage.spec(table) do
      nil ->
        unclassified(gate, table)
        unresolved()

      spec ->
        case load(gate, table, spec, id) do
          nil ->
            cond do
              Lineage.anchor?(table) ->
                unresolved(strict)

              # A document or chunk that is gone is still in the ledger as it was;
              # one the ledger never saw cannot be vouched for.
              strict ->
                case ledger_tokens(gate, table, spec, id) do
                  :none -> unresolved()
                  tokens -> tokens
                end

              true ->
                nil
            end

          row ->
            row_tokens(gate, spec, row, MapSet.put(visiting, {table, id}), strict)
        end
    end
  end

  # The tokens of version `id` and of every version behind it. The chain is
  # walked up to a version already known (or the first), then read from the
  # oldest down, so each version is read once per gate.
  defp chain_tokens(gate, id, visiting, strict) do
    spec = Lineage.spec("memories")
    outer = take_cut(gate)
    {versions, below} = chain_up(gate, spec, id, strict, [], MapSet.new())

    {tokens, remembered} =
      Enum.reduce(versions, {below, []}, fn {version_id, row}, {below, remembered} ->
        flat =
          row_tokens(gate, spec, row, MapSet.put(visiting, {"memories", version_id}), strict, [
            :memory_chain
          ])

        tokens = union(below, flat)
        {tokens, [{version_id, tokens} | remembered]}
      end)

    inner = take_cut(gate)

    unless inner,
      do:
        Enum.each(remembered, &:ets.insert(gate.memo, {{:chain, strict, elem(&1, 0)}, elem(&1, 1)}))

    if outer or inner, do: cut(gate)
    tokens
  end

  # The versions from `id` up that are not known yet, oldest first, and the
  # tokens of what is behind them. A parent that is gone cannot be vouched for.
  defp chain_up(gate, spec, id, strict, versions, seen) do
    known = :ets.lookup(gate.memo, {:chain, strict, id})

    cond do
      # A parent loop: what was read on the way round is short of the versions
      # still behind it, so none of it may be remembered.
      MapSet.member?(seen, id) ->
        cut(gate)
        {versions, nil}

      match?([_], known) ->
        {versions, known |> hd() |> elem(1)}

      true ->
        case load(gate, "memories", spec, id) do
          nil ->
            {versions, unresolved(strict)}

          row ->
            versions = [{id, row} | versions]
            seen = MapSet.put(seen, id)

            case row["parent_memory_id"] do
              parent when is_binary(parent) and parent != "" ->
                chain_up(gate, spec, parent, strict, versions, seen)

              _ ->
                {versions, nil}
            end
        end
    end
  end

  defp unresolved(strict \\ true)
  # Something that cannot be found has no labels and no partitions we can read:
  # unresolved on both axes, so a reader of every label but some partitions does
  # not see it either.
  defp unresolved(true),
    do: MapSet.new([SecurityLabels.unresolved(), SecurityLabels.unresolved_partition()])

  defp unresolved(false), do: nil

  # -- rows that are pointed at, not pointing -----------------------------------

  defp special_tokens(gate, :memory_sources, row, _visiting, _strict),
    do: Map.get(index(gate).memories, row["id"])

  defp special_tokens(gate, :context_sources, row, _visiting, _strict),
    do: Map.get(index(gate).contexts, row["id"])

  # The versions a memory was made from, parent after parent up to the first
  # (and the root, which a chain imported from a peer may not reach through its
  # parents). Each is read for what it carries itself and never for its own
  # ancestors, so a long chain costs one read per version, once, and a label
  # that came to an old version by its source package or its pointers (not by
  # value) reaches every later one.
  defp special_tokens(gate, :memory_chain, row, visiting, strict) do
    [row["parent_memory_id"], row["root_memory_id"]]
    |> Enum.filter(&(is_binary(&1) and &1 != "" and &1 != row["id"]))
    |> Enum.uniq()
    |> fold_union(gate, nil, &chain_tokens(gate, &1, visiting, strict))
  end

  # An entity is named in the sources it was resolved from.
  defp special_tokens(gate, :entity_sources, row, _visiting, _strict),
    do: Map.get(index(gate).entities, row["id"])

  # A cluster is named for its members; one with none yet (they are written
  # after it) has no lineage to read.
  defp special_tokens(gate, :cluster_members, row, visiting, strict) do
    case query_column("SELECT chunk_id FROM cluster_members WHERE cluster_id = ?1", [row["id"]]) do
      [] -> aggregate_tokens(gate)
      ids -> fold_union(ids, gate, nil, &ref_tokens(gate, {:row, "chunks", &1}, visiting, strict))
    end
  end

  # A graph edge between two documents follows them; an edge between entity
  # names (co-occurrence) is derived from every document that names them.
  defp special_tokens(gate, :edge, row, _visiting, _strict) do
    if Enum.any?([row["source_id"], row["target_id"]], &context?(gate, &1)),
      do: nil,
      else: aggregate_tokens(gate)
  end

  # A wiki page is written from what it cites: its citations, the object it
  # was projected from, and the `optimal://` addresses in its body. A page
  # that names nothing (or whose citations are not written yet) has no
  # lineage to read.
  defp special_tokens(gate, :wiki_page, row, visiting, strict) do
    case wiki_refs(gate, row) do
      [] -> aggregate_tokens(gate)
      refs -> fold_union(refs, gate, nil, &ref_tokens(gate, &1, visiting, strict))
    end
  end

  defp wiki_refs(gate, row) do
    Enum.map(wiki_citations(gate, row), &{:row, "chunks", &1}) ++
      wiki_source(row["frontmatter"]) ++ Lineage.uri_refs(row["body"])
  end

  defp wiki_citations(gate, row) do
    memoized(gate, wiki_key(row), fn ->
      query_column(
        "SELECT chunk_id FROM citations WHERE tenant_id = ?1 AND wiki_slug = ?2 AND wiki_audience = ?3",
        [row["tenant_id"], row["slug"], row["audience"]]
      )
    end)
  end

  defp wiki_key(row), do: {:wiki_citations, row["tenant_id"], row["slug"], row["audience"]}

  # The citations of a chunk of pages, one query for up to 500 slugs.
  defp load_citations(gate, pages) do
    pages
    |> Enum.filter(&(is_binary(&1["tenant_id"]) and is_binary(&1["slug"])))
    |> Enum.reject(&:ets.member(gate.memo, wiki_key(&1)))
    |> Enum.group_by(& &1["tenant_id"])
    |> Enum.each(fn {tenant, in_tenant} ->
      in_tenant
      |> Enum.map(& &1["slug"])
      |> Enum.uniq()
      |> Enum.chunk_every(@chunk)
      |> Enum.each(fn slugs ->
        marks = Enum.map_join(2..(length(slugs) + 1), ", ", &"?#{&1}")

        sql =
          "SELECT wiki_slug, wiki_audience, chunk_id FROM citations " <>
            "WHERE tenant_id = ?1 AND wiki_slug IN (#{marks})"

        found =
          sql
          |> query!([tenant | slugs])
          |> Enum.reduce(%{}, fn
            [slug, audience, chunk], acc when is_binary(chunk) ->
              Map.update(acc, {slug, audience}, [chunk], &[chunk | &1])

            _row, acc ->
              acc
          end)

        for page <- in_tenant, page["slug"] in slugs do
          :ets.insert(
            gate.memo,
            {wiki_key(page), Map.get(found, {page["slug"], page["audience"]}, [])}
          )
        end
      end)
    end)
  end

  defp wiki_source(frontmatter) do
    case SecurityLabels.metadata_map(frontmatter) do
      %{"source_object_type" => type, "source_object_id" => id} ->
        Lineage.link_refs(%{"type" => type, "id" => id})

      _ ->
        []
    end
  end

  # -- the aggregate rule -------------------------------------------------------

  # A replicating gate holds an aggregate while the workspace holds anything
  # above the gate; a reader's gate gives it every token in the workspace.
  # There is no row to point at, so there is no proof the aggregate is free of
  # any of it.
  defp aggregate_tokens(gate) do
    memoized(gate, :aggregate, fn -> workspace_tokens(gate) end)
  end

  defp workspace_tokens(%__MODULE__{mode: :class} = gate),
    do: if(holds_above?(gate), do: unresolved(), else: nil)

  # An aggregate is written from every row of the workspace, so a reader must
  # hold every partition of it, not just share one.
  defp workspace_tokens(%__MODULE__{mode: :grants} = gate) do
    tokens =
      Enum.reduce(Lineage.tables(), nil, fn table, acc ->
        spec = Lineage.spec(table)

        case carrying_rows(gate, table, spec) do
          [] -> acc
          rows -> Enum.reduce(rows, acc, &union(&2, Lineage.own_tokens(spec, &1)))
        end
      end)

    tokens &&
      MapSet.new(
        Enum.flat_map(tokens, fn
          {:partition_set, ids} -> Enum.map(ids, &{:partition_all, &1})
          other -> [other]
        end)
      )
  end

  # The distinct values of the columns of `table` that carry a class, label or
  # partition, for the rows that carry any. A metadata column is read for its
  # labels and partitions only (`metadata_labels_sql/1`), so a workspace in
  # which every memory is labelled returns a few distinct values and not every
  # memory's whole metadata.
  defp carrying_rows(gate, table, spec) do
    columns =
      Enum.reject(
        [
          spec.labels && "security_labels",
          spec.partitions && "partition_ids",
          spec.meta,
          spec.class
        ],
        &(&1 in [nil, false])
      )

    filters =
      Enum.reject(
        [
          spec.labels && non_empty_json("security_labels"),
          spec.partitions && non_empty_json("partition_ids"),
          spec.meta && metadata_candidate(spec.meta),
          spec.class &&
            "(#{spec.class} IS NOT NULL AND lower(#{spec.class}) NOT IN ('', 'internal', 'public'))"
        ],
        &(&1 in [nil, false])
      )

    if columns == [] do
      []
    else
      selects =
        Enum.map_join(columns, ", ", fn
          column when column == spec.meta -> metadata_labels_sql(column)
          column -> quote_name(column)
        end)

      sql =
        "SELECT DISTINCT #{selects} FROM #{quote_name(table)} " <>
          "WHERE tenant_id = ?1 AND workspace_id = ?2 AND (#{Enum.join(filters, " OR ")})"

      for values <- query!(sql, [gate.tenant_id, gate.workspace_id]) do
        columns |> Enum.zip(values) |> Map.new()
      end
    end
  end

  defp non_empty_json(column), do: "(#{column} NOT IN ('[]', '') OR NOT json_valid(#{column}))"

  # A metadata that may carry a label or a partition. Text that spells one of the
  # two keys is a candidate, and so is any text with a backslash in which a
  # member is named by one of them: `"security\u005flabels"` is the key
  # `security_labels` once decoded, and spelled so it does not contain it.
  # `metadata_labels_sql/1` then reads the decoded keys.
  @doc false
  def metadata_candidate(column) do
    quoted = quote_name(column)

    "(#{quoted} LIKE '%security_labels%' OR #{quoted} LIKE '%partition_ids%' OR " <>
      "(#{Lineage.backslash_sql(quoted)} AND json_valid(#{quoted}) AND " <>
      "EXISTS (SELECT 1 FROM json_each(#{quoted}) WHERE key IN ('security_labels', 'partition_ids'))))"
  end

  # The labels and partitions of a metadata column as a small JSON object, which
  # `SecurityLabels.metadata_tokens/1` reads like the whole column. Metadata that
  # is not JSON names nothing, as there.
  # A key that appears twice is read as `0`, which is not a list and so is
  # unresolved: SQLite reads the first of two, `Jason` the last, and a row must
  # not pass as unlabelled because the two disagree.
  defp metadata_labels_sql(column) do
    quoted = quote_name(column)

    field = fn key ->
      "CASE WHEN (SELECT count(*) FROM json_each(#{quoted}) WHERE key = '#{key}') > 1 THEN 0 " <>
        "ELSE json_extract(#{quoted}, '$.#{key}') END"
    end

    "CASE WHEN json_valid(#{quoted}) THEN json_object('security_labels', #{field.("security_labels")}, " <>
      "'partition_ids', #{field.("partition_ids")}) END"
  end

  defp holds_above?(gate) do
    shared(gate, :holds_above, fn ->
      index = index(gate)

      index.contexts != %{} or index.memories != %{} or
        Enum.any?(Lineage.scanned_tables(), fn table ->
          predicate = columns_above(Lineage.class_columns(Lineage.spec(table)), gate.rank)

          sql =
            "SELECT 1 FROM #{quote_name(table)} WHERE tenant_id = ?1 AND workspace_id = ?2 AND #{predicate} LIMIT 1"

          query!(sql, [gate.tenant_id, gate.workspace_id]) != []
        end)
    end)
  end

  # SQL for "some column of this table names a class above the gate".
  defp columns_above(columns, rank),
    do: "(" <> Enum.map_join(columns, " OR ", &exact_predicate(&1, rank)) <> ")"

  # SQL for "this column names a class above the gate", by the way its table
  # names a class (`Lineage.class_columns/1`). It holds what
  # `SecurityLabels.tokens/1` and `Lineage.own_tokens/2` rank above the gate, and
  # what they cannot read: a label that is not a non-blank string, a value that
  # is not an array, partitions that cannot be read, a class name this Engine
  # does not know. All of those are `restricted` for the row, so they are held
  # here too, and an aggregate never goes out around a row nobody could
  # classify. Exposed for the test that compares the two.
  @doc false
  def exact_predicate({:labels, column}, rank),
    do: Lineage.unreadable_array_sql(column, labels_above(rank))

  # Partitions that can be read rank nothing; ones that cannot rank restricted.
  def exact_predicate({:partitions, column}, _rank), do: Lineage.unreadable_array_sql(column)

  # A `security_labels` or `partition_ids` key that appears twice is above every
  # class: SQLite reads the first of two and `SecurityLabels.metadata_map/1` marks
  # the pair as unresolved, and the row must not pass as open because the first is.
  # The value is read as `SecurityLabels.tokens/1` reads it: an array, or text
  # that holds the JSON of an array (empty text and `null` name nothing);
  # anything else cannot be read.
  def exact_predicate({:meta, meta}, rank) do
    """
    (CASE WHEN json_valid(#{meta}) THEN
       (#{metadata_key(meta, "security_labels", labels_above(rank))})
       OR (#{metadata_key(meta, "partition_ids", nil)})
       ELSE 0 END)
    """
  end

  # `internal` is the default of a classification column and says nothing; a
  # name this Engine does not know cannot be read (`Lineage.own_tokens/2`).
  def exact_predicate({:class, class}, rank) do
    name = "lower(#{Lineage.trimmed_sql(class)})"
    known = Enum.map_join(SecurityLabels.classes(), ", ", &"'#{&1}'")

    "(#{class} IS NOT NULL AND #{class} != '' AND " <>
      "(#{name} NOT IN (#{known}) OR #{name} IN (#{classes_above(max(rank, 1))})))"
  end

  # An element of a label array that is a class above the gate.
  defp labels_above(rank),
    do: "lower(#{Lineage.trimmed_sql("j.value")}) IN (#{classes_above(rank)})"

  defp metadata_key(meta, key, extra) do
    path = "'$.#{key}'"
    type = "json_type(#{meta}, #{path})"
    text = "json_extract(#{meta}, #{path})"

    """
    CASE WHEN (SELECT count(*) FROM json_each(#{meta}) WHERE key = '#{key}') > 1 THEN 1
    WHEN #{type} IS NULL OR #{type} = 'null' THEN 0
    WHEN #{type} = 'array' THEN #{Lineage.unreadable_elements_sql("#{meta}, #{path}", extra)}
    WHEN #{type} = 'text' THEN
      CASE WHEN #{text} = '' THEN 0
           WHEN json_valid(#{text}) AND json_type(#{text}) = 'array'
             THEN #{Lineage.unreadable_elements_sql(text, extra)}
           ELSE 1 END
    ELSE 1 END
    """
  end

  defp classes_above(rank) do
    SecurityLabels.classes() |> Enum.drop(rank + 1) |> Enum.map_join(", ", &"'#{&1}'")
  end

  # -- history of a deleted row -------------------------------------------------

  defp history_tokens(gate, table, spec, mutation) do
    reset_budget(gate)

    with id when is_binary(id) <- mutation["entity_id"],
         tokens when tokens != :none <- ledger_tokens(gate, table, spec, id) do
      tokens
    else
      _ -> nil
    end
  end

  # What a row carried, as the local ledger recorded it, for a row that is gone:
  # every version it has there, newest first, @ledger_chunk at a time (a keyset
  # on the sequence, so a row with many versions costs a query for each fifty and
  # never reads the ledger twice). Its sources are read as they are now; one that
  # is gone too is ignored. A replicating gate stops as soon as a version is
  # restricted. A row with more than @ledger_chunk * @ledger_chunks versions is
  # not read to the end and is unresolved. `:none` when the ledger has no version.
  # Only changes of the row count: a storage mutation entry that names the row
  # is none, and could otherwise add to its history or push it past what is read.
  @ledger_chunk 50
  @ledger_chunks 20

  defp ledger_tokens(gate, table, spec, id),
    do: ledger_versions(gate, table, spec, id, 1_000_000_000_000_000_000, 1, :none)

  defp ledger_versions(gate, table, spec, id, before, chunk, seen) do
    rows =
      query!(
        """
        SELECT sequence, payload FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND entity_type = ?3 AND entity_id = ?4
          AND operation != 'delete' AND sequence < ?5 AND #{OptimalEngine.Sync.change_row_sql()}
        ORDER BY sequence DESC LIMIT #{@ledger_chunk}
        """,
        [gate.tenant_id, gate.workspace_id, table, id, before]
      )

    tokens =
      Enum.reduce(rows, if(seen == :none, do: nil, else: seen), fn [_sequence, payload], acc ->
        row = mutation_row(%{"payload" => decode_payload(payload)})
        union(acc, classify(gate, table, spec, row, false))
      end)

    cond do
      rows == [] and seen == :none ->
        :none

      length(rows) < @ledger_chunk or done?(gate, tokens) ->
        tokens

      chunk >= @ledger_chunks ->
        union(tokens, unresolved())

      true ->
        [last_sequence, _payload] = List.last(rows)
        ledger_versions(gate, table, spec, id, last_sequence, chunk + 1, tokens)
    end
  end

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_payload(%{} = payload), do: payload
  defp decode_payload(_payload), do: %{}

  # -- the index of derived documents, memories and entities ----------------------

  # `contexts`: ids of documents (and everything the ledger names) derived from
  # a selected source. `memories`: ids of versioned memories whose source
  # package or claim is selected. `entities`: ids of entities named in a
  # selected source. A source is selected when a replicating gate would hold
  # it (its class is above the peer's) or, for a reader, when it carries any
  # label or partition. Built once per gate, from the Store.
  defp index(gate),
    do: memoized(gate, :index, fn -> shared(gate, :index, fn -> build_index(gate) end) end)

  # What a scan of the workspace gave, kept for the next gate while nothing
  # was written (see `OptimalEngine.Sync.GateCache`). The stamp is read just
  # before each scan (not once per gate: a long push cycle may need a scan
  # late, after a write that an earlier scan did not see), so a write that
  # lands during a scan makes the entry stale, never the reverse. A replicating
  # gate and a reader's gate select different sources, so the mode is part of
  # the key.
  defp shared(gate, what, build) do
    key = {what, gate.tenant_id, gate.workspace_id, gate.mode, gate.rank}

    GateCache.fetch(key, stamp(gate), fn ->
      :telemetry.execute([:optimal_engine, :sync, :gate_build], %{count: 1}, %{
        what: what,
        workspace_id: gate.workspace_id
      })

      build.()
    end)
  end

  # The write sequence of the change capture and of the ledger: every write to
  # a replicated table of a workspace that syncs moves one of them, and so
  # does applying a change from a peer. The tables the gate scans that stay on
  # this Engine are not captured; the triggers `Capture` puts on them move the
  # third sequence. A workspace that does not sync is not captured, so nothing
  # tells when it changed: it is not cached. A sequence that is not there yet
  # (the Engine has not installed its triggers) is simply absent from the stamp.
  defp stamp(gate) do
    if query!("SELECT 1 FROM sync_workspaces WHERE workspace_id = ?1", [gate.workspace_id]) == [] do
      :uncached
    else
      query!(
        "SELECT name, seq FROM sqlite_sequence WHERE name IN ('sync_capture', 'sync_local_stamp', 'sync_mutations') ORDER BY name",
        []
      )
    end
  end

  defp build_index(gate) do
    scope = [gate.tenant_id, gate.workspace_id]
    source_spec = Lineage.spec("source_packages")
    claim_spec = Lineage.spec("claims")

    # A source is as classified as everything it carries: its labels, its
    # partitions and the labels and partitions in its metadata, as
    # `Lineage.own_tokens/2` reads them.
    held_sources =
      """
      SELECT id, source_uri, metadata, security_labels, partition_ids FROM source_packages
      WHERE tenant_id = ?1 AND workspace_id = ?2
        AND #{source_predicate(gate, Lineage.class_columns(source_spec))}
      """
      |> query!(scope)
      |> Enum.flat_map(fn [id, uri, metadata, labels, partitions] ->
        row = %{"security_labels" => labels, "partition_ids" => partitions, "metadata" => metadata}
        selected(gate, own(source_spec, row), {id, uri, metadata})
      end)

    held_claims =
      """
      SELECT signal_id, metadata, subject_entity_id, object_entity_id, security_labels, partition_ids
      FROM claims
      WHERE tenant_id = ?1 AND workspace_id = ?2
        AND #{source_predicate(gate, Lineage.class_columns(claim_spec))}
      """
      |> query!(scope)
      |> Enum.flat_map(fn [signal_id, metadata, subject, object, labels, partitions] ->
        row = %{"security_labels" => labels, "partition_ids" => partitions, "metadata" => metadata}
        selected(gate, own(claim_spec, row), {signal_id, metadata, [subject, object]})
      end)

    source_tokens = Map.new(held_sources, fn {tokens, {id, _uri, _metadata}} -> {id, tokens} end)

    memories =
      held_sources
      |> Enum.reduce(%{}, fn {tokens, {_id, uri, metadata}}, acc ->
        acc |> put_union(memory_of(uri), tokens) |> put_union(versioned_memory(metadata), tokens)
      end)
      |> then(fn memories ->
        Enum.reduce(held_claims, memories, fn {tokens, {_signal, metadata, _entities}}, acc ->
          put_union(acc, versioned_memory(metadata), tokens)
        end)
      end)

    contexts =
      held_claims
      |> Enum.reduce(%{}, fn {tokens, {signal_id, _metadata, _entities}}, acc ->
        put_union(acc, signal_id, tokens)
      end)
      |> then(&ledger_contexts(gate, scope, source_tokens, &1))

    %{
      contexts: contexts,
      memories: memories,
      entities: entity_tokens(gate, source_tokens, contexts, held_claims)
    }
  end

  # Entities named by a held claim, or resolved from a mention in a held
  # source package or document.
  defp entity_tokens(gate, source_tokens, contexts, held_claims) do
    named =
      Enum.reduce(held_claims, %{}, fn {tokens, {_signal, _metadata, entities}}, acc ->
        entities |> Enum.filter(&is_binary/1) |> Enum.reduce(acc, &put_union(&2, &1, tokens))
      end)

    if source_tokens == %{} and contexts == %{} do
      named
    else
      """
      SELECT resolved_entity_id, source_package_id, context_id FROM entity_mentions
      WHERE workspace_id = ?1 AND resolved_entity_id IS NOT NULL
        AND (source_package_id IN (SELECT value FROM json_each(?2))
             OR context_id IN (SELECT value FROM json_each(?3)))
      """
      |> query!([
        gate.workspace_id,
        Jason.encode!(Map.keys(source_tokens)),
        Jason.encode!(Map.keys(contexts))
      ])
      |> Enum.reduce(named, fn [entity, source, context], acc ->
        tokens = union(Map.get(source_tokens, source), Map.get(contexts, context))
        if tokens, do: put_union(acc, entity, tokens), else: acc
      end)
    end
  end

  # The tokens a row carries itself, in every column that can name a class.
  defp own(spec, row), do: Lineage.own_tokens(spec, row) || MapSet.new()

  # The tokens a row carries in its labels and partitions columns.
  defp carried(labels, partitions) do
    MapSet.new(SecurityLabels.tokens(labels) ++ SecurityLabels.partition_tokens(partitions))
  end

  # A source the index is built from: a replicating gate indexes what it
  # would hold; a reader's gate indexes whatever carries a label or partition.
  defp selected(%__MODULE__{mode: :class, rank: rank}, tokens, payload) do
    case SecurityLabels.token_rank(tokens) do
      class when is_integer(class) and class > rank -> [{tokens, payload}]
      _ -> []
    end
  end

  defp selected(%__MODULE__{mode: :grants}, tokens, payload),
    do: if(MapSet.size(tokens) > 0, do: [{tokens, payload}], else: [])

  # SQL narrowing the rows an index is built from, over `columns` (as
  # `Lineage.class_columns/1` lists them); `selected/3` then reads each row
  # exactly. A replicating gate takes a row that names a class above its own or
  # cannot be read, which is exactly what it selects; a reader's gate takes a row
  # that carries anything. Neither looks for the text of a class name: a name
  # can be spelled with an escape, and a label that is not a string has none.
  defp source_predicate(%__MODULE__{mode: :class, rank: rank}, columns),
    do: columns_above(columns, rank)

  defp source_predicate(%__MODULE__{mode: :grants}, columns),
    do: "(" <> Enum.map_join(columns, " OR ", &carries_anything/1) <> ")"

  defp carries_anything({kind, column}) when kind in [:labels, :partitions],
    do: "(#{column} NOT IN ('[]', '') OR NOT json_valid(#{column}))"

  defp carries_anything({:meta, column}), do: metadata_candidate(column)

  # The ledger entries of a labelled source, found by their own labels or by
  # the held source packages they list, name every object derived from it.
  defp ledger_contexts(gate, scope, source_tokens, contexts) do
    held? = source_tokens != %{}

    linked =
      if held?,
        do:
          " OR " <>
            Enum.map_join(
              ~w(source_package_links input_object_links evidence_links),
              " OR ",
              &links_to_held/1
            ),
        else: ""

    params = if held?, do: scope ++ [Jason.encode!(Map.keys(source_tokens))], else: scope

    sql = """
    SELECT input_object_links, output_object_links, source_package_links, evidence_links,
           security_labels, partition_ids
    FROM derivation_ledger l
    WHERE l.tenant_id = ?1 AND l.workspace_id = ?2
      AND (#{source_predicate(gate, [{:labels, "l.security_labels"}, {:partitions, "l.partition_ids"}])}#{linked})
    """

    sql
    |> query!(params)
    |> Enum.reduce(contexts, fn [input, output, sources, evidence, labels, partitions], acc ->
      linked_tokens =
        [input, sources, evidence]
        |> Enum.flat_map(&Lineage.link_refs/1)
        |> Enum.map(&Map.get(source_tokens, ref_id(&1)))
        |> Enum.reduce(nil, &union(&2, &1))

      tokens = union(carried(labels, partitions), linked_tokens)

      # What an entry produced is derived from what it was given; what it was
      # given (a public document a restricted answer was assembled from) is not.
      case selected(gate, tokens, nil) do
        [] ->
          acc

        [_] ->
          output |> Lineage.link_refs() |> Enum.reduce(acc, &put_union(&2, ref_id(&1), tokens))
      end
    end)
  end

  defp links_to_held(column) do
    """
    CASE WHEN json_valid(l.#{column}) THEN EXISTS (
      SELECT 1 FROM json_each(l.#{column}) j
      WHERE (CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.id') ELSE j.value END)
        IN (SELECT value FROM json_each(?3))
    ) ELSE 0 END
    """
  end

  defp ref_id({:row, _table, id}), do: id
  defp ref_id({:any, id}), do: id
  defp ref_id(:overflow), do: nil

  defp memory_of("memory://" <> id) when id != "", do: id
  defp memory_of(_uri), do: nil

  defp versioned_memory(metadata) do
    case SecurityLabels.metadata_map(metadata) do
      %{"versioned_memory_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp put_union(map, nil, _tokens), do: map
  defp put_union(map, key, tokens), do: Map.update(map, key, tokens, &MapSet.union(&1, tokens))

  # -- reading many rows at once --------------------------------------------------

  # Reads `{table, ids}` rows into the gate's row cache, then the rows they
  # link to, and so on level by level, so that classifying them afterwards
  # finds each row in the cache.
  defp prefetch(_gate, [], _depth), do: :ok
  defp prefetch(_gate, _wanted, depth) when depth >= @max_depth, do: :ok

  defp prefetch(gate, wanted, depth) do
    wanted
    |> Enum.flat_map(fn {table, ids} -> load_many(gate, table, ids) end)
    |> Enum.flat_map(fn {spec, row} -> Lineage.refs(spec, row) end)
    |> prefetch_refs(gate, depth)
  end

  defp prefetch_refs(refs, gate, depth) do
    typed =
      for {:row, table, id} <- refs, do: {table, id}

    untyped =
      gate
      |> resolve_any(for({:any, id} <- refs, do: id))
      |> Enum.map(fn {id, table} -> {table, id} end)

    next =
      (typed ++ untyped)
      |> Enum.uniq()
      |> Enum.reject(fn {table, id} -> :ets.member(gate.memo, {:row, table, id}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.to_list()

    prefetch(gate, next, depth + 1)
  end

  # The rows of `table` with these keys that are not cached yet, read a chunk
  # at a time. A key with no row is cached as missing.
  defp load_many(gate, table, ids) do
    with %{key: key} = spec when is_binary(key) <- Lineage.spec(table) do
      columns = Lineage.columns(spec)

      ids
      |> Enum.reject(&:ets.member(gate.memo, {:row, table, &1}))
      |> Enum.chunk_every(@chunk)
      |> Enum.flat_map(fn chunk ->
        sql =
          "SELECT #{Enum.map_join(columns, ", ", &quote_name/1)} FROM #{quote_name(table)} " <>
            "WHERE #{quote_name(key)} IN (#{Enum.map_join(1..length(chunk), ", ", &"?#{&1}")})"

        rows =
          for values <- query!(sql, chunk),
              row = columns |> Enum.zip(values) |> Map.new(),
              do: {row[key], row}

        found = Map.new(rows)

        for id <- chunk do
          row = Map.get(found, id)
          :ets.insert(gate.memo, {{:row, table, id}, row})
          if row, do: {spec, row}
        end
        |> Enum.reject(&is_nil/1)
      end)
    else
      _ -> []
    end
  end

  # The tables that hold links of no stated type, found a chunk at a time: the
  # first table of `Lineage.any_tables/0` with the id, as `find_table/2`
  # would. Ids that are in none are cached as such.
  defp resolve_any(gate, ids) do
    unknown =
      ids
      |> Enum.uniq()
      |> Enum.reject(&:ets.member(gate.memo, {:table_of, &1}))

    found =
      unknown
      |> Enum.chunk_every(@chunk)
      |> Enum.reduce(%{}, fn chunk, found ->
        Enum.reduce_while(Lineage.any_tables(), {found, chunk}, fn table, {found, remaining} ->
          key = Lineage.spec(table).key

          sql =
            "SELECT #{quote_name(key)} FROM #{quote_name(table)} " <>
              "WHERE #{quote_name(key)} IN (#{Enum.map_join(1..length(remaining), ", ", &"?#{&1}")})"

          hits = for [id] <- query!(sql, remaining), do: id
          found = Enum.reduce(hits, found, &Map.put_new(&2, &1, table))

          case remaining -- hits do
            [] -> {:halt, {found, []}}
            rest -> {:cont, {found, rest}}
          end
        end)
        |> elem(0)
      end)

    for id <- unknown do
      :ets.insert(gate.memo, {{:table_of, id}, Map.get(found, id)})
    end

    unknown
    |> Enum.reject(&Map.has_key?(found, &1))
    |> Enum.reject(&:ets.member(gate.memo, {:gone_types, &1}))
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      types = gone_types_of(gate, chunk)
      for id <- chunk, do: :ets.insert(gate.memo, {{:gone_types, id}, Map.get(types, id, [])})
    end)

    for id <- Enum.uniq(ids),
        table = :ets.lookup_element(gate.memo, {:table_of, id}, 2),
        table != nil,
        do: {id, table}
  end

  # -- reading the Store ----------------------------------------------------------

  # A row by its key, from what `prefetch/3` read or from the Store.
  defp load(gate, table, %{key: key} = spec, id) when is_binary(key) do
    memoized(gate, {:row, table, id}, fn ->
      columns = Lineage.columns(spec)

      sql =
        "SELECT #{Enum.map_join(columns, ", ", &quote_name/1)} FROM #{quote_name(table)} WHERE #{quote_name(key)} = ?1 LIMIT 1"

      case query!(sql, [id]) do
        [values | _] -> columns |> Enum.zip(values) |> Map.new()
        [] -> nil
      end
    end)
  end

  defp load(_gate, _table, _spec, _id), do: nil

  defp find_table(id) do
    Enum.find(Lineage.any_tables(), fn table ->
      key = Lineage.spec(table).key

      query!("SELECT 1 FROM #{quote_name(table)} WHERE #{quote_name(key)} = ?1 LIMIT 1", [id]) != []
    end)
  end

  defp context?(gate, id) when is_binary(id) and id != "" do
    memoized(gate, {:context, id}, fn ->
      query!("SELECT 1 FROM contexts WHERE id = ?1 LIMIT 1", [id]) != []
    end)
  end

  defp context?(_gate, _id), do: false

  # A query the gate decides by: if the Store cannot answer, nothing is sent.
  defp query!(sql, params) do
    :telemetry.execute([:optimal_engine, :sync, :gate_query], %{count: 1}, %{})

    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        raise OptimalEngine.Sync.Gate.StoreError,
          message: "the sync gate could not read the Store: #{inspect(reason)}"
    end
  end

  defp query_column(sql, params),
    do: for([value] <- query!(sql, params), is_binary(value), do: value)

  # -- small things ---------------------------------------------------------------

  # `memoized/3` for the class of a row reached through links. A result is kept
  # only when reading it did not depend on the path that led to it. A link that
  # points back onto the path is left out (or the path got too long), so a row
  # read inside a loop, or deep down a path, may lack labels that another path
  # to the same row finds: remembering it would hand that gap to every later
  # row that links it. A cut is remembered in the gate until the rows above it
  # have been read, so none of them is kept either.
  defp settled(%__MODULE__{memo: memo} = gate, key, fun) do
    case :ets.lookup(memo, key) do
      [{^key, value}] ->
        value

      [] ->
        outer = take_cut(gate)
        value = fun.()
        inner = take_cut(gate)
        unless inner, do: :ets.insert(memo, {key, value})
        if outer or inner, do: cut(gate)
        value
    end
  end

  # The rows one top-level classification may read for the first time (see the
  # moduledoc). Each call to `reset_budget/1` starts a new count; what an
  # earlier call settled stays in the cache and costs nothing.
  defp reset_budget(%__MODULE__{memo: memo}), do: :ets.insert(memo, {:budget, @node_budget})

  defp spend(%__MODULE__{memo: memo}),
    do: :ets.update_counter(memo, :budget, {2, -1}, {:budget, @node_budget}) >= 0

  defp cut(%__MODULE__{memo: memo}), do: :ets.insert(memo, {:cut, true})
  defp take_cut(%__MODULE__{memo: memo}), do: :ets.take(memo, :cut) != []

  defp memoized(%__MODULE__{memo: memo}, key, fun) do
    case :ets.lookup(memo, key) do
      [{^key, value}] ->
        value

      [] ->
        value = fun.()
        :ets.insert(memo, {key, value})
        value
    end
  end

  # A replicating gate stops as soon as a row is known to be restricted; a
  # reader's gate collects every token, since any one may be missing.
  defp fold_union(items, gate, start, fun) do
    if done?(gate, start) do
      start
    else
      Enum.reduce_while(items, start, fn item, acc ->
        acc = union(acc, fun.(item))
        if done?(gate, acc), do: {:halt, acc}, else: {:cont, acc}
      end)
    end
  end

  defp done?(%__MODULE__{mode: :class}, tokens),
    do: SecurityLabels.token_rank(tokens) == @restricted

  defp done?(%__MODULE__{}, _tokens), do: false

  defp union(nil, other), do: other
  defp union(tokens, nil), do: tokens
  defp union(left, right), do: MapSet.union(left, right)

  @doc """
  The row a mutation carries, with its BLOB columns put back. A value SQLite
  holds as a BLOB travels hex-encoded in `payload.blobs` and is nil in
  `payload.row` (any column may hold one), so a label stored that way is read
  from there. A blob that is not hex is kept as an atom no reader accepts,
  which ranks `restricted` in a labels column.
  """
  @spec mutation_row(map()) :: map()
  def mutation_row(%{"payload" => %{"row" => %{} = row} = payload}) do
    case payload["blobs"] do
      %{} = blobs -> Map.merge(row, Map.new(blobs, fn {name, hex} -> {name, blob_value(hex)} end))
      _none -> row
    end
  end

  def mutation_row(_mutation), do: %{}

  defp blob_value(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> :unreadable
    end
  end

  defp blob_value(_hex), do: :unreadable

  defp unclassified(gate, table) do
    memoized(gate, {:unclassified, table}, fn ->
      Logger.warning(
        "[Sync] #{inspect(table)} is not in the lineage map; its changes stay on this Engine until it is classified"
      )
    end)
  end

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end
end
