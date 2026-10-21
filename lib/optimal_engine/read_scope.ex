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
      with some granted only what shares one (for a row drawn from other
      rows, one with each of them that has any);
    * the access lists of `OptimalEngine.Identity.ACL`, for the address of the
      resource.

  A row's labels and partitions are not only its own: a memory, chunk, wiki
  page or entity carries those of the rows it was copied or derived from
  (`OptimalEngine.Sync.Gate`), and a row whose source cannot be found is read
  by no one.

  A key granted `"*"` (a key that may mint any grant, such as a bootstrap
  key with `*` or `admin` scope) sees every label, every partition, or both. An anonymous local caller
  is the trusted operator and is not filtered: its scope is `nil`, and every
  function here passes what it is given through.

  Whatever is left out is counted. Every function returns what was withheld
  next to what it kept, so a route can say its answer is not complete.
  """

  alias OptimalEngine.Identity.ACL
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.{Gate, Lineage}

  defstruct [
    :tenant_id,
    :principal,
    :ceiling,
    :gate,
    labels: [],
    partitions: [],
    acl_absent: :allow
  ]

  @typedoc """
  `ceiling` is the highest class rank the reader is shown (nil: no ceiling),
  for the routes that dump rows. It does not apply to a key granted `"*"` for
  labels. `gate` is the gate `shared/3` opened for a request, which the filters
  use instead of opening their own.
  """
  @type t :: %__MODULE__{
          tenant_id: String.t(),
          principal: String.t(),
          ceiling: SecurityLabels.rank() | nil,
          gate: Gate.t() | nil,
          labels: [String.t()],
          partitions: [String.t()],
          acl_absent: :allow | :deny
        }

  @doc "The grants (labels and partitions) of the scope."
  @spec grants(t()) :: SecurityLabels.grants()
  def grants(%__MODULE__{labels: labels, partitions: partitions}),
    do: SecurityLabels.grants(labels, partitions)

  # Rows a memory list reads in all to fill one page, and the batch it reads
  # them in.
  @scan_budget 10_000
  @scan_batch 200

  @doc """
  True when a list of the reader's has to be filled around what it may not see:
  its grants cut something (`grants_cut?/1`), or its access lists can (the
  tenant has any access list row, or a resource with none is denied). The
  operator (no scope), and a key granted `"*"` in a tenant that has no access
  list rows, see every row, so a page of theirs needs no refilling.
  """
  @spec filtering?(t() | nil) :: boolean()
  def filtering?(nil), do: false

  def filtering?(%__MODULE__{} = scope), do: grants_cut?(scope) or acl_cuts?(scope)

  @doc """
  True when the reader's label and partition grants cut something: a keyed
  reader without `"*"` for both. What it may see is then a subset the Engine
  cannot count without reading it, so a total it reports is only what it found.
  """
  @spec grants_cut?(t() | nil) :: boolean()
  def grants_cut?(nil), do: false
  def grants_cut?(%__MODULE__{} = scope), do: not unfiltered?(scope)

  # An access list row on any resource can hide it from any principal, so a
  # tenant that has none cannot cut. A Store that does not answer is taken to.
  defp acl_cuts?(%__MODULE__{acl_absent: :deny}), do: true

  defp acl_cuts?(%__MODULE__{tenant_id: tenant_id}) do
    case Store.raw_query("SELECT 1 FROM acls WHERE tenant_id = ?1 LIMIT 1", [tenant_id]) do
      {:ok, []} -> false
      _ -> true
    end
  end

  @doc """
  Runs `fun` with `scope` carrying one gate for `workspace_id` that its filters
  share, closed after. Without it each call of a filter opens a gate, and a gate
  reads the workspace to build its index; a scan or a widening that filters a
  batch at a time would read the workspace once per batch. The operator and a key
  granted `"*"` have no gate to open.
  """
  @spec shared(t() | nil, String.t(), (t() | nil -> result)) :: result when result: var
  def shared(nil, _workspace_id, fun), do: fun.(nil)

  def shared(%__MODULE__{} = scope, workspace_id, fun) do
    if unfiltered?(scope) do
      fun.(scope)
    else
      gate = Gate.open_reader(scope.tenant_id, workspace_id, grants(scope), scope.ceiling)

      try do
        fun.(%{scope | gate: gate})
      after
        Gate.close(gate)
      end
    end
  end

  # The gate for `workspace_id`: the one `shared/3` opened, when it is for that
  # workspace and was opened with the ceiling this call wants, else a gate of its
  # own for the call.
  defp with_gate(
         %__MODULE__{gate: %Gate{workspace_id: workspace_id} = gate, ceiling: ceiling},
         workspace_id,
         ceiling,
         fun
       ),
       do: fun.(gate)

  defp with_gate(scope, workspace_id, ceiling, fun),
    do: Gate.with_reader(scope.tenant_id, workspace_id, grants(scope), ceiling, fun)

  @doc """
  The first `need` items of a list the reader may see, for a list that is read
  a page at a time: cutting a page that was read first leaves it short, and
  empty when restricted rows come ahead of the visible ones.

  `read.(offset, count)` returns the raw items from `offset` in the order of the
  list (fewer than `count` when the list ends), and `keep.(raw)` those of them
  the reader may see. The list is read `:batch` items at a time (default 200)
  until `need` are kept, the list ends, or `:budget` raw items (default 10,000)
  have been read. The result is in the order of the list and may hold more than
  `need`; the offset of a page counts these items, not the raw ones.
  """
  @spec scan(
          non_neg_integer(),
          (non_neg_integer(), pos_integer() -> [term()]),
          ([term()] -> [term()]),
          keyword()
        ) :: [term()]
  def scan(need, read, keep, opts \\ []) do
    batch = Keyword.get(opts, :batch, @scan_batch)
    budget = Keyword.get(opts, :budget, @scan_budget)
    do_scan(need, read, keep, batch, budget, 0, [])
  end

  defp do_scan(need, read, keep, batch, budget, offset, kept) do
    raw = read.(offset, batch)
    kept = kept ++ keep.(raw)

    cond do
      length(kept) >= need -> kept
      length(raw) < batch -> kept
      offset + batch >= budget -> kept
      true -> do_scan(need, read, keep, batch, budget, offset + batch, kept)
    end
  end

  @doc """
  Like `scan/4`, for a ranked result that can only be asked for from the top
  (a search, a grep): `read.(window)` returns the first `window` results as
  `{:ok, raw}` or `{:error, reason}`, and `keep.(raw)` those the reader may see.
  The window starts at `first` (never below `need`) and doubles until `need`
  results are kept, the source returns fewer than it was asked for, or the
  window reaches `ceiling`. Returns `{:ok, kept}` or the source's error.
  """
  @spec widen(
          pos_integer(),
          pos_integer(),
          pos_integer(),
          (pos_integer() -> {:ok, [term()]} | {:error, term()}),
          ([term()] -> [term()])
        ) :: {:ok, [term()]} | {:error, term()}
  def widen(need, first, ceiling, read, keep) do
    do_widen(need, ceiling, read, keep, first |> max(need) |> min(ceiling))
  end

  defp do_widen(need, ceiling, read, keep, window) do
    with {:ok, raw} <- read.(window) do
      kept = keep.(raw)

      cond do
        length(kept) >= need -> {:ok, kept}
        length(raw) < window -> {:ok, kept}
        window >= ceiling -> {:ok, kept}
        true -> do_widen(need, ceiling, read, keep, min(window * 2, ceiling))
      end
    end
  end

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
        with_gate(scope, workspace_id, scope.ceiling, fn gate ->
          allowed = Gate.readable_ids(gate, table, Enum.map(items, id_of))
          Enum.filter(items, &MapSet.member?(allowed, id_of.(&1)))
        end)
      end

    counted(items, readable_by_acl(readable, scope, uri_of))
  end

  @doc """
  True when the reader may see the one row of `table` with this id, and its
  principal may read `address`. For a route that returns a single record.
  """
  @spec visible?(t() | nil, String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          boolean()
  def visible?(scope, workspace_id, table, id, address) do
    {kept, _withheld} = filter(scope, workspace_id, table, [id], & &1, fn _ -> address end)
    kept != []
  end

  @doc """
  True when the reader may see this wiki page (a map or struct with its tenant,
  workspace, slug, audience, version, frontmatter and body), and its principal
  may read `wiki:<slug>:<audience>`.
  """
  @spec readable_page?(t() | nil, map()) :: boolean()
  def readable_page?(scope, page) do
    {kept, _withheld} =
      filter_rows(
        scope,
        page.workspace_id,
        "wiki_pages",
        [page],
        &wiki_row/1,
        &"wiki:#{&1.slug}:#{&1.audience}"
      )

    kept != []
  end

  @doc "A wiki page as the columns the lineage reads it by."
  @spec wiki_row(map()) :: map()
  def wiki_row(page) do
    %{
      "tenant_id" => page.tenant_id,
      "workspace_id" => page.workspace_id,
      "slug" => page.slug,
      "audience" => page.audience,
      "version" => page.version,
      "frontmatter" => page.frontmatter,
      "body" => page.body
    }
  end

  @doc """
  `filter/6` for items whose table is not known (search results are documents
  or memories, possibly from several workspaces): the table of each is found
  from its id, and an id that is in none is read by no one.
  """
  @spec filter_any(
          t() | nil,
          [term()],
          (term() -> String.t() | nil),
          (term() -> String.t()),
          (term() -> String.t() | nil)
        ) :: {[term()], non_neg_integer()}
  def filter_any(nil, items, _id_of, _workspace_of, _uri_of), do: {items, 0}

  def filter_any(%__MODULE__{} = scope, items, id_of, workspace_of, uri_of) do
    readable =
      if unfiltered?(scope) do
        items
      else
        allowed =
          items
          |> Enum.group_by(workspace_of)
          |> Enum.flat_map(fn {workspace_id, group} ->
            with_gate(scope, workspace_id, nil, fn gate ->
              ids = Gate.readable_any_ids(gate, Enum.map(group, id_of))
              for item <- group, MapSet.member?(ids, id_of.(item)), do: item
            end)
          end)
          |> MapSet.new()

        Enum.filter(items, &MapSet.member?(allowed, &1))
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
        with_gate(scope, workspace_id, scope.ceiling, fn gate ->
          Gate.prefetch_rows(gate, table, Enum.map(items, row_of))
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
        Enum.map(visible, fn conflict ->
          conflict
          |> Map.merge(%{
            local: served_version(conflict.local),
            remote: served_version(conflict.remote),
            redacted: false
          })
        end)
      else
        with_gate(scope, workspace_id, scope.ceiling, fn gate ->
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
            shaped = Enum.map(mutations, &{&1, shape(&1)})
            Gate.prefetch_mutations(gate, Enum.map(shaped, &elem(&1, 1)))

            for {mutation, shape} <- shaped, Gate.readable_known?(gate, shape), do: mutation
          else
            mutations
          end

        addresses = mutation_addresses(workspace_id, readable)

        kept =
          ACL.filter(scope.principal, readable, &Map.get(addresses, &1.sequence), :read,
            tenant_id: scope.tenant_id,
            absent: scope.acl_absent
          )

        {Enum.map(kept, &served/1), length(mutations) - length(kept)}
      end)
    end

    if unfiltered?(scope),
      do: run.(nil),
      else: with_gate(scope, workspace_id, scope.ceiling, run)
  end

  # What a change shows a reader: the row and its blobs, which are what was
  # classified. Anything else a peer or a caller put in the payload was not
  # judged, so it is not served (an entry of an unknown entity type has no
  # row to judge and keeps its payload).
  defp served(%{entity_type: type, payload: %{} = payload} = mutation) do
    if Lineage.spec(type),
      do: %{mutation | payload: Map.take(payload, ["row", "blobs"])},
      else: mutation
  end

  defp served(mutation), do: mutation

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
      do: {served_version(payload), false},
      else: {%{"redacted" => "security_labels"}, true}
  end

  # The row and blobs that were classified; nothing else a peer put in the
  # payload is served.
  defp served_version(%{} = payload), do: Map.take(payload, ["row", "blobs"])
  defp served_version(other), do: other

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
