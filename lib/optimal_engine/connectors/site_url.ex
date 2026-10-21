defmodule OptimalEngine.Connectors.SiteUrl do
  @moduledoc """
  The site a Jira or Confluence connector sends its credentials to.

  Always `https`, with no user info, query or fragment. When the credential
  was issued by the broker (a held secret), the site must also be an Atlassian
  Cloud one, `<site>.atlassian.net` on port 443, so a connector's config cannot
  name another host for a platform-issued token to be sent to. A connector that
  carries its own credentials keeps working against a self-hosted site.
  """

  alias OptimalEngine.Connectors.AccessToken

  @cloud ~r/\A[a-z0-9][a-z0-9-]*\.atlassian\.net\z/

  @spec check(term(), term()) :: :ok | {:error, {:invalid_config, :site_url}}
  def check(url, token) when is_binary(url) do
    case {url, URI.parse(url)} do
      {"https://" <> _rest, %URI{host: host, port: port, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        if broker_issued?(token) and not cloud?(host, port),
          do: error(),
          else: :ok

      _other ->
        error()
    end
  end

  def check(_url, _token), do: error()

  defp broker_issued?(%AccessToken{}), do: true
  defp broker_issued?(_token), do: false

  defp cloud?(host, port), do: port == 443 and Regex.match?(@cloud, String.downcase(host, :ascii))

  defp error, do: {:error, {:invalid_config, :site_url}}
end
