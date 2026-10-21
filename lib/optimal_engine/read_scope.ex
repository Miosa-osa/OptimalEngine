defmodule OptimalEngine.ReadScope do
  @moduledoc """
  What a keyed reader may see of the rows an export or a record carries.

  Retrieval does not hand a caller everything its key can reach in a
  workspace. Governed recall admits an object only by two rules, and the
  routes that dump rows (`GET /api/batch/export/*`, `GET /api/sync/conflicts`,
  `GET /api/storage/workspaces/:id/mutations`) apply the same two, so a read
  key without a label grant never gets restricted text from them either:

    * the labels and partitions it carries against the key's grants
      (`OptimalEngine.MemoryCore.SecurityLabels.permits?/2`): every label must
      be granted, and with no partition granted only what has none is seen,
      with some granted only what shares one;
    * the access lists of `OptimalEngine.Identity.ACL`, for the address of the
      resource.

  A row's labels and partitions are not only its own: a memory, chunk, wiki
  page or entity carries those of the rows it was copied or derived from
  (`OptimalEngine.Sync.Gate`), and a row whose source cannot be found is read
  by no one.

  A key granted `"*"` (a key that may mint any grant, such as the bootstrap
  key) sees every label, every partition, or both. An anonymous local caller
  is the trusted operator and is not filtered: its scope is `nil`, and every
  function here passes what it is given through.

  Whatever is left out is counted. Every function returns what was withheld
  next to what it kept, so a route can say its answer is not complete.
  """

  alias OptimalEngine.Identity.ACL
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.{Gate, Lineage}

  defstruct [:tenant_id, :principal, labels: [], partitions: [], acl_absent: :allow]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          principal: String.t(),
          labels: [String.t()],
          partitions: [String.t()],
          acl_absent: :allow | :deny
        }

  @doc "The grants (labels and partitions) of the scope."
  @spec grants(t()) :: SecurityLabels.grants()
  def grants(%__MODULE__{labels: labels, partitions: partitions}),
    do: SecurityLabels.grants(labels, partitions)

  @doc """
  The items of `table` in `workspace_id` the reader may see, and how many it
  may not: those whose id (`id_of`) carries only what the grants cover, and
  whose address (`uri_of`) its principal may read.
  """
  @spec filter(
          t() | nil,
          String.t(),
          String.t(),
          [term()],
          (term() -> String.t()),
          (term() -> String.t() | nil)
        ) :: {[term()], non_neg_integer()}
  def filter(nil, _workspace_id, _table, items, _id_of, _uri_of), do: {items, 0}

  def filter(%__MODULE__{} = scope, workspace_id, table, items, id_of, uri_of) do
    readable =
      if unfiltered?(scope) do
        items
      else
        Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), fn gate ->
          allowed = Gate.readable_ids(gate, table, Enum.map(items, id_of))
          Enum.filter(items, &MapSet.member?(allowed, id_of.(&1)))
        end)
      end

    counted(items, readable_by_acl(readable, scope, uri_of))
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
        ) :: {[term()], non_neg_integer()}
  def filter_rows(nil, _workspace_id, _table, items, _row_of, _uri_of), do: {items, 0}

  def filter_rows(%__MODULE__{} = scope, workspace_id, table, items, row_of, uri_of) do
    readable =
      if unfiltered?(scope) do
        items
      else
        Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), fn gate ->
          Enum.filter(items, &Gate.readable_row?(gate, table, row_of.(&1)))
        end)
      end

    counted(items, readable_by_acl(readable, scope, uri_of))
  end

  @doc """
  Conflicts as the reader may see them, and how many it may not.

  A conflict records the two versions of a row. One whose resource the
  principal may not read by the access lists is left out. In the others, a
  version the reader may not see is replaced by a marker (the version as it
  was recorded, and the row as it is now, must both be readable), and the
  conflict says it was redacted. Its table, kind and state stay: they name no
  content. Its key stays when it is an opaque id; a key that is a name (a
  wiki page) is replaced by a hash of it when the conflict is redacted.
  """
  @spec redact_conflicts(t() | nil, String.t(), [map()]) ::
          {[map()], %{withheld: non_neg_integer(), redacted: non_neg_integer()}}
  def redact_conflicts(nil, _workspace_id, conflicts) do
    {Enum.map(conflicts, &Map.put(&1, :redacted, false)), %{withheld: 0, redacted: 0}}
  end

  def redact_conflicts(%__MODULE__{} = scope, workspace_id, conflicts) do
    addresses = conflict_addresses(workspace_id, conflicts)

    visible =
      ACL.filter(scope.principal, conflicts, &Map.get(addresses, &1.id), :read,
        tenant_id: scope.tenant_id,
        absent: scope.acl_absent
      )

    shown =
      if unfiltered?(scope) do
        Enum.map(visible, &Map.put(&1, :redacted, false))
      else
        Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), fn gate ->
          Enum.map(visible, &redact_conflict(gate, &1))
        end)
      end

    {shown,
     %{withheld: length(conflicts) - length(visible), redacted: Enum.count(shown, & &1.redacted)}}
  end

  @doc """
  Runs `fun` with a filter for the changes of a workspace's ledger (as
  `OptimalEngine.Storage.PolicyStore` reads them): `filter.(mutations)` returns
  `{kept, withheld}`, the changes the reader may see by its grants and the
  access lists of what they change. One gate serves every call, so the pages of
  a read share what it learned.
  """
  @spec with_mutation_filter(t() | nil, String.t(), (([map()] -> {[map()], non_neg_integer()}) ->
                                                       result)) :: result
        when result: var
  def with_mutation_filter(nil, _workspace_id, fun), do: fun.(fn mutations -> {mutations, 0} end)

  def with_mutation_filter(%__MODULE__{} = scope, workspace_id, fun) do
    run = fn gate ->
      fun.(fn mutations ->
        readable =
          if gate do
            Enum.filter(mutations, &Gate.readable_known?(gate, shape(&1)))
          else
            mutations
          end

        addresses = mutation_addresses(workspace_id, readable)

        kept =
          ACL.filter(scope.principal, readable, &Map.get(addresses, &1.sequence), :read,
            tenant_id: scope.tenant_id,
            absent: scope.acl_absent
          )

        {kept, length(mutations) - length(kept)}
      end)
    end

    if unfiltered?(scope),
      do: run.(nil),
      else: Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), run)
  end

  defp shape(mutation) do
    %{
      "entity_type" => mutation.entity_type,
      "entity_id" => mutation.entity_id,
      "operation" => to_string(mutation.operation),
      "payload" => mutation.payload
    }
  end

  defp mutation_addresses(workspace_id, mutations) do
    context_ids = for %{entity_type: "contexts", entity_id: id} <- mutations, do: id
    uris = context_uris(workspace_id, context_ids)

    Map.new(mutations, fn mutation ->
      {mutation.sequence, address(workspace_id, mutation.entity_type, mutation.entity_id, uris)}
    end)
  end

  # -- conflicts -------------------------------------------------------------------

  defp redact_conflict(gate, conflict) do
    {local, local_hidden?} = redact_version(gate, conflict, conflict.local)
    {remote, remote_hidden?} = redact_version(gate, conflict, conflict.remote)
    hidden? = local_hidden? or remote_hidden?

    conflict
    |> Map.merge(%{local: local, remote: remote, redacted: hidden?})
    |> hide_name_key(hidden?)
  end

  defp redact_version(_gate, _conflict, nil), do: {nil, false}

  defp redact_version(gate, conflict, payload) do
    mutation = %{
      "entity_type" => conflict.table,
      "entity_id" => conflict.entity_key,
      "operation" => "update",
      "payload" => payload
    }

    if Gate.readable_mutation?(gate, mutation) and live_row_readable?(gate, conflict),
      do: {payload, false},
      else: {%{"redacted" => "security_labels"}, true}
  end

  # The row as it is stored now may carry labels the recorded version did not:
  # it was labelled afterwards. Only rows named by an id can be looked up.
  defp live_row_readable?(gate, conflict) do
    case Lineage.spec(conflict.table) do
      %{key: "id"} -> Gate.readable_or_gone?(gate, conflict.table, conflict.entity_key)
      _ -> true
    end
  end

  # A key that is not an id names the thing (a wiki page's slug): it says
  # what the redacted version would have said.
  defp hide_name_key(conflict, false), do: conflict

  defp hide_name_key(conflict, true) do
    case Lineage.spec(conflict.table) do
      %{key: "id"} ->
        conflict

      _ ->
        hashed =
          :crypto.hash(:sha256, to_string(conflict.entity_key)) |> Base.encode16(case: :lower)

        Map.merge(conflict, %{entity_key: "sha256:" <> binary_part(hashed, 0, 16), key_hidden: true})
    end
  end

  # The address the access lists know a conflict's resource by.
  defp conflict_addresses(workspace_id, conflicts) do
    context_ids = for %{table: "contexts", entity_key: id} <- conflicts, do: id
    uris = context_uris(workspace_id, context_ids)

    Map.new(conflicts, fn conflict ->
      {conflict.id, address(workspace_id, conflict.table, conflict.entity_key, uris)}
    end)
  end

  # The address the access lists know a row by, from its table and key: the
  # same addresses retrieval and the exports use. Nil for a table no access
  # list governs.
  defp address(workspace_id, "memories", id, _uris), do: "optimal://memory/#{workspace_id}/#{id}"
  defp address(_workspace_id, "contexts", id, uris), do: Map.get(uris, id) || id

  defp address(_workspace_id, "wiki_pages", key, _uris) when is_binary(key) do
    case Jason.decode(key) do
      {:ok, [_tenant, slug, audience | _version]} -> "wiki:#{slug}:#{audience}"
      _ -> nil
    end
  end

  defp address(_workspace_id, _table, _key, _uris), do: nil

  defp context_uris(_workspace_id, []), do: %{}

  defp context_uris(workspace_id, ids) do
    ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn chunk, acc ->
      marks = Enum.map_join(1..length(chunk), ", ", &"?#{&1 + 1}")

      case Store.raw_query(
             "SELECT id, uri FROM contexts WHERE workspace_id = ?1 AND id IN (#{marks})",
             [workspace_id | chunk]
           ) do
        {:ok, rows} ->
          Enum.reduce(rows, acc, fn [id, uri], acc -> Map.put(acc, id, uri) end)

        {:error, reason} ->
          raise "could not read the addresses of the conflicts: #{inspect(reason)}"
      end
    end)
  end

  # -- common ----------------------------------------------------------------------

  defp unfiltered?(scope) do
    grants = grants(scope)
    grants.all_labels? and grants.all_partitions?
  end

  defp readable_by_acl(items, %__MODULE__{principal: principal} = scope, uri_of) do
    ACL.filter(principal, items, uri_of, :read,
      tenant_id: scope.tenant_id,
      absent: scope.acl_absent
    )
  end

  defp counted(items, kept), do: {kept, length(items) - length(kept)}
end
