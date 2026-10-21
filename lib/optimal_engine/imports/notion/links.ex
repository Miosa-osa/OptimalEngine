defmodule OptimalEngine.Imports.Notion.Links do
  @moduledoc """
  Resolves the links inside an exported Notion page.

  A Markdown link to another exported page or database (a relative path such
  as `Child%20Page%200123...cdef.md`, or a `notion.so` / `notion.site` URL
  carrying the target's id) is rewritten to the target's `optimal://` URI and
  reported, so the importer can store a `links_to` edge. A link that names a
  page or database the export does not hold is left as written and counted as
  unresolved. Images, assets, anchors and other web links are left alone and
  not counted.
  """

  alias OptimalEngine.Imports.Notion.Plan

  # [text](target) with one level of brackets in the text and of parentheses
  # in the target; an image (`![alt](src)`) is matched so it can be skipped.
  @link ~r/(!?)\[((?:[^\[\]\n]|\[[^\[\]\n]*\])*)\]\(([^()\s]+(?:\([^()\s]*\)[^()\s]*)*)\)/u
  @notion_url ~r{\Ahttps?://(?:[a-z0-9-]+\.)*notion\.(?:so|site)/}i
  @scheme ~r/\A[a-z][a-z0-9+.-]*:/i
  @hex_id ~r/([0-9a-f]{32})(?![0-9a-f])/
  @uuid ~r/([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})/

  @type result :: %{text: String.t(), targets: [String.t()], unresolved: non_neg_integer()}

  @doc """
  Rewrites the links of `text`, the content of the page at `page_path`.
  `plan` supplies the export's paths and ids; `uri_of` maps a target id to its
  URI. Returns the new text, the distinct target ids, and the unresolved count.
  """
  @spec rewrite(String.t(), String.t(), Plan.t(), (String.t() -> String.t())) :: result()
  def rewrite(text, page_path, plan, uri_of) do
    dir = Path.dirname(page_path)

    {pieces, {targets, unresolved}} =
      @link
      |> Regex.split(text, include_captures: true)
      |> Enum.map_reduce({[], 0}, fn piece, {targets, unresolved} ->
        case Regex.run(@link, piece) do
          [^piece, "", label, href] ->
            case resolve(href, dir, plan) do
              {:ok, id} ->
                {"[#{label}](#{uri_of.(id)})", {[id | targets], unresolved}}

              :unresolved ->
                {piece, {targets, unresolved + 1}}

              :ignore ->
                {piece, {targets, unresolved}}
            end

          _ ->
            {piece, {targets, unresolved}}
        end
      end)

    %{
      text: IO.iodata_to_binary(pieces),
      targets: targets |> Enum.reverse() |> Enum.uniq(),
      unresolved: unresolved
    }
  end

  @doc """
  Resolves one link target: `{:ok, id}` for an exported page or database,
  `:unresolved` for a page reference the export does not hold, `:ignore` for
  anything else.
  """
  @spec resolve(String.t(), String.t(), Plan.t()) :: {:ok, String.t()} | :unresolved | :ignore
  def resolve(href, dir, plan) do
    target = href |> String.split(["#", "?"], parts: 2) |> hd()

    cond do
      target == "" ->
        :ignore

      Regex.match?(@notion_url, target) ->
        by_id(id_in(target), plan)

      Regex.match?(@scheme, target) ->
        :ignore

      page_reference?(target) ->
        relative(target, dir, plan)

      true ->
        :ignore
    end
  end

  defp relative(target, dir, plan) do
    decoded = decode(target)

    case join(dir, decoded) do
      {:ok, path} ->
        case Map.get(plan.by_path, path) do
          nil -> by_id(Plan.id_of(decoded), plan)
          id -> {:ok, id}
        end

      :error ->
        by_id(Plan.id_of(decoded), plan)
    end
  end

  defp by_id(nil, _plan), do: :unresolved

  defp by_id(id, plan) do
    cond do
      Map.has_key?(plan.by_id, id) -> {:ok, id}
      Map.has_key?(plan.by_id, id <> "-database") -> {:ok, id <> "-database"}
      true -> :unresolved
    end
  end

  defp page_reference?(target) do
    ext = target |> decode() |> Path.extname() |> String.downcase()
    ext in [".md", ".csv"]
  end

  # The id of a notion.so URL is the last 32 hex run (or dashed UUID) in it.
  defp id_in(url) do
    url = String.downcase(url)

    case Regex.scan(@hex_id, url) do
      [_ | _] = found ->
        found |> List.last() |> List.last()

      [] ->
        case Regex.scan(@uuid, url) do
          [_ | _] = found -> found |> List.last() |> tl() |> Enum.join()
          [] -> nil
        end
    end
  end

  defp decode(target) do
    URI.decode(target)
  rescue
    ArgumentError -> target
  end

  # Joins a relative target onto the page's folder, resolving `.` and `..`;
  # a target that climbs above the export root resolves to nothing.
  defp join(dir, target) do
    segments = if dir == ".", do: [], else: String.split(dir, "/")

    target
    |> String.split("/")
    |> Enum.reduce_while({:ok, Enum.reverse(segments)}, fn
      segment, acc when segment in ["", "."] -> {:cont, acc}
      "..", {:ok, []} -> {:halt, :error}
      "..", {:ok, [_ | rest]} -> {:cont, {:ok, rest}}
      segment, {:ok, acc} -> {:cont, {:ok, [segment | acc]}}
    end)
    |> case do
      {:ok, []} -> :error
      {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> Enum.join("/")}
      :error -> :error
    end
  end
end
