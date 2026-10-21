defmodule OptimalEngine.Connectors.Adapters.GoHighLevel do
  @moduledoc """
  GoHighLevel connector - contacts, conversations with their messages, and
  opportunities, read from the v2 API at `services.leadconnectorhq.com`.

  ## Required config keys
    * `:location_ids` - list of GoHighLevel location (sub-account) ids

  ## Optional config keys
    * `:currency` - three-letter code stamped on opportunity amounts. An
      opportunity record does not normally name a currency (it is a location
      setting), so this is where the `currency=` value comes from. A
      `currency` on the record itself wins.
    * `:max_pages` - list pages one run may fetch, default 20. It bounds the
      batch: a run that reaches it stops and returns a cursor to resume from.

  ## Credentials
    * `:api_token` - a location token, **or**
    * `:agency_token` - an agency token that can read the listed locations

  `:api_token` wins when both are present. The token is sent as
  `Authorization: Bearer <token>`, with `Version: 2021-07-28`, on every call.
  An agency token is sent as it is; it is not exchanged for a location token.

  ## Records
  Each record becomes one Signal. `transform/1` takes the API record with a
  `"_family"` key (`"contact"`, `"conversation"` or `"opportunity"`) that
  `sync/2` adds, and for a conversation a `"messages"` list.

    * contact (genre `"contact"`) - name, email, phone and tags. The email is
      the entity routing rules match as `sender`.
    * conversation (genre `"message"`) - the message bodies, oldest first. SMS
      and email bodies are preferred: when a conversation has any, other
      channels are left out, and a conversation with none keeps every message
      that has a body. Only the first page of messages (up to 100) is read.
      If its messages cannot be read the conversation keeps `lastMessageBody`.
      The counterparty email comes from the conversation's `email`, or the
      `from` of an inbound and the `to` of an outbound message.
    * opportunity (genre `"opportunity"`) - name, status, stage and value, with
      the structured line below.

  ## Structured values
  A `%Signal{}` has no metadata map, so an amount travels as a labelled,
  parseable first line of `content`, then a blank line, then the sentence:

      amount_minor=12000 currency=usd stage=proposal

  `amount_minor` is the `monetaryValue` in minor units, which assumes a
  currency with two decimals. `currency` is lower case and `stage` is the stage
  name lower-cased with runs of other characters as `_`; either is left out
  when unknown. The whole line is left out when the opportunity has no amount
  (a missing or zero `monetaryValue`).

  ## Cursor shape
  Opaque string `"<family>:<location_id>:<last_seen_id>"`, for example
  `"contacts:loc_0001:abc123"`. `nil` starts a full pass.

  A pass walks contacts, then conversations, then opportunities, one location
  after another within each. A run stops at `:max_pages` and returns the cursor
  of the page it did not fetch, so the next run resumes that family and
  location with `startAfter` (`startAfterDate` for conversations, whose token
  is the `lastMessageDate` of the last conversation read). An empty
  `last_seen_id` means that family and location starts from its first page.
  The cursor only moves forward through the families. When the pass finishes
  the cursor is `nil` and the next run starts a new pass: the API has no
  "updated since" filter, and Signal ids are stable, so a record seen again
  does not duplicate. A cursor that cannot be read starts a new pass.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :go_high_level,
    display_name: "GoHighLevel",
    auth_scheme: :token,
    required_keys: [:location_ids],
    credential_keys: [],
    token_key: :api_token

  alias OptimalEngine.Connectors.HTTP

  @base_url "https://services.leadconnectorhq.com"
  @api_version "2021-07-28"
  @page_size 100
  @max_pages 20
  @families [:contacts, :conversations, :opportunities]
  @email ~r/[^\s<>",;:]+@[^\s<>",;:]+\.[A-Za-z]{2,}/
  @epoch ~U[1970-01-01 00:00:00Z]

  @impl true
  def init(config) do
    flat = flatten_credentials(config)

    with :ok <- require_keys(flat, required_config_keys()),
         {:ok, location_ids} <- location_ids(flat),
         {:ok, token} <- token(flat) do
      {:ok,
       %{
         token: token,
         location_ids: location_ids,
         max_pages: max_pages(pick(flat, :max_pages)),
         currency: currency_code(pick(flat, :currency))
       }}
    end
  end

  @impl true
  def sync(state, cursor) do
    state.location_ids
    |> steps(parse_cursor(cursor))
    |> walk(%{signals: [], pages_left: state.max_pages}, state)
  end

  @impl true
  def transform(%{"_family" => family, "id" => id} = raw) when is_binary(id) and id != "" do
    case family do
      "contact" -> {:ok, contact_signal(raw)}
      "conversation" -> {:ok, conversation_signal(raw)}
      "opportunity" -> {:ok, opportunity_signal(raw)}
      _ -> {:error, :unrecognised_payload}
    end
  end

  def transform(_raw), do: {:error, :unrecognised_payload}

  # ---- init -------------------------------------------------------------------

  defp location_ids(flat) do
    ids =
      flat
      |> pick(:location_ids)
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    if ids == [], do: {:error, {:missing_config, [:location_ids]}}, else: {:ok, ids}
  end

  defp token(flat) do
    [:api_token, :agency_token]
    |> Enum.find_value(fn key ->
      case pick(flat, key) do
        # A token the credential broker issued is held opaque and kept so.
        %OptimalEngine.Connectors.AccessToken{} = token -> token
        token when is_binary(token) -> if String.trim(token) != "", do: String.trim(token)
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, {:missing_credentials, [:api_token]}}
      token -> {:ok, token}
    end
  end

  defp max_pages(pages) when is_integer(pages) and pages > 0, do: pages
  defp max_pages(_), do: @max_pages

  defp currency_code(code) when is_binary(code) do
    if Regex.match?(~r/\A[A-Za-z]{3}\z/, code), do: String.downcase(code)
  end

  defp currency_code(_), do: nil

  # ---- the walk ---------------------------------------------------------------

  # The pass in order: every (family, location) pair, families outermost. A
  # cursor names where to resume, and only that first step carries its token.
  defp steps(locations, resume) do
    pairs = for family <- @families, location <- locations, do: {family, location}
    fresh = fn pairs -> Enum.map(pairs, fn {family, location} -> {family, location, nil} end) end

    with {family, location, token} <- resume,
         {_done, [{^family, ^location} | rest]} <-
           Enum.split_while(pairs, &(&1 != {family, location})) do
      [{family, location, token} | fresh.(rest)]
    else
      _ -> fresh.(pairs)
    end
  end

  defp walk([], acc, _state), do: finish(acc, nil)

  defp walk([{family, location, token} | rest], acc, state) do
    case walk_pages(family, location, token, acc, state) do
      {:done, acc} -> walk(rest, acc, state)
      {:more, acc, next} -> finish(acc, encode_cursor(family, location, next))
      {:error, _reason} = error -> error
    end
  end

  # Out of pages: stop here, and let the next run pick this step up from `token`.
  defp walk_pages(_family, _location, token, %{pages_left: 0} = acc, _state) do
    {:more, acc, token || ""}
  end

  defp walk_pages(family, location, token, acc, state) do
    case fetch_page(family, location, token, state) do
      {:ok, signals, next} ->
        acc = %{acc | signals: Enum.reverse(signals, acc.signals), pages_left: acc.pages_left - 1}

        # A token that does not move would only refetch the same page.
        if next && next != token,
          do: walk_pages(family, location, next, acc, state),
          else: {:done, acc}

      {:error, _reason} = error ->
        error
    end
  end

  defp finish(acc, cursor), do: {:ok, %{signals: Enum.reverse(acc.signals), cursor: cursor}}

  defp encode_cursor(family, location, token), do: "#{family}:#{location}:#{token}"

  defp parse_cursor(cursor) when is_binary(cursor) do
    with [name, location, token] <- String.split(cursor, ":", parts: 3),
         family when not is_nil(family) <- Enum.find(@families, &(Atom.to_string(&1) == name)),
         true <- location != "" do
      {family, location, if(token == "", do: nil, else: token)}
    else
      _ -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil

  # ---- pages ------------------------------------------------------------------

  defp fetch_page(:contacts, location, token, state) do
    url =
      "#{@base_url}/contacts/?locationId=#{enc(location)}&limit=#{@page_size}" <>
        after_param("startAfter", token)

    with {:ok, body} <- get(url, state) do
      records = records(body, "contacts")
      {:ok, signals(records, "contact", state), next_after(body, records)}
    end
  end

  defp fetch_page(:opportunities, location, token, state) do
    url =
      "#{@base_url}/opportunities/search?location_id=#{enc(location)}&limit=#{@page_size}" <>
        after_param("startAfter", token)

    with {:ok, body} <- get(url, state) do
      records = records(body, "opportunities")
      {:ok, signals(records, "opportunity", state), next_after(body, records)}
    end
  end

  # The search response names no next page, so the walk goes on from the last
  # conversation's date until a page comes back empty.
  defp fetch_page(:conversations, location, token, state) do
    url =
      "#{@base_url}/conversations/search?locationId=#{enc(location)}&limit=#{@page_size}" <>
        after_param("startAfterDate", token)

    with {:ok, body} <- get(url, state),
         records = records(body, "conversations"),
         {:ok, records} <- attach_messages(records, state) do
      {:ok, signals(records, "conversation", state), next_date(records)}
    end
  end

  defp after_param(_name, nil), do: ""
  defp after_param(name, token), do: "&#{name}=#{enc(token)}"

  # `nextPageUrl` is null on the last page even though `startAfterId` is still
  # set, so it is what says there is more.
  defp next_after(%{"meta" => %{"nextPageUrl" => next_url, "startAfterId" => id}}, [_ | _])
       when is_binary(next_url) and next_url != "" and is_binary(id) and id != "",
       do: id

  defp next_after(_body, _records), do: nil

  defp next_date([]), do: nil

  defp next_date(records) do
    case List.last(records)["lastMessageDate"] do
      nil -> nil
      date -> to_string(date)
    end
  end

  defp attach_messages(conversations, state) do
    conversations
    |> Enum.reduce_while({:ok, []}, fn conversation, {:ok, acc} ->
      case fetch_messages(conversation["id"], state) do
        {:ok, messages} ->
          {:cont, {:ok, [Map.put(conversation, "messages", messages) | acc]}}

        # The conversation is listed but its messages are not served (removed
        # since the listing, say). Keep it with its last message body. Any
        # other failure ends the run: it would only repeat on the next one.
        {:error, reason} = error ->
          if unreadable?(reason),
            do: {:cont, {:ok, [conversation | acc]}},
            else: {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_messages(conversation_id, state) do
    url = "#{@base_url}/conversations/#{enc(conversation_id)}/messages?limit=#{@page_size}"

    with {:ok, body} <- get(url, state) do
      {:ok, message_list(body)}
    end
  end

  defp unreadable?({:http, _status}), do: true
  defp unreadable?(:invalid_response), do: true
  defp unreadable?(_reason), do: false

  defp message_list(%{"messages" => %{"messages" => messages}}), do: list(messages)
  defp message_list(%{"messages" => messages}), do: list(messages)
  defp message_list(_body), do: []

  # ---- http -------------------------------------------------------------------

  defp get(url, state) do
    headers = [{"authorization", "Bearer #{state.token}"}, {"version", @api_version}]

    case HTTP.get_json(url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :invalid_response}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :auth_expired}
      {:ok, %{status: 429, headers: resp}} -> {:error, rate_limited(resp)}
      {:ok, %{status: status}} when status >= 500 -> {:error, :transient}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rate_limited(headers) do
    case HTTP.retry_after(headers) do
      nil -> :rate_limited
      ms -> {:rate_limited, ms}
    end
  end

  # ---- records ----------------------------------------------------------------

  defp records(body, key) do
    body[key]
    |> list()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["id"]) and &1["id"] != ""))
  end

  defp signals(records, family, state) do
    Enum.flat_map(records, fn record ->
      case transform(tag(record, family, state)) do
        {:ok, signal} -> [signal]
        {:error, _reason} -> []
      end
    end)
  end

  defp tag(record, "opportunity", %{currency: currency}) when is_binary(currency) do
    record
    |> Map.put_new("currency", currency)
    |> Map.put("_family", "opportunity")
  end

  defp tag(record, family, _state), do: Map.put(record, "_family", family)

  # ---- signals ----------------------------------------------------------------

  defp contact_signal(raw) do
    ext_id = raw["id"]
    email = text(raw["email"])
    phone = text(raw["phone"])
    name = [raw["firstName"], raw["lastName"]] |> Enum.map(&text/1) |> Enum.reject(&(&1 == ""))
    title = Enum.find([Enum.join(name, " "), email, phone, ext_id], &(&1 != ""))

    tags =
      raw["tags"] |> list() |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))

    content =
      [
        title,
        labelled("Email", email),
        labelled("Phone", phone),
        labelled("Tags", Enum.join(tags, ", ")),
        labelled("Location", text(raw["locationId"]))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Transform.new_signal(%{
      id: Transform.signal_id(:go_high_level, ext_id),
      title: String.slice(title, 0, 120),
      content: content,
      path: Transform.source_uri(:go_high_level, ext_id),
      genre: "contact",
      mode: :linguistic,
      entities: emails_in([email]),
      modified_at: Transform.parse_epoch(raw["dateUpdated"] || raw["dateAdded"])
    })
  end

  defp conversation_signal(raw) do
    ext_id = raw["id"]
    messages = raw["messages"] |> list() |> Enum.filter(&is_map/1)
    entities = emails_in([raw["email"] | message_addresses(messages)])

    name =
      Enum.find([text(raw["fullName"]), text(raw["contactName"])], &(&1 != "")) ||
        List.first(entities)

    Transform.new_signal(%{
      id: Transform.signal_id(:go_high_level, ext_id),
      title: if(name, do: "Conversation with #{name}", else: "Conversation #{ext_id}"),
      content: conversation_text(raw, messages),
      path: Transform.source_uri(:go_high_level, ext_id),
      genre: "message",
      mode: :linguistic,
      entities: entities,
      modified_at: Transform.parse_epoch(raw["lastMessageDate"], newest_message_at(messages))
    })
  end

  defp opportunity_signal(raw) do
    ext_id = raw["id"]
    name = Enum.find([text(raw["name"]), ext_id], &(&1 != ""))
    stage = Enum.find([text(raw["pipelineStageName"]), text(raw["pipelineStageId"])], &(&1 != ""))
    amount = amount_minor(raw["monetaryValue"])
    currency = currency_code(raw["currency"])
    status = text(raw["status"])
    contact_id = text(raw["contactId"])

    details =
      Enum.filter(
        [
          status != "" && "status #{status}",
          stage && "stage #{stage}",
          amount && "value #{format_minor(amount)}#{currency && " " <> currency}",
          contact_id != "" && "contact #{contact_id}"
        ],
        & &1
      )

    sentence =
      "Opportunity #{name}" <>
        if(details == [], do: ".", else: " - " <> Enum.join(details, ", ") <> ".")

    Transform.new_signal(%{
      id: Transform.signal_id(:go_high_level, ext_id),
      title: String.slice(name, 0, 120),
      content:
        [structured_line(amount, currency, stage), sentence]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n"),
      path: Transform.source_uri(:go_high_level, ext_id),
      genre: "opportunity",
      mode: :linguistic,
      entities: emails_in([get_in_contact_email(raw)]),
      modified_at: Transform.parse_epoch(raw["updatedAt"] || raw["createdAt"])
    })
  end

  # ---- helpers ----------------------------------------------------------------

  # SMS and email first: when a conversation has any of those bodies it is
  # those that are kept. A conversation with neither keeps whatever has a body.
  defp conversation_text(raw, messages) do
    texts =
      messages
      |> Enum.sort_by(&message_at/1, DateTime)
      |> Enum.map(&{&1, text(&1["body"])})
      |> Enum.reject(fn {_message, body} -> body == "" end)

    preferred = Enum.filter(texts, fn {message, _body} -> text_channel?(message["type"]) end)

    case Enum.map(if(preferred == [], do: texts, else: preferred), &elem(&1, 1)) do
      [] -> text(raw["lastMessageBody"])
      bodies -> Enum.join(bodies, "\n")
    end
  end

  defp text_channel?(type) when is_binary(type) do
    type = String.downcase(type)
    String.contains?(type, "sms") or String.contains?(type, "email")
  end

  defp text_channel?(_type), do: false

  defp message_at(message), do: Transform.parse_epoch(message["dateAdded"], @epoch)

  defp newest_message_at([]), do: nil
  defp newest_message_at(messages), do: messages |> Enum.map(&message_at/1) |> Enum.max(DateTime)

  # The contact is the sender of an inbound message and the recipient of an
  # outbound one; the other side of either is us.
  defp message_addresses(messages) do
    Enum.map(messages, fn message ->
      if message["direction"] == "inbound", do: message["from"], else: message["to"]
    end)
  end

  defp get_in_contact_email(%{"contact" => %{"email" => email}}), do: email
  defp get_in_contact_email(_raw), do: nil

  defp emails_in(values) do
    values
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn value -> @email |> Regex.scan(value) |> List.flatten() end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp amount_minor(value) when is_number(value) and value > 0, do: round(value * 100)

  defp amount_minor(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> amount_minor(number)
      _ -> nil
    end
  end

  defp amount_minor(_value), do: nil

  defp format_minor(amount) do
    "#{div(amount, 100)}.#{amount |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp structured_line(nil, _currency, _stage), do: nil

  defp structured_line(amount, currency, stage) do
    [{"amount_minor", amount}, {"currency", currency}, {"stage", stage_slug(stage)}]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map_join(" ", fn {label, value} -> "#{label}=#{value}" end)
  end

  defp stage_slug(nil), do: nil

  defp stage_slug(stage) do
    stage |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "_") |> String.trim("_")
  end

  defp labelled(_label, ""), do: nil
  defp labelled(label, value), do: "#{label}: #{value}"

  # Trimmed text of a scalar, "" for anything else. A body that is HTML (email)
  # is stripped to text; plain text keeps its line breaks.
  defp text(value) when is_binary(value) do
    if Regex.match?(~r/<[a-z!\/][^>]*>/i, value),
      do: Transform.strip_html(value),
      else: String.trim(value)
  end

  defp text(_value), do: ""

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
