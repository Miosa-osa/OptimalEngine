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
        ORDER BY sequence
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

  @doc """
  A stored payload (`sync_conflicts`, a ledger row) as its tombstone: the
  key and what the gate classifies the row by. `nil` stays `nil`, a tombstone
  stays as it is.
  """
  @spec tombstone_payload(String.t(), map(), term()) :: String.t() | nil
  def tombstone_payload(table, key_row, payload), do: redact_payload(table, key_row, payload)

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
  After a seal, for what no erasure redacted in its own transaction:

    * a delete just sealed redacts the earlier changes of its row;
    * a change just sealed of a row an erasure already asked to redact (a
      `ledger_redactions` request at or after the time it occurred, as when
      the seal read the change before a forget or a retention redact took it
      out of the capture) is redacted too, with what the rule derives.

  Each row is redacted in a transaction of its own, so one that fails leaves
  the others done. Never raises; a failure is logged, and `backfill/1`
  redacts what is left (nothing else retries it).
  """
  @spec redact_sealed([list()]) :: :ok
  def redact_sealed(entries) do
    deletes =
      for [_id, _tenant, _org, ws, _device, table, entity, "delete", payload, _hash, _key, _at] <-
            entries,
          not String.starts_with?(entity, "row:"),
          do: {ws, table, entity, payload}

    Enum.each(deletes, fn {ws, table, entity, payload} ->
      guarded("the changes of a deleted row", fn ->
        Store.transaction(
          fn txn ->
            key_row = (Jason.decode!(payload) || %{})["row"] || %{}
            {:ok, [[seq]]} = delete_sequence(txn, ws, table, entity)
            {:ok, _} = redact_entity(txn, ws, table, entity, key_row, before: seq)
            {:ok, :redacted}
          end,
          120_000
        )
      end)
    end)

    entries
    |> requested_after_seal()
    |> Enum.each(fn {ws, request} ->
      guarded("a change sealed after its erasure", fn ->
        Store.transaction(
          fn txn ->
            :ok = redact_request_ledger(txn, ws, request)
            {:ok, :redacted}
          end,
          120_000
        )
      end)
    end)

    :ok
  rescue
    error ->
      Logger.error("[Sync] could not redact after a seal: #{Exception.message(error)}")
      :ok
  end

  defp guarded(what, fun) do
    case fun.() do
      {:ok, _} -> :ok
      other -> Logger.error("[Sync] could not redact #{what}: #{inspect(other)}")
    end
  rescue
    error -> Logger.error("[Sync] could not redact #{what}: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.error("[Sync] could not redact #{what}: #{kind} #{inspect(reason)}")
  end

  # The rows of sealed changes (not deletes) that a request already names with
  # a version at or after the change: `{workspace, request}` for each.
  defp requested_after_seal(entries) do
    for [_id, _tenant, _org, ws, _device, table, entity, op, _payload, _hash, _key, at] <- entries,
        op != "delete",
        {rule_table, id} <- [erased_target(table, entity)],
        rule_table != nil,
        uniq: true do
      {ws, rule_table, id, at}
    end
    |> Enum.flat_map(fn {ws, rule_table, id, at} ->
      case outstanding_version(ws, rule_table, id) do
        version when is_binary(version) and is_binary(at) and at <= version ->
          [{ws, request_for(rule_table, id, version)}]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  # The table with an erasure rule a change belongs to, and the row's id: the
  # row itself, or the row a derived row of the rule names first.
  defp erased_target(table, entity) do
    cond do
      Map.has_key?(rules(), table) ->
        {table, entity}

      parent = derived_parent(table) ->
        case Jason.decode(entity) do
          {:ok, [first | _]} when is_binary(first) -> {parent, first}
          _ -> {nil, nil}
        end

      true ->
        {nil, nil}
    end
  end

  # The table with an erasure rule that derives rows of `table`, or nil.
  defp derived_parent(table) do
    Enum.find_value(rules(), fn {parent, rule} ->
      if List.keymember?(rule.derived, table, 0), do: parent
    end)
  end

  defp outstanding_version(ws, table, id) do
    case Store.raw_query(
           "SELECT MAX(version) FROM ledger_redactions WHERE workspace_id = ?1 AND target_type = ?2 AND entity_id = ?3",
           [ws, rules()[table].type, id]
         ) do
      {:ok, [[version]]} -> version
      _ -> nil
    end
  end

  defp request_for(table, id, version),
    do: %{
      table: table,
      entity_id: id,
      key_row: %{"id" => id},
      version: version,
      rule: rules()[table]
    }

  @doc """
  The version a request this Engine holds erased the row of `table` (one
  with an erasure rule, or a row its rule derives) named by the change's
  `entity_id` at, when the change occurred at or before it; `nil` otherwise.
  A change that old is one the erasure took out: a peer that had not caught
  up, or a hub relaying one, must not bring it back.
  """
  @spec erased_version(String.t(), String.t(), map()) :: String.t() | nil
  def erased_version(workspace_id, table, %{"operation" => op} = mutation) when op != "delete" do
    with {rule_table, id} when is_binary(rule_table) <-
           erased_target(table, mutation["entity_id"] || ""),
         version when is_binary(version) <- outstanding_version(workspace_id, rule_table, id),
         at when is_binary(at) <- mutation["occurred_at"],
         true <- at <= version do
      version
    else
      _ -> nil
    end
  end

  def erased_version(_workspace_id, _table, _mutation), do: nil

  @doc """
  The target of a change a batch would apply, as `erased_target/2` finds it
  (`{table, id}` or `{nil, nil}`), for a batch that tracks the requests it
  applied itself.
  """
  @spec erased_target_of(String.t(), String.t()) :: {String.t() | nil, String.t() | nil}
  def erased_target_of(table, entity), do: erased_target(table, entity)

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

  defp rules, do: @rules

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
    version = Keyword.get_lazy(opts, :version, &version_now/0)

    # Under the ledger lock (PostgreSQL), so a seal that read these changes
    # before the erasure writes them either before it (redacted here) or after
    # this commits (its `redact_sealed/1` finds the request).
    :ok = OptimalEngine.Sync.Postgres.lock_ledger(txn)

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
         true <- not future_version?(row["version"]),
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

  # How far ahead of this Engine's clock a request's version may be: the clock
  # drift allowed between devices (`DEVICE_SIGNATURE_SKEW_MS`, 10 minutes). A
  # version beyond it would erase every change the row gets until then.
  @version_skew_ms 600_000

  defp future_version?(version) do
    {:ok, limit} =
      DateTime.utc_now()
      |> DateTime.add(@version_skew_ms, :millisecond)
      |> DateTime.to_unix(:millisecond)
      |> DateTime.from_unix(:millisecond)

    version > limit |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

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
    :ok = redact_request_ledger(txn, workspace_id, request)

    if newer_here?(txn, workspace_id, table, id, version) do
      :ok
    else
      with :ok <- delete_derived(txn, workspace_id, rule, id),
           {:ok, governed} <- governed(txn, workspace_id, table, id, rule.governed),
           do: set_erased(txn, workspace_id, table, id, Map.merge(rule.erased, governed))
    end
  end

  @doc """
  The ledger part of `apply_request/3`: this Engine's changes of the named row,
  and of the rows its rule derives from it, that occurred at or before the
  request's version are redacted. Idempotent.
  """
  @spec redact_request_ledger(term(), String.t(), map()) :: :ok
  def redact_request_ledger(txn, workspace_id, request) do
    %{table: table, entity_id: id, version: version, rule: rule} = request
    {:ok, _} = redact_entity(txn, workspace_id, table, id, request.key_row, through: version)
    {:ok, _} = redact_derived(txn, workspace_id, rule, id, through: version)
    :ok
  end

  @doc """
  In an apply, before its ledger rows are written (`Sync`, which writes them
  at the end of its transaction): the changes still pending in `entries` that
  an erasure applied in the same batch takes out become tombstones, marked
  `"redacted_at"`, so the text never reaches the ledger. `erasure` is
  `{:request, request}` (the named row and what its rule derives, at or
  before its version), `{:delete, table, entity_id, occurred_at}` (the row's
  changes at or before the delete), or `{:parents, %{table => ids}}` (the
  append-only rows made from deleted parents, `append_only_links/0`).
  """
  @spec tombstone_pending([map()], tuple()) :: [map()]
  def tombstone_pending(entries, erasure) do
    at = now()

    Enum.map(entries, fn entry ->
      if entry["operation"] != "delete" and not Map.has_key?(entry, "redacted_at") and
           pending_erased?(entry, erasure),
         do: tombstone_entry(entry, at),
         else: entry
    end)
  end

  defp pending_erased?(entry, {:request, request}) do
    type = entry["entity_type"]
    at = entry["occurred_at"]
    earlier? = is_binary(at) and at <= request.version

    earlier? and
      ((type in entity_types(request.table) and entry["entity_id"] == request.entity_id) or
         Enum.any?(request.rule.derived, fn {table, _column} ->
           type == table and
             String.starts_with?(
               entry["entity_id"] || "",
               "[" <> Jason.encode!(request.entity_id) <> ","
             )
         end))
  end

  defp pending_erased?(entry, {:delete, table, entity, occurred_at}) do
    at = entry["occurred_at"]

    entry["entity_type"] in entity_types(table) and entry["entity_id"] == entity and
      (not is_binary(occurred_at) or (is_binary(at) and at <= occurred_at))
  end

  defp pending_erased?(entry, {:parents, parents}) do
    row = get_in(entry, ["payload", "row"]) || %{}

    Enum.any?(parents, fn {parent, ids} ->
      Enum.any?(Map.get(append_only_links(), parent, []), fn {table, column} ->
        entry["entity_type"] == table and row[column] in ids
      end)
    end)
  end

  defp tombstone_entry(entry, at) do
    table = entry["entity_type"]
    row = get_in(entry, ["payload", "row"]) || %{}
    key_row = pending_key_row(entry["entity_id"], row)
    {tombstone, _hash} = tombstone(tombstone_row(target(table), key_row, row))

    entry
    |> Map.put("payload", Jason.decode!(tombstone))
    |> Map.put("redacted_at", at)
  end

  # The key of a pending change, from its row (the schema is not read inside
  # the apply's transaction): the columns holding the parts of a composite
  # `entity_id`, else the column holding the id, else `id`.
  defp pending_key_row(entity, row) do
    parts =
      case Jason.decode(entity || "") do
        {:ok, list} when is_list(list) -> list
        _ -> [entity]
      end

    case Map.filter(row, fn {_column, value} -> value in parts and value != nil end) do
      keys when map_size(keys) > 0 ->
        if Map.has_key?(row, "id") and row["id"] in parts, do: %{"id" => row["id"]}, else: keys

      _ ->
        %{"id" => row["id"] || entity}
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
      {"graph_edges", "target_id"}
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

  # Append-only tables no erasure deletes with a parent: `edges` (the legacy
  # graph, its endpoints are any node, not only contexts) and `observations`
  # (`source` is a provenance word such as `explicit`, not a row). Their rows
  # are redacted only by their own deletes.
  @unlinked_append_only ~w(edges observations)

  # Links that are not foreign keys: an endpoint that names no context may be
  # an entity or any other node, so a missing context is no evidence that the
  # row was erased (`backfill/1` requires the context's delete in the ledger).
  @soft_links [{"graph_edges", "source_id"}, {"graph_edges", "target_id"}]

  @doc "The append-only tables no erasure deletes with a parent row."
  @spec unlinked_append_only() :: [String.t()]
  def unlinked_append_only, do: @unlinked_append_only

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
          ORDER BY sequence
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
  defp missing(workspace_id \\ nil, tables \\ :all) do
    for table <- Capture.replicated_tables(),
        table != @table,
        tables == :all or table in tables,
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
    # The version erased is when the forget happened (its change, the last of
    # the row's in the ledger), not now: a peer's change made after the forget
    # stands, as it would have against the forget itself.
    {:ok, n} =
      redact_rows(txn, ws, table, [entity],
        tenant_id: tenant,
        reason: "backfill",
        version: forget_version(txn, ws, table, entity)
      )

    {n, if(replicates?(txn, ws), do: 1, else: 0)}
  end

  defp backfill_row(txn, {_kind, ws, _tenant, table, entity, before, key_row}) do
    {:ok, n} = redact_entity(txn, ws, table, entity, key_row, before: before)
    {n, 0}
  end

  defp forget_version(txn, ws, table, entity) do
    case Store.txn_query(
           txn,
           "SELECT MAX(occurred_at) FROM sync_mutations WHERE workspace_id = ?1 AND entity_type = ?2 AND entity_id = ?3 AND operation <> 'delete'",
           [ws, table, entity]
         ) do
      {:ok, [[at]]} when is_binary(at) ->
        normalized = at |> String.replace(" ", "T") |> String.trim_trailing("Z")
        if Regex.match?(@version, normalized), do: normalized, else: version_now()

      _ ->
        version_now()
    end
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

      parent_ids = links |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      present = present_ids(parent, parent_ids)

      # A foreign key: a parent that is gone was deleted. Any other link: only a
      # parent whose delete is in the ledger was erased.
      erased? =
        if {table, column} in @soft_links do
          deleted = deleted_ids(parent, parent_ids)
          fn ws, parent_id -> MapSet.member?(deleted, {ws, parent_id}) end
        else
          fn _ws, parent_id -> not MapSet.member?(present, parent_id) end
        end

      found =
        for {id, ws, parent_id, row} <- links,
            not MapSet.member?(present, parent_id),
            erased?.(ws, parent_id),
            do: {ws, table, id, row}

      [last | _] = List.last(rows)
      linked_missing(parent, table, column, last, acc ++ found)
    end
  end

  # `{workspace, id}` of the rows of `parent` among `ids` whose delete is in
  # the ledger.
  defp deleted_ids(_parent, []), do: MapSet.new()

  defp deleted_ids(parent, ids) do
    names = entity_types(parent)

    ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(MapSet.new(), fn batch, acc ->
      type_marks = names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

      id_marks =
        batch
        |> Enum.with_index(length(names) + 1)
        |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

      {:ok, rows} =
        Store.raw_query(
          "SELECT DISTINCT workspace_id, entity_id FROM sync_mutations WHERE operation = 'delete' AND entity_type IN (#{type_marks}) AND entity_id IN (#{id_marks})",
          names ++ batch
        )

      MapSet.union(acc, MapSet.new(rows, fn [ws, id] -> {ws, id} end))
    end)
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

  `tables` scopes the search to the tables the erasure deleted rows from (an
  erasure passes what it removed, `removed_tables/1`), so an erasure in a
  workspace that does not replicate does not scan every replicated table.
  `:all` (the default) is the whole workspace, as a workspace's removal needs.
  """
  @spec redact_missing([String.t()], :all | [String.t()]) :: :ok
  def redact_missing(workspace_ids, tables \\ :all)
  def redact_missing(_workspace_ids, []), do: :ok

  def redact_missing(workspace_ids, tables) do
    for ws <- Enum.uniq(workspace_ids), not replicates_now?(ws), has_ledger?(ws) do
      rows = missing(ws, tables)
      apply_backfill(rows)
      purge_missing_in_nats(rows)
    end

    :ok
  rescue
    error ->
      Logger.error("[Sync] could not redact the ledger of erased rows: #{Exception.message(error)}")
      :ok
  end

  @doc """
  The replicated tables an erasure deleted rows from, from its per-step
  counts (`%{table_or_step => count}`): the keys that name a table and
  counted at least one row, plus `extra`.
  """
  @spec removed_tables(map(), [String.t()]) :: :all | [String.t()]
  def removed_tables(removed, extra \\ []) do
    replicated = MapSet.new(Capture.replicated_tables())

    removed
    |> Enum.filter(fn {_key, count} -> is_integer(count) and count > 0 end)
    |> Enum.map(fn {key, _count} -> key |> to_string() |> String.replace_suffix("_deleted", "") end)
    |> Kernel.++(extra)
    |> with_cascades()
    |> case do
      :all -> :all
      tables -> tables |> Enum.filter(&MapSet.member?(replicated, &1)) |> Enum.uniq()
    end
  end

  # The tables and every table whose rows a foreign key deletes with theirs
  # (a chunk's embeddings): read from the schema once per boot. A schema that
  # cannot be read scopes nothing out (`:all`).
  defp with_cascades(tables) do
    case foreign_keys() do
      {:ok, edges} -> closure(MapSet.new(tables), edges)
      :error -> :all
    end
  end

  defp closure(set, edges) do
    next =
      for {child, parent} <- edges, MapSet.member?(set, parent), into: set, do: child

    if MapSet.size(next) == MapSet.size(set), do: MapSet.to_list(set), else: closure(next, edges)
  end

  defp foreign_keys do
    key = {__MODULE__, :foreign_keys, OptimalEngine.Sync.Postgres.active?()}

    case :persistent_term.get(key, nil) do
      nil ->
        sql =
          if OptimalEngine.Sync.Postgres.active?(),
            do: """
            SELECT tc.table_name, ccu.table_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.constraint_column_usage ccu
              ON ccu.constraint_name = tc.constraint_name AND ccu.constraint_schema = tc.constraint_schema
            WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = current_schema()
            """,
            else: """
            SELECT m.name, p."table" FROM sqlite_master m, pragma_foreign_key_list(m.name) p
            WHERE m.type = 'table'
            """

        case Store.raw_query(sql, []) do
          {:ok, rows} ->
            edges = Enum.map(rows, fn [child, parent] -> {child, parent} end)
            :persistent_term.put(key, edges)
            {:ok, edges}

          _ ->
            :error
        end

      edges ->
        {:ok, edges}
    end
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
