defmodule OptimalEngine.Sync.Gate do
  @moduledoc """
  The data-class gate of replication: which changes stay on this Engine.

  A peer is cleared up to a `max_class` (`public`, `internal`,
  `confidential`, `restricted`). A change whose row is classified above it is
  not sent. Classification is not only the row's own `security_labels`: a
  row copied or derived from a labelled row is as classified as its source
  (see `OptimalEngine.Sync.Lineage`), so a versioned memory staged from a
  restricted source package, the chunks and vectors of a restricted
  document, and a wiki page citing either stay home with it.

  Sending is fail-closed. A row stays home when

    * its own labels, or those of any row it derives from, are above the
      peer's class;
    * a row it must derive from (a source package, a claim) cannot be found,
      or its lineage is deeper than 40 hops;
    * its table is not in the lineage map;
    * it is an aggregate (`analysis_reports`) and the workspace holds
      anything above the peer's class.

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

  A gate is opened for one pass (one push cycle, one served page) and closed:
  it caches what it reads from the Store for the pass and builds, on first
  use, an index of the documents and memories derived from labelled sources.
  """

  require Logger

  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Lineage

  @internal 1
  @restricted 3
  @max_depth 40

  defstruct [:tenant_id, :workspace_id, :rank, :memo]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          workspace_id: String.t(),
          rank: non_neg_integer(),
          memo: :ets.tid()
        }

  # -- opening ------------------------------------------------------------------

  @doc "Opens a gate for a workspace and the highest class a peer may hold."
  @spec open(String.t(), String.t(), String.t()) :: t()
  def open(tenant_id, workspace_id, max_class) do
    %__MODULE__{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      rank: class_rank(max_class),
      memo: :ets.new(:sync_gate, [:set, :private])
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
    gate = open(tenant_id, workspace_id, max_class)

    try do
      fun.(gate)
    after
      close(gate)
    end
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
        raise "the sync gate could not read the workspace: #{inspect(other)}"
    end
  end

  @doc "True when the workspace's own data class is above the gate."
  @spec workspace_above?(t()) :: boolean()
  def workspace_above?(%__MODULE__{workspace_id: workspace_id, rank: rank}),
    do: workspace_rank(workspace_id) > rank

  # -- sending ------------------------------------------------------------------

  @doc "True when the mutation must stay on this Engine."
  @spec hold?(t(), map()) :: boolean()
  def hold?(%__MODULE__{rank: rank}, _mutation) when rank >= @restricted, do: false

  def hold?(%__MODULE__{rank: gate_rank} = gate, mutation) do
    case mutation_rank(gate, mutation) do
      nil -> false
      rank -> rank > gate_rank
    end
  end

  @doc """
  `hold?/2` for a ledger that callers may also append to
  (`OptimalEngine.Storage.PolicyStore`): a mutation of an entity type that
  is not a replicated table is not held, since no row of ours is behind it.
  """
  @spec hold_known?(t(), map()) :: boolean()
  def hold_known?(%__MODULE__{} = gate, mutation),
    do: Lineage.spec(mutation["entity_type"]) != nil and hold?(gate, mutation)

  @doc """
  The class rank a mutation is held at: nil when nothing classifies it,
  otherwise 0..3. For tests and audits; `hold?/2` is the gate.
  """
  @spec mutation_rank(t(), map()) :: SecurityLabels.rank() | nil
  def mutation_rank(%__MODULE__{} = gate, mutation) do
    table = mutation["entity_type"]

    case Lineage.spec(table) do
      nil ->
        unclassified(gate, table)
        @restricted

      spec ->
        if mutation["operation"] == "delete",
          do: history_rank(gate, table, spec, mutation),
          else: top_rank(gate, table, spec, mutation_row(mutation), true)
    end
  end

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

  # -- classifying a row --------------------------------------------------------

  # The row being classified is on the path from the start, so a link back to
  # itself (the root of a version chain is the row itself) is not followed.
  defp top_rank(gate, table, spec, row, strict) do
    visiting =
      case row[spec.key] do
        id when is_binary(id) -> MapSet.new([{table, id}])
        _ -> MapSet.new()
      end

    row_rank(gate, spec, row, visiting, strict)
  end

  # `strict` is false only while reading the earlier changes of a deleted row:
  # a link to a row that is gone is then not doubt, the row is being removed.
  defp row_rank(gate, spec, row, visiting, strict) do
    start = Lineage.own_rank(spec, row)

    ranked =
      spec
      |> Lineage.refs(row)
      |> fold_max(start, &ref_rank(gate, &1, visiting, strict))

    ranked =
      if spec.kind == :aggregate,
        do: max_rank(ranked, aggregate_rank(gate)),
        else: ranked

    fold_max(spec.special, ranked, &special_rank(gate, &1, row, visiting, strict))
  end

  defp ref_rank(gate, {:row, table, id}, visiting, strict) do
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
        settled(gate, {strict, table, id}, fn -> row_ref(gate, table, id, visiting, strict) end)
    end
  end

  # More references than can be followed: not trusted.
  defp ref_rank(_gate, :overflow, _visiting, strict), do: unresolved(strict)

  defp ref_rank(gate, {:any, id}, visiting, strict) do
    table = memoized(gate, {:table_of, id}, fn -> find_table(id) end)
    if is_binary(table), do: ref_rank(gate, {:row, table, id}, visiting, strict), else: nil
  end

  defp row_ref(gate, table, id, visiting, strict) do
    case Lineage.spec(table) do
      nil ->
        unclassified(gate, table)
        @restricted

      spec ->
        case load(table, spec, id) do
          nil ->
            cond do
              Lineage.anchor?(table) -> unresolved(strict)
              # A document or chunk that is gone is still in the ledger as it was.
              strict -> ledger_rank(gate, table, spec, id)
              true -> nil
            end

          row ->
            row_rank(gate, spec, row, MapSet.put(visiting, {table, id}), strict)
        end
    end
  end

  defp unresolved(true), do: @restricted
  defp unresolved(false), do: nil

  # -- rows that are pointed at, not pointing -----------------------------------

  defp special_rank(gate, :memory_sources, row, _visiting, _strict),
    do: Map.get(index(gate).memories, row["id"])

  defp special_rank(gate, :context_sources, row, _visiting, _strict),
    do: Map.get(index(gate).contexts, row["id"])

  # An entity is named in the sources it was resolved from.
  defp special_rank(gate, :entity_sources, row, _visiting, _strict),
    do: Map.get(index(gate).entities, row["id"])

  # A cluster is named for its members; one with none yet (they are written
  # after it) has no lineage to read.
  defp special_rank(gate, :cluster_members, row, visiting, strict) do
    case query_column("SELECT chunk_id FROM cluster_members WHERE cluster_id = ?1", [row["id"]]) do
      [] -> aggregate_rank(gate)
      ids -> fold_max(ids, nil, &ref_rank(gate, {:row, "chunks", &1}, visiting, strict))
    end
  end

  # A graph edge between two documents follows them; an edge between entity
  # names (co-occurrence) is derived from every document that names them.
  defp special_rank(gate, :edge, row, _visiting, _strict) do
    if Enum.any?([row["source_id"], row["target_id"]], &context?(gate, &1)),
      do: nil,
      else: aggregate_rank(gate)
  end

  # A wiki page is written from what it cites: its citations, the object it
  # was projected from, and the `optimal://` addresses in its body. A page
  # that names nothing (or whose citations are not written yet) has no
  # lineage to read.
  defp special_rank(gate, :wiki_page, row, visiting, strict) do
    cited =
      query_column(
        "SELECT chunk_id FROM citations WHERE tenant_id = ?1 AND wiki_slug = ?2 AND wiki_audience = ?3",
        [row["tenant_id"], row["slug"], row["audience"]]
      )

    case Enum.map(cited, &{:row, "chunks", &1}) ++
           wiki_source(row["frontmatter"]) ++ Lineage.uri_refs(row["body"]) do
      [] -> aggregate_rank(gate)
      refs -> fold_max(refs, nil, &ref_rank(gate, &1, visiting, strict))
    end
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

  # Held while the workspace holds anything above the gate: there is no row to
  # point at, so there is no proof the aggregate is free of it.
  defp aggregate_rank(gate) do
    memoized(gate, :aggregate, fn -> if holds_above?(gate), do: @restricted, else: nil end)
  end

  defp holds_above?(gate) do
    index = index(gate)

    index.contexts != %{} or index.memories != %{} or
      Enum.any?(Lineage.tables(), fn table ->
        case exact_predicate(Lineage.spec(table), gate.rank) do
          nil ->
            false

          predicate ->
            sql =
              "SELECT 1 FROM #{quote_name(table)} WHERE tenant_id = ?1 AND workspace_id = ?2 AND #{predicate} LIMIT 1"

            query!(sql, [gate.tenant_id, gate.workspace_id]) != []
        end
      end)
  end

  # SQL for "this row names a class above the gate", exactly, by the way its
  # table names a class; nil for a table that names none.
  defp exact_predicate(%{labels: true}, rank) do
    """
    (CASE WHEN json_valid(security_labels)
       THEN EXISTS (SELECT 1 FROM json_each(security_labels) j WHERE lower(j.value) IN (#{classes_above(rank)}))
       ELSE 1 END)
    """
  end

  defp exact_predicate(%{meta: meta}, rank) when is_binary(meta) do
    """
    (CASE WHEN json_valid(#{meta}) THEN
       CASE json_type(#{meta}, '$.security_labels')
         WHEN 'array' THEN EXISTS (SELECT 1 FROM json_each(#{meta}, '$.security_labels') j WHERE lower(j.value) IN (#{classes_above(rank)}))
         WHEN 'text' THEN lower(json_extract(#{meta}, '$.security_labels')) IN (#{classes_above(rank)})
         ELSE 0 END
       ELSE 0 END)
    """
  end

  # `internal` is the default of a classification column and says nothing.
  defp exact_predicate(%{class: class}, rank) when is_binary(class),
    do: "lower(#{class}) IN (#{classes_above(max(rank, 1))})"

  defp exact_predicate(_spec, _rank), do: nil

  defp classes_above(rank) do
    SecurityLabels.classes() |> Enum.drop(rank + 1) |> Enum.map_join(", ", &"'#{&1}'")
  end

  # -- history of a deleted row -------------------------------------------------

  defp history_rank(gate, table, spec, mutation) do
    case mutation["entity_id"] do
      id when is_binary(id) -> ledger_rank(gate, table, spec, id)
      _ -> nil
    end
  end

  # The class of a row as the local ledger last recorded it, for a row that is
  # gone. Its sources are read as they are now; one that is gone too is ignored.
  defp ledger_rank(gate, table, spec, id) do
    rows =
      query!(
        """
        SELECT payload FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND entity_type = ?3 AND entity_id = ?4
          AND operation != 'delete'
        ORDER BY sequence DESC LIMIT 20
        """,
        [gate.tenant_id, gate.workspace_id, table, id]
      )

    for [payload] <- rows, reduce: nil do
      acc ->
        row = mutation_row(%{"payload" => decode_payload(payload)})
        max_rank(acc, top_rank(gate, table, spec, row, false))
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

  # -- the index of derived documents and memories -------------------------------

  # `contexts`: ids of documents (and everything the ledger names) derived from
  # a source above the gate. `memories`: ids of versioned memories whose source
  # package or claim is above the gate. Built once per gate, from the Store.
  defp index(gate), do: memoized(gate, :index, fn -> build_index(gate) end)

  defp build_index(gate) do
    scope = [gate.tenant_id, gate.workspace_id]
    predicate = above_predicate("security_labels", gate.rank)

    held_sources =
      """
      SELECT id, source_uri, metadata, security_labels FROM source_packages
      WHERE tenant_id = ?1 AND workspace_id = ?2 AND #{predicate}
      """
      |> query!(scope)
      |> Enum.flat_map(fn [id, uri, metadata, labels] ->
        above(gate, SecurityLabels.rank(labels), {id, uri, metadata})
      end)

    held_claims =
      """
      SELECT signal_id, metadata, subject_entity_id, object_entity_id, security_labels FROM claims
      WHERE tenant_id = ?1 AND workspace_id = ?2 AND #{predicate}
      """
      |> query!(scope)
      |> Enum.flat_map(fn [signal_id, metadata, subject, object, labels] ->
        above(gate, SecurityLabels.rank(labels), {signal_id, metadata, [subject, object]})
      end)

    source_ranks = Map.new(held_sources, fn {rank, {id, _uri, _metadata}} -> {id, rank} end)

    memories =
      held_sources
      |> Enum.reduce(%{}, fn {rank, {_id, uri, metadata}}, acc ->
        acc |> put_max(memory_of(uri), rank) |> put_max(versioned_memory(metadata), rank)
      end)
      |> then(fn memories ->
        Enum.reduce(held_claims, memories, fn {rank, {_signal, metadata, _entities}}, acc ->
          put_max(acc, versioned_memory(metadata), rank)
        end)
      end)

    contexts =
      held_claims
      |> Enum.reduce(%{}, fn {rank, {signal_id, _metadata, _entities}}, acc ->
        put_max(acc, signal_id, rank)
      end)
      |> then(&ledger_contexts(gate, scope, source_ranks, &1))

    %{
      contexts: contexts,
      memories: memories,
      entities: entity_ranks(gate, source_ranks, contexts, held_claims)
    }
  end

  # Entities named by a held claim, or resolved from a mention in a held
  # source package or document.
  defp entity_ranks(gate, source_ranks, contexts, held_claims) do
    named =
      Enum.reduce(held_claims, %{}, fn {rank, {_signal, _metadata, entities}}, acc ->
        entities |> Enum.filter(&is_binary/1) |> Enum.reduce(acc, &put_max(&2, &1, rank))
      end)

    if source_ranks == %{} and contexts == %{} do
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
        Jason.encode!(Map.keys(source_ranks)),
        Jason.encode!(Map.keys(contexts))
      ])
      |> Enum.reduce(named, fn [entity, source, context], acc ->
        rank = max_rank(Map.get(source_ranks, source), Map.get(contexts, context))
        if rank, do: put_max(acc, entity, rank), else: acc
      end)
    end
  end

  defp above(%__MODULE__{rank: gate_rank}, rank, payload)
       when is_integer(rank) and rank > gate_rank,
       do: [{rank, payload}]

  defp above(_gate, _rank, _payload), do: []

  # The ledger entries of a labelled source, found by their own labels or by
  # the held source packages they list, name every object derived from it.
  defp ledger_contexts(gate, scope, source_ranks, contexts) do
    held? = source_ranks != %{}

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

    params = if held?, do: scope ++ [Jason.encode!(Map.keys(source_ranks))], else: scope

    sql = """
    SELECT input_object_links, output_object_links, source_package_links, evidence_links, security_labels
    FROM derivation_ledger l
    WHERE l.tenant_id = ?1 AND l.workspace_id = ?2
      AND (#{above_predicate("l.security_labels", gate.rank)}#{linked})
    """

    sql
    |> query!(params)
    |> Enum.reduce(contexts, fn [input, output, sources, evidence, labels], acc ->
      linked_rank =
        [input, sources, evidence]
        |> Enum.flat_map(&Lineage.link_refs/1)
        |> Enum.map(&Map.get(source_ranks, ref_id(&1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end)

      rank = max_rank(SecurityLabels.rank(labels), linked_rank)

      # What an entry produced is derived from what it was given; what it was
      # given (a public document a restricted answer was assembled from) is not.
      if is_integer(rank) and rank > gate.rank,
        do: output |> Lineage.link_refs() |> Enum.reduce(acc, &put_max(&2, ref_id(&1), rank)),
        else: acc
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

  defp put_max(map, nil, _rank), do: map
  defp put_max(map, key, rank), do: Map.update(map, key, rank, &max(&1, rank))

  # -- reading the Store ----------------------------------------------------------

  # SQL for "this column names a class above the gate, or cannot be read". It
  # narrows the rows an index is built from; each row's class is then read
  # exactly (`SecurityLabels.rank/1`).
  defp above_predicate(column, rank, unreadable? \\ true) do
    likes =
      SecurityLabels.classes()
      |> Enum.drop(rank + 1)
      |> Enum.map_join(" OR ", &"lower(#{column}) LIKE '%#{&1}%'")

    if unreadable?, do: "(#{likes} OR NOT json_valid(#{column}))", else: "(#{likes})"
  end

  defp load(table, %{key: key} = spec, id) when is_binary(key) do
    columns = Lineage.columns(spec)

    sql =
      "SELECT #{Enum.map_join(columns, ", ", &quote_name/1)} FROM #{quote_name(table)} WHERE #{quote_name(key)} = ?1 LIMIT 1"

    case query!(sql, [id]) do
      [values | _] -> columns |> Enum.zip(values) |> Map.new()
      [] -> nil
    end
  end

  defp load(_table, _spec, _id), do: nil

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
    case Store.raw_query(sql, params) do
      {:ok, rows} -> rows
      {:error, reason} -> raise "the sync gate could not read the Store: #{inspect(reason)}"
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

  defp fold_max(_items, @restricted, _fun), do: @restricted

  defp fold_max(items, start, fun) do
    Enum.reduce_while(items, start, fn item, acc ->
      acc = max_rank(acc, fun.(item))
      if acc == @restricted, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp max_rank(nil, other), do: other
  defp max_rank(rank, nil), do: rank
  defp max_rank(left, right), do: max(left, right)

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
