defmodule OptimalEngine.Viability.SignalEvents do
  @moduledoc """
  Events about Signals that the proxy metrics are computed from, recorded by
  the Engine itself or by the apps and agents that act on Signals.

  | Kind | Meaning | Feeds |
  | --- | --- | --- |
  | `acted` | First meaningful action on a Signal (`context_id`) | time to decode |
  | `rerouted` | A Signal was sent somewhere other than its first route | bounce rate |
  | `re_encoded` | A follow-up had to re-explain intent | re-encoding frequency |
  | `feedback_confirmed` | The receiver confirmed a Signal | feedback loop closure |
  | `genre_checked` | A pre-send check of a draft (`value` 1 fit, 0 mismatch) | genre recognition |
  | `produced` | The workspace sent a Signal (`genre`, `mode`) | requisite variety |
  | `outward` | A Signal from outside the org (`topic`) | System 4 |

  Events never block the write path they describe; a failed record is
  logged and dropped.
  """

  require Logger

  alias OptimalEngine.Store

  @kinds ~w(acted rerouted re_encoded feedback_confirmed genre_checked produced outward)
  @outward_topics ~w(market customers competitors technology risk regulation partners)

  @doc "The event kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The System 4 topics an outward Signal may carry."
  @spec outward_topics() :: [String.t()]
  def outward_topics, do: @outward_topics

  @doc """
  Records an event. `attrs` takes `workspace_id`, `kind`, and optionally
  `context_id`, `ref`, `value`, `genre`, `mode`, `topic`, `occurred_at`
  (ISO 8601) and `metadata`.
  """
  @spec record(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def record(tenant_id, attrs, actor \\ nil) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, workspace_id} <- required(attrs["workspace_id"] || attrs["workspace"]),
         {:ok, kind} <- kind(attrs["kind"]),
         :ok <- topic(kind, attrs["topic"]),
         {:ok, occurred_at} <- occurred_at(attrs["occurred_at"]) do
      event = %{
        id: "sev_" <> random_id(),
        workspace_id: workspace_id,
        kind: kind,
        context_id: attrs["context_id"],
        ref: attrs["ref"],
        value: number(attrs["value"]),
        genre: attrs["genre"],
        mode: attrs["mode"],
        topic: attrs["topic"],
        actor: actor,
        occurred_at: occurred_at,
        metadata: if(is_map(attrs["metadata"]), do: attrs["metadata"], else: %{})
      }

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO signal_events
            (id, tenant_id, workspace_id, kind, context_id, ref, value, genre, mode, topic, actor,
             occurred_at, metadata)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
          """,
          [
            event.id,
            tenant_id,
            workspace_id,
            kind,
            event.context_id,
            event.ref,
            event.value,
            event.genre,
            event.mode,
            event.topic,
            actor,
            occurred_at,
            Jason.encode!(event.metadata)
          ]
        )

      {:ok, event}
    end
  end

  @doc "Records an event and logs instead of failing when it cannot."
  @spec note(String.t(), map(), String.t() | nil) :: :ok
  def note(tenant_id, attrs, actor \\ nil) do
    case record(tenant_id, attrs, actor) do
      {:ok, _event} -> :ok
      {:error, reason} -> Logger.debug("[Viability] signal event not recorded: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("[Viability] signal event failed: #{Exception.message(error)}")
  end

  @doc "Recent events for workspaces, newest first. Options `:kind`, `:limit`."
  @spec list(String.t(), [String.t()], keyword()) :: [map()]
  def list(tenant_id, workspace_ids, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(1_000)
    placeholders = Enum.map_join(1..length(workspace_ids), ", ", &"?#{&1 + 1}")
    kind_index = length(workspace_ids) + 2

    {kind_sql, params} =
      case opts[:kind] do
        nil -> {"", []}
        kind -> {" AND kind = ?#{kind_index}", [kind]}
      end

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, workspace_id, kind, context_id, ref, value, genre, mode, topic, actor,
               occurred_at, metadata
        FROM signal_events
        WHERE tenant_id = ?1 AND workspace_id IN (#{placeholders})#{kind_sql}
        ORDER BY occurred_at DESC LIMIT #{limit}
        """,
        [tenant_id | workspace_ids] ++ params
      )

    Enum.map(rows, fn [id, ws, kind, context_id, ref, value, genre, mode, topic, actor, at, meta] ->
      %{
        id: id,
        workspace_id: ws,
        kind: kind,
        context_id: context_id,
        ref: ref,
        value: value,
        genre: genre,
        mode: mode,
        topic: topic,
        actor: actor,
        occurred_at: at,
        metadata: decode(meta)
      }
    end)
  end

  # ---------------------------------------------------------------------------

  defp required(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value), do: {:error, :workspace_required}

  defp kind(kind) when kind in @kinds, do: {:ok, kind}
  defp kind(_kind), do: {:error, :invalid_kind}

  defp topic("outward", topic) when topic in @outward_topics, do: :ok
  defp topic("outward", _topic), do: {:error, :invalid_topic}
  defp topic(_kind, _topic), do: :ok

  defp occurred_at(nil), do: {:ok, now()}

  defp occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      _ -> {:error, :invalid_occurred_at}
    end
  end

  defp occurred_at(_value), do: {:error, :invalid_occurred_at}

  defp number(value) when is_number(value), do: value * 1.0
  defp number(true), do: 1.0
  defp number(false), do: 0.0
  defp number(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp decode(nil), do: %{}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
