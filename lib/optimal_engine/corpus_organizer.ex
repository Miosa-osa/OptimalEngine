defmodule OptimalEngine.CorpusOrganizer do
  @moduledoc """
  Deterministic, evidence-preserving routing for Knowledge Intake contexts.

  Records are placed by name markers (`rules/0`) and, when enabled, by
  meaning (`semantic_settings/0`): a record's document vector is compared
  with the centroid of each workspace's filed documents, with its nearest
  filed documents, or both. A placed record keeps the evidence of its
  placement in `metadata.routing_placement`; one that is not placed gets a
  routing review entry with the best proposal.
  """

  require Logger

  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  @default_intake_slug "knowledge-intake"
  @minimum_score 8
  @minimum_margin 5
  @semantic_margin 0.04
  @semantic_min_examples 5
  @semantic_k 10
  @semantic_share 0.8

  @doc """
  The routing rules: a map of target workspace id to `{marker, weight}`
  pairs. Rules are deployment data, not code. They come from
  `config :optimal_engine, :corpus_routing_rules` when set, else from the
  `rules` section of the routing rules file (`OptimalEngine.RoutingRules`,
  env `OPTIMAL_CORPUS_RULES`):

      rules:
        default:example-client:
          - {marker: "example client", weight: 10}
          - {marker: "example project", weight: 5}

  With no rules configured every record stays in routing review.
  """
  @spec rules() :: %{String.t() => [{String.t(), pos_integer()}]}
  def rules do
    case Application.get_env(:optimal_engine, :corpus_routing_rules) do
      rules when is_map(rules) -> normalize_rules(rules)
      _ -> normalize_rules(OptimalEngine.RoutingRules.section("rules"))
    end
  end

  @doc """
  The intake workspace of `tenant_id`, where the organizer routes from and the
  routing review queue is read.

  Every tenant has its own: `<tenant>:knowledge-intake`. The slug is
  `config :optimal_engine, :corpus_intake_slug`. An intake named in
  `config :optimal_engine, :corpus_source_workspace` is the intake of the
  tenant that owns that workspace and of no other.
  """
  @spec source_workspace(String.t()) :: String.t()
  def source_workspace(tenant_id) when is_binary(tenant_id) do
    case configured_source() do
      nil -> tenant_intake(tenant_id)
      id -> if intake_tenant(id) == tenant_id, do: id, else: tenant_intake(tenant_id)
    end
  end

  @doc """
  The intake workspace of the deployment: the configured one, else that of the
  default tenant. The organizer routes from it when it is not given a tenant.
  """
  @spec source_workspace() :: String.t()
  def source_workspace do
    configured_source() || tenant_intake(Tenant.default_id())
  end

  defp configured_source do
    case Application.get_env(:optimal_engine, :corpus_source_workspace) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp tenant_intake(tenant_id), do: tenant_id <> ":" <> intake_slug()

  defp intake_slug do
    case Application.get_env(:optimal_engine, :corpus_intake_slug) do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> @default_intake_slug
    end
  end

  # The tenant an intake workspace belongs to: the one a context written there
  # is stored under (Workspace.tenant_of/1). Reads the Store, so it is never
  # called inside `Store.transaction/2`.
  defp intake_tenant(workspace_id), do: Workspace.tenant_of(workspace_id)

  # The tenant and the intake workspace an organizer call acts on: the
  # tenant's own, or with no `:tenant_id` the deployment's.
  defp intake(opts) do
    case Keyword.get(opts, :tenant_id) do
      nil ->
        source = source_workspace()
        {intake_tenant(source), source}

      tenant_id ->
        {tenant_id, source_workspace(tenant_id)}
    end
  end

  @doc """
  Placement by meaning, off unless enabled in `config :optimal_engine,
  :corpus_semantic_placement` or the `semantic` section of the routing rules
  file:

      semantic:
        enabled: true
        method: centroid      # centroid (the default), knn, or agree
        margin: 0.04          # centroid, agree: best centroid similarity minus the runner-up
        k: 10                 # knn, agree: the nearest filed documents that vote
        share: 0.8            # knn, agree: least share of the vote to win (0 < share <= 1)
        min_similarity: 0.0   # floor for the best similarity (below)
        min_examples: 5       # filed documents with vectors a target needs
        exclude: [default:example-private]

  Targets are the active workspaces of the intake workspace's tenant with at
  least `min_examples` document vectors, other than the intake itself and
  the excluded ones; there must be two, so there is a choice.

    * `centroid` compares the record's vector with the centroid of each
      target's filed vectors. The record is placed when the closest centroid
      clears `min_similarity` and beats the runner-up by `margin`.
    * `knn` takes the `k` filed documents closest to the record, from every
      active workspace of the tenant, and each votes for its workspace with
      its similarity. Documents of small or excluded workspaces vote, but
      only a target can win. The record is placed when the leading target
      holds at least `share` of the vote and its closest document clears
      `min_similarity`. Votes are weighted by similarity, so a workspace
      with fewer than `share * k` of the neighbours can still win when its
      documents are much closer than the others; in practice a workspace
      needs most of the neighbours, and a small one rarely attracts records.
    * `agree` places only when `knn` places and the closest centroid is the
      same workspace, at least `margin` ahead of the runner-up.

  In every method a name marker proposing another workspace blocks the
  placement. An unknown method, or a `k` or `share` out of range, turns
  placement by meaning off with a warning. Returns the settings, or `nil`.
  """
  @spec semantic_settings() :: map() | nil
  def semantic_settings do
    raw =
      case Application.get_env(:optimal_engine, :corpus_semantic_placement) do
        nil -> OptimalEngine.RoutingRules.section("semantic")
        settings when is_map(settings) or is_list(settings) -> settings
        _ -> %{}
      end
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    if raw["enabled"] == true do
      with {:ok, method} <- semantic_method(raw["method"]),
           {:ok, k} <- vote_size(raw["k"]),
           {:ok, share} <- vote_share(raw["share"]) do
        %{
          method: method,
          margin: number(raw["margin"], @semantic_margin),
          min_similarity: number(raw["min_similarity"], 0.0),
          min_examples: number(raw["min_examples"], @semantic_min_examples),
          exclude: raw["exclude"] |> List.wrap() |> Enum.map(&to_string/1),
          k: k,
          share: share
        }
      else
        {:error, setting, value} ->
          Logger.warning(
            "[CorpusOrganizer] semantic #{setting} #{inspect(value)} is not valid; placement by meaning is off"
          )

          nil
      end
    end
  end

  defp semantic_method(nil), do: {:ok, :centroid}
  defp semantic_method(method) when method in [:centroid, :knn, :agree], do: {:ok, method}

  defp semantic_method(method) when is_binary(method) do
    case String.downcase(method) do
      "centroid" -> {:ok, :centroid}
      "knn" -> {:ok, :knn}
      "agree" -> {:ok, :agree}
      _ -> {:error, "method", method}
    end
  end

  defp semantic_method(method), do: {:error, "method", method}

  defp vote_size(nil), do: {:ok, @semantic_k}
  defp vote_size(k) when is_integer(k) and k > 0, do: {:ok, k}
  defp vote_size(k), do: {:error, "k", k}

  defp vote_share(nil), do: {:ok, @semantic_share}
  defp vote_share(share) when is_number(share) and share > 0 and share <= 1, do: {:ok, share}
  defp vote_share(share), do: {:error, "share", share}

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp normalize_rules(rules) do
    for {workspace_id, markers} <- rules, is_list(markers), into: %{} do
      {to_string(workspace_id), Enum.flat_map(markers, &normalize_marker/1)}
    end
  end

  defp normalize_marker({marker, weight}) when is_binary(marker) and is_integer(weight),
    do: [{String.downcase(marker), weight}]

  defp normalize_marker(%{"marker" => marker, "weight" => weight})
       when is_binary(marker) and is_integer(weight),
       do: [{String.downcase(marker), weight}]

  defp normalize_marker(_marker), do: []

  def classify(text) when is_binary(text) do
    classify_fields(text, text, "")
  end

  def classify_fields(title, abstract, content),
    do: classify_fields(title, abstract, content, rules())

  @doc false
  def classify_fields(title, abstract, content, rules) do
    prominent = normalize("#{title}\n#{abstract}")
    body = normalize(content)

    ranked =
      rules
      |> Enum.map(fn {workspace_id, markers} ->
        hits =
          markers
          |> Enum.map(fn {marker, weight} ->
            cond do
              String.contains?(prominent, marker) -> {marker, weight}
              occurrence_count(body, marker) >= 3 -> {marker, div(weight + 1, 2)}
              true -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {workspace_id, Enum.sum(Enum.map(hits, &elem(&1, 1))), Enum.map(hits, &elem(&1, 0))}
      end)
      |> Enum.sort_by(fn {_workspace, score, _hits} -> score end, :desc)

    {workspace_id, score, hits, rest} =
      case ranked do
        [{workspace_id, score, hits} | rest] -> {workspace_id, score, hits, rest}
        [] -> {nil, 0, [], []}
      end

    second_score =
      rest |> List.first() |> then(fn entry -> if entry, do: elem(entry, 1), else: 0 end)

    confidence = confidence(score, second_score)

    %{
      workspace_id: if(confidence == :high, do: workspace_id, else: nil),
      proposed_workspace_id: if(score > 0, do: workspace_id, else: nil),
      score: score,
      margin: score - second_score,
      confidence: confidence,
      markers: hits
    }
  end

  # Intake is read and written in pages and batches so the Store, which
  # serializes every query, is free for other callers between them.
  @page_size 50
  @batch_size 200

  @doc """
  What the organizer would do with the records of an intake workspace.
  Options: `:tenant_id` (the intake of that tenant; without it, the
  deployment's), `:limit`, `:page_size`.
  """
  def preview(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)
    page_size = Keyword.get(opts, :page_size, @page_size)
    {tenant_id, source} = intake(opts)
    rules = tenant_rules(rules(), tenant_id)

    with {:ok, rows} <- intake_rows(tenant_id, source, "", limit, page_size, []),
         {:ok, placer} <-
           semantic_placer(tenant_id, source, semantic_settings(), Enum.map(rows, &hd/1)) do
      proposals =
        Enum.map(rows, fn [id, title, l0, content] ->
          title
          |> classify_fields(l0, content, rules)
          |> by_meaning(id, placer)
          |> Map.merge(%{id: id, title: title})
        end)

      {:ok, summarize(proposals)}
    end
  end

  # The routing rules belong to the deployment and may name the workspaces of
  # any tenant. The records of a tenant are placed in its own active workspaces
  # only: a rule that names another workspace is not applied, and does not
  # show the tenant a workspace that is not its own.
  defp tenant_rules(rules, _tenant_id) when map_size(rules) == 0, do: rules

  defp tenant_rules(rules, tenant_id) do
    case Store.raw_query(
           "SELECT id FROM workspaces WHERE tenant_id = ?1 AND status = 'active'",
           [tenant_id]
         ) do
      {:ok, rows} ->
        active = MapSet.new(List.flatten(rows))
        Map.filter(rules, fn {workspace_id, _markers} -> workspace_id in active end)

      {:error, _} ->
        %{}
    end
  end

  # -- placement by meaning ----------------------------------------------------

  defp semantic_placer(_tenant_id, _source, nil, _ids), do: {:ok, %{settings: nil}}

  # Compares only the records the preview read (`ids`), so a preview with a
  # `:limit` costs that many comparisons on the request path.
  defp semantic_placer(tenant_id, source, settings, ids) do
    vote? = settings.method in [:knn, :agree]

    with {:ok, {sums, documents}} <- filed_vectors(tenant_id, source, vote?, "", {%{}, []}),
         {:ok, vectors} <- intake_vectors(ids) do
      targets =
        for {{workspace_id, dims}, {_sum, count}} <- sums,
            count >= settings.min_examples,
            workspace_id not in settings.exclude,
            reduce: %{} do
          targets ->
            Map.update(targets, dims, MapSet.new([workspace_id]), &MapSet.put(&1, workspace_id))
        end

      centroids =
        for {{workspace_id, dims}, {sum, _count}} <- sums,
            MapSet.member?(Map.get(targets, dims, MapSet.new()), workspace_id),
            do: %{workspace_id: workspace_id, dims: dims, centroid: unit(sum)}

      {:ok,
       %{
         settings: settings,
         centroids: centroids,
         targets: targets,
         vectors: vectors,
         neighbours: if(vote?, do: nearest(vectors, documents, settings.k), else: %{})
       }}
    end
  end

  # Sums of unit document vectors per {workspace, dimensions} over the
  # tenant's active, filed documents, read in pages. With `keep_documents`
  # each document is also kept as a voter for `nearest/3`.
  defp filed_vectors(tenant_id, source, keep_documents, after_id, {sums, documents}) do
    case Store.raw_query(
           """
           SELECT c.id, c.workspace_id, v.embedding
           FROM vectors v
           JOIN contexts c ON c.id = v.context_id
           JOIN workspaces w ON w.id = c.workspace_id
           WHERE c.tenant_id = ?1 AND c.workspace_id <> ?2 AND c.archived_at IS NULL
             AND w.status = 'active' AND c.id > ?3
           ORDER BY c.id
           LIMIT ?4
           """,
           [tenant_id, source, after_id, @page_size * 10]
         ) do
      {:ok, []} ->
        {:ok, {sums, documents}}

      {:ok, rows} ->
        acc =
          Enum.reduce(rows, {sums, documents}, fn [_id, workspace_id, blob], {sums, documents} ->
            values = floats(blob)
            norm = norm(values)
            vector = scale(values, norm)

            sums =
              Map.update(sums, {workspace_id, length(vector)}, {vector, 1}, fn {sum, count} ->
                {add(sum, vector), count + 1}
              end)

            {sums, voter(documents, keep_documents, workspace_id, blob, values, norm)}
          end)

        [last_id | _] = List.last(rows)
        filed_vectors(tenant_id, source, keep_documents, last_id, acc)

      {:error, _} = error ->
        error
    end
  end

  # A filed document as a voter: its workspace, its stored vector (compared
  # as stored, so thousands of documents cost their bytes rather than float
  # lists), and the inverse of its norm. A vector that does not decode whole
  # does not vote.
  defp voter(documents, true, workspace_id, blob, values, norm)
       when norm > 0.0 and length(values) * 4 == byte_size(blob),
       do: [{workspace_id, blob, 1.0 / norm} | documents]

  defp voter(documents, _keep, _workspace_id, _blob, _values, _norm), do: documents

  # The document vectors of the previewed intake records by id, read in
  # batches and kept as stored bytes until compared.
  defp intake_vectors(ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, vectors} ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"?#{&1}")

      case Store.raw_query(
             "SELECT context_id, embedding FROM vectors WHERE context_id IN (#{placeholders})",
             batch
           ) do
        {:ok, rows} ->
          vectors = Enum.reduce(rows, vectors, fn [id, blob], acc -> Map.put(acc, id, blob) end)
          {:cont, {:ok, vectors}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # The `k` filed documents closest to each intake vector, by intake id, as
  # `{dimensions, [{workspace_id, similarity}]}` nearest first. The records
  # are split over all schedulers but one, which stays free for requests and
  # the Store; each part compares its records with every filed document of
  # the same dimensions.
  defp nearest(vectors, documents, k) do
    parts = max(System.schedulers_online() - 1, 1)
    size = max(div(map_size(vectors) + parts - 1, parts), 1)

    vectors
    |> Enum.chunk_every(size)
    |> Task.async_stream(
      fn part -> Enum.map(part, fn {id, blob} -> {id, nearest_to(blob, documents, k)} end) end,
      max_concurrency: parts,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, part}, acc -> Enum.into(part, acc) end)
  end

  defp nearest_to(blob, documents, k) do
    query = blob |> floats() |> unit()
    bytes = byte_size(blob)

    similarities =
      if length(query) * 4 == bytes do
        for {workspace_id, stored, inverse_norm} <- documents,
            byte_size(stored) == bytes,
            do: {workspace_id, dot_stored(stored, query, 0.0) * inverse_norm}
      else
        []
      end

    {length(query), similarities |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(k)}
  end

  defp by_meaning(result, id, %{settings: %{} = settings} = placer) do
    case meaning(settings.method, id, placer) do
      {semantic, floor?, rule?} ->
        result
        |> place_by_meaning(semantic, floor?, rule?)
        |> Map.put(:semantic, semantic)

      nil ->
        by_meaning(result, id, nil)
    end
  end

  defp by_meaning(result, _id, _placer) do
    Map.merge(result, %{method: marker_method(result), semantic: nil})
  end

  # `{proposal, clears min_similarity?, clears the method's rule?}` for an
  # intake record, or nil when it has no vector or nothing to compare with.
  defp meaning(:centroid, id, %{settings: settings, centroids: centroids, vectors: vectors}) do
    with blob when is_binary(blob) <- Map.get(vectors, id),
         [{workspace_id, similarity}, {_, second} | _] <- ranked(blob, centroids) do
      margin = similarity - second

      semantic = %{
        method: :centroid,
        workspace_id: workspace_id,
        similarity: Float.round(similarity, 4),
        margin: Float.round(margin, 4)
      }

      {semantic, similarity >= settings.min_similarity, margin >= settings.margin}
    else
      _ -> nil
    end
  end

  defp meaning(:knn, id, %{settings: settings, targets: targets, neighbours: neighbours}) do
    with {dims, [_ | _] = voters} <- Map.get(neighbours, id),
         eligible = Map.get(targets, dims, MapSet.new()),
         true <- MapSet.size(eligible) >= 2,
         {workspace_id, weight, votes, closest} <- leading(voters, eligible) do
      share = weight / (voters |> Enum.map(&max(elem(&1, 1), 0.0)) |> Enum.sum())

      semantic = %{
        method: :knn,
        workspace_id: workspace_id,
        similarity: Float.round(closest, 4),
        share: Float.round(share, 4),
        votes: votes,
        neighbours: length(voters)
      }

      {semantic, closest >= settings.min_similarity, share >= settings.share}
    else
      _ -> nil
    end
  end

  defp meaning(:agree, id, placer) do
    with {vote, floor?, voted?} <- meaning(:knn, id, placer) do
      case meaning(:centroid, id, placer) do
        {centroid, _floor?, margin?} ->
          semantic =
            Map.merge(vote, %{
              method: :agree,
              centroid_workspace_id: centroid.workspace_id,
              centroid_similarity: centroid.similarity,
              margin: centroid.margin
            })

          agreed? = voted? and margin? and centroid.workspace_id == vote.workspace_id
          {semantic, floor?, agreed?}

        nil ->
          {Map.put(vote, :method, :agree), floor?, false}
      end
    end
  end

  # The target with the largest vote among the nearest documents: its
  # weight (the sum of its documents' similarities, none below zero), its
  # votes, and its closest document's similarity. Documents of other
  # workspaces count only in the total.
  defp leading(voters, eligible) do
    voters
    |> Enum.filter(fn {workspace_id, _similarity} -> MapSet.member?(eligible, workspace_id) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {workspace_id, similarities} ->
      weight = similarities |> Enum.map(&max(&1, 0.0)) |> Enum.sum()
      {workspace_id, weight, length(similarities), Enum.max(similarities)}
    end)
    |> Enum.filter(fn {_workspace_id, weight, _votes, _closest} -> weight > 0.0 end)
    |> Enum.max_by(&elem(&1, 1), &>=/2, fn -> nil end)
  end

  # Targets of the vector's dimensions by similarity of their centroid,
  # closest first.
  defp ranked(blob, centroids) do
    vector = blob |> floats() |> unit()
    dims = length(vector)

    for(
      %{dims: ^dims} = centroid <- centroids,
      do: {centroid.workspace_id, dot(vector, centroid.centroid)}
    )
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp place_by_meaning(%{confidence: :high} = result, _semantic, _floor, _rule),
    do: Map.put(result, :method, :markers)

  defp place_by_meaning(result, semantic, true, true)
       when result.proposed_workspace_id in [nil, semantic.workspace_id] do
    Map.merge(result, %{
      workspace_id: semantic.workspace_id,
      proposed_workspace_id: semantic.workspace_id,
      confidence: :high,
      method: :semantic
    })
  end

  defp place_by_meaning(%{proposed_workspace_id: nil} = result, semantic, true, _rule) do
    Map.merge(result, %{
      proposed_workspace_id: semantic.workspace_id,
      confidence: :review,
      method: nil
    })
  end

  defp place_by_meaning(result, _semantic, _floor, _rule), do: Map.put(result, :method, nil)

  defp marker_method(%{confidence: :high}), do: :markers
  defp marker_method(_result), do: nil

  defp floats(blob), do: for(<<value::float-little-32 <- blob>>, do: value)

  defp unit(vector), do: scale(vector, norm(vector))

  defp norm(vector), do: vector |> Enum.reduce(0.0, &(&1 * &1 + &2)) |> :math.sqrt()

  defp scale(vector, norm) when norm == 0.0, do: vector
  defp scale(vector, norm), do: Enum.map(vector, &(&1 / norm))

  defp add(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, &(&1 * &2 + &3))

  # A stored little-endian float32 vector against a float list of the same
  # length, without decoding the stored one into a list first.
  defp dot_stored(<<value::float-little-32, rest::binary>>, [x | xs], acc),
    do: dot_stored(rest, xs, acc + value * x)

  defp dot_stored(<<>>, [], acc), do: acc

  # `:preview` reuses a preview the caller already read, so one run reads
  # the intake once.
  defp given_or_fresh_preview(opts) do
    case Keyword.get(opts, :preview) do
      %{high_confidence: _, review: _, unresolved: _} = preview -> {:ok, preview}
      _ -> preview(opts)
    end
  end

  defp intake_rows(_tenant_id, _workspace, _after_id, remaining, _page_size, acc)
       when remaining <= 0,
       do: {:ok, acc |> Enum.reverse() |> Enum.concat()}

  defp intake_rows(tenant_id, workspace, after_id, remaining, page_size, acc) do
    case Store.raw_query(
           "SELECT id, title, l0_abstract, content FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND archived_at IS NULL AND id > ?3 ORDER BY id LIMIT ?4",
           [tenant_id, workspace, after_id, min(page_size, remaining)]
         ) do
      {:ok, []} ->
        {:ok, acc |> Enum.reverse() |> Enum.concat()}

      {:ok, rows} ->
        [last_id | _] = List.last(rows)

        intake_rows(tenant_id, workspace, last_id, remaining - length(rows), page_size, [
          rows | acc
        ])

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Moves every record the preview places with high confidence to its
  workspace. Options: `:tenant_id` (the intake of that tenant; without it,
  the deployment's), `:preview`.
  """
  def apply_high_confidence(opts \\ []) do
    with {:ok, preview} <- given_or_fresh_preview(opts) do
      {tenant_id, _source} = intake(opts)

      results =
        Enum.map(preview.high_confidence, fn proposal ->
          {proposal,
           move_context(proposal.id, proposal.workspace_id,
             tenant_id: tenant_id,
             evidence: evidence(proposal)
           )}
        end)

      errors = Enum.filter(results, fn {_proposal, result} -> not match?({:ok, _}, result) end)

      if errors == [] do
        {:ok, %{moved: length(results), by_workspace: preview.by_workspace}}
      else
        {:error, %{moved: length(results) - length(errors), errors: errors}}
      end
    end
  end

  @doc """
  Writes a routing review entry on every intake record that is not placed
  automatically. A record already queued with the same state and proposal
  is left alone, so a daily run rewrites nothing that did not change.
  Writes run in transactions of `:batch_size` (default 200). Options:
  `:tenant_id` (the intake of that tenant; without it, the deployment's),
  `:preview`, `:batch_size`. Returns the number of entries written.
  """
  def queue_remaining(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    with {:ok, preview} <- given_or_fresh_preview(opts) do
      {tenant_id, source} = intake(opts)

      (preview.review ++ preview.unresolved)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, count} ->
        case queue_batch(batch, tenant_id, source) do
          {:ok, written} -> {:cont, {:ok, count + written}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp queue_batch(proposals, tenant_id, source) do
    queued_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Store.transaction(fn txn ->
      Enum.reduce_while(proposals, {:ok, 0}, fn proposal, {:ok, count} ->
        state = Atom.to_string(proposal.confidence)

        routing_review =
          Jason.encode!(%{
            "state" => state,
            "proposed_workspace_id" => proposal.proposed_workspace_id,
            "score" => proposal.score,
            "margin" => proposal.margin,
            "markers" => proposal.markers,
            "semantic" => Map.get(proposal, :semantic),
            "queued_at" => queued_at
          })

        case Store.txn_execute(
               txn,
               """
               UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_review', json(?1))
               WHERE id = ?2 AND tenant_id = ?3 AND workspace_id = ?4 AND archived_at IS NULL
                 AND (json_extract(metadata, '$.routing_review.state') IS NOT ?5
                      OR json_extract(metadata, '$.routing_review.proposed_workspace_id') IS NOT ?6)
               """,
               [
                 routing_review,
                 proposal.id,
                 tenant_id,
                 source,
                 state,
                 proposal.proposed_workspace_id
               ]
             ) do
          {:ok, changed} -> {:cont, {:ok, count + changed}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
    |> tap(fn _ -> Store.evict_cached(Enum.map(proposals, & &1.id)) end)
  end

  # The records to archive: all but the newest of those of one workspace that
  # hold exactly the same content. `?1` is the tenant and `?2` its intake
  # workspace, or both NULL for every workspace of every tenant.
  @duplicates_sql """
  WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, workspace_id, content
             ORDER BY modified_at DESC, created_at DESC, id DESC
           ) AS duplicate_rank
    FROM contexts
    WHERE archived_at IS NULL AND trim(content) <> ''
      AND (?1 IS NULL OR (tenant_id = ?1 AND workspace_id = ?2))
  )
  SELECT id FROM ranked WHERE duplicate_rank > 1
  """

  @doc """
  Archives all but the newest of the records of one workspace that hold
  exactly the same content. Options: `:tenant_id` limits the sweep to the
  intake workspace of that tenant, which is where the organizer works;
  `all_tenants: true` sweeps every workspace of every tenant, for an operator.
  One of the two is required. Duplicates are found within a workspace of one
  tenant, never across them.
  """
  def deduplicate_exact(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)

    if is_nil(tenant_id) and Keyword.get(opts, :all_tenants) != true,
      do: raise(ArgumentError, "deduplicate_exact needs :tenant_id, or all_tenants: true")

    intake = tenant_id && source_workspace(tenant_id)

    Store.transaction(fn txn ->
      with {:ok, rows} <- Store.txn_query(txn, @duplicates_sql, [tenant_id, intake]),
           ids = List.flatten(rows),
           {:ok, count} <- archive(txn, ids) do
        {:ok, {ids, count}}
      end
    end)
    |> case do
      {:ok, {ids, count}} ->
        # The read cache holds the records as they were before they were archived.
        Store.evict_cached(ids)
        {:ok, %{archived_exact_duplicates: count}}

      {:error, _} = error ->
        error
    end
  end

  defp archive(txn, ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, total} ->
      placeholders = Enum.map_join(1..length(chunk), ", ", &"?#{&1}")

      case Store.txn_execute(
             txn,
             """
             UPDATE contexts
             SET archived_at = datetime('now'),
                 metadata = json_set(COALESCE(metadata, '{}'), '$.cleanup_reason', 'exact_duplicate_context')
             WHERE id IN (#{placeholders})
             """,
             chunk
           ) do
        {:ok, changed} -> {:cont, {:ok, total + changed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Moves an intake context of a tenant and everything derived from it to
  `target_workspace_id`.

  Options: `:tenant_id` (required); `:evidence`, which is kept on the context
  as `metadata.routing_placement` with the time of the move; `:reviewed_by`,
  which marks the routing review entry of the context accepted by that actor
  in the same transaction.

  The context must be in the tenant's intake workspace and belong to the
  tenant (`{:error, :not_found_or_not_in_intake}` otherwise, whoever else's
  it is), and the target must be an active workspace of the tenant
  (`{:error, :target_workspace_not_registered}`). The rows derived from the
  context move with it and take its tenant, except rows labelled with another
  tenant, which are not the context's and stay.
  """
  def move_context(context_id, target_workspace_id, opts) when is_list(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    evidence = Keyword.get(opts, :evidence)
    reviewed_by = Keyword.get(opts, :reviewed_by)
    source = source_workspace(tenant_id)

    Store.transaction(fn txn ->
      with {:ok, [[^source]]} <-
             Store.txn_query(
               txn,
               "SELECT workspace_id FROM contexts WHERE id = ?1 AND tenant_id = ?2 AND archived_at IS NULL",
               [context_id, tenant_id]
             ),
           :ok <- check_target(txn, tenant_id, target_workspace_id),
           {:ok, _} <- update_context(txn, context_id, target_workspace_id, tenant_id),
           {:ok, _} <- record_placement(txn, context_id, tenant_id, evidence),
           {:ok, _} <- record_review(txn, context_id, tenant_id, reviewed_by),
           {:ok, _} <-
             update(txn, "chunks", "signal_id", context_id, target_workspace_id, tenant_id),
           {:ok, _} <-
             update(txn, "vectors", "context_id", context_id, target_workspace_id, tenant_id),
           {:ok, _} <-
             update(txn, "entities", "context_id", context_id, target_workspace_id, tenant_id),
           {:ok, _} <- update_edges(txn, context_id, source, target_workspace_id, tenant_id),
           {:ok, _} <-
             update(txn, "claims", "signal_id", context_id, target_workspace_id, tenant_id),
           {:ok, _} <- update_source_packages(txn, context_id, target_workspace_id, tenant_id),
           {:ok, _} <- update_entity_mentions(txn, context_id, target_workspace_id, tenant_id),
           {:ok, _} <- update_chunk_embeddings(txn, context_id, target_workspace_id, tenant_id) do
        {:ok, %{context_id: context_id, workspace_id: target_workspace_id}}
      else
        {:ok, _not_in_intake} -> {:error, :not_found_or_not_in_intake}
        {:error, _} = error -> error
      end
    end)
    |> tap(fn result ->
      # The read cache holds the context as it was before the move.
      if match?({:ok, _}, result), do: Store.evict_cached([context_id])
    end)
  end

  # The target of a move is an active workspace of the tenant; one of another
  # tenant is not registered as far as the caller can tell.
  defp check_target(txn, tenant_id, workspace_id) when is_binary(workspace_id) do
    case Store.txn_query(
           txn,
           "SELECT tenant_id FROM workspaces WHERE id = ?1 AND status = 'active'",
           [workspace_id]
         ) do
      {:ok, [[^tenant_id]]} -> :ok
      {:ok, _} -> {:error, :target_workspace_not_registered}
      {:error, _} = error -> error
    end
  end

  defp check_target(_txn, _tenant_id, _workspace_id), do: {:error, :target_workspace_required}

  # Placement by meaning keeps the method and its numbers: similarity and
  # margin (centroid); similarity, share, votes and neighbours (knn); all of
  # them with the centroid's workspace and similarity (agree).
  defp evidence(%{method: :semantic, semantic: semantic, workspace_id: workspace_id}) do
    semantic
    |> Map.drop([:method, :workspace_id])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{
      "method" => "semantic",
      "semantic_method" => Atom.to_string(semantic.method),
      "workspace_id" => workspace_id
    })
  end

  defp evidence(proposal) do
    %{
      "method" => "markers",
      "workspace_id" => proposal.workspace_id,
      "score" => proposal.score,
      "margin" => proposal.margin,
      "markers" => proposal.markers
    }
  end

  defp record_placement(_txn, _context_id, _tenant_id, nil), do: {:ok, 0}

  defp record_placement(txn, context_id, tenant_id, evidence) do
    placed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Store.txn_execute(
      txn,
      "UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_placement', json(?1)) WHERE id = ?2 AND tenant_id = ?3",
      [Jason.encode!(Map.put(evidence, "placed_at", placed_at)), context_id, tenant_id]
    )
  end

  defp record_review(_txn, _context_id, _tenant_id, nil), do: {:ok, 0}

  defp record_review(txn, context_id, tenant_id, reviewed_by) do
    Store.txn_execute(
      txn,
      """
      UPDATE contexts SET metadata = json_set(
        COALESCE(metadata, '{}'), '$.routing_review.state', 'accepted',
        '$.routing_review.reviewed_at', datetime('now'),
        '$.routing_review.reviewed_by', ?3
      ) WHERE id = ?1 AND tenant_id = ?2
      """,
      [context_id, tenant_id, reviewed_by]
    )
  end

  defp update_context(txn, context_id, workspace_id, tenant_id) do
    Store.txn_execute(
      txn,
      "UPDATE contexts SET workspace_id = ?1 WHERE id = ?2 AND tenant_id = ?3",
      [workspace_id, context_id, tenant_id]
    )
  end

  # A row derived from a context moves with it and takes its tenant. Some
  # writers do not label a derived row with its tenant (it keeps the unscoped
  # default), so the context's tenant and the default are both its own; a row
  # labelled with another tenant is not, and stays.
  defp update(txn, table, key, id, workspace_id, tenant_id) do
    Store.txn_execute(
      txn,
      "UPDATE #{table} SET workspace_id = ?1, tenant_id = ?3 WHERE #{key} = ?2 AND tenant_id IN (?3, ?4)",
      [workspace_id, id, tenant_id, Tenant.default_id()]
    )
  end

  # An edge joins two records. The context's edges in its source workspace move
  # with it, under its tenant; one that reaches a record of another tenant is
  # not moved. Edges are unique per tenant and workspace, so the move is three
  # statements in portable SQL (no UPDATE OR REPLACE, which PostgreSQL lacks):
  #
  #   1. A default-tenant copy of an edge the tenant also holds in the source
  #      workspace would land on the tenant's own: the tenant's copy is kept.
  #   2. An edge the target workspace already holds for the tenant is replaced
  #      by the moving one.
  #   3. The moving edges take the target workspace and the tenant.
  #
  # The moving set is the same in every statement: an edge of the context in
  # the source workspace, of the tenant or the default tenant, that reaches no
  # record of another tenant. Whether an edge reaches one depends only on its
  # endpoints, which a duplicate or a replaced copy shares.
  defp update_edges(txn, context_id, source_workspace_id, workspace_id, tenant_id) do
    default = Tenant.default_id()

    with {:ok, _} <-
           drop_default_copies(txn, context_id, source_workspace_id, tenant_id, default),
         {:ok, _} <-
           Store.txn_execute(
             txn,
             """
             DELETE FROM graph_edges
             WHERE workspace_id = ?1 AND tenant_id = ?3
               AND EXISTS (
                 SELECT 1 FROM graph_edges moving
                 WHERE moving.id <> graph_edges.id
                   AND moving.source_id = graph_edges.source_id
                   AND moving.target_id = graph_edges.target_id
                   AND moving.relation = graph_edges.relation
                   AND moving.workspace_id = ?5 AND moving.tenant_id IN (?3, ?4)
                   AND (moving.source_id = ?2 OR moving.target_id = ?2)
               )
               AND NOT EXISTS (
                 SELECT 1 FROM contexts other
                 WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
                   AND other.id <> ?2 AND other.tenant_id <> ?3
               )
             """,
             [workspace_id, context_id, tenant_id, default, source_workspace_id]
           ) do
      Store.txn_execute(
        txn,
        """
        UPDATE graph_edges SET workspace_id = ?1, tenant_id = ?3
        WHERE (source_id = ?2 OR target_id = ?2) AND workspace_id = ?5 AND tenant_id IN (?3, ?4)
          AND NOT EXISTS (
            SELECT 1 FROM contexts other
            WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
              AND other.id <> ?2 AND other.tenant_id <> ?3
          )
        """,
        [workspace_id, context_id, tenant_id, default, source_workspace_id]
      )
    end
  end

  # A default-tenant context has no second copy to collide with.
  defp drop_default_copies(_txn, _context_id, _source, tenant_id, tenant_id), do: {:ok, 0}

  defp drop_default_copies(txn, context_id, source_workspace_id, tenant_id, default) do
    Store.txn_execute(
      txn,
      """
      DELETE FROM graph_edges
      WHERE workspace_id = ?1 AND tenant_id = ?4
        AND (source_id = ?2 OR target_id = ?2)
        AND EXISTS (
          SELECT 1 FROM graph_edges kept
          WHERE kept.workspace_id = ?1 AND kept.tenant_id = ?3
            AND kept.source_id = graph_edges.source_id
            AND kept.target_id = graph_edges.target_id
            AND kept.relation = graph_edges.relation
        )
        AND NOT EXISTS (
          SELECT 1 FROM contexts other
          WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
            AND other.id <> ?2 AND other.tenant_id <> ?3
        )
      """,
      [source_workspace_id, context_id, tenant_id, default]
    )
  end

  # The source packages of the claims that moved (they carry the tenant now).
  defp update_source_packages(txn, context_id, workspace_id, tenant_id) do
    Store.txn_execute(
      txn,
      """
      UPDATE source_packages SET workspace_id = ?1, tenant_id = ?3
      WHERE tenant_id IN (?3, ?4)
        AND id IN (SELECT source_package_id FROM claims WHERE signal_id = ?2 AND tenant_id = ?3)
      """,
      [workspace_id, context_id, tenant_id, Tenant.default_id()]
    )
  end

  # The mentions found in the context or in a source package of the claims that
  # moved (they carry the tenant now), and the decisions made on them, go where
  # they were found.
  defp update_entity_mentions(txn, context_id, workspace_id, tenant_id) do
    mentions = """
    SELECT id FROM entity_mentions
    WHERE context_id = ?2
       OR source_package_id IN (
         SELECT source_package_id FROM claims WHERE signal_id = ?2 AND tenant_id = ?3
       )
    """

    with {:ok, _} <-
           Store.txn_execute(
             txn,
             "UPDATE resolution_decisions SET workspace_id = ?1 WHERE mention_id IN (#{mentions})",
             [workspace_id, context_id, tenant_id]
           ) do
      Store.txn_execute(
        txn,
        "UPDATE entity_mentions SET workspace_id = ?1 WHERE id IN (#{mentions})",
        [workspace_id, context_id, tenant_id]
      )
    end
  end

  # The embeddings of the chunks that moved (they carry the tenant now).
  defp update_chunk_embeddings(txn, context_id, workspace_id, tenant_id) do
    Store.txn_execute(
      txn,
      """
      UPDATE chunk_embeddings SET workspace_id = ?1, tenant_id = ?3
      WHERE tenant_id IN (?3, ?4)
        AND chunk_id IN (SELECT id FROM chunks WHERE signal_id = ?2 AND tenant_id = ?3)
      """,
      [workspace_id, context_id, tenant_id, Tenant.default_id()]
    )
  end

  defp confidence(score, second_score)
       when score >= @minimum_score and score - second_score >= @minimum_margin do
    :high
  end

  defp confidence(score, _second_score) when score > 0, do: :review
  defp confidence(_, _), do: :unresolved

  defp normalize(value) do
    value |> to_string() |> String.downcase() |> String.replace(~r/\s+/u, " ")
  end

  defp occurrence_count(text, marker), do: text |> :binary.matches(marker) |> length()

  defp summarize(proposals) do
    high = Enum.filter(proposals, &(&1.confidence == :high))

    %{
      total: length(proposals),
      high_confidence: high,
      review: Enum.filter(proposals, &(&1.confidence == :review)),
      unresolved: Enum.filter(proposals, &(&1.confidence == :unresolved)),
      by_workspace: Enum.frequencies_by(high, & &1.workspace_id),
      by_method: Enum.frequencies_by(high, &Map.get(&1, :method))
    }
  end
end
