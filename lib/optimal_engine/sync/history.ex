defmodule OptimalEngine.Sync.History do
  @moduledoc """
  What replication did, for people to read: one `sync_runs` row per peer
  cycle (`record_run/3`, `runs/3`) and the changes in a workspace's ledger
  with where each came from (`ledger/3`).

  * A run is written once at the end of every cycle with a peer, complete or
    failed: `ok` (the cycle ran), `paused` (the peer is on another schema
    version) or `error` (anything else, a halted peer included). `pulled` is
    the changes applied from the peer, `pushed` the changes sent to it,
    `conflicts` the conflicts this Engine recorded while applying, and
    `gated` the changes the data-class gate held back on either side. A run
    that could not start because another was under way records nothing. The
    newest #{10_000} rows of each peer are kept.
  * A ledger entry names its table, row, operation and device, never its
    payload. Its `origin` is `local` when the device is this Engine's replica
    id and `peer` otherwise, with `origin_label` the label of the peer that
    answers under that replica id, or `"unknown peer"`.

  Both lists are newest first, `limit` (default 50) is capped at 200, and
  `next_cursor` is the `before` that reads the next page, `nil` on the last.
  Every timestamp is ISO-8601 UTC.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Sync

  @keep_runs 10_000
  @default_limit 50
  @max_limit 200
  @unknown_peer "unknown peer"

  @doc "The page size a request gets: `limit` when positive, at most #{@max_limit}."
  @spec limit(integer() | nil) :: pos_integer()
  def limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  def limit(_n), do: @default_limit

  @doc """
  Records one cycle with `peer`, started at `started_at`, from the result
  `Sync.run_peer/1` returns (or `%{status: "error"}` for a cycle that raised),
  and prunes the peer's oldest rows past #{@keep_runs}. `message` is what the
  peer's status says after the cycle.
  """
  @spec record_run(map(), String.t(), map(), String.t() | nil) :: :ok
  def record_run(peer, started_at, result, message) do
    peer_id = Sync.peer_id(peer)
    {pulled, pull_conflicts, pull_gated} = pull_counts(result[:pull])
    {pushed, push_gated} = push_counts(result[:push])

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_runs
          (tenant_id, workspace_id, peer_id, started_at, finished_at, status, pulled, pushed,
           conflicts, gated, message)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          peer.tenant_id,
          peer.workspace_id,
          peer_id,
          iso(started_at),
          iso(Sync.now_iso()),
          run_status(result[:status]),
          pulled,
          pushed,
          pull_conflicts,
          pull_gated + push_gated,
          message
        ]
      )

    {:ok, _} =
      Store.raw_query(
        """
        DELETE FROM sync_runs
        WHERE peer_id = ?1 AND id NOT IN (
          SELECT id FROM sync_runs WHERE peer_id = ?1 ORDER BY id DESC LIMIT ?2)
        """,
        [peer_id, keep_runs()]
      )

    :ok
  end

  defp keep_runs, do: Application.get_env(:optimal_engine, :sync_runs_kept, @keep_runs)

  defp run_status("active"), do: "ok"
  defp run_status("paused_version"), do: "paused"
  defp run_status(_status), do: "error"

  defp pull_counts({:ok, %{applied: applied} = totals}),
    do: {applied, Map.get(totals, :conflicts, 0), get_in(totals, [:skipped, :gated]) || 0}

  defp pull_counts(_pulled), do: {0, 0, 0}

  defp push_counts({:ok, %{sent: sent} = totals}), do: {sent, Map.get(totals, :gated, 0)}
  defp push_counts(_pushed), do: {0, 0}

  @doc """
  Runs of a workspace's peers, newest first. Options: `:peer_id`, `:limit`,
  `:before` (a run id).
  """
  @spec runs(String.t(), String.t(), keyword()) :: %{data: [map()], next_cursor: String.t() | nil}
  def runs(tenant_id, workspace_id, opts \\ []) do
    limit = limit(opts[:limit])

    {where, params} =
      filters([tenant_id, workspace_id], [
        {opts[:peer_id], "peer_id = ?"},
        {opts[:before], "id < ?"}
      ])

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, peer_id, started_at, finished_at, status, pulled, pushed, conflicts, gated, message
        FROM sync_runs WHERE tenant_id = ?1 AND workspace_id = ?2#{where}
        ORDER BY id DESC LIMIT ?#{length(params) + 1}
        """,
        params ++ [limit + 1]
      )

    labels = Map.new(Sync.peers(tenant_id, workspace_id), &{&1.id, &1.label})

    page(rows, limit, &to_run(&1, labels))
  end

  defp to_run(row, labels) do
    [id, peer_id, started, finished, status, pulled, pushed, conflicts, gated, message] = row

    %{
      id: id,
      peer_id: peer_id,
      peer_label: Map.get(labels, peer_id),
      started_at: started,
      finished_at: finished,
      status: status,
      pulled: pulled,
      pushed: pushed,
      conflicts: conflicts,
      gated: gated,
      message: message
    }
  end

  @doc """
  The changes in a workspace's ledger, newest first, this Engine's own
  included. Options: `:limit`, `:before` (a sequence), `:table`, `:origin`
  (`"local"` or `"peer"`).
  """
  @spec ledger(String.t(), String.t(), keyword()) ::
          %{data: [map()], next_cursor: String.t() | nil}
  def ledger(tenant_id, workspace_id, opts \\ []) do
    {:ok, _} = Sync.Capture.seal()
    limit = limit(opts[:limit])
    local = Sync.replica_id()

    {origin_sql, origin_param} =
      case opts[:origin] do
        "local" -> {"m.device_id = ?", local}
        "peer" -> {"m.device_id != ?", local}
        _ -> {nil, nil}
      end

    {where, params} =
      filters([tenant_id, workspace_id], [
        {opts[:before], "m.sequence < ?"},
        {opts[:table], "m.entity_type = ?"},
        {origin_param, origin_sql}
      ])

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT m.sequence, m.entity_type, m.entity_id, m.operation, m.device_id, m.occurred_at, m.recorded_at
        FROM sync_mutations m
        WHERE m.tenant_id = ?1 AND m.workspace_id = ?2 AND #{Sync.change_row_sql("m")}#{where}
        ORDER BY m.sequence DESC LIMIT ?#{length(params) + 1}
        """,
        params ++ [limit + 1]
      )

    own_label = Sync.label()
    peers = peer_labels(tenant_id, workspace_id)

    page(rows, limit, fn [sequence, table, entity_id, operation, device, occurred, recorded] ->
      {origin, origin_label} =
        if device == local,
          do: {"local", own_label},
          else: {"peer", Map.get(peers, device, @unknown_peer)}

      %{
        sequence: sequence,
        table: table,
        entity_id: entity_id,
        op: op(operation),
        device_id: device,
        origin: origin,
        origin_label: origin_label,
        occurred_at: iso(occurred),
        recorded_at: iso(recorded)
      }
    end)
  end

  # The label of each peer by the replica id it answers under: the workspace's
  # own peers first, then the tenant's other peers for a device they forwarded.
  defp peer_labels(tenant_id, workspace_id) do
    by_replica = fn peers ->
      for %{peer_replica_id: replica, label: label} <- peers,
          is_binary(replica),
          into: %{},
          do: {replica, label}
    end

    tenant_id
    |> Sync.peers()
    |> by_replica.()
    |> Map.merge(by_replica.(Sync.peers(tenant_id, workspace_id)))
  end

  defp op("create"), do: "insert"
  defp op(operation), do: operation

  # Optional conditions, numbered after the fixed parameters.
  defp filters(fixed, conditions) do
    Enum.reduce(conditions, {"", fixed}, fn
      {nil, _sql}, acc ->
        acc

      {value, sql}, {where, params} ->
        n = length(params) + 1
        {where <> " AND " <> String.replace(sql, "?", "?#{n}"), params ++ [value]}
    end)
  end

  # One row past the page says there is another page.
  defp page(rows, limit, to_entry) do
    {shown, rest} = Enum.split(rows, limit)
    data = Enum.map(shown, to_entry)

    cursor =
      case {rest, List.last(shown)} do
        {[], _} -> nil
        {_more, [first | _]} -> to_string(first)
      end

    %{data: data, next_cursor: cursor}
  end

  @doc """
  A stored time as ISO-8601 UTC: SQLite's `datetime('now')` text and a
  zoneless ISO time (both UTC) get a `T` and a `Z`; a time with a zone stays.
  """
  @spec iso(String.t() | nil) :: String.t() | nil
  def iso(nil), do: nil

  def iso(text) when is_binary(text) do
    text = String.replace(text, " ", "T", global: false)
    if Regex.match?(~r/(Z|[+-]\d\d:?\d\d)\z/, text), do: text, else: text <> "Z"
  end

  def iso(other), do: other
end
