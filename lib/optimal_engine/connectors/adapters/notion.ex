defmodule OptimalEngine.Connectors.Adapters.Notion do
  @moduledoc """
  Notion connector -- pages, databases, blocks.

  ## Required config keys
    * `:workspace_name`, `:database_ids` (list; empty = all accessible)

  ## Credentials
    * `:integration_token` -- `secret_...`, or
    * an `:access_token` -- a public integration's OAuth token, given directly
      or issued by the credential broker (`credential_source: "broker"`).
      Every Notion call goes through `OptimalEngine.Connectors.AccessToken`,
      which renews a brokered token before it expires and once after a `401`.

  ## Content
  One database page becomes one Signal. The title is the page's title
  property, whatever the database names it, with its rich-text fragments
  joined. The body is the page's top-level blocks (paragraphs, headings, list
  items, to-dos, quotes, callouts, toggles, code) as Markdown lines; a page
  with no text blocks carries its title as its content, so it is not dropped
  as empty on intake. Nested child blocks are not followed.

  ## Cursor shape
  Opaque: a JSON object of `database_id => last_edited_time`, the latest edit
  seen in each database. A database with no entry is read from the beginning,
  so a database shared with the integration later still yields its history. A
  plain timestamp (the shape before per-database watermarks) is read as the
  watermark of every database; anything else is read as `nil`, which is safe
  because Signal ids are derived from page ids. Initial sync: `nil`.

  ## Errors
  A `401` is `:auth_expired`, a `429` is `:rate_limited` (or
  `{:rate_limited, ms}` when Notion names a `Retry-After`), a `5xx` or a
  transport failure ends the sync with that reason; the Runner retries with
  the same cursor. Any other status from one database (not shared with the
  integration, deleted, a bad filter) skips that database, keeps its
  watermark and logs a warning, so one bad database does not stop the others.
  When every database fails that way the sync returns the first error.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :notion,
    display_name: "Notion",
    auth_scheme: :token,
    required_keys: [:workspace_name, :database_ids],
    credential_keys: [:integration_token],
    access_token: true,
    token_key: :integration_token

  alias OptimalEngine.Connectors.{AccessToken, HTTP}

  require Logger

  @base_url "https://api.notion.com/v1"
  @version [{"notion-version", "2022-06-28"}]
  @page_size 100
  @max_pages 20
  @max_block_pages 10

  @impl true
  def sync(state, cursor) do
    AccessToken.session(state, &integration_token/1, fn token ->
      with {:ok, databases} <- database_ids(state, token),
           {:ok, signals, marks} <- sync_databases(databases, parse_cursor(cursor), token) do
        {:ok, %{signals: signals, cursor: encode_cursor(marks)}}
      end
    end)
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = raw["id"] || ""
    title = extract_title(raw)
    body = flatten_blocks(raw["blocks"] || [])

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:notion, ext_id),
       title: title || "Untitled",
       content: if(body == "", do: title || "", else: body),
       path: Transform.source_uri(:notion, ext_id),
       genre: "document",
       mode: :linguistic,
       format: :markdown,
       modified_at: Transform.parse_iso8601(raw["last_edited_time"])
     })}
  end

  def transform(_raw), do: {:error, :invalid_payload}

  defp integration_token(state), do: {:ok, pick(state, :integration_token)}

  # ---- databases ----------------------------------------------------------------

  defp database_ids(state, token) do
    case pick(state, :database_ids, []) do
      [_ | _] = ids -> {:ok, Enum.uniq(ids)}
      _ -> search_databases(nil, token, [], 0)
    end
  end

  # Every database the integration can see. `/search` pages like every other
  # list, so a workspace with more than one page of databases needs the cursor.
  defp search_databases(_cursor, _token, ids, page) when page >= @max_pages, do: {:ok, ids}

  defp search_databases(start_cursor, token, ids, page) do
    body =
      %{
        "filter" => %{"value" => "database", "property" => "object"},
        "page_size" => @page_size
      }
      |> put_start_cursor(start_cursor)

    case AccessToken.post_json(token, "#{@base_url}/search", body, headers: @version) do
      {:ok, %{status: 200, body: %{"results" => results} = resp}} ->
        ids = ids ++ Enum.flat_map(results, &List.wrap(&1["id"]))

        case next_cursor(resp) do
          nil -> {:ok, ids}
          next -> search_databases(next, token, ids, page + 1)
        end

      other ->
        {:error, error_reason(other)}
    end
  end

  # Walks the databases one by one, each from its own watermark. A failure the
  # Runner can act on (auth, rate limit, server, transport) ends the walk; a
  # failure particular to one database skips it and keeps its watermark.
  defp sync_databases(databases, marks, token) do
    start = %{chunks: [], marks: marks, synced: 0, failed: []}

    outcome =
      Enum.reduce_while(databases, start, fn db_id, acc ->
        since = watermark(acc.marks, db_id)

        case sync_database(db_id, since, token) do
          {:ok, signals, mark} ->
            {:cont,
             %{
               acc
               | chunks: [signals | acc.chunks],
                 marks: put_mark(acc.marks, db_id, mark),
                 synced: acc.synced + 1
             }}

          {:error, {:http, _status} = reason} ->
            Logger.warning("[Connectors.Notion] database #{db_id} skipped: #{inspect(reason)}")

            {:cont,
             %{acc | marks: put_mark(acc.marks, db_id, since), failed: [reason | acc.failed]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case outcome do
      {:error, _reason} = error -> error
      %{synced: 0, failed: [_ | _] = failed} -> {:error, List.last(failed)}
      %{chunks: chunks, marks: marks} -> {:ok, chunks |> Enum.reverse() |> Enum.concat(), marks}
    end
  end

  defp sync_database(db_id, since, token) do
    with {:ok, pages} <- query_pages(db_id, since, nil, token, []),
         {:ok, pages} <- attach_blocks(pages, token) do
      {:ok, to_signals(pages), latest_edit(pages, since)}
    end
  end

  # Pages edited after `since`, oldest edit first, every page of the answer.
  defp query_pages(db_id, since, start_cursor, token, acc) do
    body = query_body(since, start_cursor)
    url = "#{@base_url}/databases/#{db_id}/query"

    case AccessToken.post_json(token, url, body, headers: @version) do
      {:ok, %{status: 200, body: %{"results" => results} = resp}} ->
        acc = acc ++ results

        case next_cursor(resp) do
          nil -> {:ok, acc}
          next -> query_pages(db_id, since, next, token, acc)
        end

      other ->
        {:error, error_reason(other)}
    end
  end

  defp query_body(since, start_cursor) do
    base = %{
      "sorts" => [%{"timestamp" => "last_edited_time", "direction" => "ascending"}],
      "page_size" => @page_size
    }

    base =
      if since do
        Map.put(base, "filter", %{
          "timestamp" => "last_edited_time",
          "last_edited_time" => %{"after" => since}
        })
      else
        base
      end

    put_start_cursor(base, start_cursor)
  end

  # ---- blocks -------------------------------------------------------------------

  # A database query returns pages with their properties only. The body of a
  # page is its block children, one request per page, so they are fetched here
  # and carried on the page as `"blocks"` for `transform/1`.
  defp attach_blocks(pages, token) do
    pages
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, acc} ->
      case fetch_blocks(page["id"], nil, token, [], 0) do
        {:ok, blocks} ->
          {:cont, {:ok, [Map.put(page, "blocks", blocks) | acc]}}

        {:error, {:http, _status} = reason} ->
          Logger.warning(
            "[Connectors.Notion] page #{page["id"]} body unreadable: #{inspect(reason)}"
          )

          {:cont, {:ok, [Map.put(page, "blocks", []) | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp fetch_blocks(_page_id, _cursor, _token, blocks, count) when count >= @max_block_pages,
    do: {:ok, blocks}

  defp fetch_blocks(page_id, start_cursor, token, blocks, count) do
    url =
      "#{@base_url}/blocks/#{page_id}/children?page_size=#{@page_size}" <>
        if(start_cursor, do: "&start_cursor=#{URI.encode_www_form(start_cursor)}", else: "")

    case AccessToken.get_json(token, url, headers: @version) do
      {:ok, %{status: 200, body: %{"results" => results} = resp}} ->
        blocks = blocks ++ results

        case next_cursor(resp) do
          nil -> {:ok, blocks}
          next -> fetch_blocks(page_id, next, token, blocks, count + 1)
        end

      other ->
        {:error, error_reason(other)}
    end
  end

  # ---- signals ------------------------------------------------------------------

  defp to_signals(pages) do
    Enum.flat_map(pages, fn page ->
      case transform(page) do
        {:ok, signal} -> [signal]
        _ -> []
      end
    end)
  end

  # The title property is the one that carries a `title` list; the database
  # names it (`Name`, `Task name`, ...), and its text can span several fragments.
  defp extract_title(%{"properties" => properties}) when is_map(properties) do
    Enum.find_value(properties, fn
      {_name, %{"title" => fragments}} when is_list(fragments) -> present(plain_text(fragments))
      _ -> nil
    end)
  end

  defp extract_title(_raw), do: nil

  defp flatten_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp flatten_blocks(_blocks), do: ""

  # Every text-bearing block type keeps its words under `rich_text`; blocks
  # without text (dividers, images, child pages) contribute nothing.
  defp block_line(%{"type" => type} = block) when is_binary(type) do
    case block[type] do
      %{"rich_text" => fragments} = content when is_list(fragments) ->
        case plain_text(fragments) do
          "" -> ""
          text -> prefix(type, content) <> text
        end

      _ ->
        ""
    end
  end

  defp block_line(_block), do: ""

  defp prefix("heading_1", _content), do: "# "
  defp prefix("heading_2", _content), do: "## "
  defp prefix("heading_3", _content), do: "### "
  defp prefix("bulleted_list_item", _content), do: "- "
  defp prefix("numbered_list_item", _content), do: "1. "
  defp prefix("to_do", %{"checked" => true}), do: "- [x] "
  defp prefix("to_do", _content), do: "- [ ] "
  defp prefix("quote", _content), do: "> "
  defp prefix(_type, _content), do: ""

  defp plain_text(fragments) do
    fragments
    |> Enum.map_join("", fn
      %{"plain_text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> String.trim()
  end

  defp present(""), do: nil
  defp present(text), do: text

  # ---- cursor -------------------------------------------------------------------

  defp parse_cursor("{" <> _ = cursor) do
    case Jason.decode(cursor) do
      {:ok, %{} = marks} ->
        %{floor: nil, dbs: marks |> Enum.filter(fn {_id, at} -> iso8601?(at) end) |> Map.new()}

      _ ->
        %{floor: nil, dbs: %{}}
    end
  end

  defp parse_cursor(cursor) when is_binary(cursor) do
    if iso8601?(cursor), do: %{floor: cursor, dbs: %{}}, else: %{floor: nil, dbs: %{}}
  end

  defp parse_cursor(_cursor), do: %{floor: nil, dbs: %{}}

  defp encode_cursor(%{dbs: dbs}) when map_size(dbs) > 0, do: Jason.encode!(dbs)
  defp encode_cursor(%{floor: floor}), do: floor

  defp watermark(%{dbs: dbs, floor: floor}, db_id), do: Map.get(dbs, db_id) || floor

  defp put_mark(marks, _db_id, nil), do: marks
  defp put_mark(%{dbs: dbs} = marks, db_id, mark), do: %{marks | dbs: Map.put(dbs, db_id, mark)}

  defp latest_edit(pages, since) do
    Enum.reduce(pages, since, fn page, latest -> later(latest, page["last_edited_time"]) end)
  end

  # Notion stamps every edit in one format, but the cursor may carry another
  # (an older run, an operator edit), so instants are compared as instants.
  defp later(nil, other), do: other
  defp later(one, nil), do: one

  defp later(one, other) do
    with {:ok, a, _} <- DateTime.from_iso8601(one),
         {:ok, b, _} <- DateTime.from_iso8601(other) do
      if DateTime.compare(a, b) == :lt, do: other, else: one
    else
      _ -> max(one, other)
    end
  end

  defp iso8601?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp iso8601?(_value), do: false

  # ---- paging + errors ----------------------------------------------------------

  defp put_start_cursor(body, nil), do: body
  defp put_start_cursor(body, cursor), do: Map.put(body, "start_cursor", cursor)

  # `has_more` with no `next_cursor` would ask for the same page forever.
  defp next_cursor(%{"has_more" => true, "next_cursor" => cursor}) when is_binary(cursor),
    do: cursor

  defp next_cursor(_resp), do: nil

  defp error_reason({:ok, %{status: 401}}), do: :auth_expired

  defp error_reason({:ok, %{status: 429, headers: headers}}) do
    case HTTP.retry_after(headers) do
      nil -> :rate_limited
      retry_after_ms -> {:rate_limited, retry_after_ms}
    end
  end

  defp error_reason({:ok, %{status: status}}) when status >= 500, do: :transient
  defp error_reason({:ok, %{status: 200}}), do: :bad_response
  defp error_reason({:ok, %{status: status}}), do: {:http, status}
  defp error_reason({:error, reason}), do: reason
end
