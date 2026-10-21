defmodule OptimalEngine.Connectors.Adapters.Beehiiv do
  @moduledoc """
  beehiiv connector -- newsletter posts and subscribers.

  ## Required config keys
    * `:publication_id` -- the publication to read (`pub_...`)
    * optional `:max_pages` -- pages fetched per run across both record
      families (default 20)
    * optional `:families` -- the record families to read, `["posts"]`,
      `["subscribers"]` or both (default both). Subscribers are personal
      data; a knowledge base that only needs the newsletter reads posts.

  ## Credentials
    * `:api_key` -- a beehiiv API key, sent as a bearer token

  ## Cursor shape
  Opaque string: `"<family>:<page>"`, where family is `posts` or
  `subscribers` and page is the next page number to fetch. Initial sync: `nil`.

  A run walks pages from the cursor, posts first and then subscribers, until
  it reaches the end of both or spends its page bound. At the bound the cursor
  names the next page, so the following run resumes there. At the end the
  cursor is `nil` and the following run starts over: the API has no
  changed-since filter, and signal ids are deterministic, so replaying a page
  does not create duplicates.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :beehiiv,
    display_name: "beehiiv",
    auth_scheme: :token,
    required_keys: [:publication_id],
    credential_keys: [:api_key],
    token_key: :api_key

  alias OptimalEngine.Connectors.HTTP

  @base_url "https://api.beehiiv.com/v2/publications"
  @page_size 100
  @max_pages 20

  # Walk order, and the API collection each record family lives under.
  @families ["posts", "subscribers"]
  @collections %{"posts" => "posts", "subscribers" => "subscriptions"}

  @impl true
  def sync(state, cursor) do
    publication = URI.encode(to_string(pick(state, :publication_id)), &URI.char_unreserved?/1)

    with {:ok, families} <- families(state) do
      ctx = %{
        base: "#{@base_url}/#{publication}",
        headers: [{"authorization", "Bearer #{pick(state, :api_key)}"}],
        families: families
      }

      walk(ctx, parse_cursor(cursor, families), [], max_pages(state))
    end
  end

  # The two record families have no marker in common, so the shape decides: a
  # subscription carries an `email`, a post does not.
  @impl true
  def transform(raw) when is_map(raw) do
    if Map.has_key?(raw, "email") do
      {:ok, subscriber_signal(raw)}
    else
      {:ok, post_signal(raw)}
    end
  end

  # ---- private ----------------------------------------------------------------

  # `acc` holds signals newest first; `position` is the next page to fetch.
  defp walk(_ctx, :done, acc, _budget), do: finish(acc, nil)
  defp walk(_ctx, position, acc, 0), do: finish(acc, encode_cursor(position))

  defp walk(ctx, {family, page} = position, acc, budget) do
    with {:ok, body} <- fetch_page(ctx, family, page),
         {:ok, records} <- records(body) do
      acc = Enum.reduce(records, acc, &add_signal/2)
      walk(ctx, next_position(position, body, ctx.families), acc, budget - 1)
    end
  end

  defp finish(acc, cursor), do: {:ok, %{signals: Enum.reverse(acc), cursor: cursor}}

  defp add_signal(record, acc) do
    case transform(record) do
      {:ok, signal} -> [signal | acc]
      _ -> acc
    end
  end

  defp fetch_page(ctx, family, page) do
    url = "#{ctx.base}/#{Map.fetch!(@collections, family)}?limit=#{@page_size}&page=#{page}"

    case HTTP.get_json(url, headers: ctx.headers) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, {:unexpected_response, 200}}
      {:ok, %{status: status}} -> status_error(status)
      {:error, reason} -> {:error, reason}
    end
  end

  defp records(%{"data" => data}) when is_list(data), do: {:ok, Enum.filter(data, &is_map/1)}
  defp records(_body), do: {:error, {:unexpected_response, 200}}

  # Another page of the same family while `page < total_pages`; otherwise the
  # first page of the next family, or `:done` after the last one.
  defp next_position({family, page}, %{"total_pages" => total}, _families)
       when is_integer(total) and page < total,
       do: {family, page + 1}

  defp next_position({family, _page}, _body, families) do
    index = Enum.find_index(families, &(&1 == family))

    case Enum.at(families, index + 1) do
      nil -> :done
      next_family -> {next_family, 1}
    end
  end

  # A cursor for a family the row no longer reads starts over on the first one.
  defp parse_cursor(cursor, families) when is_binary(cursor) do
    with [family, page] <- String.split(cursor, ":", parts: 2),
         true <- family in families,
         {page, ""} when page >= 1 <- Integer.parse(page) do
      {family, page}
    else
      _ -> {hd(families), 1}
    end
  end

  defp parse_cursor(_cursor, families), do: {hd(families), 1}

  # The configured families in walk order; anything else is refused rather
  # than widened to a full read.
  defp families(state) do
    case pick(state, :families) do
      nil ->
        {:ok, @families}

      names when is_list(names) and names != [] ->
        names = Enum.map(names, &to_string/1)

        if Enum.all?(names, &(&1 in @families)),
          do: {:ok, Enum.filter(@families, &(&1 in names))},
          else: {:error, {:invalid_config, :families}}

      _other ->
        {:error, {:invalid_config, :families}}
    end
  end

  defp encode_cursor({family, page}), do: "#{family}:#{page}"

  defp max_pages(state) do
    case pick(state, :max_pages) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_pages
    end
  end

  defp status_error(status) when status in [401, 403], do: {:error, :auth_expired}
  defp status_error(429), do: {:error, :rate_limited}
  defp status_error(status) when status >= 500, do: {:error, :transient}
  defp status_error(status), do: {:error, {:http, status}}

  # ---- signals ----------------------------------------------------------------

  defp post_signal(raw) do
    ext_id = external_id(raw)

    Transform.new_signal(%{
      id: Transform.signal_id(:beehiiv, ext_id),
      title: String.slice(present(raw["title"]) || "Untitled", 0, 120),
      content: Transform.strip_html(present(raw["preview_text"]) || present(raw["subtitle"])),
      path: Transform.source_uri(:beehiiv, ext_id),
      genre: "post",
      modified_at: Transform.parse_epoch(raw["publish_date"] || raw["created"])
    })
  end

  defp subscriber_signal(raw) do
    ext_id = external_id(raw)
    email = present(raw["email"])
    created = Transform.parse_epoch(raw["created"])

    Transform.new_signal(%{
      id: Transform.signal_id(:beehiiv, ext_id),
      title: "Subscriber #{email || ext_id}",
      content: subscriber_content(raw, email),
      path: Transform.source_uri(:beehiiv, ext_id),
      genre: "subscriber",
      entities: if(email, do: [email], else: []),
      created_at: created,
      modified_at: created
    })
  end

  defp subscriber_content(raw, email) do
    [
      {"Email", email},
      {"Status", present(raw["status"])},
      {"Tier", present(raw["subscription_tier"])},
      {"Source", present(raw["utm_source"])}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end)
  end

  defp external_id(%{"id" => id}) when is_binary(id), do: id
  defp external_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp external_id(_raw), do: ""

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
