defmodule OptimalEngine.Authority.Evidence do
  @moduledoc """
  The signed, hash-chained evidence log for authority.

  Every authority event (a grant issued, admitted, denied, checkpointed,
  completed, withheld, narrowed, suspended, restored, revoked; a policy
  published; a local deny added or lifted; an enforcement that could not be
  carried out; a receipt from an outside enforcer) is appended as one entry.

  Each entry carries the tenant's next sequence number and the hash of the
  previous entry, is hashed over its RFC 8785 canonical form, and is signed
  with the tenant's evidence key (separate from the grant key). `verify/1`
  recomputes the chain, so a changed, removed, inserted, or reordered entry
  is detected. `checkpoint/1` signs the current head so it can be anchored
  outside the Engine; `export/2` returns the chain a page at a time, with its
  head and the public keys needed to verify it anywhere.

  Appends run inside the Store's serialized transaction, so the chain never
  forks under concurrency.
  """

  alias OptimalEngine.Authority.{CanonicalJSON, JWS, Keys}
  alias OptimalEngine.Store

  require Logger

  @genesis String.duplicate("0", 64)
  # Reads walk the chain in pages of this many entries, by tenant_seq, so none holds a
  # whole chain of any length at once.
  @where_page 1_000

  @kinds ~w(grant.issued grant.narrowed grant.admitted grant.denied grant.checkpoint
            grant.suspended grant.restored grant.revoked action.completed action.withheld
            decision.denied decision.ask decision.allowed decision.observed
            policy.published policy.loosened local_deny.added local_deny.lifted
            approval.requested approval.approved approval.denied
            could_not_enforce external.receipt issuer.registered revocations.received
            settings.changed key.rotated key.minted key.revoked integrity.finding
            agent_action.step connector.registered connector.changed connector.deleted
            connector.run workspace.renamed workspace.rekeyed)

  @doc "The evidence kinds the Engine records."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The tenant's active evidence key, for a caller that appends inside its own
  transaction (`append_in/5`) and so fetches the key first: creating one
  writes to the Store. `nil` when the Engine cannot sign evidence, for
  example the key that wraps the signing key is missing.
  """
  @spec signing_key(String.t()) :: map() | nil
  def signing_key(tenant_id) do
    case Keys.active(tenant_id, "evidence") do
      {:ok, key} -> key
      {:error, _reason} -> nil
    end
  end

  @doc """
  Whether `entry` sits where it was signed: its `prev_hash` is the hash of the
  entry before it in the tenant's chain (the genesis hash for the first).
  Entry hashes cover `prev_hash` and `seq`, so a signed entry copied to
  another position, or one whose predecessor is gone, is not linked.
  """
  @spec linked?(String.t(), map()) :: boolean()
  def linked?(_tenant_id, %{"seq" => 1, "prev_hash" => prev_hash}), do: prev_hash == @genesis

  def linked?(tenant_id, %{"seq" => seq, "prev_hash" => prev_hash})
      when is_integer(seq) and seq > 1 do
    case Store.raw_query(
           "SELECT hash FROM authority_evidence WHERE tenant_id = ?1 AND tenant_seq = ?2",
           [tenant_id, seq - 1]
         ) do
      {:ok, [[hash]]} -> hash == prev_hash
      _ -> false
    end
  end

  def linked?(_tenant_id, _entry), do: false

  @doc """
  Appends one entry. `attrs` may carry `:jti`, `:subject`, `:action`,
  `:resource`, `:workspace_id`, and `:detail` (a JSON-able map).
  """
  @spec append(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(tenant_id, kind, attrs \\ %{}) when kind in @kinds do
    with {:ok, key} <- Keys.active(tenant_id, "evidence") do
      Store.transaction(fn txn -> append_in(txn, key, tenant_id, kind, attrs) end)
    end
  end

  @doc """
  Appends one entry inside a Store transaction the caller already holds, so
  the entry commits or rolls back with the caller's own writes. `key` is the
  tenant's active evidence key (`OptimalEngine.Authority.Keys.active/2`); the
  caller fetches it before the transaction opens, because creating one writes
  to the Store. Takes the same `attrs` as `append/3`.
  """
  @spec append_in(term(), map(), String.t(), String.t(), map()) :: {:ok, map()}
  def append_in(txn, key, tenant_id, kind, attrs \\ %{}) when kind in @kinds do
    {:ok, rows} =
      Store.txn_query(
        txn,
        "SELECT tenant_seq, hash FROM authority_evidence WHERE tenant_id = ?1 ORDER BY tenant_seq DESC LIMIT 1",
        [tenant_id]
      )

    {seq, prev_hash} =
      case rows do
        [[last_seq, last_hash]] -> {last_seq + 1, last_hash}
        [] -> {1, @genesis}
      end

    entry = %{
      "tenant_id" => tenant_id,
      "seq" => seq,
      "id" => "ev_" <> random_id(),
      "kind" => kind,
      "jti" => attrs[:jti],
      "subject" => attrs[:subject],
      "action" => attrs[:action],
      "resource" => attrs[:resource],
      "workspace_id" => attrs[:workspace_id],
      "detail" => attrs[:detail] || %{},
      "prev_hash" => prev_hash,
      "recorded_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }

    hash = CanonicalJSON.hash(entry)
    signature = Keys.sign(key, hash) |> JWS.encode64()

    {:ok, 1} =
      Store.txn_execute(
        txn,
        """
        INSERT INTO authority_evidence
          (id, tenant_id, tenant_seq, kind, jti, subject, action, resource, workspace_id,
           detail, prev_hash, hash, kid, signature, recorded_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        """,
        [
          entry["id"],
          tenant_id,
          seq,
          kind,
          entry["jti"],
          entry["subject"],
          entry["action"],
          entry["resource"],
          entry["workspace_id"],
          CanonicalJSON.encode(entry["detail"]),
          prev_hash,
          hash,
          key.kid,
          signature,
          entry["recorded_at"]
        ]
      )

    {:ok, Map.merge(entry, %{"hash" => hash, "kid" => key.kid, "signature" => signature})}
  end

  @doc "Entries after `after_seq` (exclusive), oldest first."
  @spec list(String.t(), keyword()) :: [map()]
  def list(tenant_id, opts \\ []) do
    after_seq = Keyword.get(opts, :after, 0)
    limit = Keyword.get(opts, :limit, 1_000) |> max(1) |> min(10_000)

    filters =
      [
        {"jti = ?", opts[:jti]},
        {"subject = ?", opts[:subject]},
        {"kind = ?", opts[:kind]}
      ]
      |> Enum.reject(fn {_sql, value} -> is_nil(value) end)

    where =
      ["tenant_id = ?1", "tenant_seq > ?2"] ++
        (filters
         |> Enum.with_index(3)
         |> Enum.map(fn {{sql, _}, i} -> String.replace(sql, "?", "?#{i}") end))

    params = [tenant_id, after_seq] ++ Enum.map(filters, &elem(&1, 1))

    {:ok, rows} =
      Store.raw_query(
        select_sql() <>
          " WHERE " <> Enum.join(where, " AND ") <> " ORDER BY tenant_seq ASC LIMIT #{limit}",
        params
      )

    Enum.map(rows, &to_entry/1)
  end

  @doc """
  Every entry matching a SQL condition over the evidence columns (`kind`,
  `jti`, `subject`, `workspace_id`, `detail`), oldest first. Parameters start
  at `?2`; `?1` is the tenant. For internal callers only: the condition is
  code, values are always bound.

  It reads in pages of #{@where_page} by sequence number and returns all of
  them, so a caller asking for the entries of a long chain gets every one.
  `stream/3` reads the same entries lazily, for a caller that does not need them
  all at once.
  """
  @spec where(String.t(), String.t(), [term()]) :: [map()]
  def where(tenant_id, condition, params) do
    tenant_id |> stream(condition, params) |> Enum.to_list()
  end

  @doc "How many entries `where/3` would return for the same condition, counted by the database."
  @spec count(String.t(), String.t(), [term()]) :: non_neg_integer()
  def count(tenant_id, condition, params) do
    {:ok, [[n]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM authority_evidence WHERE tenant_id = ?1 AND (" <> condition <> ")",
        [tenant_id | params]
      )

    n
  end

  @doc """
  The entries `where/3` returns, oldest first, as a stream that reads them in
  pages of #{@where_page} by `tenant_seq` (keyset, not offset), each page when the
  one before it is used up. A chain of any length is walked in bounded memory.
  The condition defaults to every entry of the tenant.
  """
  @spec stream(String.t(), String.t(), [term()]) :: Enumerable.t()
  def stream(tenant_id, condition \\ "1 = 1", params \\ []) do
    sql =
      select_sql() <>
        " WHERE tenant_id = ?1 AND (" <>
        condition <>
        ") AND tenant_seq > ?#{length(params) + 2} ORDER BY tenant_seq ASC LIMIT #{@where_page}"

    0
    |> Stream.unfold(fn
      nil ->
        nil

      after_seq ->
        {:ok, rows} = Store.raw_query(sql, [tenant_id | params] ++ [after_seq])

        case Enum.map(rows, &to_entry/1) do
          [] -> nil
          page when length(page) < @where_page -> {page, nil}
          page -> {page, List.last(page)["seq"]}
        end
    end)
    |> Stream.flat_map(& &1)
  end

  @doc """
  Verifies one entry on its own: its hash over the canonical fields and its
  signature against the tenant's evidence keys. Chain position is checked
  by `verify/1`.
  """
  @spec verify_one(String.t(), map()) :: :ok | {:error, atom()}
  def verify_one(tenant_id, entry) do
    if CanonicalJSON.hash(chained_fields(entry)) != entry["hash"] do
      {:error, :hash_mismatch}
    else
      case Keys.verification_key(tenant_id, entry["kid"], "evidence") do
        {:ok, public_key} ->
          if signature_valid?(public_key, entry), do: :ok, else: {:error, :bad_signature}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies the tenant's whole chain: sequence continuity, previous-hash
  links, each entry's hash, and each signature against the evidence keys.
  Also checks every signed checkpoint still matches the chain.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, map()}
  def verify(tenant_id) do
    checkpoints = checkpoints(tenant_id)
    checkpointed = MapSet.new(checkpoints, & &1["seq"])

    # The chain is read a page at a time; only the hashes at checkpointed seqs are kept.
    result =
      tenant_id
      |> stream()
      |> Enum.reduce_while({:ok, 0, @genesis, %{}}, &verify_step(tenant_id, checkpointed, &1, &2))

    with {:ok, count, head, by_seq} <- result,
         :ok <- verify_checkpoints(tenant_id, checkpoints, by_seq) do
      {:ok, %{entries: count, head: head}}
    else
      {:error, %{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @doc "Signs and stores the current head so it can be anchored externally."
  @spec checkpoint(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def checkpoint(tenant_id, anchor \\ nil) do
    with {:ok, key} <- Keys.active(tenant_id, "evidence") do
      case Store.raw_query(
             "SELECT tenant_seq, hash FROM authority_evidence WHERE tenant_id = ?1 ORDER BY tenant_seq DESC LIMIT 1",
             [tenant_id]
           ) do
        {:ok, [[seq, hash]]} ->
          statement =
            CanonicalJSON.encode(%{"tenant_id" => tenant_id, "seq" => seq, "hash" => hash})

          signature = Keys.sign(key, statement) |> JWS.encode64()

          {:ok, _} =
            Store.raw_query(
              """
              INSERT OR REPLACE INTO authority_checkpoints (tenant_id, tenant_seq, hash, kid, signature, anchor)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6)
              """,
              [tenant_id, seq, hash, key.kid, signature, anchor]
            )

          {:ok,
           %{
             "tenant_id" => tenant_id,
             "seq" => seq,
             "hash" => hash,
             "kid" => key.kid,
             "signature" => signature,
             "anchor" => anchor
           }}

        {:ok, []} ->
          {:error, :empty_chain}
      end
    end
  end

  @doc """
  A page of the chain for export, with the public keys and checkpoints needed to
  verify it:

    * `"entries"` - at most `:limit` entries (default and most 10,000) after
      `:after` (default 0), oldest first, none past the head;
    * `"head"` - `{"seq", "hash"}` of the chain's last entry when the page is read,
      or of the entry at `:until`, so pages read with the same `:until` share one
      head however the chain grows; `nil` for an empty chain;
    * `"head_signature"` - `{"kid", "signature"}`, the evidence key's signature over
      the statement a checkpoint signs for that head, so a head moved to match a
      bundle cut short is caught; `nil` with no head;
    * `"total"` - how many entries the chain holds from seq 1 through the head, the
      same on every page;
    * `"complete"` - true only on the page whose last entry is the head (and for an
      empty chain);
    * `"next_after"` - the `:after` of the next page, `nil` on the last.

  `{:error, :until_out_of_range}` when `:until` names no entry of the chain, or one
  below `:after`.
  """
  @spec export(String.t(), keyword()) :: {:ok, map()} | {:error, :until_out_of_range}
  def export(tenant_id, opts \\ []) do
    after_seq = Keyword.get(opts, :after, 0)
    limit = opts |> Keyword.get(:limit, 10_000) |> max(1) |> min(10_000)

    with {:ok, head} <- head(tenant_id, after: after_seq, until: Keyword.get(opts, :until)) do
      through = if head, do: head["seq"], else: 0

      entries =
        tenant_id
        |> stream("tenant_seq > ?2 AND tenant_seq <= ?3", [after_seq, through])
        |> Enum.take(limit)

      last = if entries == [], do: after_seq, else: List.last(entries)["seq"]
      complete = last >= through

      {:ok,
       %{
         "tenant_id" => tenant_id,
         "entries" => entries,
         "complete" => complete,
         "total" => count(tenant_id, "tenant_seq <= ?2", [through]),
         "head" => head,
         "head_signature" => head_signature(tenant_id, head),
         "next_after" => if(complete, do: nil, else: last),
         "keys" => Keys.jwks(tenant_id),
         "checkpoints" => checkpoints(tenant_id)
       }}
    end
  end

  @doc """
  A page as NDJSON: one line per entry (`ndjson_entry/1`), then one `export_end` line
  (`ndjson_end/1`). There are no key or checkpoint lines: a verifier reads the
  evidence keys by `kid` from `GET /api/authority/keys`.
  """
  @spec to_ndjson(map()) :: iodata()
  def to_ndjson(%{"entries" => entries} = page),
    do: [Enum.map(entries, &ndjson_entry/1), ndjson_end(page)]

  @doc """
  An entry's NDJSON line, with its newline: the entry object as `export/2` returns it,
  with `"type": "entry"` added.
  """
  @spec ndjson_entry(map()) :: iodata()
  def ndjson_entry(entry), do: [entry |> Map.put("type", "entry") |> Jason.encode_to_iodata!(), ?\n]

  @doc """
  The `export_end` line of an NDJSON export of `page`, with its newline:
  `{"type":"export_end","head":...,"head_signature":...,"total":N,"complete":...,"next_after":...}`.
  """
  @spec ndjson_end(map()) :: iodata()
  def ndjson_end(page) do
    line =
      Jason.OrderedObject.new([
        {"type", "export_end"},
        {"head", page["head"]},
        {"head_signature", page["head_signature"]},
        {"total", page["total"]},
        {"complete", page["complete"]},
        {"next_after", page["next_after"]}
      ])

    [Jason.encode_to_iodata!(line), ?\n]
  end

  @doc """
  An export's head: `{"seq", "hash"}` of the chain's last entry, or with `until:` of
  the entry at that seq; `nil` for an empty chain. `{:error, :until_out_of_range}`
  when `until:` names no entry, or one below `after:` (default 0).
  """
  @spec head(String.t(), keyword()) :: {:ok, map() | nil} | {:error, :until_out_of_range}
  def head(tenant_id, opts \\ []) do
    after_seq = Keyword.get(opts, :after, 0)

    case Keyword.get(opts, :until) do
      nil ->
        {:ok, head_row(tenant_id, "1 = 1", [])}

      until when is_integer(until) and until >= 1 and until >= after_seq ->
        case head_row(tenant_id, "tenant_seq = ?2", [until]) do
          nil -> {:error, :until_out_of_range}
          head -> {:ok, head}
        end

      _until ->
        {:error, :until_out_of_range}
    end
  end

  defp head_row(tenant_id, condition, params) do
    case Store.raw_query(
           "SELECT tenant_seq, hash FROM authority_evidence WHERE tenant_id = ?1 AND (#{condition}) ORDER BY tenant_seq DESC LIMIT 1",
           [tenant_id | params]
         ) do
      {:ok, [[seq, hash]]} -> %{"seq" => seq, "hash" => hash}
      {:ok, []} -> nil
    end
  end

  @doc """
  The tenant's evidence key's signature over `head`, `{"kid", "signature"}`: the
  statement a checkpoint signs. `nil` for no head, or a tenant without an evidence key.
  """
  @spec head_signature(String.t(), map() | nil) :: map() | nil
  def head_signature(_tenant_id, nil), do: nil

  def head_signature(tenant_id, head) do
    case Keys.active(tenant_id, "evidence") do
      {:ok, key} ->
        %{
          "kid" => key.kid,
          "signature" => key |> Keys.sign(head_statement(tenant_id, head)) |> JWS.encode64()
        }

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Verifies an exported bundle without the Engine's database: every entry's link,
  hash and signature, and that the bundle is the whole chain through its head.

  The head must be signed by one of the bundle's keys (`"head_signature"`). A
  bundle that is the whole chain starts at seq 1, holds `"total"` entries, ends at
  the head and says it is `"complete"`; one cut short is caught. A page that is not
  the whole chain (it says it is not complete, or it starts after seq 1) is
  `{:error, %{reason: :partial}}`, with how far its entries verified: join the pages
  into one bundle, with the last page's head, to verify them.
  """
  @spec verify_export(map()) :: {:ok, map()} | {:error, map()}
  def verify_export(%{"entries" => entries, "keys" => %{"keys" => keys}} = bundle) do
    public_keys =
      for %{"kid" => kid} = jwk <- keys,
          {:ok, key} <- [Keys.from_jwk(jwk)],
          into: %{},
          do: {kid, key}

    with {:ok, last_seq, last_hash} <- verify_run(entries, public_keys),
         :ok <- verify_completeness(bundle, public_keys, entries, last_seq, last_hash) do
      {:ok, %{entries: length(entries), head: last_hash}}
    end
  end

  defp verify_run(entries, public_keys) do
    Enum.reduce_while(entries, {:ok, nil, nil}, fn entry, {:ok, prev_seq, prev_hash} ->
      expected_seq = if prev_seq, do: prev_seq + 1, else: entry["seq"]
      expected_prev = prev_hash || if(entry["seq"] == 1, do: @genesis, else: entry["prev_hash"])

      cond do
        entry["seq"] != expected_seq ->
          {:halt, {:error, %{seq: entry["seq"], reason: :sequence_gap}}}

        entry["prev_hash"] != expected_prev ->
          {:halt, {:error, %{seq: entry["seq"], reason: :broken_link}}}

        CanonicalJSON.hash(chained_fields(entry)) != entry["hash"] ->
          {:halt, {:error, %{seq: entry["seq"], reason: :hash_mismatch}}}

        not signature_valid?(public_keys[entry["kid"]], entry) ->
          {:halt, {:error, %{seq: entry["seq"], reason: :bad_signature}}}

        true ->
          {:cont, {:ok, entry["seq"], entry["hash"]}}
      end
    end)
  end

  defp verify_completeness(bundle, public_keys, entries, last_seq, last_hash) do
    head = bundle["head"]
    count = length(entries)
    first_seq = if entries == [], do: nil, else: hd(entries)["seq"]

    # Only an empty chain has no head.
    head_ok =
      if is_nil(head),
        do: count == 0 and bundle["total"] == 0,
        else: is_map(head) and is_integer(head["seq"]) and is_binary(head["hash"])

    cond do
      not head_ok ->
        {:error, %{reason: :missing_head}}

      head != nil and
          not head_signed?(bundle["tenant_id"], head, bundle["head_signature"], public_keys) ->
        {:error, %{seq: head["seq"], reason: :bad_head_signature}}

      bundle["complete"] == false or (first_seq != nil and first_seq != 1) ->
        {:error,
         %{
           reason: :partial,
           entries: count,
           verified_from: first_seq,
           verified_through: last_seq,
           next_after: bundle["next_after"]
         }}

      bundle["complete"] != true or not is_integer(bundle["total"]) ->
        {:error, %{reason: :missing_completeness}}

      count != bundle["total"] ->
        {:error, %{reason: :count_mismatch, entries: count, total: bundle["total"]}}

      head == nil ->
        :ok

      last_seq != head["seq"] or last_hash != head["hash"] ->
        {:error, %{seq: last_seq, reason: :head_mismatch}}

      true ->
        :ok
    end
  end

  defp head_signed?(tenant_id, head, signature, public_keys) do
    with %{"kid" => kid, "signature" => encoded} when is_binary(encoded) <- signature,
         key when not is_nil(key) <- public_keys[kid],
         {:ok, raw} <- JWS.decode64(encoded) do
      :crypto.verify(:eddsa, :none, head_statement(tenant_id, head), raw, [key, :ed25519])
    else
      _ -> false
    end
  end

  # What a checkpoint, and an export's head, sign.
  defp head_statement(tenant_id, head) do
    CanonicalJSON.encode(%{"tenant_id" => tenant_id, "seq" => head["seq"], "hash" => head["hash"]})
  end

  # ---------------------------------------------------------------------------

  defp verify_step(tenant_id, checkpointed, entry, {:ok, prev_seq, prev_hash, seen}) do
    case verify_entry(tenant_id, entry, prev_seq + 1, prev_hash) do
      :ok ->
        seen =
          if MapSet.member?(checkpointed, entry["seq"]),
            do: Map.put(seen, entry["seq"], entry["hash"]),
            else: seen

        {:cont, {:ok, entry["seq"], entry["hash"], seen}}

      {:error, reason} ->
        {:halt, {:error, %{seq: entry["seq"], reason: reason}}}
    end
  end

  defp verify_entry(tenant_id, entry, expected_seq, prev_hash) do
    cond do
      entry["seq"] != expected_seq ->
        {:error, :sequence_gap}

      entry["prev_hash"] != prev_hash ->
        {:error, :broken_link}

      CanonicalJSON.hash(chained_fields(entry)) != entry["hash"] ->
        {:error, :hash_mismatch}

      true ->
        case Keys.verification_key(tenant_id, entry["kid"], "evidence") do
          {:ok, public_key} ->
            if signature_valid?(public_key, entry), do: :ok, else: {:error, :bad_signature}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # `by_seq` holds the chain's hash at each checkpointed seq the chain still has.
  defp verify_checkpoints(tenant_id, checkpoints, by_seq) do
    Enum.reduce_while(checkpoints, :ok, fn checkpoint, :ok ->
      statement =
        CanonicalJSON.encode(%{
          "tenant_id" => tenant_id,
          "seq" => checkpoint["seq"],
          "hash" => checkpoint["hash"]
        })

      with {:ok, public_key} <- Keys.verification_key(tenant_id, checkpoint["kid"], "evidence"),
           {:ok, signature} <- JWS.decode64(checkpoint["signature"]),
           true <- :crypto.verify(:eddsa, :none, statement, signature, [public_key, :ed25519]),
           true <- by_seq[checkpoint["seq"]] == checkpoint["hash"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, %{seq: checkpoint["seq"], reason: :checkpoint_mismatch}}}
      end
    end)
  end

  @doc "The tenant's signed checkpoints, oldest first."
  @spec checkpoints(String.t()) :: [map()]
  def checkpoints(tenant_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT tenant_seq, hash, kid, signature, anchor, created_at FROM authority_checkpoints WHERE tenant_id = ?1 ORDER BY tenant_seq",
        [tenant_id]
      )

    Enum.map(rows, fn [seq, hash, kid, signature, anchor, created_at] ->
      %{
        "seq" => seq,
        "hash" => hash,
        "kid" => kid,
        "signature" => signature,
        "anchor" => anchor,
        "created_at" => created_at
      }
    end)
  end

  defp signature_valid?(nil, _entry), do: false

  defp signature_valid?(public_key, entry) do
    case JWS.decode64(entry["signature"] || "") do
      {:ok, signature} when byte_size(signature) == 64 ->
        :crypto.verify(:eddsa, :none, entry["hash"], signature, [public_key, :ed25519])

      _ ->
        false
    end
  end

  @chained ~w(tenant_id seq id kind jti subject action resource workspace_id detail prev_hash recorded_at)

  defp chained_fields(entry), do: Map.take(entry, @chained)

  defp select_sql do
    """
    SELECT tenant_id, tenant_seq, id, kind, jti, subject, action, resource, workspace_id, detail,
           prev_hash, hash, kid, signature, recorded_at
    FROM authority_evidence
    """
  end

  defp to_entry([
         tenant,
         seq,
         id,
         kind,
         jti,
         subject,
         action,
         resource,
         workspace,
         detail,
         prev,
         hash,
         kid,
         sig,
         at
       ]) do
    %{
      "tenant_id" => tenant,
      "seq" => seq,
      "id" => id,
      "kind" => kind,
      "jti" => jti,
      "subject" => subject,
      "action" => action,
      "resource" => resource,
      "workspace_id" => workspace,
      "detail" => decode_detail(detail, tenant, seq, id),
      "prev_hash" => prev,
      "hash" => hash,
      "kid" => kid,
      "signature" => sig,
      "recorded_at" => at
    }
  end

  # A row whose detail is not JSON (written by hand, or damaged) reads as an
  # empty detail and is logged, once per entry for the life of the node, not on
  # every read. Its hash then no longer matches, so it fails verification like
  # any other changed entry, instead of stopping every reader of the chain
  # with an exception.
  defp decode_detail(nil, _tenant, _seq, _id), do: %{}

  defp decode_detail(detail, tenant, seq, id) do
    case Jason.decode(detail) do
      {:ok, decoded} ->
        decoded

      {:error, _reason} ->
        warn_once(tenant, seq, id)
        %{}
    end
  end

  defp warn_once(tenant, seq, id) do
    key = {__MODULE__, :unreadable_detail, tenant, id}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "[Evidence] entry #{id} (seq #{seq}) of #{tenant} has a detail that is not JSON; reading it as empty"
      )
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
