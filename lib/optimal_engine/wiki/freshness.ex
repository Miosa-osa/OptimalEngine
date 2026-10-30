defmodule OptimalEngine.Wiki.Freshness do
  @moduledoc """
  Decides whether a wiki page is stale and whether it may answer a question.

  A page is **stale** when it is older than the workspace's configured
  `max_stale_days` (by `last_curated`, the page's updated time) and either

    * it has no citation rows, so nothing it rests on can be checked, or
    * a context was ingested into one of its cited nodes after `last_curated`.

  A page with no citations can therefore never be "fresh by absence of new
  signals": once it passes the limit it is stale.

  A page may **answer** (`answerable?/2`) only when it is not stale and
  carries at least one `{{cite: ...}}` source. `OptimalEngine.Retrieval.RAG`
  uses this so a stale or unsourced page falls through to retrieval over
  contexts instead of being served as the answer.
  """

  alias OptimalEngine.Store, as: RawStore
  alias OptimalEngine.Wiki.Page
  alias OptimalEngine.Workspace.Config

  @default_max_stale_days 7

  @doc "Default stale limit in days when the workspace sets none."
  @spec default_max_stale_days() :: pos_integer()
  def default_max_stale_days, do: @default_max_stale_days

  @doc "The workspace's configured stale limit in days."
  @spec max_stale_days(String.t()) :: number()
  def max_stale_days(workspace_id) do
    section =
      Config.get_section(workspace_id, :curation, %{max_stale_days: @default_max_stale_days})

    case Map.get(section, :max_stale_days, @default_max_stale_days) do
      days when is_number(days) and days >= 0 -> days
      _ -> @default_max_stale_days
    end
  end

  @doc """
  True when the page is older than `max_stale_days` and either has no
  citations or has new signals in its cited nodes.
  """
  @spec stale?(Page.t(), number()) :: boolean()
  def stale?(%Page{} = page, max_stale_days) do
    older_than?(page, max_stale_days) and needs_curation?(page)
  end

  @doc "True when `last_curated` is more than `max_stale_days` before now."
  @spec older_than?(Page.t(), number(), DateTime.t()) :: boolean()
  def older_than?(%Page{last_curated: last}, max_stale_days, now \\ DateTime.utc_now()) do
    case parse_time(last) do
      {:ok, curated_at} -> DateTime.diff(now, curated_at, :second) > max_stale_days * 86_400
      :error -> false
    end
  end

  @doc "True when the page has no citation rows, or its cited nodes have new signals."
  @spec needs_curation?(Page.t()) :: boolean()
  def needs_curation?(%Page{} = page), do: not cited?(page) or has_new_signals?(page)

  @doc "True when the page has at least one row in the citations table."
  @spec cited?(Page.t()) :: boolean()
  def cited?(%Page{} = page) do
    sql = """
    SELECT COUNT(*) FROM citations
    WHERE wiki_slug = ?1 AND wiki_audience = ?2 AND tenant_id = ?3
    """

    case RawStore.raw_query(sql, [page.slug, page.audience, page.tenant_id]) do
      {:ok, [[count]]} when is_integer(count) and count > 0 -> true
      _ -> false
    end
  end

  @doc "True when the page body names at least one `{{cite: ...}}` source."
  @spec sourced?(Page.t()) :: boolean()
  def sourced?(%Page{body: body}) when is_binary(body),
    do: Regex.match?(~r/\{\{\s*cite\s*:\s*[^\}\s]+/, body)

  def sourced?(_), do: false

  @doc "True when the page may answer a question: it has sources and is not stale."
  @spec answerable?(Page.t(), number()) :: boolean()
  def answerable?(%Page{} = page, max_stale_days) do
    sourced?(page) and not stale?(page, max_stale_days)
  end

  @doc """
  Parse a stored timestamp, ISO 8601 or SQLite `YYYY-MM-DD HH:MM:SS` (UTC).
  """
  @spec parse_time(String.t() | nil) :: {:ok, DateTime.t()} | :error
  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  def parse_time(_), do: :error

  # Any context ingested into a cited node after the page was last curated.
  @doc false
  @spec has_new_signals?(Page.t()) :: boolean()
  def has_new_signals?(%Page{last_curated: nil}), do: true

  def has_new_signals?(%Page{} = page) do
    sql = """
    SELECT COUNT(*)
    FROM contexts ctx
    WHERE ctx.node IN (
      SELECT DISTINCT ctx2.node
      FROM contexts ctx2
      JOIN chunks ch  ON ch.signal_id = ctx2.id
      JOIN citations  cit ON cit.chunk_id = ch.id
      WHERE cit.wiki_slug     = ?1
        AND cit.wiki_audience = ?2
        AND cit.tenant_id     = ?3
    )
    AND datetime(ctx.created_at) > datetime(?4)
    AND ctx.workspace_id = ?5
    LIMIT 1
    """

    params = [
      page.slug,
      page.audience,
      page.tenant_id,
      page.last_curated,
      page.workspace_id
    ]

    case RawStore.raw_query(sql, params) do
      {:ok, [[count]]} when count > 0 -> true
      _ -> false
    end
  end
end
