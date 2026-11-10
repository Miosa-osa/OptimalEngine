defmodule OptimalEngine.Sync.Redaction do
  @moduledoc """
  Erased content leaves the replication ledger.

  Change capture records every write of a replicated row with the whole row
  (`OptimalEngine.Sync.Capture`), so before this module an erasure only
  appended one more change: the text it erased stayed in the earlier changes
  in `sync_mutations` (and in `sync_capture` before a seal, and in the payloads
  `sync_conflicts` keeps), was served to every peer that had not caught up,
  and was published to NATS.

  ## What redaction does to a row's changes

  A redacted ledger row keeps its place: its id, sequence, device, operation,
  idempotency key and times are unchanged, so cursors, conflict clocks and the
  history page still read it. Its payload becomes a tombstone,

      {"row": {<key columns, and what the gate classifies the row by>},
       "blobs": {}, "redacted": true}

  its `payload_hash` is the SHA-256 of that payload, computed as the ledger
  computes every hash, and `redacted_at` records when. The ledger is not hash
  chained: each row's hash covers its own payload and nothing else, and a peer
  recomputes the hash of every change it stores rather than trusting the
  sender's, so a rewritten row verifies as any other. A redacted row is never
  served, pushed or published (`Sync.changes/3` and the push read
  `redacted_at IS NULL`). A delete already carries only the key and is not
  rewritten.

  The tombstone keeps, beside the key, what the data-class gate classifies the
  row by (`tombstone_row/3`): labels, partitions, class, the label keys of its
  metadata, and its link ids. The gate decides whether a delete may go to a
  peer from the row's earlier versions in the ledger, and the history page
  checks a reader's grants against them, so a redaction leaves both as they
  were. None of it is content.

  On the same row, `sync_capture` rows not sealed yet are dropped (they hold
  the whole row; a delete is kept), and the `local_payload`/`remote_payload`
  of its `sync_conflicts` become the tombstone.

  ## When

  * Every delete of a replicated row redacts the row's earlier changes:
    in the transaction of the erasure that deleted it (`redact_deleted/2`,
    called by every erasure path for the deletes it and its foreign-key
    cascades captured), when the delete is sealed (`redact_sealed/1`, for any
    other delete), and on a peer when it applies a delete it received.
  * An erasure that keeps the row and empties it (a forgotten memory, a
    context redacted in place) calls `redact_rows/5` in its transaction. That
    redacts the row's changes so far and, for a workspace that replicates,
    writes a `ledger_redactions` row: the type of the row (`memory` or
    `context`), its id, a reason code and the version erased (the time of the
    erasure, as `occurred_at` is written). Nothing else: no values. The row is
    replicated like any other change, classed at the class of the row it names,
    and a peer that applies it erases by its own rule for that table
    (`erasure_rule/1`): it redacts its copies of the row's changes made at or
    before the version, deletes what it derived from the row, and sets the
    columns the rule names, unless a newer change of the row is here.
  * A row of an append-only table (a single `INTEGER` row id: intents,
    citations, classifications, cluster members, decisions, entities, graph
    edges, memory relations) is named by its link to the chunk, context or
    memory it was made from (`append_only_links/0`). When that parent goes, the
    ledger rows of its append-only rows are redacted too, here and on a peer
    applying the parent's delete, which also deletes its own append-only rows
    the origin deletes with the parent.
  * `backfill/1` does the same once for what an Engine erased before it had
    this module.
  """

  require Logger

  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Sync.{Capture, Lineage}

  @table "ledger_redactions"

  @doc "The replicated table of redaction requests."
  @spec table() :: String.t()
  def table, do: @table

  @doc """
  The tombstone payload of a row with key columns `key_row`, and its hash, the
  SHA-256 the ledger gives every payload.
  """
  @spec tombstone(map()) :: {String.t(), String.t()}
  def tombstone(key_row) when is_map(key_row) do
    payload = Jason.encode!(%{"row" => key_row, "blobs" => %{}, "redacted" => true})
    {payload, hash(payload)}
  end

  @doc "The ledger's hash of a payload: lower-case hex SHA-256."
  @spec hash(String.t()) :: String.t()
  def hash(payload), do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

  @doc "Whether a decoded payload is a tombstone."
  @spec tombstone?(term()) :: boolean()
  def tombstone?(%{"redacted" => true}), do: true
  def tombstone?(_payload), do: false

  @doc """
  The key columns of a row of `table` named by `entity_id`, the ledger's
  `entity_id` (the key as text, or a JSON array of the keys). `nil` when the
  table has no key or the id does not fit it.
  """
  @spec key_row(String.t(), String.t()) :: map() | nil
  def key_row(table, entity_id) when is_binary(entity_id) do
    case Capture.key_columns(Capture.columns(table)) do
      [] ->
        nil

      [key] ->
        %{key => entity_id}

      keys ->
        case Jason.decode(entity_id) do
          {:ok, values} when is_list(values) and length(values) == length(keys) ->
            keys |> Enum.zip(values) |> Map.new()

          _ ->
            nil
        end
    end
  end

  def key_row(_table, _entity_id), do: nil

  defp key_row_of([], _entity_id), do: %{}
  defp key_row_of([key], entity_id), do: %{key => entity_id}

  defp key_row_of(keys, entity_id) do
    case Jason.decode(entity_id) do
      {:ok, values} when is_list(values) and length(values) == length(keys) ->
        keys |> Enum.zip(values) |> Map.new()

      _ ->
        %{}
    end
  end

  @doc """
  The row a tombstone keeps of `row`, a version of a row of `table`: what the
  data-class gate and the readers' grant checks classify a row by
  (`OptimalEngine.Sync.Lineage`), reduced to class ranks and ids, and its key.

    * labels: the class names and the id-shaped labels; a value that cannot be
      read, or an element that is not a string, becomes `["restricted"]`, the
      rank the gate gives it;
    * partitions: the id-shaped ones; any other makes the value unreadable,
      which ranks as it did;
    * metadata: only its labels and partitions (as above) and the id keys the
      map reads;
    * a class column: the class name, or `restricted` for one that cannot be read;
    * link columns: only ids (and the type of a typed link); of a text column,
      only its `optimal://` addresses;
    * key columns: an id is kept; a natural text key (an alias, a name) is
      replaced by a keyed hash (`text_key/2`).

  A delete of the row is judged by its earlier versions, and a redacted
  version still ranks as it did. Never content.
  """
  @spec tombstone_row(String.t(), map(), term()) :: map()
  def tombstone_row(table, key_row, row) when is_map(row) do
    keys = Map.new(key_row, fn {name, value} -> {name, key_value(table, value)} end)

    case Lineage.spec(table) do
      nil ->
        keys

      spec ->
        spec
        |> kept_columns(row)
        |> Map.merge(keys)
    end
  end

  def tombstone_row(table, key_row, _row), do: tombstone_row(table, key_row, %{})

  defp kept_columns(spec, row) do
    meta_ids = for {:meta_id, key, _table} <- spec.refs, do: key

    [
      spec.labels && {"security_labels", &labels/1},
      spec.partitions && {"partition_ids", &partitions/1},
      is_binary(spec.meta) && {spec.meta, &meta(&1, meta_ids)},
      is_binary(spec.class) && {spec.class, &class/1}
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(for column <- spec.extra, do: {column, &id_or_nil/1})
    |> Kernel.++(Enum.flat_map(spec.refs, &ref_columns/1))
    |> Enum.reduce(%{}, fn {column, fun}, acc ->
      if Map.has_key?(row, column), do: Map.put(acc, column, fun.(row[column])), else: acc
    end)
  end

  defp ref_columns({:id, column, _table}), do: [{column, &id_or_nil/1}]
  defp ref_columns({:typed, type, id}), do: [{type, &type_or_nil/1}, {id, &id_or_nil/1}]
  defp ref_columns({:links, column}), do: [{column, &links/1}]
  defp ref_columns({:json_ids, column, _table}), do: [{column, &json_ids/1}]
  defp ref_columns({:json_map, column, mapping}), do: [{column, &json_map(&1, Map.keys(mapping))}]
  defp ref_columns({:uris, column}), do: [{column, &addresses/1}]
  defp ref_columns({:meta_id, _key, _table}), do: []

  @id ~r/\A[A-Za-z0-9_\-:.]{1,256}\z/
  @type_name ~r/\A[a-z_]{1,64}\z/

  defp id?(value), do: is_binary(value) and Regex.match?(@id, value)
  defp id_or_nil(value), do: if(id?(value), do: value)
  defp type_or_nil(value), do: if(is_binary(value) and Regex.match?(@type_name, value), do: value)

  @unreadable ~s(["restricted"])

  defp labels(nil), do: nil

  defp labels(value) do
    case decode_list(value) do
      {:ok, list} ->
        kept = for label <- list, is_binary(label), class_or_id?(label), do: label

        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
          do: Jason.encode!(kept),
          else: Jason.encode!(Enum.uniq(["restricted" | kept]))

      :invalid ->
        @unreadable
    end
  end

  defp class_or_id?(label),
    do:
      SecurityLabels.class_rank(label) != nil or
        Regex.match?(~r/\A[a-z0-9][a-z0-9_.:\-]{0,63}\z/, label)

  defp partitions(nil), do: nil

  defp partitions(value) do
    case decode_list(value) do
      {:ok, list} -> if Enum.all?(list, &id?/1), do: Jason.encode!(list), else: "0"
      :invalid -> "0"
    end
  end

  defp meta(nil, _keys), do: nil

  defp meta(value, keys) do
    map = SecurityLabels.metadata_map(value)

    %{}
    |> put_if(map, "security_labels", fn value ->
      case labels(value) do
        nil -> nil
        json -> Jason.decode!(json)
      end
    end)
    |> put_if(map, "partition_ids", fn value ->
      case partitions(value) do
        nil -> nil
        "0" -> 0
        json -> Jason.decode!(json)
      end
    end)
    |> then(fn acc ->
      Enum.reduce(keys, acc, fn key, acc ->
        if id?(map[key]), do: Map.put(acc, key, map[key]), else: acc
      end)
    end)
    |> Jason.encode!()
  end

  defp put_if(acc, map, key, fun),
    do: if(Map.has_key?(map, key), do: Map.put(acc, key, fun.(map[key])), else: acc)

  defp class(value) when value in [nil, ""], do: value

  defp class(value) do
    case SecurityLabels.class_rank(value) do
      nil -> "restricted"
      rank -> Enum.at(SecurityLabels.classes(), rank)
    end
  end

  defp links(nil), do: nil

  defp links(value) do
    case decode_any(value) do
      list when is_list(list) ->
        list
        |> Enum.flat_map(fn
          id when is_binary(id) -> if id?(id), do: [id], else: []
          %{} = link -> link_ref(link)
          _ -> []
        end)
        |> Jason.encode!()

      _ ->
        "[]"
    end
  end

  defp link_ref(link) do
    id = link["id"]
    type = link["type"]

    cond do
      not id?(id) -> []
      type_or_nil(type) -> [%{"type" => type, "id" => id}]
      true -> [%{"id" => id}]
    end
  end

  defp json_ids(value) do
    case decode_any(value) do
      list when is_list(list) -> list |> Enum.filter(&id?/1) |> Jason.encode!()
      _ -> nil
    end
  end

  defp json_map(value, keys) do
    case decode_any(value) do
      %{} = map ->
        map
        |> Map.take(keys)
        |> Map.new(fn
          {key, list} when is_list(list) -> {key, Enum.filter(list, &id?/1)}
          {key, id} -> {key, id_or_nil(id)}
        end)
        |> Jason.encode!()

      _ ->
        nil
    end
  end

  defp addresses(text) when is_binary(text) do
    ~r|optimal://[A-Za-z0-9_\-:./#?=&%]+|
    |> Regex.scan(text)
    |> Enum.map_join(" ", fn [uri] -> uri end)
  end

  defp addresses(_value), do: nil

  defp decode_list(value) when is_list(value), do: {:ok, value}

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :invalid
    end
  end

  defp decode_list(_value), do: :invalid

  defp decode_any(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_any(value), do: value

  # A key value that is an id is kept; a natural text key (an alias, a name, a
  # slug with spaces) is kept as a hash keyed by its table, so the tombstone
  # still tells versions of one row apart without saying what it named.
  defp key_value(_table, value) when is_integer(value), do: value

  defp key_value(table, value) do
    if id?(value), do: value, else: text_key(table, value)
  end

  @doc "The keyed hash a tombstone keeps of a natural text key of `table`."
  @spec text_key(String.t(), term()) :: String.t()
  def text_key(table, value) do
    mac = :crypto.mac(:hmac, :sha256, "optimal-ledger-redaction:" <> table, to_string(value))
    "h:" <> (mac |> Base.encode16(case: :lower) |> binary_part(0, 32))
  end

  @doc """
  Redacts the changes of one row in `txn`: its ledger rows (all, or those
  before the sequence `:before`, or those that occurred at or before the time
  `:through`), its captured rows not sealed yet (all but a delete, or those
  before `:capture_before`, or at or before `:through`), and its conflict
  payloads. Returns how many ledger rows were rewritten.

  `:through` is how a peer bounds an erasure it applies: the origin erased the
  versions up to that time, and a change made here after it stands.
  """
  @spec redact_entity(term(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, non_neg_integer()}
  def redact_entity(txn, workspace_id, table, entity_id, key_row, opts \\ []) do
    names = entity_types(table)

    marks = fn from ->
      names |> Enum.with_index(from) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)
    end

    {before_sql, before} = bound(opts, "sequence", 3 + length(names))

    {:ok, rows} =
      Store.txn_query(
        txn,
        """
        SELECT id, payload FROM sync_mutations
        WHERE workspace_id = ?1 AND entity_id = ?2 AND entity_type IN (#{marks.(3)})
          AND operation <> 'delete' AND redacted_at IS NULL#{before_sql}
        """,
        [workspace_id, entity_id] ++ names ++ before
      )

    at = now()

    Enum.each(rows, fn [id, payload] ->
      {tombstone, hash} = tombstone(tombstone_row(table, key_row, payload_row(payload)))

      {:ok, _} =
        Store.txn_execute(
          txn,
          "UPDATE sync_mutations SET payload = ?1, payload_hash = ?2, redacted_at = ?3 WHERE id = ?4",
          [tombstone, hash, at, id]
        )
    end)

    {capture_sql, capture_before} =
      bound([before: opts[:capture_before], through: opts[:through]], "seq", 3 + length(names))

    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        DELETE FROM sync_capture
        WHERE workspace_id = ?1 AND entity_key = ?2 AND table_name IN (#{marks.(3)})
          AND operation <> 'delete'#{capture_sql}
        """,
        [workspace_id, entity_id] ++ names ++ capture_before
      )

    redact_conflicts(txn, workspace_id, table, entity_id, key_row, names, marks.(3))
    {:ok, length(rows)}
  end

  # A condition on a ledger (`sequence`) or capture (`seq`) row's place, or on
  # the time it occurred, with its parameter at position `at`.
  defp bound(opts, column, at) do
    cond do
      opts[:before] -> {" AND #{column} < ?#{at}", [opts[:before]]}
      opts[:through] -> {" AND occurred_at <= ?#{at}", [opts[:through]]}
      true -> {"", []}
    end
  end

  defp redact_conflicts(txn, workspace_id, table, entity_id, key_row, names, marks) do
    {:ok, rows} =
      Store.txn_query(
        txn,
        """
        SELECT id, local_payload, remote_payload FROM sync_conflicts
        WHERE workspace_id = ?1 AND entity_key = ?2 AND table_name IN (#{marks})
        """,
        [workspace_id, entity_id] ++ names
      )

    for [id, local, remote] <- rows,
        {local2, remote2} =
          {redact_payload(table, key_row, local), redact_payload(table, key_row, remote)},
        {local2, remote2} != {local, remote} do
      {:ok, _} =
        Store.txn_execute(
          txn,
          "UPDATE sync_conflicts SET local_payload = ?1, remote_payload = ?2 WHERE id = ?3",
          [local2, remote2, id]
        )
    end

    :ok
  end

  defp redact_payload(_table, _key_row, nil), do: nil

  defp redact_payload(table, key_row, payload) do
    case decode_payload(payload) do
      %{"redacted" => true} -> payload
      decoded -> table |> tombstone_row(key_row, (decoded || %{})["row"]) |> tombstone() |> elem(0)
    end
  end

  defp payload_row(payload), do: (decode_payload(payload) || %{})["row"]

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_payload(%{} = payload), do: payload
  defp decode_payload(_payload), do: nil

  # A change sealed before an upgrade may name a table by its old name.
  defp entity_types(table) do
    old = for {from, to} <- Migrations.superseded_tables(), to == table, do: from
    [table | old]
  end

  @doc """
  In an erasure's transaction, after its deletes: redacts the earlier changes
  of every row of `workspace_ids` whose delete capture holds (the rows the
  erasure deleted and those its foreign keys cascaded to). A workspace that
  does not replicate captures nothing; its ledger, if it has one from when it
  did, is redacted by `redact_missing/2` (the erasure paths run it after the
  commit). Returns how many ledger rows were rewritten.
  """
  @spec redact_deleted(term(), [String.t()]) :: {:ok, non_neg_integer()}
  def redact_deleted(_txn, []), do: {:ok, 0}

  def redact_deleted(txn, workspace_ids) do
    workspace_ids = Enum.uniq(workspace_ids)
    marks = workspace_ids |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    {:ok, rows} =
      Store.txn_query(
        txn,
        """
        SELECT seq, workspace_id, table_name, entity_key, row_data FROM sync_capture
        WHERE operation = 'delete' AND entity_key IS NOT NULL AND workspace_id IN (#{marks})
        ORDER BY seq
        """,
        workspace_ids
      )

    total =
      Enum.reduce(rows, 0, fn [seq, ws, table, entity, row_data], acc ->
        key_row = decode_row(row_data) || %{}
        {:ok, n} = redact_entity(txn, ws, table, entity, key_row, capture_before: seq)
        acc + n
      end)

    # The append-only rows made from what was deleted (a chunk's intents and
    # citations, a context's decisions): their ids differ per Engine and their
    # deletes are not captured, so they are found by the row they link to.
    linked =
      rows
      |> Enum.group_by(fn [_seq, ws, _table, _entity, _row] -> ws end)
      |> Enum.reduce(0, fn {ws, ws_rows}, acc ->
        {:ok, n} = redact_linked(txn, ws, parents(ws_rows))
        acc + n
      end)

    {:ok, total + linked}
  end

  defp parents(rows) do
    rows
    |> Enum.filter(fn [_seq, _ws, table, _entity, _row] ->
      Map.has_key?(append_only_links(), table)
    end)
    |> Enum.group_by(fn [_seq, _ws, table, _entity, _row] -> table end, fn [_, _, _, entity, _] ->
      entity
    end)
  end

  @doc """
  After a seal: the deletes just sealed (ledger entries as `Capture` writes
  them) redact the earlier changes of their rows, for a delete no erasure path
  redacted in its own transaction. Never raises; a failure is logged and the
  next seal or `backfill/1` redacts.
  """
  @spec redact_sealed([list()]) :: :ok
  def redact_sealed(entries) do
    deletes =
      for [_id, _tenant, _org, ws, _device, table, entity, "delete", payload, _hash, _key, _at] <-
            entries,
          not String.starts_with?(entity, "row:"),
          do: {ws, table, entity, payload}

    if deletes != [] do
      {:ok, _} =
        Store.transaction(
          fn txn ->
            Enum.each(deletes, fn {ws, table, entity, payload} ->
              key_row = (Jason.decode!(payload) || %{})["row"] || %{}
              {:ok, [[seq]]} = delete_sequence(txn, ws, table, entity)
              {:ok, _} = redact_entity(txn, ws, table, entity, key_row, before: seq)
            end)

            {:ok, :redacted}
          end,
          120_000
        )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "[Sync] could not redact the changes of deleted rows: #{Exception.message(error)}"
      )

      :ok
  end

  defp delete_sequence(txn, ws, table, entity) do
    Store.txn_query(
      txn,
      """
      SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations
      WHERE workspace_id = ?1 AND entity_type = ?2 AND entity_id = ?3 AND operation = 'delete'
      """,
      [ws, table, entity]
    )
  end

  # What a peer does when a row of a table is erased while the row stays: the
  # columns it sets, and the rows derived from it that go (`{table, column}`,
  # by the link column naming the row). A request names a table on this list,
  # by type, and carries nothing else: a peer erases by its own rule.
  #
  # A forgotten memory is what `Memory.Versioned.Erasure` leaves at the origin:
  # flagged, with no text, no hash or address of it, no source chunk, and only
  # the governed keys (labels, partitions) of its metadata (`governed`: reduced
  # here from this Engine's own copy).
  @rules %{
    "memories" => %{
      type: "memory",
      erased: %{
        "is_forgotten" => 1,
        "content" => "",
        "content_hash" => nil,
        "citation_uri" => nil,
        "source_chunk_id" => nil
      },
      governed: ["metadata"],
      derived: [{"memory_embeddings", "memory_id"}]
    },
    # A context's text is replaced, not emptied: the rewrite replicates after
    # the request, and what was derived from the old text arrives as deletes.
    "contexts" => %{type: "context", erased: %{}, governed: [], derived: []}
  }

  @reasons ~w(memory_forget retention_redact backfill)
  @version ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?\z/
  @request_columns ~w(id tenant_id workspace_id target_type entity_id reason version)

  @doc "What a peer does for an erased row of `table`, or nil when it is not erased by request."
  @spec erasure_rule(String.t()) :: map() | nil
  def erasure_rule(table), do: Map.get(@rules, table)

  @doc "The reason codes a request may carry."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc """
  In an erasure's transaction, for rows of `table` (one with an erasure rule)
  the erasure keeps and empties: redacts every change of each row named in
  `ids` so far, and of the rows its rule derives from it, and, when the
  workspace replicates, records a `ledger_redactions` request for each, which
  is captured and replicated so peers erase their copies. `opts`:
  `:tenant_id` (required) and `:reason` (one of `reasons/0`).

  Call it after the erasing write when the rule restates the row's erased
  state (a forgotten memory: every change of it goes, a peer sets the rule's
  columns), or before it when the write itself must replicate (a context whose
  text is replaced by a redacted text).
  """
  @spec redact_rows(term(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, non_neg_integer()}
  def redact_rows(txn, workspace_id, table, ids, opts) do
    rule = Map.fetch!(@rules, table)
    tenant = Keyword.fetch!(opts, :tenant_id)
    reason = Keyword.fetch!(opts, :reason)
    true = reason in @reasons
    replicates? = replicates?(txn, workspace_id)
    version = version_now()

    total =
      Enum.reduce(Enum.uniq(ids), 0, fn id, acc ->
        {:ok, n} = redact_entity(txn, workspace_id, table, id, %{"id" => id})
        {:ok, d} = redact_derived(txn, workspace_id, rule, id, [])

        if replicates?,
          do: :ok = record_request(txn, tenant, workspace_id, rule.type, id, reason, version)

        acc + n + d
      end)

    {:ok, total}
  end

  # The changes of the rows a rule derives from row `id` (a memory's
  # embeddings, keyed by the memory and a model): found by the first key of
  # their `entity_id`, sealed or not.
  defp redact_derived(txn, workspace_id, rule, id, opts) do
    prefix = "[" <> Jason.encode!(id) <> ","

    Enum.reduce(rule.derived, {:ok, 0}, fn {table, column}, {:ok, acc} ->
      {:ok, rows} =
        Store.txn_query(
          txn,
          """
          SELECT DISTINCT entity_id FROM sync_mutations
          WHERE workspace_id = ?1 AND entity_type = ?2 AND substr(entity_id, 1, length(?3)) = ?3
            AND operation <> 'delete' AND redacted_at IS NULL
          """,
          [workspace_id, table, prefix]
        )

      n =
        Enum.reduce(rows, 0, fn [entity], n ->
          {:ok, k} =
            redact_entity(txn, workspace_id, table, entity, key_row_of_entity(column, entity), opts)

          n + k
        end)

      {:ok, _} =
        Store.txn_execute(
          txn,
          """
          DELETE FROM sync_capture
          WHERE workspace_id = ?1 AND table_name = ?2 AND operation <> 'delete'
            AND substr(entity_key, 1, length(?3)) = ?3
          """,
          [workspace_id, table, prefix]
        )

      {:ok, acc + n}
    end)
  end

  defp key_row_of_entity(column, entity) do
    case Jason.decode(entity) do
      {:ok, [first | _]} -> %{column => first}
      _ -> %{}
    end
  end

  defp replicates?(txn, workspace_id) do
    match?(
      {:ok, [_ | _]},
      Store.txn_query(txn, "SELECT 1 FROM sync_workspaces WHERE workspace_id = ?1", [workspace_id])
    )
  end

  defp record_request(txn, tenant, workspace_id, type, entity_id, reason, version) do
    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT INTO ledger_redactions (id, tenant_id, workspace_id, target_type, entity_id, reason, version)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """,
        ["lr_" <> random_id(), tenant, workspace_id, type, entity_id, reason, version]
      )

    :ok
  end

  # The time of an erasure, as change capture writes `occurred_at`
  # (`YYYY-MM-DDTHH:MM:SS.sss`, UTC), so a peer compares the two as text.
  defp version_now do
    {{y, mo, d}, {h, mi, sec}} = :calendar.universal_time()
    ms = rem(System.os_time(:millisecond), 1000)

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0B", [y, mo, d, h, mi, sec, ms])
    |> IO.iodata_to_binary()
  end

  @doc """
  What a request a peer sent asks of this Engine, checked: it carries the
  request's columns and nothing else, names a type with an erasure rule
  (`erasure_rule/1`), an id, a reason code and a version. The erased state is
  this Engine's rule for the table, never anything the peer sent.
  `{:ok, %{table:, entity_id:, key_row:, version:, rule:, columns:}}` or
  `{:error, :invalid_redaction}`. It reads the schema, so it runs before the
  apply's transaction.
  """
  @spec request(map(), (String.t() -> String.t())) :: {:ok, map()} | {:error, atom()}
  def request(row, target_table \\ & &1)

  def request(row, target_table) when is_map(row) do
    type = row["target_type"]
    entity = row["entity_id"]

    with true <- Enum.all?(Map.keys(row), &(&1 in @request_columns)),
         {table, rule} <- Enum.find(@rules, fn {_table, rule} -> rule.type == type end),
         table = target_table.(table),
         true <- id?(entity),
         true <- row["reason"] in @reasons,
         true <- is_binary(row["version"]) and Regex.match?(@version, row["version"]),
         [_ | _] = columns <- Capture.columns(table) do
      {:ok,
       %{
         table: table,
         entity_id: entity,
         key_row: %{"id" => entity},
         version: row["version"],
         rule: rule,
         columns: columns
       }}
    else
      _ -> {:error, :invalid_redaction}
    end
  end

  def request(_row, _target_table), do: {:error, :invalid_redaction}

  @doc """
  On a peer, in the apply's transaction: what an applied request erases here,
  bounded by its version. The changes of the row and of the rows its rule
  derives from it that occurred at or before the version are redacted, the
  derived rows are deleted, and the rule's columns are set, unless a change of
  the row here is newer than the version (the newer change wins, as for any
  other change). Returns `:ok` or `{:error, reason}`.
  """
  @spec apply_request(term(), String.t(), map()) :: :ok | {:error, term()}
  def apply_request(txn, workspace_id, request) do
    %{table: table, entity_id: id, version: version, rule: rule} = request
    {:ok, _} = redact_entity(txn, workspace_id, table, id, request.key_row, through: version)
    {:ok, _} = redact_derived(txn, workspace_id, rule, id, through: version)

    if newer_here?(txn, workspace_id, table, id, version) do
      :ok
    else
      with :ok <- delete_derived(txn, workspace_id, rule, id),
           {:ok, governed} <- governed(txn, workspace_id, table, id, rule.governed),
           do: set_erased(txn, workspace_id, table, id, Map.merge(rule.erased, governed))
    end
  end

  # The governed keys (labels and partitions) of a JSON column of this
  # Engine's own copy of the row, and nothing else of it.
  defp governed(_txn, _workspace_id, _table, _id, []), do: {:ok, %{}}

  defp governed(txn, workspace_id, table, id, columns) do
    select = Enum.map_join(columns, ", ", &quote_name/1)

    case Store.txn_query(
           txn,
           "SELECT #{select} FROM #{quote_name(table)} WHERE id = ?1 AND workspace_id = ?2",
           [id, workspace_id]
         ) do
      {:ok, [values]} ->
        {:ok,
         columns
         |> Enum.zip(values)
         |> Map.new(fn {column, value} ->
           {column,
            value
            |> SecurityLabels.metadata_map()
            |> Map.take(["security_labels", "partition_ids"])
            |> Jason.encode!()}
         end)}

      {:ok, []} ->
        {:ok, %{}}

      {:error, _} = error ->
        error
    end
  end

  defp newer_here?(txn, workspace_id, table, id, version) do
    match?(
      {:ok, [_ | _]},
      Store.txn_query(
        txn,
        """
        SELECT 1 FROM sync_mutations
        WHERE workspace_id = ?1 AND entity_type = ?2 AND entity_id = ?3 AND operation <> 'delete'
          AND redacted_at IS NULL AND occurred_at > ?4
        LIMIT 1
        """,
        [workspace_id, table, id, version]
      )
    )
  end

  defp delete_derived(txn, workspace_id, rule, id) do
    Enum.reduce_while(rule.derived, :ok, fn {table, column}, :ok ->
      case Store.txn_execute(
             txn,
             "DELETE FROM #{quote_name(table)} WHERE #{quote_name(column)} = ?1 AND workspace_id = ?2",
             [id, workspace_id]
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp set_erased(_txn, _workspace_id, _table, _id, erased) when map_size(erased) == 0, do: :ok

  defp set_erased(txn, workspace_id, table, id, erased) do
    names = Map.keys(erased)

    sets =
      names
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {n, i} -> "#{quote_name(n)} = ?#{i}" end)

    at = length(names)

    case Store.txn_execute(
           txn,
           "UPDATE #{quote_name(table)} SET #{sets} WHERE id = ?#{at + 1} AND workspace_id = ?#{at + 2}",
           Enum.map(names, &erased[&1]) ++ [id, workspace_id]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Append-only rows
  # ---------------------------------------------------------------------------

  # The rows of the append-only tables (a single INTEGER row id, which differs
  # per Engine) and the column that links each to the row it was made from.
  # A test checks this against `Sync.Lineage` and `Capture.append_only_tables/0`.
  @append_only_links %{
    "chunks" => [
      {"intents", "chunk_id"},
      {"classifications", "chunk_id"},
      {"cluster_members", "chunk_id"},
      {"citations", "chunk_id"}
    ],
    "contexts" => [
      {"decisions", "context_id"},
      {"entities", "context_id"},
      {"graph_edges", "source_id"},
      {"graph_edges", "target_id"},
      {"edges", "source_id"},
      {"edges", "target_id"},
      {"observations", "source"}
    ],
    "memories" => [
      {"memory_relations", "source_memory_id"},
      {"memory_relations", "target_memory_id"}
    ]
  }

  # What the origin deletes with a context that no foreign key cascades on a
  # peer (`Compliance.DerivedData`): a peer applying the context's delete
  # deletes its own copies. A chunk's and a memory's append-only rows go by
  # their foreign keys.
  @deleted_with %{
    "contexts" => [
      {"decisions", "context_id"},
      {"entities", "context_id"},
      {"graph_edges", "source_id"},
      {"graph_edges", "target_id"}
    ]
  }

  @doc "The append-only tables and the link column of each, by the table it links to."
  @spec append_only_links() :: %{String.t() => [{String.t(), String.t()}]}
  def append_only_links, do: @append_only_links

  @doc """
  In `txn`: the ledger rows (and unsealed captures) of the append-only rows
  made from the rows in `parents` (`%{"chunks" => ids, ...}`), redacted. The
  payload of such a row names its parent; the row is matched on that.
  Returns how many ledger rows were rewritten.
  """
  @spec redact_linked(term(), String.t(), %{String.t() => [String.t()]}) ::
          {:ok, non_neg_integer()}
  def redact_linked(txn, workspace_id, parents) do
    total =
      for {parent, ids} <- parents,
          ids != [],
          set = MapSet.new(ids),
          {table, column} <- Map.get(@append_only_links, parent, []),
          reduce: 0 do
        acc -> acc + redact_linked_rows(txn, workspace_id, table, column, set)
      end

    {:ok, total}
  end

  @like_batch 50

  # `LIKE` only narrows what is read (a `%` or `_` in an id widens it); the
  # decoded payload is then compared exactly.
  defp redact_linked_rows(txn, workspace_id, table, column, ids) do
    at = now()

    ids
    |> Enum.chunk_every(@like_batch)
    |> Enum.reduce(0, fn batch, acc ->
      params = [workspace_id, table] ++ Enum.map(batch, &("%" <> &1 <> "%"))

      likes = fn column_name ->
        batch
        |> Enum.with_index(3)
        |> Enum.map_join(" OR ", fn {_, i} -> "#{column_name} LIKE ?#{i}" end)
      end

      {:ok, rows} =
        Store.txn_query(
          txn,
          """
          SELECT id, payload FROM sync_mutations
          WHERE workspace_id = ?1 AND entity_type = ?2 AND operation <> 'delete'
            AND redacted_at IS NULL AND (#{likes.("payload")})
          """,
          params
        )

      n =
        for [id, payload] <- rows,
            row = payload_row(payload) || %{},
            MapSet.member?(ids, row[column]),
            reduce: 0 do
          n ->
            {tombstone, hash} = tombstone(tombstone_row(table, %{"id" => row["id"]}, row))

            {:ok, _} =
              Store.txn_execute(
                txn,
                "UPDATE sync_mutations SET payload = ?1, payload_hash = ?2, redacted_at = ?3 WHERE id = ?4",
                [tombstone, hash, at, id]
              )

            n + 1
        end

      {:ok, captured} =
        Store.txn_query(
          txn,
          "SELECT seq, row_data FROM sync_capture WHERE workspace_id = ?1 AND table_name = ?2 AND (#{likes.("row_data")})",
          params
        )

      for [seq, data] <- captured, MapSet.member?(ids, (decode_row(data) || %{})[column]) do
        {:ok, _} = Store.txn_execute(txn, "DELETE FROM sync_capture WHERE seq = ?1", [seq])
      end

      acc + n
    end)
  end

  @doc """
  On a peer, in the apply's transaction: the append-only rows the origin
  deletes with the rows in `parents` and that no foreign key deletes here
  (a context's decisions, entities and graph edges), deleted.
  """
  @spec delete_linked(term(), String.t(), %{String.t() => [String.t()]}) :: :ok
  def delete_linked(txn, workspace_id, parents) do
    for {parent, ids} <- parents,
        ids != [],
        {table, column} <- Map.get(@deleted_with, parent, []),
        batch <- Enum.chunk_every(ids, 500) do
      marks = batch |> Enum.with_index(2) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

      {:ok, _} =
        Store.txn_execute(
          txn,
          "DELETE FROM #{quote_name(table)} WHERE workspace_id = ?1 AND #{quote_name(column)} IN (#{marks})",
          [workspace_id | batch]
        )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Backfill
  # ---------------------------------------------------------------------------

  @doc """
  Redacts what an Engine erased before it redacted its ledger: the changes of
  rows whose delete is in the ledger, of rows of a keyed table that no longer
  exist, and of forgotten memories, in every workspace, plus the
  `sync_capture` and `sync_conflicts` rows of workspaces that no longer exist.
  For a forgotten memory of a workspace that replicates it also records a
  `ledger_redactions` request, so peers redact their copies, and afterwards
  the NATS ledger publisher purges the redacted rows' subjects.

  Idempotent: a redacted row is never counted again, and a forgotten memory
  whose changes are all redacted gets no second request.

  `dry_run: true` changes nothing and reports counts only (no ids, no
  content): the workspaces that replicate, the registered peers, and per
  table the rows still to redact and their ledger changes.
  """
  @spec backfill(keyword()) :: {:ok, map()}
  def backfill(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    # Sealing writes the ledger (and redacts the deletes it seals): a dry run
    # reads the ledger as it stands, and counts what is still to be sealed.
    unless dry_run, do: {:ok, _} = Capture.seal()

    found = find_exposed()
    linked = find_linked()

    report = %{
      dry_run: dry_run,
      sync_enabled_workspaces: count("SELECT COUNT(*) FROM sync_workspaces"),
      registered_peers: count("SELECT COUNT(*) FROM sync_peers"),
      exposed: Map.merge(summarize(found), summarize_linked(linked)),
      unsealed_capture_rows: count("SELECT COUNT(*) FROM sync_capture"),
      orphan_capture_rows: count(orphan_sql("sync_capture", "COUNT(*)")),
      orphan_conflict_rows: count(orphan_sql("sync_conflicts", "COUNT(*)"))
    }

    if dry_run do
      {:ok, report}
    else
      {redacted, requests, workspaces} = apply_backfill(found)
      linked_redacted = apply_linked(linked)
      {:ok, _} = Store.raw_query(orphan_sql("sync_capture", nil), [])
      {:ok, _} = Store.raw_query(orphan_sql("sync_conflicts", nil), [])
      purge_missing_in_nats(found)
      nats = flush_nats(workspaces)

      {:ok,
       Map.merge(report, %{
         ledger_rows_redacted: redacted + linked_redacted,
         peer_requests: requests,
         nats: nats
       })}
    end
  end

  defp count(sql) do
    {:ok, [[n]]} = Store.raw_query(sql, [])
    n || 0
  end

  # Rows of a workspace that no longer exists: what its ledger held went with
  # it by foreign key, the capture and the conflicts have no foreign key.
  defp orphan_sql(table, nil),
    do: "DELETE FROM #{table} WHERE workspace_id NOT IN (SELECT id FROM workspaces)"

  defp orphan_sql(table, what),
    do: "SELECT #{what} FROM #{table} WHERE workspace_id NOT IN (SELECT id FROM workspaces)"

  # Every row with unredacted changes that should have none, as
  # `{kind, workspace, tenant, table, entity, before}`: `before` limits the
  # redaction to the changes before the row's last delete (a row created again
  # after it keeps its new changes).
  defp find_exposed do
    deleted() ++ missing() ++ forgotten()
  end

  defp deleted do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT d.workspace_id, d.tenant_id, d.entity_type, d.entity_id, MAX(d.sequence)
        FROM sync_mutations d
        WHERE d.operation = 'delete' AND d.entity_id NOT LIKE 'row:%'
          AND EXISTS (SELECT 1 FROM sync_mutations m
                      WHERE m.workspace_id = d.workspace_id AND m.entity_type = d.entity_type
                        AND m.entity_id = d.entity_id AND m.operation <> 'delete'
                        AND m.redacted_at IS NULL AND m.sequence < d.sequence)
        GROUP BY d.workspace_id, d.tenant_id, d.entity_type, d.entity_id
        """,
        []
      )

    keys = Map.new(Capture.replicated_tables(), &{&1, Capture.key_columns(Capture.columns(&1))})

    for [ws, tenant, type, entity, seq] <- rows,
        key_row = key_row_of(Map.get(keys, target(type), []), entity),
        do: {:deleted, ws, tenant, target(type), entity, seq + 1, key_row}
  end

  # A row of a single-keyed table whose changes are in the ledger and that this
  # Engine no longer holds: deleted while its workspace did not replicate (its
  # delete was not captured), or by a peer's delete before this module.
  defp missing(workspace_id \\ nil) do
    for table <- Capture.replicated_tables(),
        table != @table,
        columns = Capture.columns(table),
        not Capture.rowid_key?(columns),
        [key] <- [Capture.key_columns(columns)],
        text? = text_column?(columns, key),
        row <- missing_rows(table, key, text?, workspace_id),
        do: row
  end

  # `entity_id` is the key as text: a key column of another type is compared
  # as text (PostgreSQL does not compare an integer with text).
  defp text_column?(columns, key) do
    type = Enum.find_value(columns, "", &(&1.name == key && (&1.type || "")))
    type == "" or String.contains?(type, "TEXT") or String.contains?(type, "CHAR")
  end

  defp missing_rows(table, key, text?, workspace_id) do
    names = entity_types(table)
    marks = names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    {scope, params} =
      if workspace_id,
        do: {" AND m.workspace_id = ?#{length(names) + 1}", names ++ [workspace_id]},
        else: {"", names}

    key_sql =
      if text?,
        do: "t.#{quote_name(key)}",
        else: "CAST(t.#{quote_name(key)} AS TEXT)"

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT DISTINCT m.workspace_id, m.tenant_id, m.entity_id FROM sync_mutations m
        WHERE m.entity_type IN (#{marks}) AND m.operation <> 'delete' AND m.redacted_at IS NULL
          AND m.entity_id NOT LIKE 'row:%'#{scope}
          AND NOT EXISTS (SELECT 1 FROM #{quote_name(table)} t WHERE #{key_sql} = m.entity_id)
        """,
        params
      )

    for [ws, tenant, entity] <- rows,
        do: {:missing, ws, tenant, table, entity, nil, %{key => entity}}
  end

  defp forgotten do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT DISTINCT m.workspace_id, m.tenant_id, m.entity_id FROM sync_mutations m
        JOIN memories r ON r.id = m.entity_id AND r.workspace_id = m.workspace_id
        WHERE m.entity_type = 'memories' AND m.operation <> 'delete' AND m.redacted_at IS NULL
          AND r.is_forgotten = 1
        """,
        []
      )

    for [ws, tenant, entity] <- rows,
        do: {:forgotten, ws, tenant, "memories", entity, nil, %{"id" => entity}}
  end

  defp target(table), do: Map.get(Migrations.superseded_tables(), table, table)

  # Counts per table, never ids.
  defp summarize(found) do
    found
    |> Enum.uniq_by(fn {_kind, ws, _tenant, table, entity, _before, _key} ->
      {ws, table, entity}
    end)
    |> Enum.group_by(fn {_kind, _ws, _tenant, table, _entity, _before, _key} -> table end)
    |> Map.new(fn {table, rows} ->
      changes = Enum.reduce(rows, 0, fn row, acc -> acc + exposed_changes(row) end)
      {table, %{rows: length(rows), changes: changes}}
    end)
  end

  defp exposed_changes({_kind, ws, _tenant, table, entity, before, _key}) do
    names = entity_types(table)
    marks = names |> Enum.with_index(3) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    {sql, params} =
      case before do
        nil -> {"", []}
        seq -> {" AND sequence < ?#{3 + length(names)}", [seq]}
      end

    {:ok, [[n]]} =
      Store.raw_query(
        """
        SELECT COUNT(*) FROM sync_mutations
        WHERE workspace_id = ?1 AND entity_id = ?2 AND entity_type IN (#{marks})
          AND operation <> 'delete' AND redacted_at IS NULL#{sql}
        """,
        [ws, entity] ++ names ++ params
      )

    n
  end

  @backfill_batch 200

  defp apply_backfill(found) do
    found
    |> Enum.uniq_by(fn {_kind, ws, _tenant, table, entity, _before, _key} ->
      {ws, table, entity}
    end)
    |> Enum.chunk_every(@backfill_batch)
    |> Enum.reduce({0, 0, MapSet.new()}, fn batch, {redacted, requests, workspaces} ->
      {:ok, {n, r}} =
        Store.transaction(
          fn txn ->
            {:ok,
             Enum.reduce(batch, {0, 0}, fn row, {n, r} ->
               {dn, dr} = backfill_row(txn, row)
               {n + dn, r + dr}
             end)}
          end,
          120_000
        )

      ws = batch |> Enum.map(&elem(&1, 1)) |> MapSet.new()
      {redacted + n, requests + r, MapSet.union(workspaces, ws)}
    end)
    |> then(fn {n, r, ws} -> {n, r, MapSet.to_list(ws)} end)
  end

  defp backfill_row(txn, {:forgotten, ws, tenant, table, entity, _before, _key}) do
    {:ok, n} = redact_rows(txn, ws, table, [entity], tenant_id: tenant, reason: "backfill")

    {n, if(replicates?(txn, ws), do: 1, else: 0)}
  end

  defp backfill_row(txn, {_kind, ws, _tenant, table, entity, before, key_row}) do
    {:ok, n} = redact_entity(txn, ws, table, entity, key_row, before: before)
    {n, 0}
  end

  # The append-only rows whose parent this Engine no longer holds, with
  # changes still unredacted: `{workspace, table, [ledger id], parent table}`.
  defp find_linked do
    for {parent, links} <- @append_only_links,
        {table, column} <- links,
        row <- linked_missing(parent, table, column),
        do: row
  end

  @scan_page 1_000

  defp linked_missing(parent, table, column) do
    linked_missing(parent, table, column, 0, [])
  end

  defp linked_missing(parent, table, column, after_sequence, acc) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, workspace_id, payload FROM sync_mutations
        WHERE entity_type = ?1 AND operation <> 'delete' AND redacted_at IS NULL AND sequence > ?2
        ORDER BY sequence LIMIT ?3
        """,
        [table, after_sequence, @scan_page]
      )

    if rows == [] do
      acc
    else
      links =
        for [_seq, id, ws, payload] <- rows,
            row = payload_row(payload) || %{},
            is_binary(row[column]),
            do: {id, ws, row[column], row}

      present = present_ids(parent, links |> Enum.map(&elem(&1, 2)) |> Enum.uniq())

      found =
        for {id, ws, parent_id, row} <- links,
            not MapSet.member?(present, parent_id),
            do: {ws, table, id, row}

      [last | _] = List.last(rows)
      linked_missing(parent, table, column, last, acc ++ found)
    end
  end

  defp present_ids(_parent, []), do: MapSet.new()

  defp present_ids(parent, ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(MapSet.new(), fn batch, acc ->
      marks = batch |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

      {:ok, rows} =
        Store.raw_query("SELECT id FROM #{quote_name(parent)} WHERE id IN (#{marks})", batch)

      MapSet.union(acc, MapSet.new(List.flatten(rows)))
    end)
  end

  defp summarize_linked(linked) do
    linked
    |> Enum.uniq_by(fn {_ws, _table, id, _row} -> id end)
    |> Enum.group_by(fn {_ws, table, _id, _row} -> table end)
    |> Map.new(fn {table, rows} -> {table, %{rows: length(rows), changes: length(rows)}} end)
  end

  defp apply_linked(linked) do
    linked
    |> Enum.uniq_by(fn {_ws, _table, id, _row} -> id end)
    |> Enum.chunk_every(@backfill_batch)
    |> Enum.reduce(0, fn batch, total ->
      at = now()

      {:ok, n} =
        Store.transaction(
          fn txn ->
            Enum.each(batch, fn {_ws, table, id, row} ->
              {tombstone, hash} = tombstone(tombstone_row(table, %{"id" => row["id"]}, row))

              {:ok, _} =
                Store.txn_execute(
                  txn,
                  "UPDATE sync_mutations SET payload = ?1, payload_hash = ?2, redacted_at = ?3 WHERE id = ?4 AND redacted_at IS NULL",
                  [tombstone, hash, at, id]
                )
            end)

            {:ok, length(batch)}
          end,
          120_000
        )

      total + n
    end)
  end

  # A row deleted while its workspace did not replicate has no delete in the
  # ledger and no request, so the publisher never purges its subject: the
  # erasure asks for the purge of each such row's subject itself.
  defp purge_missing_in_nats(found) do
    found
    |> Enum.filter(&match?({:missing, _ws, _tenant, _table, _entity, _before, _key}, &1))
    |> Enum.group_by(fn {_, ws, tenant, _, _, _, _} -> {tenant, ws} end, fn {_, _, _, table, entity,
                                                                             _, _} ->
      [table, entity]
    end)
    |> Enum.each(fn {{tenant, ws}, rows} ->
      publisher =
        Application.get_env(
          :optimal_engine,
          :nats_ledger_publisher,
          OptimalEngine.Storage.NATS.LedgerPublisher
        )

      OptimalEngine.Storage.NATS.LedgerPublisher.forget_rows(publisher, tenant, ws, rows, "erased")
    end)
  end

  @doc """
  After an erasure committed: the NATS ledger publisher runs a pass over the
  workspaces now, so what was erased leaves the stream (a delete purges its
  row's subject, a redaction request the subject of the row it names). What
  the publisher returns (`%{state: "off"}` without the flow).
  """
  @spec flush_nats([String.t()]) :: map()
  def flush_nats([]), do: %{state: "nothing_to_flush"}

  def flush_nats(workspace_ids) do
    OptimalEngine.Storage.NATS.LedgerPublisher.flush(Enum.uniq(workspace_ids))
  end

  @doc """
  After an erasure committed, for workspaces that did not replicate when it
  ran (their deletes were not captured): redacts the changes their ledger
  still holds of rows that no longer exist. Cheap when the workspace has no
  ledger.
  """
  @spec redact_missing([String.t()]) :: :ok
  def redact_missing(workspace_ids) do
    for ws <- Enum.uniq(workspace_ids), not replicates_now?(ws), has_ledger?(ws) do
      rows = missing(ws)
      apply_backfill(rows)
      purge_missing_in_nats(rows)
    end

    :ok
  rescue
    error ->
      Logger.error("[Sync] could not redact the ledger of erased rows: #{Exception.message(error)}")
      :ok
  end

  defp replicates_now?(ws),
    do:
      match?(
        {:ok, [_ | _]},
        Store.raw_query("SELECT 1 FROM sync_workspaces WHERE workspace_id = ?1", [ws])
      )

  defp has_ledger?(ws),
    do:
      match?(
        {:ok, [_ | _]},
        Store.raw_query(
          "SELECT 1 FROM sync_mutations WHERE workspace_id = ?1 AND redacted_at IS NULL LIMIT 1",
          [ws]
        )
      )

  defp decode_row(nil), do: nil

  defp decode_row(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, row} when is_map(row) and map_size(row) > 0 -> row
      _ -> nil
    end
  end

  defp decode_row(row) when is_map(row), do: row

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end
end
