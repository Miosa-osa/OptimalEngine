defmodule OptimalEngine.LogUrl do
  @moduledoc """
  A URL as a log line may name it: its scheme, host and port, and nothing else.

  The path, query, fragment and user info of a webhook or sync peer URL can
  hold its secret (Slack and Discord webhook URLs carry it in the path), so a
  log line never shows them. User info runs to the last `@` of the authority.
  An `@` after a `/` (ahead of the query) reads two ways: a password holding a
  `/` (`https://admin:12345/x@host`) or a path holding an `@` (a token, or the
  tenant id of a legacy Teams webhook URL). Either reading could show a secret
  as the host, so such a URL is unparsable. The host must be a DNS name or
  IPv4 address (letters, digits, dots and hyphens) or a bracketed IPv6
  address, followed by an optional port and then the end of the URL or a `/`,
  `?` or `#`. Anything else, a control character included, is named
  "an unparsable URL".
  """

  @unparsable "an unparsable URL"

  @doc """
  `scheme://host[:port]/...` for `url`, the port only when it is not the
  scheme's default, or "an unparsable URL".
  """
  @spec render(term()) :: String.t()
  def render(url) when is_binary(url) do
    case Regex.run(
           ~r/\A([A-Za-z][A-Za-z0-9+.-]*):\/\/(?![^\/?#\s]*+\/[^@?#\s]*+@)(?>(?:[^\/?#\s]*@)?)(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(?:[\/?#]|\z)/,
           url
         ) do
      [_whole, scheme, host | port] ->
        scheme = String.downcase(scheme)
        "#{scheme}://#{host}#{port(scheme, port)}/..."

      nil ->
        @unparsable
    end
  end

  def render(_url), do: @unparsable

  defp port(_scheme, []), do: ""

  defp port(scheme, [port]) do
    if String.to_integer(port) == URI.default_port(scheme), do: "", else: ":" <> port
  end
end
