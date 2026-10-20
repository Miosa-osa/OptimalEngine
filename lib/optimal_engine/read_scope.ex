defmodule OptimalEngine.ReadScope do
  @moduledoc """
  What a keyed reader may see of the rows an export or a record carries.

  Retrieval does not hand a caller everything its key can reach in a
  workspace. Governed recall admits an object only when every label and
  partition it carries is among the caller's grants (an empty grant admits
  only what carries none), and the access lists of `OptimalEngine.Identity.ACL`
  decide which resources the caller's principal may read. The routes that dump
  rows (`GET /api/batch/export/*`, `GET /api/sync/conflicts`) apply the same
  two rules, so a read key without a label grant never gets restricted text
  from them either.

  A row's labels are not only its own: a memory, chunk, wiki page or entity
  carries the labels of the rows it was copied or derived from
  (`OptimalEngine.Sync.Gate`), and a row whose source cannot be found is read
  by no one.

  An anonymous local caller is the trusted operator and is not filtered: its
  scope is `nil`, and every function here passes what it is given through.
  """

  alias OptimalEngine.Identity.ACL
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Sync.Gate

  defstruct [:tenant_id, :principal, labels: [], partitions: [], acl_absent: :allow]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          principal: String.t(),
          labels: [String.t()],
          partitions: [String.t()],
          acl_absent: :allow | :deny
        }

  @doc "The grants (labels and partitions) of the scope, as tokens."
  @spec grants(t()) :: MapSet.t(String.t())
  def grants(%__MODULE__{labels: labels, partitions: partitions}),
    do: SecurityLabels.grants(labels, partitions)

  @doc """
  The items of `table` in `workspace_id` the reader may see: those whose id
  (`id_of`) carries only labels and partitions it is granted, and whose
  address (`uri_of`) its principal may read.
  """
  @spec filter(
          t() | nil,
          String.t(),
          String.t(),
          [term()],
          (term() -> String.t()),
          (term() -> String.t() | nil)
        ) :: [term()]
  def filter(nil, _workspace_id, _table, items, _id_of, _uri_of), do: items

  def filter(%__MODULE__{} = scope, workspace_id, table, items, id_of, uri_of) do
    scope.tenant_id
    |> Gate.with_reader(workspace_id, grants(scope), fn gate ->
      Enum.filter(items, &Gate.readable_id?(gate, table, id_of.(&1)))
    end)
    |> readable_by_acl(scope, uri_of)
  end

  @doc """
  `filter/6` for rows that are not looked up by id: `row_of` gives the columns
  of an item as a map with string keys.
  """
  @spec filter_rows(
          t() | nil,
          String.t(),
          String.t(),
          [term()],
          (term() -> map()),
          (term() -> String.t() | nil)
        ) :: [term()]
  def filter_rows(nil, _workspace_id, _table, items, _row_of, _uri_of), do: items

  def filter_rows(%__MODULE__{} = scope, workspace_id, table, items, row_of, uri_of) do
    scope.tenant_id
    |> Gate.with_reader(workspace_id, grants(scope), fn gate ->
      Enum.filter(items, &Gate.readable_row?(gate, table, row_of.(&1)))
    end)
    |> readable_by_acl(scope, uri_of)
  end

  @doc """
  Conflicts as the reader may see them. A conflict records the two versions of
  a row; a version the reader may not see is replaced by a marker, and the
  conflict says it was redacted. Its table, key, kind and state stay: they name
  no content.
  """
  @spec redact_conflicts(t() | nil, String.t(), [map()]) :: [map()]
  def redact_conflicts(nil, _workspace_id, conflicts), do: conflicts

  def redact_conflicts(%__MODULE__{} = scope, workspace_id, conflicts) do
    Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), fn gate ->
      Enum.map(conflicts, &redact_conflict(gate, &1))
    end)
  end

  defp redact_conflict(gate, conflict) do
    {local, local_hidden?} = redact_version(gate, conflict, conflict.local)
    {remote, remote_hidden?} = redact_version(gate, conflict, conflict.remote)

    conflict
    |> Map.merge(%{local: local, remote: remote})
    |> Map.put(:redacted, local_hidden? or remote_hidden?)
  end

  defp redact_version(_gate, _conflict, nil), do: {nil, false}

  defp redact_version(gate, conflict, payload) do
    mutation = %{
      "entity_type" => conflict.table,
      "entity_id" => conflict.entity_key,
      "operation" => "update",
      "payload" => payload
    }

    if Gate.readable_mutation?(gate, mutation),
      do: {payload, false},
      else: {%{"redacted" => "security_labels"}, true}
  end

  defp readable_by_acl(items, %__MODULE__{principal: principal} = scope, uri_of) do
    ACL.filter(principal, items, uri_of, :read,
      tenant_id: scope.tenant_id,
      absent: scope.acl_absent
    )
  end
end
