defmodule OptimalEngine.ChatSession do
  @moduledoc """
  Commits a finished chat to the Engine in one retry-safe call.

  A chat client sends the whole transcript when a chat ends
  (`POST /api/sessions/commit`). The Engine keeps it the way the session
  lifecycle asks (`docs/reference/session-lifecycle.md`): a conversation
  summary is source evidence, never a Fact.

  * The transcript becomes a Source Package, written first.
  * The session becomes an Episode (`kind: "session"`) in the chat's
    workspace, the Engine's episodic memory record, with provenance back to
    the Source Package.
  * A context at `optimal://<workspace>/sessions/<id>` carries the summary and
    the transcript, so later chats, CLI agents and scheduled runs find the
    chat with search and read it by address.
  * What the chat learned (decisions, tasks, corrections, facts) becomes
    pending Claims in the workspace's review queue: the Engine's extraction
    plus anything the client proposes. A reviewer accepts (promotes, with
    edited text when needed) or rejects each one.
  * The session record (`sessions` table) is written last. The same
    `correlation_id` in the same workspace returns the stored result; a
    different transcript under it is `{:error, {:idempotency_key_conflict,
    session_id}}`. Commits of one chat are serialized, so concurrent retries
    store it once.

  Limits per call (`config :optimal_engine, :chat_sessions`): `max_messages`
  (default 1,000) and `max_bytes` of text (default 1,000,000), plus 50 learned
  items.
  """

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Context
  alias OptimalEngine.Insight.MemoryExtractor
  alias OptimalEngine.MemoryCore.{ClaimExtractor, DerivationLedgerEntry, Episode, ID, SourcePackage}
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.{Session, Store}

  @roles ~w(user assistant system tool)
  @categories ~w(fact decision task correction preference relationship context skill)
  @episode_kind "session"
  @record_kind "chat"
  @extractor "system:chat-session"
  @parser "optimal_engine.chat_session"
  @max_learned 50
  @max_title 200
  @max_source 100
  @max_summary 4_000
  @max_correlation_id 200

  @type normalized :: %{
          correlation_id: String.t(),
          title: String.t() | nil,
          source: String.t(),
          summary: String.t() | nil,
          messages: [map()],
          learned: [map()]
        }

  @doc "The roles a message may have."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The categories of a learned item."
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc "The per-call limits in force."
  @spec limits() :: %{
          max_messages: pos_integer(),
          max_bytes: pos_integer(),
          max_learned: pos_integer()
        }
  def limits do
    config = Application.get_env(:optimal_engine, :chat_sessions, [])

    %{
      max_messages: Keyword.get(config, :max_messages, 1_000),
      max_bytes: Keyword.get(config, :max_bytes, 1_000_000),
      max_learned: @max_learned
    }
  end

  @doc """
  Validates a commit request body (string keys) and returns the normalized
  commit. Errors: `{:error, {:invalid, detail}}` for a malformed body and
  `{:error, {:too_large, %{"limit", "max", "got"}}}` past a limit.
  """
  @spec normalize(map()) ::
          {:ok, normalized()} | {:error, {:invalid, String.t()} | {:too_large, map()}}
  def normalize(params) when is_map(params) do
    limits = limits()

    with {:ok, correlation_id} <- correlation_id(params["correlation_id"]),
         :ok <- count_limit("messages", params["messages"], limits.max_messages),
         :ok <- count_limit("learned", params["learned"], limits.max_learned),
         {:ok, messages} <- messages(params["messages"]),
         {:ok, learned} <- learned(params["learned"]),
         {:ok, title} <- optional_text(params["title"], "title", @max_title),
         {:ok, source} <- optional_text(params["source"], "source", @max_source),
         {:ok, summary} <- optional_text(params["summary"], "summary", @max_summary),
         :ok <- byte_limit(messages, learned, [title, summary], limits.max_bytes) do
      {:ok,
       %{
         correlation_id: correlation_id,
         title: title,
         source: source || "chat",
         summary: summary,
         messages: messages,
         learned: learned
       }}
    end
  end

  def normalize(_params), do: invalid("body must be a JSON object")

  @doc """
  Commits a normalized chat in `workspace_id` as `actor_id`. Returns
  `{:ok, result, :created}` the first time and `{:ok, result, :replayed}`
  for a retry of the same transcript.
  """
  @spec commit(String.t(), String.t(), String.t(), normalized()) ::
          {:ok, map(), :created | :replayed}
          | {:error, {:idempotency_key_conflict, String.t()} | term()}
  def commit(tenant_id, workspace_id, actor_id, %{correlation_id: correlation_id} = chat) do
    session_id = session_id(tenant_id, workspace_id, correlation_id)
    payload_sha256 = CanonicalJSON.hash(fingerprint(chat))

    # One commit of a chat at a time: a retry racing the first attempt waits,
    # then replays it.
    :global.trans(
      {{__MODULE__, session_id}, self()},
      fn ->
        case fetch(tenant_id, workspace_id, session_id) do
          {:ok, row} ->
            if row.metadata["payload_sha256"] == payload_sha256,
              do: {:ok, result(row), :replayed},
              else: {:error, {:idempotency_key_conflict, session_id}}

          {:error, :not_found} ->
            store(tenant_id, workspace_id, actor_id, session_id, payload_sha256, chat)

          {:error, reason} ->
            {:error, reason}
        end
      end,
      [node()],
      :infinity
    )
  end

  @doc """
  Lists the chat sessions of a workspace, newest first. Options: `:limit`
  (default 50), `:offset`, `:correlation_id`.
  """
  @spec list(String.t(), String.t(), keyword()) ::
          {:ok, %{sessions: [map()], total: non_neg_integer()}} | {:error, term()}
  def list(tenant_id, workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    correlation_id = Keyword.get(opts, :correlation_id)

    {filter, params} =
      if is_binary(correlation_id) and correlation_id != "",
        do: {" AND json_extract(metadata, '$.correlation_id') = ?3", [correlation_id]},
        else: {"", []}

    where =
      "WHERE tenant_id = ?1 AND workspace_id = ?2 AND json_extract(metadata, '$.kind') = '#{@record_kind}'" <>
        filter

    base = [tenant_id, workspace_id] ++ params
    n = length(base)

    with {:ok, [[total]]} <- Store.raw_query("SELECT COUNT(*) FROM sessions #{where}", base),
         {:ok, rows} <-
           Store.raw_query(
             select_sql() <>
               " #{where} ORDER BY committed_at DESC, id LIMIT ?#{n + 1} OFFSET ?#{n + 2}",
             base ++ [limit, offset]
           ) do
      {:ok, %{sessions: Enum.map(rows, &(&1 |> to_row() |> summary_of())), total: total}}
    end
  end

  @doc """
  One chat session of the workspace, with the live review status of what it
  learned. `include_transcript: true` adds the transcript.
  """
  @spec get(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(tenant_id, workspace_id, session_id, opts \\ []) do
    with {:ok, row} <- fetch(tenant_id, workspace_id, session_id) do
      result = result(row)

      if Keyword.get(opts, :include_transcript, false),
        do: {:ok, Map.put(result, :transcript, transcript_of(row))},
        else: {:ok, result}
    end
  end

  # ---------------------------------------------------------------------------
  # Storing a commit
  # ---------------------------------------------------------------------------

  defp store(tenant_id, workspace_id, actor_id, session_id, payload_sha256, chat) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    committed_at = DateTime.to_iso8601(now)
    started_at = chat.messages |> List.first() |> Map.get("at") || committed_at
    ended_at = chat.messages |> List.last() |> Map.get("at") || committed_at
    uri = "optimal://#{workspace_id}/sessions/#{session_id}"
    episode_id = ID.content_id("epi", [tenant_id, ":", workspace_id, ":session:", session_id])
    transcript = render(session_id, chat, started_at)

    source_package =
      SourcePackage.from_text(transcript,
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        source_type: "chat_session",
        source_class: "text",
        source_system: chat.source,
        source_uri: uri,
        source_time: started_at,
        trust_label: "unreviewed",
        created_by: actor_id,
        metadata: %{
          "session_id" => session_id,
          "correlation_id" => chat.correlation_id,
          "title" => chat.title,
          "message_count" => length(chat.messages)
        }
      )

    {summary, summary_source} =
      case chat.summary do
        nil -> {Session.summarize(Enum.map(chat.messages, &session_message/1)), "generated"}
        given -> {given, "client"}
      end

    with :ok <- MemoryCoreStore.insert_source_package(source_package),
         {:ok, learned} <- propose(source_package, session_id, actor_id, chat) do
      claim_ids = Enum.map(learned, & &1["claim_id"])

      metadata = %{
        "kind" => @record_kind,
        "correlation_id" => chat.correlation_id,
        "title" => chat.title,
        "source" => chat.source,
        "actor_id" => actor_id,
        "payload_sha256" => payload_sha256,
        "episode_id" => episode_id,
        "source_package_id" => source_package.id,
        "uri" => uri,
        "ended_at" => ended_at,
        "summary_source" => summary_source,
        "learned" => learned
      }

      context = %Context{
        id: session_id,
        uri: uri,
        type: :memory,
        title: chat.title || "Chat session",
        content: summary <> "\n\n" <> transcript,
        l0_abstract: "SESSION | #{chat.source} | #{chat.title || summary}",
        l1_overview: summary,
        node: "inbox",
        sn_ratio: 0.6,
        created_at: now,
        modified_at: now,
        workspace_id: workspace_id,
        tenant_id: tenant_id,
        metadata: %{
          "kind" => "chat_session",
          "session_id" => session_id,
          "correlation_id" => chat.correlation_id,
          "episode_id" => episode_id,
          "source_package_id" => source_package.id
        }
      }

      {:ok, episode} =
        Episode.new(%{
          id: episode_id,
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          kind: @episode_kind,
          occurred_at: ended_at,
          summary: summary,
          provenance: %{
            "session_id" => session_id,
            "source_package_id" => source_package.id,
            "context_id" => session_id,
            "correlation_id" => chat.correlation_id,
            "claim_ids" => claim_ids
          },
          metadata: %{
            "title" => chat.title,
            "source" => chat.source,
            "actor_id" => actor_id,
            "message_count" => length(chat.messages),
            "started_at" => started_at,
            "ended_at" => ended_at
          }
        })

      source_ref = DerivationLedgerEntry.object_ref("source_package", source_package.id)

      ledger =
        DerivationLedgerEntry.new(
          "chat_session.commit",
          "source_package_to_episode",
          [source_ref],
          [
            DerivationLedgerEntry.object_ref("episode", episode_id),
            DerivationLedgerEntry.object_ref("context", session_id)
          ] ++ Enum.map(claim_ids, &DerivationLedgerEntry.object_ref("claim", &1)),
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          source_package_links: [source_ref],
          evidence_links: [source_ref],
          actor_id: actor_id,
          parser_id: @parser,
          metadata: %{session_id: session_id, correlation_id: chat.correlation_id}
        )

      with :ok <- Store.insert_context(context),
           :ok <- MemoryCoreStore.insert_episode(episode),
           :ok <- MemoryCoreStore.insert_derivation_entry(ledger),
           :ok <-
             insert_record(
               [
                 session_id,
                 tenant_id,
                 workspace_id,
                 started_at,
                 committed_at,
                 summary,
                 length(chat.messages)
               ],
               metadata
             ),
           {:ok, row} <- fetch(tenant_id, workspace_id, session_id) do
        {:ok, result(row), :created}
      end
    end
  end

  # The session record is the commit marker: written last, so a commit that
  # failed part way is redone in full (every row it wrote has a stable id).
  defp insert_record(values, metadata) do
    Store.raw_execute(
      """
      INSERT INTO sessions (id, tenant_id, workspace_id, started_at, committed_at, summary,
                            message_count, metadata)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      values ++ [Jason.encode!(metadata)]
    )
  end

  # Client proposals first (they carry owner and due date), then what the
  # Engine extracted; the same text is proposed once.
  defp propose(source_package, session_id, actor_id, chat) do
    extracted =
      chat.messages
      |> Enum.filter(&(&1["role"] in ["user", "assistant"]))
      |> Enum.map_join("\n", & &1["content"])
      |> MemoryExtractor.extract(llm: llm_extraction?())
      |> elem(1)
      |> Enum.map(fn memory ->
        %{
          "content" => memory.content,
          "category" => to_string(memory.category),
          "origin" => "engine",
          "confidence" => memory.confidence
        }
      end)

    chat.learned
    |> Enum.map(&Map.put(&1, "origin", "client"))
    |> Kernel.++(extracted)
    |> Enum.uniq_by(&(&1["content"] |> String.trim() |> String.downcase()))
    |> Enum.take(@max_learned)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case propose_one(source_package, session_id, actor_id, chat, item) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  # What a client proposes is evaluated by its principal; what the Engine
  # extracts is evaluated by the commit path, so the person who submitted the
  # chat can review it (a reviewer may not accept a claim they evaluated).
  defp propose_one(source_package, session_id, actor_id, chat, item) do
    evaluator = if item["origin"] == "client", do: actor_id, else: @extractor

    metadata =
      item
      |> Map.take(["origin", "category", "owner", "due", "confidence"])
      |> Map.merge(%{"session_id" => session_id, "correlation_id" => chat.correlation_id})

    case ClaimExtractor.extract_from_source(source_package,
           claim_text: item["content"],
           claim_type: item["category"],
           actor_id: actor_id,
           extracted_by: evaluator,
           parser_id: @parser,
           metadata: metadata
         ) do
      {:ok, claim} ->
        {:ok,
         item
         |> Map.take(["content", "category", "origin", "owner", "due"])
         |> Map.put("claim_id", claim.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp select_sql do
    """
    SELECT id, tenant_id, workspace_id, started_at, committed_at, summary, message_count,
           metadata
    FROM sessions
    """
  end

  defp fetch(tenant_id, workspace_id, session_id) do
    case Store.raw_query(
           select_sql() <>
             " WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3 AND json_extract(metadata, '$.kind') = ?4",
           [session_id, tenant_id, workspace_id, @record_kind]
         ) do
      {:ok, [row]} -> {:ok, to_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_row([id, tenant_id, workspace_id, started_at, committed_at, summary, count, metadata]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      started_at: started_at,
      committed_at: committed_at,
      summary: summary,
      message_count: count,
      metadata: Jason.decode!(metadata || "{}")
    }
  end

  defp result(row) do
    meta = row.metadata
    statuses = claim_statuses(row)

    %{
      session_id: row.id,
      uri: meta["uri"],
      tenant_id: row.tenant_id,
      workspace_id: row.workspace_id,
      correlation_id: meta["correlation_id"],
      title: meta["title"],
      source: meta["source"],
      summary: row.summary,
      summary_source: meta["summary_source"],
      message_count: row.message_count,
      started_at: row.started_at,
      ended_at: meta["ended_at"],
      committed_at: row.committed_at,
      actor_id: meta["actor_id"],
      episode: %{
        id: meta["episode_id"],
        kind: @episode_kind,
        uri: "optimal://#{row.workspace_id}/episodes/#{meta["episode_id"]}"
      },
      source_package_id: meta["source_package_id"],
      stored: %{
        episodes: meta["episode_id"],
        sessions: row.id,
        contexts: row.id,
        source_packages: meta["source_package_id"]
      },
      learned:
        Enum.map(meta["learned"] || [], fn item ->
          {status, review_status} = Map.get(statuses, item["claim_id"], {nil, nil})

          item
          |> Map.put("uri", "optimal://#{row.workspace_id}/memory-core/claims/#{item["claim_id"]}")
          |> Map.put("status", status)
          |> Map.put("review_status", review_status)
        end)
    }
  end

  defp summary_of(row) do
    meta = row.metadata

    %{
      session_id: row.id,
      uri: meta["uri"],
      title: meta["title"],
      summary: row.summary,
      correlation_id: meta["correlation_id"],
      source: meta["source"],
      actor_id: meta["actor_id"],
      message_count: row.message_count,
      started_at: row.started_at,
      ended_at: meta["ended_at"],
      committed_at: row.committed_at,
      episode_id: meta["episode_id"],
      learned_count: length(meta["learned"] || [])
    }
  end

  # The review state of each learned claim, read now: accepting or rejecting
  # one in the review queue shows here.
  defp claim_statuses(row) do
    ids = Enum.map(row.metadata["learned"] || [], & &1["claim_id"])

    if ids == [] do
      %{}
    else
      placeholders = Enum.map_join(3..(length(ids) + 2), ", ", &"?#{&1}")

      case Store.raw_query(
             "SELECT id, lifecycle_state, review_status FROM claims WHERE tenant_id = ?1 AND workspace_id = ?2 AND id IN (#{placeholders})",
             [row.tenant_id, row.workspace_id | ids]
           ) do
        {:ok, rows} -> Map.new(rows, fn [id, state, review] -> {id, {state, review}} end)
        _ -> %{}
      end
    end
  end

  defp transcript_of(row) do
    case Store.raw_query(
           "SELECT raw_text FROM source_packages WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3",
           [row.metadata["source_package_id"], row.tenant_id, row.workspace_id]
         ) do
      {:ok, [[text]]} -> text
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Shape
  # ---------------------------------------------------------------------------

  @doc "The session id of a chat: stable for a tenant, workspace and correlation id."
  @spec session_id(String.t(), String.t(), String.t()) :: String.t()
  def session_id(tenant_id, workspace_id, correlation_id),
    do: ID.content_id("ses", [tenant_id, ":", workspace_id, ":", correlation_id])

  defp fingerprint(chat) do
    %{
      "title" => chat.title,
      "source" => chat.source,
      "summary" => chat.summary,
      "messages" => chat.messages,
      "learned" => chat.learned
    }
  end

  defp render(session_id, chat, started_at) do
    header =
      "# #{chat.title || "Chat session"}\n> Session: #{session_id}\n> Started: #{started_at}\n"

    body =
      Enum.map_join(chat.messages, "\n\n", fn message ->
        "**#{String.upcase(message["role"])}:** #{message["content"]}"
      end)

    header <> "\n" <> body
  end

  @role_atoms %{"user" => :user, "assistant" => :assistant, "system" => :system, "tool" => :tool}

  defp session_message(message),
    do: %{role: Map.fetch!(@role_atoms, message["role"]), content: message["content"]}

  defp llm_extraction? do
    :optimal_engine |> Application.get_env(:session, []) |> Keyword.get(:llm_extraction, true)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp correlation_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> invalid("correlation_id is required")
      String.length(trimmed) > @max_correlation_id -> invalid("correlation_id is too long")
      true -> {:ok, trimmed}
    end
  end

  defp correlation_id(_value), do: invalid("correlation_id is required")

  defp count_limit(limit, list, max) when is_list(list) and length(list) > max,
    do: {:error, {:too_large, %{"limit" => limit, "max" => max, "got" => length(list)}}}

  defp count_limit(_limit, _list, _max), do: :ok

  defp byte_limit(messages, learned, texts, max) do
    got =
      Enum.sum(Enum.map(messages, &byte_size(&1["content"]))) +
        Enum.sum(Enum.map(learned, &byte_size(&1["content"]))) +
        Enum.sum(Enum.map(texts, &byte_size(&1 || "")))

    if got > max,
      do: {:error, {:too_large, %{"limit" => "bytes", "max" => max, "got" => got}}},
      else: :ok
  end

  defp messages([_ | _] = list) do
    list
    |> Enum.with_index()
    |> collect(fn {message, index} -> message(message, "messages[#{index}]") end)
  end

  defp messages(_value), do: invalid("messages must be a non-empty list")

  defp message(%{} = message, at) do
    role = message["role"]
    content = message["content"]

    cond do
      role not in @roles ->
        invalid("#{at}.role must be one of #{Enum.join(@roles, ", ")}")

      not (is_binary(content) and String.trim(content) != "") ->
        invalid("#{at}.content must be a non-empty string")

      true ->
        with {:ok, time} <- timestamp(message["at"], "#{at}.at") do
          {:ok, %{"role" => role, "content" => content, "at" => time}}
        end
    end
  end

  defp message(_message, at), do: invalid("#{at} must be an object")

  defp learned(nil), do: {:ok, []}

  defp learned(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> collect(fn {item, index} -> learned_item(item, "learned[#{index}]") end)
  end

  defp learned(_value), do: invalid("learned must be a list")

  defp learned_item(%{} = item, at) do
    content = item["content"]
    category = item["category"] || "fact"

    with true <- (is_binary(content) and String.trim(content) != "") || {:content, at},
         true <- category in @categories || {:category, at},
         {:ok, owner} <- optional_text(item["owner"], "#{at}.owner", @max_title),
         {:ok, due} <- optional_text(item["due"], "#{at}.due", @max_title) do
      {:ok,
       %{"content" => String.trim(content), "category" => category}
       |> maybe_put("owner", owner)
       |> maybe_put("due", due)}
    else
      {:content, at} -> invalid("#{at}.content must be a non-empty string")
      {:category, at} -> invalid("#{at}.category must be one of #{Enum.join(@categories, ", ")}")
      error -> error
    end
  end

  defp learned_item(_item, at), do: invalid("#{at} must be an object")

  defp optional_text(nil, _field, _max), do: {:ok, nil}

  defp optional_text(value, _field, max) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> {:ok, String.slice(text, 0, max)}
    end
  end

  defp optional_text(_value, field, _max), do: invalid("#{field} must be a string")

  defp timestamp(nil, _field), do: {:ok, nil}

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      _ -> invalid("#{field} must be an ISO 8601 date-time")
    end
  end

  defp timestamp(_value, field), do: invalid("#{field} must be an ISO 8601 date-time")

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp invalid(detail), do: {:error, {:invalid, detail}}
end
