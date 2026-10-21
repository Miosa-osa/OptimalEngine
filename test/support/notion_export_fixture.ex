defmodule OptimalEngine.TestSupport.NotionExportFixture do
  @moduledoc """
  Builds synthetic Notion export zips for tests, in memory or on disk.

  `export/0` is a small export with nested pages, a database with an `_all`
  view, a row page, a row without a page, relative, `notion.so`, broken and
  external links, an image, and Finder litter. `raw_zip/1` writes an archive
  byte by byte, so a test can lie in a header, store a raw non-UTF-8 name, or
  name a path outside the archive, none of which `:zip` will write.

  All content is invented.
  """

  @ids %{
    handbook: "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
    onboarding: "1b2c3d4e5f60718293a4b5c6d7e8f90a",
    first_week: "2c3d4e5f60718293a4b5c6d7e8f90a1b",
    tasks: "3d4e5f60718293a4b5c6d7e8f90a1b2c",
    write_guide: "4e5f60718293a4b5c6d7e8f90a1b2c3d",
    standalone: "5f60718293a4b5c6d7e8f90a1b2c3d4e",
    missing: "60718293a4b5c6d7e8f90a1b2c3d4e5f"
  }

  @doc "The Notion ids `export/0` uses, by name."
  def ids, do: @ids

  @doc "The files of the small export, as `{path, content}`."
  def files do
    i = @ids
    handbook = "Team Handbook #{i.handbook}"
    enc = fn path -> String.replace(path, " ", "%20") end

    [
      {"#{handbook}.md",
       """
       # Team Handbook

       Welcome to the handbook. Start with [Onboarding](#{enc.("#{handbook}/Onboarding #{i.onboarding}.md")}) and track work in [Tasks](#{enc.("#{handbook}/Tasks #{i.tasks}.csv")}).
       Read the [public site](https://example.com/handbook) too.
       This page was removed: [Gone](#{enc.("Gone #{i.missing}.md")}).

       ![diagram](#{enc.("#{handbook}/diagram.png")})
       """},
      {"#{handbook}/Onboarding #{i.onboarding}.md",
       """
       # Onboarding

       The badge office opens at nine. Go back to the [handbook](#{enc.("../Team Handbook #{i.handbook}.md")}).
       The same page on the web: [handbook](https://www.notion.so/Team-Handbook-#{i.handbook}?pvs=4).
       """},
      {"#{handbook}/Onboarding #{i.onboarding}/First Week #{i.first_week}.md",
       """
       # First Week

       Pair with a buddy and reconcile the quartz ledger before Friday.
       """},
      {"#{handbook}/Tasks #{i.tasks}.csv",
       "Name,Status,Owner\nWrite guide,Done,Avery\nReview guide,Open,Blake\n"},
      {"#{handbook}/Tasks #{i.tasks}_all.csv",
       "\uFEFFName,Status,Owner,Due\nWrite guide,Done,Avery,2026-10-01\nReview guide,Open,Blake,2026-10-09\n"},
      {"#{handbook}/Tasks #{i.tasks}/Write guide #{i.write_guide}.md",
       """
       # Write guide

       Status: Done
       Owner: Avery

       Draft the zephyr checklist for new starters.
       """},
      {"#{handbook}/diagram.png",
       <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)},
      {".DS_Store", <<0, 0, 0, 1>>},
      {"Standalone Note #{i.standalone}.md", "# Standalone Note\n"}
    ]
  end

  @doc "The small export as zip bytes."
  def export, do: zip(files())

  @doc "Zips `{path, content}` files with `:zip` (deflate, UTF-8 names)."
  def zip(files) do
    entries = Enum.map(files, fn {path, content} -> {String.to_charlist(path), content} end)
    {:ok, {_name, bytes}} = :zip.create(~c"export.zip", entries, [:memory])
    bytes
  end

  @doc "Writes `bytes` to a fresh file under `dir` and returns its path."
  def write!(dir, bytes, name \\ "export.zip") do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  @doc """
  Writes a zip byte by byte. Each entry is a map: `:name` (raw bytes),
  `:data`, `:method` (0 stored, 8 deflate; default 8), and optional lies:
  `:declared_size`, `:declared_crc`, `:flags`.
  """
  def raw_zip(entries) do
    {locals, centrals, _offset} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {locals, centrals, offset} ->
        name = entry.name
        data = entry.data
        method = Map.get(entry, :method, 8)
        payload = if method == 8, do: deflate(data), else: data
        size = Map.get(entry, :declared_size, byte_size(data))
        crc = Map.get(entry, :declared_crc, :erlang.crc32(data))
        flags = Map.get(entry, :flags, if(String.valid?(name), do: 0x800, else: 0))

        local =
          <<0x50, 0x4B, 0x03, 0x04, 20::little-16, flags::little-16, method::little-16,
            0::little-16, 0::little-16, crc::little-32, byte_size(payload)::little-32,
            size::little-32, byte_size(name)::little-16, 0::little-16, name::binary,
            payload::binary>>

        central =
          <<0x50, 0x4B, 0x01, 0x02, 20::little-16, 20::little-16, flags::little-16,
            method::little-16, 0::little-16, 0::little-16, crc::little-32,
            byte_size(payload)::little-32, size::little-32, byte_size(name)::little-16,
            0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32, offset::little-32,
            name::binary>>

        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    body = locals |> Enum.reverse() |> IO.iodata_to_binary()
    cd = centrals |> Enum.reverse() |> IO.iodata_to_binary()
    count = length(entries)

    eocd =
      <<0x50, 0x4B, 0x05, 0x06, 0::little-16, 0::little-16, count::little-16, count::little-16,
        byte_size(cd)::little-32, byte_size(body)::little-32, 0::little-16>>

    body <> cd <> eocd
  end

  defp deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    out = :zlib.deflate(z, data, :finish)
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  @doc """
  A synthetic export of about `target_bytes` of Markdown and CSV: top-level
  sections, each with nested pages two levels deep, databases with row pages,
  links between siblings, and one known phrase per page (`marker/1`), so a
  test can search for any page. Text is drawn from a word list so it
  compresses like prose, not like a repeated string.
  """
  def large_export(target_bytes, opts \\ []) do
    words = word_list()
    page_bytes = Keyword.get(opts, :page_bytes, 24_000)
    sections = Keyword.get(opts, :sections, 20)
    rand = :rand.seed_s(:exsss, {1, 2, 3})
    pages = max(div(target_bytes, page_bytes), sections)
    per_section = div(pages, sections)

    {files, _rand} =
      Enum.flat_map_reduce(1..sections, rand, fn s, rand ->
        section_id = hex_id("section", s)
        section = "Section #{s} #{section_id}"

        {children, rand} =
          Enum.flat_map_reduce(1..per_section, rand, fn p, rand ->
            id = hex_id("page", s * 100_000 + p)
            {text, rand} = prose(words, page_bytes, rand)
            sibling = hex_id("page", s * 100_000 + max(p - 1, 1))
            # Every tenth page heads a topic; the nine after it are its children.
            head = div(p - 1, 10) * 10 + 1
            head_folder = "Topic #{s}-#{head} #{hex_id("page", s * 100_000 + head)}"
            parent_dir = if p == head, do: section, else: "#{section}/#{head_folder}"
            path = "#{parent_dir}/Topic #{s}-#{p} #{id}.md"

            link = "[previous](Topic%20#{s}-#{max(p - 1, 1)}%20#{sibling}.md)"
            body = "# Topic #{s}-#{p}\n\n#{marker(id)}\n\n#{link}\n\n#{text}\n"
            {[{path, body}], rand}
          end)

        db_id = hex_id("db", s)

        rows =
          Enum.map(1..50, fn r ->
            "Item #{s}-#{r},#{Enum.at(words, rem(r, length(words)))},#{r}\n"
          end)

        csv = {"#{section}/Ledger #{s} #{db_id}.csv", "Name,Kind,Amount\n" <> Enum.join(rows)}

        row_pages =
          Enum.map(1..10, fn r ->
            row_id = hex_id("row", s * 1000 + r)

            {"#{section}/Ledger #{s} #{db_id}/Item #{s}-#{r} #{row_id}.md",
             "# Item #{s}-#{r}\n\nKind: entry\n\n#{marker(row_id)}\n\nLedger row #{r} of section #{s}.\n"}
          end)

        index = {"#{section}.md", "# Section #{s}\n\n#{marker(section_id)}\n"}
        {[index, csv | row_pages] ++ children, rand}
      end)

    files
  end

  @doc "The phrase only the page with this id carries."
  def marker(id), do: "Marker phrase kestrel#{binary_part(id, 0, 12)} belongs here."

  @doc "A stable 32 hex id for a synthetic item."
  def hex_id(kind, n),
    do: :crypto.hash(:md5, "#{kind}:#{n}") |> Base.encode16(case: :lower)

  defp prose(words, bytes, rand) do
    words = List.to_tuple(words)
    count = tuple_size(words)

    {list, rand} =
      Enum.map_reduce(1..div(bytes, 7), rand, fn _, rand ->
        {n, rand} = :rand.uniform_s(count, rand)
        {elem(words, n - 1), rand}
      end)

    text =
      list
      |> Enum.chunk_every(14)
      |> Enum.map_join(" ", fn sentence -> Enum.join(sentence, " ") <> "." end)

    {text, rand}
  end

  defp word_list do
    ~w(account action agenda answer archive asset audit backlog balance batch board branch
       brief budget build cache calendar campaign channel chart claim client cluster column
       comment commit contract cost customer cycle dashboard data deadline decision delivery
       demand design detail device draft driver edge effort engine entry estimate event
       evidence export feature field filter forecast format funnel gateway goal graph guide
       handoff header history impact incident index input insight invoice issue journal
       ledger level limit linkage listing margin market measure meeting memo method metric
       milestone model module monitor network note notice offer onboarding option order
       outcome owner package partner payment period pipeline plan policy portal priority
       process product profile progress project proposal quality quarter query queue range
       record region release report request resource result review revenue risk roadmap
       rollout route rule schedule scope script segment service session signal sprint stage
       standard status step storage strategy summary supplier support survey system target
       task team template tenant test ticket timeline topic track trend update usage user
       value vendor version volume window workflow workspace)
  end
end
