defmodule OptimalEngine.LogUrlTest do
  @moduledoc """
  The form a log line gives a URL: scheme, host and port, never the path,
  query, fragment or user info, and nothing for a URL it cannot read.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.LogUrl

  test "keeps the scheme, host and a port that is not the default" do
    for {url, logged} <- [
          {"https://hooks.example/services/T0/B0/secret-path", "https://hooks.example/..."},
          {"https://user:pw@chat.example/api/webhooks/1/x", "https://chat.example/..."},
          {"https://user:p@ss-w0rd@b.example/y", "https://b.example/..."},
          {"http://127.0.0.1:4321/hook?token=x#frag", "http://127.0.0.1:4321/..."},
          {"http://[::1]:4000/x", "http://[::1]:4000/..."},
          {"HTTPS://Host.Example:443/x", "https://Host.Example/..."},
          {"https://host.example", "https://host.example/..."},
          {"https://host.example?query=x", "https://host.example/..."},
          {"relay+https://api.example/api/v1/engines/e1/sync", "relay+https://api.example/..."}
        ] do
      assert LogUrl.render(url) == logged, url
    end
  end

  test "names a URL it cannot read, user info and control characters included, unparsable" do
    for url <- [
          "https://user:p/ss@host/x",
          "https://ho\e[31mst/x",
          "https://host\u0085name/x",
          "https:///no-host",
          "mailto:someone@example.com",
          "not a url",
          ""
        ] do
      assert LogUrl.render(url) == "an unparsable URL", inspect(url)
    end

    assert LogUrl.render(nil) == "an unparsable URL"
    assert LogUrl.render(42) == "an unparsable URL"
  end
end
