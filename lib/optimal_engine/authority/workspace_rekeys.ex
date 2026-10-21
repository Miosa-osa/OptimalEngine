defmodule OptimalEngine.Authority.WorkspaceRekeys do
  @moduledoc """
  The signed record of a workspace id repair.

  An operator can move a workspace's rows to a new id
  (`OptimalEngine.DataSteward.rename_workspace/3`, `repair_orphan_scope/3`).
  Signed evidence is never rewritten: an entry keeps the workspace id it was
  written with, and what was signed under the old id is read through the
  repair. The move itself is appended to the evidence chain as
  `workspace.rekeyed` (from, to, who, mode), in the transaction that moves the
  rows:

      current(rekeys, signed_id, seq)

  applies the re-keys recorded after entry `seq`, in order.

  ## Two modes

    * `rename`: the rows of `from` were moved to a workspace that took its
      place (`rename_workspace/3`). `from` is the same workspace under a new
      id.
    * `merge`: the rows of an unregistered id were moved into a workspace that
      already existed and has its own data and policies (`repair_orphan_scope/3`).
      `from` is not that workspace.

  A step of an action chain is verified through both: it is a record of what
  happened, and it moved with the rows. A grant is followed through renames
  only, so a grant for an unregistered id is never carried into a workspace
  it was not issued for. A local deny is followed through both, because
  following can only add denials.

  ## What counts as a re-key

  `list/2` returns only entries a reader can rely on, so a row written into the
  table by hand explains nothing:

    * the entry belongs to the tenant, is of kind `workspace.rekeyed`, names
      `from` and `to` as strings and has a `mode` of `rename` or `merge`;
    * its hash and signature verify against a tenant evidence key that is not
      revoked (`OptimalEngine.Authority.Evidence.verify_one/2`);
    * its `prev_hash` is the hash of the entry before it
      (`OptimalEngine.Authority.Evidence.linked?/2`). That is a consistency
      check, not a second proof: a forged row can carry a matching link, and
      what keeps it out is the signature.

  Each call checks every re-key of the tenant, which is cheap because repairs
  are rare. A caller that follows one or two ids (an admission) passes them as
  `near:` and only the re-keys reachable from them are checked: a signature
  is verified for a re-key that can matter, not for every repair the tenant
  ever made. A re-key that was deleted is not noticed here: its steps stop
  verifying (a deleted record explains nothing, so this fails closed), and the
  gap in the chain is reported by `Evidence.verify/1` and the integrity scan
  (`OptimalEngine.Authority.Integrity.scan/2`).

  `list(tenant, trust: :recorded)` returns every structurally valid entry
  without checking signatures. It is for the one reader that cannot be hurt
  by a forged row: local denies, where following a re-key can only make a deny
  apply to more, so a forged re-key cannot lift one.
  """

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Store

  require Logger

  @kind "workspace.rekeyed"
  @max 10_000
  @modes %{"rename" => :rename, "merge" => :merge}

  @type mode :: :rename | :merge
  @type rekey :: %{seq: pos_integer(), from: String.t(), to: String.t(), mode: mode() | nil}

  @doc """
  Appends the re-key of `from` to `to` inside the caller's Store transaction.
  `key` comes from `OptimalEngine.Authority.Evidence.signing_key/1`; with `nil`
  nothing is written.
  """
  @spec record(term(), map() | nil, String.t(), String.t(), String.t(), String.t(), mode()) ::
          :ok
  def record(txn, key, tenant_id, from, to, actor, mode) when mode in [:rename, :merge] do
    do_record(txn, key, tenant_id, from, to, actor, mode)
  end

  defp do_record(_txn, nil, _tenant_id, _from, _to, _actor, _mode), do: :ok

  defp do_record(txn, key, tenant_id, from, to, actor, mode) do
    # The action is the one the Authority plug names for these routes (a
    # POST is a write); the old and the new id are in the detail.
    {:ok, _entry} =
      Evidence.append_in(txn, key, tenant_id, @kind, %{
        subject: actor,
        action: "write",
        resource: "optimal://#{to}",
        workspace_id: to,
        detail: %{"from" => from, "to" => to, "by" => actor, "mode" => Atom.to_string(mode)}
      })

    :ok
  end

  @doc "Whether the tenant has recorded any workspace id repair at all (one indexed read)."
  @spec any?(String.t()) :: boolean()
  def any?(tenant_id) do
    match?(
      {:ok, [_]},
      Store.raw_query(
        "SELECT 1 FROM authority_evidence WHERE tenant_id = ?1 AND kind = ?2 LIMIT 1",
        [tenant_id, @kind]
      )
    )
  end

  @doc """
  Every re-key of the tenant that verifies and links to the entry before it
  (see the module doc), oldest first. Reads at most 10,000 entries and logs
  when the tenant has that many. Options:

    * `trust: :recorded` skips the signature and link checks;
    * `near: ids` keeps only the re-keys reachable from those workspace ids,
      by following `from` to `to`, and `after: seq` only those recorded after
      that position. What `current/4` would apply to `ids` after `seq` is
      always among them.
  """
  @spec list(String.t(), keyword()) :: [rekey()]
  def list(tenant_id, opts \\ []) do
    trust = Keyword.get(opts, :trust, :verified)
    entries = Evidence.list(tenant_id, kind: @kind, limit: @max)

    if length(entries) >= @max do
      Logger.warning(
        "[WorkspaceRekeys] #{tenant_id} has #{@max} or more workspace id repairs; later ones are not followed"
      )
    end

    shaped = for entry <- entries, %{} = rekey <- [shape(entry)], do: {entry, rekey}

    shaped =
      case Keyword.get(opts, :near) do
        nil -> shaped
        ids -> reachable(shaped, ids, Keyword.get(opts, :after, 0))
      end

    for {entry, rekey} <- shaped, reliable?(trust, tenant_id, entry, rekey), do: rekey
  end

  # The re-keys after `after_seq` that start at one of `ids` or at where an
  # earlier one of them ended, in the order they were recorded.
  defp reachable(shaped, ids, after_seq) do
    candidates = Enum.filter(shaped, fn {_entry, rekey} -> rekey.seq > after_seq end)

    candidates
    |> reach(MapSet.new(ids), [])
    |> Enum.sort_by(fn {_entry, rekey} -> rekey.seq end)
  end

  defp reach(candidates, ids, reached) do
    case Enum.split_with(candidates, fn {_entry, rekey} -> rekey.from in ids end) do
      {[], _rest} ->
        reached

      {hit, rest} ->
        reach(
          rest,
          Enum.reduce(hit, ids, fn {_e, r}, acc -> MapSet.put(acc, r.to) end),
          hit ++ reached
        )
    end
  end

  @doc "The workspace id inside an `optimal://<workspace id>/...` resource, or nil."
  @spec resource_workspace(term()) :: String.t() | nil
  def resource_workspace("optimal://" <> rest) do
    rest |> String.split("/", parts: 2) |> hd()
  end

  def resource_workspace(_resource), do: nil

  @doc """
  The id `id` is now: `id` as written at evidence entry `after_seq`, followed
  through the re-keys recorded after it. `modes` limits which kinds of repair
  are followed (default: all).
  """
  @spec current([rekey()], String.t() | nil, non_neg_integer(), :any | [mode()]) ::
          String.t() | nil
  def current(rekeys, id, after_seq, modes \\ :any) do
    Enum.reduce(rekeys, id, fn rekey, current ->
      if rekey.seq > after_seq and rekey.from == current and followed?(rekey, modes),
        do: rekey.to,
        else: current
    end)
  end

  @doc """
  The resource URI of a grant or a step as it reads now: when it is
  `optimal://<workspace id>/...`, the workspace id is followed through the
  re-keys recorded after `after_seq`. Any other value is returned as given.
  """
  @spec current_resource([rekey()], term(), non_neg_integer(), :any | [mode()]) :: term()
  def current_resource(rekeys, resource, after_seq, modes \\ :any)

  def current_resource(rekeys, "optimal://" <> rest, after_seq, modes) do
    case String.split(rest, "/", parts: 2) do
      [workspace] ->
        "optimal://" <> current(rekeys, workspace, after_seq, modes)

      [workspace, path] ->
        "optimal://" <> current(rekeys, workspace, after_seq, modes) <> "/" <> path
    end
  end

  def current_resource(_rekeys, resource, _after_seq, _modes), do: resource

  defp followed?(_rekey, :any), do: true
  defp followed?(rekey, modes) when is_list(modes), do: rekey.mode in modes

  # The re-key an entry records, or nil when it does not have the shape of one.
  defp shape(entry) do
    detail = entry["detail"]

    if is_map(detail) and is_binary(detail["from"]) and is_binary(detail["to"]) and
         is_integer(entry["seq"]) do
      %{
        seq: entry["seq"],
        from: detail["from"],
        to: detail["to"],
        mode: Map.get(@modes, detail["mode"])
      }
    end
  end

  defp reliable?(:recorded, _tenant_id, _entry, _rekey), do: true

  defp reliable?(:verified, tenant_id, entry, rekey) do
    not is_nil(rekey.mode) and entry["tenant_id"] == tenant_id and entry["kind"] == @kind and
      Evidence.verify_one(tenant_id, entry) == :ok and Evidence.linked?(tenant_id, entry)
  rescue
    # A row written by hand can be any shape.
    _ -> false
  end
end
