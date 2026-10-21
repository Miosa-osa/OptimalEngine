defmodule OptimalEngine.Federation do
  @moduledoc """
  The org-wide view: one search across this Engine's workspace sections and
  the separate workspace Engines that share upward.

  Local sections take part when their share-up policy is `read`
  (`OptimalEngine.Scope`) and the caller may see them. Remote workspace
  Engines are registered as peers with a URL, a workspace id, and an API
  key scoped to that workspace (encrypted at rest with `CONNECTOR_KEY`, the
  same envelope as connector credentials); a peer takes part when its
  share-up policy is `read`. Every result names its source workspace and
  Engine; a peer that cannot be reached is reported, never silently dropped.

  Nothing is copied: a workspace Engine's data stays in that Engine and is
  only queried.
  """

  alias OptimalEngine.Connectors.{Credential, HTTP}
  alias OptimalEngine.Retrieval.AsOf
  alias OptimalEngine.{Scope, Store}

  @timeout 4_000

  @doc """
  Registers a peer workspace Engine. Attrs: `workspace_id`, `url`, `api_key`,
  `share_up` (`read` or `none`, default `none`).
  """
  @spec add_peer(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def add_peer(tenant_id, attrs, added_by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    share_up = attrs["share_up"] || "none"

    cond do
      not (is_binary(attrs["workspace_id"]) and attrs["workspace_id"] != "") ->
        {:error, :workspace_id_required}

      not (is_binary(attrs["url"]) and String.match?(attrs["url"], ~r{\Ahttps?://})) ->
        {:error, :invalid_url}

      not is_binary(attrs["api_key"]) ->
        {:error, :api_key_required}

      share_up not in ["read", "none"] ->
        {:error, :invalid_share_up}

      true ->
        store_peer(tenant_id, attrs, share_up, added_by)
    end
  end

  @doc "Peers in the tenant, without their keys."
  @spec peers(String.t()) :: [map()]
  def peers(tenant_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT workspace_id, url, share_up, added_by, created_at FROM federation_peers WHERE tenant_id = ?1 ORDER BY workspace_id",
        [tenant_id]
      )

    Enum.map(rows, fn [workspace_id, url, share_up, by, at] ->
      %{workspace_id: workspace_id, url: url, share_up: share_up, added_by: by, created_at: at}
    end)
  end

  @doc "Removes a peer."
  @spec remove_peer(String.t(), String.t()) :: :ok
  def remove_peer(tenant_id, workspace_id) do
    {:ok, _} =
      Store.raw_query("DELETE FROM federation_peers WHERE tenant_id = ?1 AND workspace_id = ?2", [
        tenant_id,
        workspace_id
      ])

    :ok
  end

  @doc """
  Searches every sharing section the caller may see (`allowed`: list of
  workspace ids, nil for all) plus sharing peers. Returns results with
  `source_workspace_id` and `source_engine`, and per-source status.

  `:as_of` (an ISO 8601 instant or `DateTime`, see `OptimalEngine.Retrieval.AsOf`)
  is the instant every source measures freshness against, local and peer alike;
  one that is not valid answers `{:error, {:invalid_as_of, value}}`.
  """
  @spec search(String.t(), String.t(), keyword()) :: map() | {:error, AsOf.error()}
  def search(tenant_id, query, opts \\ []) do
    with {:ok, opts} <- AsOf.put_if_given(opts) do
      do_search(tenant_id, query, opts)
    end
  end

  defp do_search(tenant_id, query, opts) do
    allowed = opts[:allowed]
    as_of = opts[:as_of]
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)

    local_sources = Scope.sharing_workspaces(tenant_id, allowed)
    remote_sources = sharing_peers(tenant_id, allowed)

    labels =
      Enum.map(local_sources, &{&1.id, "local"}) ++
        Enum.map(remote_sources, &{&1.workspace_id, &1.url})

    tasks =
      Enum.map(local_sources, fn workspace ->
        Task.async(fn ->
          {workspace.id, "local", local_search(tenant_id, workspace.id, query, limit, as_of)}
        end)
      end) ++
        Enum.map(remote_sources, fn peer ->
          Task.async(fn ->
            {peer.workspace_id, peer.url, remote_search(peer, query, limit, as_of)}
          end)
        end)

    # A slow source is reported as timed out instead of failing the search.
    outcomes =
      tasks
      |> Task.yield_many(@timeout + 1_000)
      |> Enum.zip(labels)
      |> Enum.map(fn
        {{_task, {:ok, outcome}}, _label} ->
          outcome

        {{task, _timeout_or_exit}, {workspace_id, engine}} ->
          Task.shutdown(task, :brutal_kill)
          {workspace_id, engine, {:error, :timeout}}
      end)

    results =
      outcomes
      |> Enum.flat_map(fn
        {workspace_id, engine, {:ok, hits}} ->
          Enum.map(
            hits,
            &Map.merge(&1, %{"source_workspace_id" => workspace_id, "source_engine" => engine})
          )

        _ ->
          []
      end)
      |> Enum.sort_by(&merge_key/1)
      |> Enum.take(limit)

    %{
      query: query,
      results: results,
      sources:
        Enum.map(outcomes, fn
          {workspace_id, engine, {:ok, hits}} ->
            %{workspace_id: workspace_id, engine: engine, status: "ok", hits: length(hits)}

          {workspace_id, engine, {:error, reason}} ->
            %{
              workspace_id: workspace_id,
              engine: engine,
              status: "unavailable",
              reason: inspect(reason)
            }
        end)
    }
  end

  # ---------------------------------------------------------------------------

  # Best score first; a tie goes by uri, id, then the workspace it came from, so
  # the merged list is the same on every call. Remote hits carry only the score
  # rounded for display, which is the most a peer's API gives.
  defp merge_key(hit) do
    {0 - (hit["score"] || 0), hit["uri"] || "", hit["id"] || "", hit["source_workspace_id"] || ""}
  end

  defp local_search(tenant_id, workspace_id, query, limit, as_of) do
    search_opts =
      [limit: limit, workspace_id: workspace_id, tenant_id: tenant_id]
      |> put_as_of(as_of)

    case OptimalEngine.search(query, search_opts) do
      {:ok, hits} ->
        {:ok,
         Enum.map(hits, fn hit ->
           %{
             "id" => Map.get(hit, :id),
             "title" => Map.get(hit, :title),
             "uri" => Map.get(hit, :uri),
             "l0_abstract" => Map.get(hit, :l0_abstract),
             "score" => Map.get(hit, :score)
           }
         end)}

      error ->
        {:error, error}
    end
  end

  defp remote_search(peer, query, limit, as_of) do
    with {:ok, key} <- peer_key(peer) do
      params = %{"q" => query, "workspace" => peer.workspace_id, "limit" => limit}
      params = if as_of, do: Map.put(params, "as_of", DateTime.to_iso8601(as_of)), else: params
      url = peer.url <> "/api/search?" <> URI.encode_query(params)

      case HTTP.get_json(url, headers: [{"authorization", "Bearer " <> key}], timeout: @timeout) do
        {:ok, %{status: 200, body: %{"results" => hits}}} when is_list(hits) ->
          {:ok, Enum.map(hits, &Map.take(&1, ["id", "title", "uri", "l0_abstract", "score"]))}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp put_as_of(opts, nil), do: opts
  defp put_as_of(opts, as_of), do: Keyword.put(opts, :as_of, as_of)

  defp sharing_peers(tenant_id, allowed) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT workspace_id, url, credential FROM federation_peers WHERE tenant_id = ?1 AND share_up = 'read'",
        [tenant_id]
      )

    for [workspace_id, url, credential] <- rows, is_nil(allowed) or workspace_id in allowed do
      %{workspace_id: workspace_id, url: String.trim_trailing(url, "/"), credential: credential}
    end
  end

  defp peer_key(%{credential: envelope}) do
    case Credential.decrypt(envelope) do
      {:ok, %{"api_key" => key}} -> {:ok, key}
      _ -> {:error, :peer_credential_unreadable}
    end
  end

  defp store_peer(tenant_id, attrs, share_up, added_by) do
    case Credential.encrypt(%{"api_key" => attrs["api_key"]}) do
      {:ok, envelope} ->
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO federation_peers (tenant_id, workspace_id, url, credential, share_up, added_by)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(tenant_id, workspace_id) DO UPDATE SET
              url = excluded.url, credential = excluded.credential, share_up = excluded.share_up,
              added_by = excluded.added_by
            """,
            [tenant_id, attrs["workspace_id"], attrs["url"], envelope, share_up, added_by]
          )

        _ =
          OptimalEngine.Authority.Evidence.append(tenant_id, "settings.changed", %{
            workspace_id: attrs["workspace_id"],
            detail: %{"federation_peer" => attrs["url"], "share_up" => share_up, "by" => added_by}
          })

        {:ok, %{workspace_id: attrs["workspace_id"], url: attrs["url"], share_up: share_up}}

      {:error, _} ->
        {:error, :connector_key_missing}
    end
  end
end
