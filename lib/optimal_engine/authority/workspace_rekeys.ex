defmodule OptimalEngine.Authority.WorkspaceRekeys do
  @moduledoc """
  The signed record of a workspace id repair.

  An operator can move a workspace's rows to a new id
  (`OptimalEngine.DataSteward.rename_workspace/3`, `repair_orphan_scope/3`).
  Signed evidence is never rewritten: an entry keeps the workspace id it was
  written with, and a step of an agent action chain is verified against the
  id inside its signed entry. The move itself is appended to the evidence
  chain as `workspace.rekeyed` (from, to, who), in the transaction that moves
  the rows, so a reader can follow an old id to the current one:

      current(rekeys, signed_id, seq)

  applies the re-keys recorded after entry `seq`, in order. A step whose live
  `workspace_id` is not what that gives, for example one moved by hand in the
  database, does not verify.

  ## What counts as a re-key

  `list/1` returns only entries a reader can rely on, so a row written
  into the table by hand explains nothing:

    * the entry belongs to the tenant, is of kind `workspace.rekeyed`, and
      names `from` and `to` as strings;
    * its hash and signature verify against a tenant evidence key that is not
      revoked (`OptimalEngine.Authority.Evidence.verify_one/2`);
    * it sits where it was signed: its `prev_hash` is the hash of the entry
      before it (`OptimalEngine.Authority.Evidence.linked?/2`).

  Each call checks every re-key of the tenant, which is cheap because repairs
  are rare. A re-key that was deleted is not noticed here: its steps stop
  verifying (a deleted record explains nothing, so this fails closed), and the
  gap in the chain is reported by `Evidence.verify/1` and the integrity scan
  (`OptimalEngine.Authority.Integrity.scan/2`).
  """

  alias OptimalEngine.Authority.Evidence

  require Logger

  @kind "workspace.rekeyed"
  @max 10_000

  @type rekey :: %{seq: pos_integer(), from: String.t(), to: String.t()}

  @doc """
  Appends the re-key of `from` to `to` inside the caller's Store transaction.
  `key` comes from `OptimalEngine.Authority.Evidence.signing_key/1`; with `nil`
  nothing is written.
  """
  @spec record(term(), map() | nil, String.t(), String.t(), String.t(), String.t()) :: :ok
  def record(_txn, nil, _tenant_id, _from, _to, _actor), do: :ok

  def record(txn, key, tenant_id, from, to, actor) do
    # The action is the one the Authority plug names for these routes (a
    # POST is a write); the old and the new id are in the detail.
    {:ok, _entry} =
      Evidence.append_in(txn, key, tenant_id, @kind, %{
        subject: actor,
        action: "write",
        resource: "optimal://#{to}",
        workspace_id: to,
        detail: %{"from" => from, "to" => to, "by" => actor}
      })

    :ok
  end

  @doc """
  Every re-key of the tenant that verifies and sits where it was signed (see
  the module doc), oldest first. Reads at most 10,000 entries and logs when
  the tenant has that many.
  """
  @spec list(String.t()) :: [rekey()]
  def list(tenant_id) do
    entries = Evidence.list(tenant_id, kind: @kind, limit: @max)

    if length(entries) >= @max do
      Logger.warning(
        "[WorkspaceRekeys] #{tenant_id} has #{@max} or more workspace id repairs; later ones are not followed"
      )
    end

    for entry <- entries, trusted?(tenant_id, entry) do
      %{seq: entry["seq"], from: entry["detail"]["from"], to: entry["detail"]["to"]}
    end
  end

  @doc """
  The id `id` is now: `id` as written at evidence entry `after_seq`, followed
  through the re-keys recorded after it.
  """
  @spec current([rekey()], String.t() | nil, non_neg_integer()) :: String.t() | nil
  def current(rekeys, id, after_seq) do
    Enum.reduce(rekeys, id, fn rekey, current ->
      if rekey.seq > after_seq and rekey.from == current, do: rekey.to, else: current
    end)
  end

  @doc """
  The resource URI of a grant or a step as it reads now: when it is
  `optimal://<workspace id>/...`, the workspace id is followed through the
  re-keys recorded after `after_seq`. Any other value is returned as given.
  """
  @spec current_resource([rekey()], term(), non_neg_integer()) :: term()
  def current_resource(rekeys, "optimal://" <> rest, after_seq) do
    case String.split(rest, "/", parts: 2) do
      [workspace] -> "optimal://" <> current(rekeys, workspace, after_seq)
      [workspace, path] -> "optimal://" <> current(rekeys, workspace, after_seq) <> "/" <> path
    end
  end

  def current_resource(_rekeys, resource, _after_seq), do: resource

  defp trusted?(tenant_id, entry) do
    detail = entry["detail"]

    is_map(detail) and is_binary(detail["from"]) and is_binary(detail["to"]) and
      is_integer(entry["seq"]) and entry["tenant_id"] == tenant_id and entry["kind"] == @kind and
      Evidence.verify_one(tenant_id, entry) == :ok and Evidence.linked?(tenant_id, entry)
  rescue
    # A row written by hand can be any shape.
    _ -> false
  end
end
