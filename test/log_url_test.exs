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
          {"relay+https://api.example/api/v1/engines/e1/sync", "relay+https://api.example/..."},
          # Everything before the last @ ahead of the query is user info, so a
          # password holding a / never reads as a host or a port.
          {"https://admin:12345/x@host.example/y", "https://host.example/..."},
          {"https://user:p/ss@host/x", "https://host/..."},
          {"https://u:p@h1.example/a@h2.example:8443?x=1", "https://h2.example:8443/..."}
        ] do
      assert LogUrl.render(url) == logged, url
    end
  end

  test "names a URL it cannot read, user info and control characters included, unparsable" do
    for url <- [
          "https://user:pass@ho st/x",
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

  @levels [:debug, :info, :notice, :warning, :warn, :error, :critical, :alert, :emergency, :log]

  test "no log message under lib/ interpolates a URL as it is" do
    sample = ~S|Logger.warning("[Sync] peer #{peer.url} and #{LogUrl.render(peer.url)}")|
    assert raw_url_interpolations(Code.string_to_quoted!(sample)) == ["peer.url"]

    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          found <- raw_url_interpolations(Code.string_to_quoted!(File.read!(path))),
          do: "#{path}: #{found}"

    assert offenders == [], "render each URL with LogUrl.render/1:\n" <> Enum.join(offenders, "\n")
  end

  # Each #{...} inside a Logger call whose value is a variable or field named
  # like a URL, as opposed to the value of a call such as LogUrl.render/1.
  defp raw_url_interpolations(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, args} = node, acc
        when level in @levels ->
          {node, acc ++ interpolated_urls(args)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp interpolated_urls(args) do
    {_args, found} =
      Macro.prewalk(args, [], fn
        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [value]}, {:binary, _, _}]} = node, acc ->
          if url_named?(value), do: {node, acc ++ [Macro.to_string(value)]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp url_named?({name, _, context}) when is_atom(name) and is_atom(context), do: url?(name)
  defp url_named?({{:., _, [_base, field]}, _, []}) when is_atom(field), do: url?(field)
  defp url_named?(_value), do: false

  defp url?(name), do: name |> Atom.to_string() |> String.downcase() |> String.contains?("url")
end
