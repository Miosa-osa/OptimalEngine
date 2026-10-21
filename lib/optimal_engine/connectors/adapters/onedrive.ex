defmodule OptimalEngine.Connectors.Adapters.OneDrive do
  @moduledoc """
  OneDrive / SharePoint connector -- files, documents, sites.

  ## Required config keys
    * `:tenant_id_ms`, `:drive_id`

  ## Credentials
    * `:client_id`, `:client_secret` (Azure AD app), or
    * an `:access_token`, given directly or issued by the credential broker
    (`credential_source: "broker"`); calls go through
    `OptimalEngine.Connectors.AccessToken`, which renews a brokered token
    before it expires and once after a `401`

  ## Cursor shape
  Microsoft Graph delta link (URL string). Initial sync: `nil`.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :onedrive,
    display_name: "OneDrive",
    auth_scheme: :oauth2,
    required_keys: [:tenant_id_ms, :drive_id],
    credential_keys: [:client_id, :client_secret],
    access_token: true

  alias OptimalEngine.Connectors.{AccessToken, TokenExchange}

  @graph_base "https://graph.microsoft.com/v1.0"
  @page_size 100

  @impl true
  def sync(state, cursor) do
    session(state, &acquire_token/1, fn token ->
      case cursor do
        nil -> full_sync(state, token)
        delta_link -> delta_sync(delta_link, token)
      end
    end)
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = raw["id"] || ""

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:onedrive, ext_id),
       title: raw["name"] || "Untitled",
       content: raw["content"] || "",
       path: Transform.source_uri(:onedrive, ext_id),
       genre: "file",
       modified_at: Transform.parse_iso8601(raw["lastModifiedDateTime"])
     })}
  end

  # ---- private ----------------------------------------------------------------

  defp acquire_token(state) do
    tenant_id = pick(state, :tenant_id_ms)
    url = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"

    TokenExchange.exchange(url,
      grant_type: "client_credentials",
      client_id: pick(state, :client_id),
      client_secret: pick(state, :client_secret),
      scope: "https://graph.microsoft.com/.default"
    )
  end

  defp full_sync(state, token) do
    drive_id = pick(state, :drive_id)
    url = "#{@graph_base}/drives/#{drive_id}/root/delta?$top=#{@page_size}"
    fetch_delta_page(url, [], token)
  end

  defp delta_sync(delta_link, token) do
    fetch_delta_page(delta_link, [], token)
  end

  # The token is sent to every link Graph hands back, so each must be Graph's.
  @graph_hosts ~w(graph.microsoft.com graph.microsoft.us dod-graph.microsoft.us
                  graph.microsoft.de microsoftgraph.chinacloudapi.cn)

  defp fetch_delta_page(url, acc, token) do
    if trusted_link?(url),
      do: pull_delta_page(url, acc, token),
      else: {:error, :untrusted_url}
  end

  defp trusted_link?("https://" <> _rest = url) do
    case URI.parse(url) do
      %URI{host: host, port: 443, userinfo: nil} when is_binary(host) ->
        String.downcase(host, :ascii) in @graph_hosts

      _other ->
        false
    end
  end

  defp trusted_link?(_url), do: false

  defp pull_delta_page(url, acc, token) do
    case AccessToken.get_json(token, url) do
      {:ok, %{status: 200, body: body}} ->
        items =
          (body["value"] || [])
          |> Enum.reject(fn item -> Map.has_key?(item, "deleted") end)

        signals =
          Enum.flat_map(items, fn item ->
            case transform(item) do
              {:ok, s} -> [s]
              _ -> []
            end
          end)

        all_signals = acc ++ signals

        cond do
          body["@odata.nextLink"] ->
            fetch_delta_page(body["@odata.nextLink"], all_signals, token)

          body["@odata.deltaLink"] ->
            {:ok, %{signals: all_signals, cursor: body["@odata.deltaLink"]}}

          true ->
            {:ok, %{signals: all_signals, cursor: url}}
        end

      {:ok, %{status: 401}} ->
        {:error, :auth_expired}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
