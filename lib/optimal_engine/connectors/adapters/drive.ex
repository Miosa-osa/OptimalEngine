defmodule OptimalEngine.Connectors.Adapters.Drive do
  @moduledoc """
  Google Drive connector -- docs, sheets, slides and text files.

  ## Required config keys
    * `:scope` -- `:my_drive | :shared_drive | :starred`
    * `:drive_id` -- required when `scope: :shared_drive`

  Optional: `:max_pages` -- pages of 100 files read per sync (default 20).

  `:my_drive` reads the account's own corpus (files it owns and files shared
  with it), `:shared_drive` reads one shared drive, `:starred` keeps only starred
  files. Trashed files are never read.

  ## Credentials
    * `:oauth_refresh_token`, `:client_id`, `:client_secret`

  ## Content
  Drive's file listing carries metadata only, so each file's text is fetched
  per file:

    * Google Docs are exported as Markdown, Google Slides as plain text, and
      Google Sheets as CSV (Drive exports only the first sheet)
    * a text file (`text/*`, JSON, XML) up to 5 MB is downloaded as it is; an
      HTML file has its markup stripped

  A file with no text to read -- a folder, a PDF, an image, an Office binary --
  is skipped: it would reach the engine with empty content, which the intake
  sink drops, and reporting it as ingested would be a lie. A file Drive refuses
  to hand over for its own reasons (deleted since the listing, too large to
  export) is skipped and named in the log. Anything that is not about that one
  file -- an expired token, a rate limit, a server fault, a missing permission
  -- stops the sync with an error, so a broken connector never looks like an
  empty Drive.

  ## Cursor shape
  A Google Drive change-list page token. Initial sync: `nil`, which takes the
  current `changes.getStartPageToken` before it lists, then lists files newest
  first and parks that token, so a change made while the listing ran is read by
  the next sync. A later sync reads the change list from the cursor, follows
  `nextPageToken` and parks `newStartPageToken`. A run that stops at
  `:max_pages` parks Drive's own `nextPageToken`, which does not expire, and the
  next run resumes there.

  The initial listing is bounded at `:max_pages` pages of the most recently
  modified files; a larger Drive logs that older files were left out. A listing
  page token expires within hours, so the walk is not resumable the way the
  change list is.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :drive,
    display_name: "Google Drive",
    auth_scheme: :oauth2,
    required_keys: [:scope],
    credential_keys: [:oauth_refresh_token, :client_id, :client_secret]

  alias OptimalEngine.Connectors.HTTP

  require Logger

  @token_url "https://oauth2.googleapis.com/token"
  @base_url "https://www.googleapis.com/drive/v3"
  @page_size 100
  @default_max_pages 20
  @max_download_bytes 5 * 1_024 * 1_024
  # An export of a long document can outlast the 10s default.
  @text_timeout_ms 30_000
  @file_fields "id,name,mimeType,modifiedTime,size,trashed,starred"

  @scopes %{"my_drive" => :my_drive, "shared_drive" => :shared_drive, "starred" => :starred}

  # Google-native files have no bytes of their own; Drive converts them on
  # request, and these are the conversions that yield text.
  @exports %{
    "application/vnd.google-apps.document" => "text/markdown",
    "application/vnd.google-apps.spreadsheet" => "text/csv",
    "application/vnd.google-apps.presentation" => "text/plain"
  }

  @text_blobs ["application/json", "application/xml"]

  # Why Drive refuses one file, as opposed to why it refuses us.
  @per_file_reasons ~w(exportSizeLimitExceeded fileNotExportable fileNotDownloadable
                       cannotDownloadFile downloadRestrictedForRevision)

  @rate_limit_reasons ~w(rateLimitExceeded userRateLimitExceeded)

  @auth_errors ~w(invalid_grant invalid_client unauthorized_client)

  @impl true
  def init(config) do
    with {:ok, state} <- super(config),
         :ok <- check_scope(state) do
      {:ok, state}
    end
  end

  @impl true
  def sync(state, cursor) do
    with {:ok, access_token} <- refresh_access_token(state) do
      ctx = %{
        headers: [{"authorization", "Bearer #{access_token}"}],
        scope: scope(state),
        drive_id: present(pick(state, :drive_id)),
        max_pages: max_pages(state)
      }

      case present(cursor) do
        nil -> bootstrap_sync(ctx)
        page_token -> incremental_sync(page_token, ctx)
      end
    end
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = raw["id"] || ""
    name = raw["name"] || "Untitled"
    mime = raw["mimeType"] || ""

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:drive, ext_id),
       title: name,
       content: content(mime, raw["text"]),
       path: Transform.source_uri(:drive, ext_id),
       genre: drive_genre(mime),
       mode: drive_mode(mime),
       format: drive_format(mime),
       modified_at: Transform.parse_iso8601(raw["modifiedTime"])
     })}
  end

  # ---- config -----------------------------------------------------------------

  defp check_scope(state) do
    case scope(state) do
      :shared_drive ->
        if present(pick(state, :drive_id)),
          do: :ok,
          else: {:error, {:missing_config, [:drive_id]}}

      nil ->
        {:error, {:invalid_config, :scope}}

      _scope ->
        :ok
    end
  end

  defp scope(state), do: Map.get(@scopes, to_string(pick(state, :scope)))

  defp max_pages(state) do
    case pick(state, :max_pages, @default_max_pages) do
      pages when is_integer(pages) and pages > 0 ->
        pages

      pages when is_binary(pages) ->
        case Integer.parse(pages) do
          {n, ""} when n > 0 -> n
          _ -> @default_max_pages
        end

      _ ->
        @default_max_pages
    end
  end

  # ---- auth -------------------------------------------------------------------

  defp refresh_access_token(state) do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => pick(state, :oauth_refresh_token),
      "client_id" => pick(state, :client_id),
      "client_secret" => pick(state, :client_secret)
    }

    case HTTP.post_json(@token_url, body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      # Google answers a revoked or expired refresh token with a 400.
      {:ok, %{status: status, body: %{"error" => error}}}
      when status in [400, 401] and error in @auth_errors ->
        {:error, :auth_expired}

      {:ok, %{status: 401}} ->
        {:error, :auth_expired}

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        {:error, error_reason(response)}

      {:ok, %{body: body}} ->
        {:error, {:token_error, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- initial sync -----------------------------------------------------------

  # The start page token is taken before the listing, so a file changed while the
  # listing runs is picked up by the first incremental sync rather than lost.
  defp bootstrap_sync(ctx) do
    with {:ok, start_token} <- start_page_token(ctx),
         {:ok, files} <- list_pages(ctx, nil, [], 1),
         {:ok, signals} <- to_signals(files, ctx) do
      {:ok, %{signals: signals, cursor: start_token}}
    end
  end

  defp start_page_token(ctx) do
    url = "#{@base_url}/changes/startPageToken" <> query_string(drive_params(ctx))

    case HTTP.get_json(url, headers: ctx.headers) do
      {:ok, %{status: 200, body: %{"startPageToken" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, response} ->
        {:error, error_reason(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Follows `nextPageToken` until Drive stops sending one or the page bound is
  # reached. Drive returns only the fields named in `fields`, so the list asks
  # for `nextPageToken` explicitly: without it every page looks like the last.
  defp list_pages(ctx, page_token, acc, page) do
    case HTTP.get_json(list_url(ctx, page_token), headers: ctx.headers) do
      {:ok, %{status: 200, body: %{} = body}} ->
        acc = [List.wrap(body["files"]) | acc]

        case present(body["nextPageToken"]) do
          nil ->
            {:ok, flatten(acc)}

          _next when page >= ctx.max_pages ->
            files = flatten(acc)

            Logger.warning(
              "[Connectors.Drive] initial listing stopped at max_pages=#{ctx.max_pages} " <>
                "(#{length(files)} files); older files are not included. Raise max_pages to read more."
            )

            {:ok, files}

          next ->
            list_pages(ctx, next, acc, page + 1)
        end

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, response} ->
        {:error, error_reason(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_url(ctx, page_token) do
    params =
      [
        {"q", list_filter(ctx.scope)},
        {"fields", "nextPageToken,files(#{@file_fields})"},
        {"pageSize", @page_size},
        {"orderBy", "modifiedTime desc"}
      ] ++ corpus_params(ctx) ++ if(page_token, do: [{"pageToken", page_token}], else: [])

    "#{@base_url}/files" <> query_string(params)
  end

  defp list_filter(:starred), do: "starred = true and trashed = false"
  defp list_filter(_scope), do: "trashed = false"

  # ---- incremental sync -------------------------------------------------------

  # Reads the change list from `page_token`. Drive ends a list with
  # `newStartPageToken` (park it) and continues one with `nextPageToken` (follow
  # it). A run cut off at the page bound parks that `nextPageToken`.
  defp incremental_sync(page_token, ctx) do
    with {:ok, files, cursor} <- change_pages(ctx, page_token, [], 1),
         {:ok, signals} <- to_signals(files, ctx) do
      {:ok, %{signals: signals, cursor: cursor}}
    end
  end

  defp change_pages(ctx, page_token, acc, page) do
    case HTTP.get_json(changes_url(ctx, page_token), headers: ctx.headers) do
      {:ok, %{status: 200, body: %{} = body}} ->
        acc = [changed_files(body) | acc]

        case {present(body["nextPageToken"]), present(body["newStartPageToken"])} do
          {next, _new_start} when next != nil and page >= ctx.max_pages ->
            {:ok, flatten(acc), next}

          {nil, nil} ->
            # Neither token is not a shape Drive sends. Stay where we are.
            {:ok, flatten(acc), page_token}

          {nil, new_start} ->
            {:ok, flatten(acc), new_start}

          {next, _new_start} ->
            change_pages(ctx, next, acc, page + 1)
        end

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, response} ->
        {:error, error_reason(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp changes_url(ctx, page_token) do
    params =
      [
        {"pageToken", page_token},
        {"fields", "nextPageToken,newStartPageToken,changes(removed,fileId,file(#{@file_fields}))"},
        {"pageSize", @page_size}
      ] ++ corpus_params(ctx)

    "#{@base_url}/changes" <> query_string(params)
  end

  # A removed file has no `file` object, and a removal is not something this
  # additive pipe can act on.
  defp changed_files(body) do
    body
    |> Map.get("changes")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"removed" => true} -> []
      %{"file" => %{} = file} -> [file]
      _change -> []
    end)
  end

  # ---- files and their text ---------------------------------------------------

  # Reads each file's text in order. The first failure that is not about the
  # file itself ends the sync: swallowing it would report a broken connector as
  # an empty Drive and advance the cursor past files that were never read.
  defp to_signals(files, ctx) do
    files
    |> readable(ctx)
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, signals} ->
      case file_signal(file, ctx) do
        {:ok, signal} -> {:cont, {:ok, [signal | signals]}}
        :skip -> {:cont, {:ok, signals}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, signals} -> {:ok, Enum.reverse(signals)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The change list can name a file more than once and cannot be filtered by
  # query, so the scope and the trash are applied here too. The latest entry for
  # a file wins.
  defp readable(files, ctx) do
    files
    |> Enum.filter(&(is_binary(&1["id"]) and &1["trashed"] != true and in_scope?(&1, ctx.scope)))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1["id"])
    |> Enum.reverse()
  end

  defp in_scope?(file, :starred), do: file["starred"] == true
  defp in_scope?(_file, _scope), do: true

  defp file_signal(file, ctx) do
    with {:ok, text} <- file_text(file, ctx),
         true <- String.trim(text) != "",
         {:ok, signal} <- transform(Map.put(file, "text", text)) do
      {:ok, signal}
    else
      false -> :skip
      :skip -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_text(file, ctx) do
    case text_source(file) do
      {:export, mime} ->
        fetch_text(
          "#{@base_url}/files/#{enc(file["id"])}/export" <> query_string([{"mimeType", mime}]),
          file,
          ctx
        )

      :download ->
        fetch_text(
          "#{@base_url}/files/#{enc(file["id"])}" <>
            query_string([{"alt", "media"}, {"supportsAllDrives", "true"}]),
          file,
          ctx
        )

      :none ->
        :skip
    end
  end

  defp text_source(%{"mimeType" => mime} = file) do
    cond do
      export = Map.get(@exports, mime) -> {:export, export}
      text_blob?(mime) and within_download_cap?(file) -> :download
      true -> :none
    end
  end

  defp text_source(_file), do: :none

  defp text_blob?("text/" <> _), do: true
  defp text_blob?(mime), do: mime in @text_blobs

  # `size` is a string of bytes, present for files with content of their own.
  defp within_download_cap?(%{"size" => size}) when is_binary(size) do
    case Integer.parse(size) do
      {bytes, ""} -> bytes <= @max_download_bytes
      _ -> false
    end
  end

  defp within_download_cap?(_file), do: true

  # The body is asked for raw: a JSON file would otherwise be decoded into a map.
  defp fetch_text(url, file, ctx) do
    case HTTP.get_json(url, headers: ctx.headers, parse_json: false, timeout: @text_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, response} ->
        file_failure(response, file)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_failure(%{status: 404}, file), do: skip_file(file, "notFound")

  defp file_failure(%{status: 403, body: body} = response, file) do
    reasons = error_reasons(body)

    case Enum.find(reasons, &(&1 in @per_file_reasons)) do
      nil -> {:error, error_reason(response)}
      reason -> skip_file(file, reason)
    end
  end

  defp file_failure(response, _file), do: {:error, error_reason(response)}

  defp skip_file(file, reason) do
    Logger.warning(
      "[Connectors.Drive] skipped #{file["id"]} (#{file["name"]}): Drive refused it (#{reason})"
    )

    :skip
  end

  # ---- errors -----------------------------------------------------------------

  defp error_reason(%{status: 401}), do: :auth_expired
  defp error_reason(%{status: 429, headers: headers}), do: rate_limited(headers)

  defp error_reason(%{status: 403, headers: headers, body: body}) do
    if Enum.any?(error_reasons(body), &(&1 in @rate_limit_reasons)),
      do: rate_limited(headers),
      else: {:http, 403}
  end

  defp error_reason(%{status: status}) when status >= 500, do: :transient
  defp error_reason(%{status: status}), do: {:http, status}

  defp rate_limited(headers) do
    case HTTP.retry_after(headers) do
      nil -> :rate_limited
      retry_after_ms -> {:rate_limited, retry_after_ms}
    end
  end

  # Drive names the cause in `error.errors[].reason`. The body arrives decoded
  # from a JSON call and as the raw string from a text fetch.
  defp error_reasons(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> error_reasons(decoded)
      _ -> []
    end
  end

  defp error_reasons(%{"error" => %{"errors" => errors}}) when is_list(errors) do
    for %{"reason" => reason} <- errors, is_binary(reason), do: reason
  end

  defp error_reasons(_body), do: []

  # ---- request helpers --------------------------------------------------------

  # What a shared drive needs on every call that lists or reads its files.
  defp corpus_params(%{scope: :shared_drive, drive_id: drive_id}) do
    [
      {"corpora", "drive"},
      {"driveId", drive_id},
      {"includeItemsFromAllDrives", "true"},
      {"supportsAllDrives", "true"}
    ]
  end

  defp corpus_params(_ctx), do: []

  # `changes.getStartPageToken` takes the drive and the shared-drive flag only.
  defp drive_params(%{scope: :shared_drive, drive_id: drive_id}) do
    [{"driveId", drive_id}, {"supportsAllDrives", "true"}]
  end

  defp drive_params(_ctx), do: []

  defp query_string([]), do: ""

  defp query_string(params) do
    "?" <> Enum.map_join(params, "&", fn {key, value} -> "#{key}=#{enc(to_string(value))}" end)
  end

  defp enc(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp flatten(pages), do: pages |> Enum.reverse() |> Enum.concat()

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil

  # ---- signal mapping ---------------------------------------------------------

  defp content("text/html", text) when is_binary(text), do: Transform.strip_html(text)
  defp content(_mime, text) when is_binary(text), do: text
  defp content(_mime, _text), do: ""

  defp drive_genre("application/vnd.google-apps.document"), do: "document"
  defp drive_genre("application/vnd.google-apps.spreadsheet"), do: "table"
  defp drive_genre("application/vnd.google-apps.presentation"), do: "slides"
  defp drive_genre("application/pdf"), do: "document"
  defp drive_genre(_), do: "file"

  defp drive_mode("application/vnd.google-apps.spreadsheet"), do: :data
  defp drive_mode("image/" <> _), do: :visual
  defp drive_mode(_), do: :linguistic

  defp drive_format("application/vnd.google-apps.document"), do: :markdown
  defp drive_format("text/markdown"), do: :markdown
  defp drive_format("application/json"), do: :json
  defp drive_format(_), do: :unknown
end
