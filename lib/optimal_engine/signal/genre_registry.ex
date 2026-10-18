defmodule OptimalEngine.Signal.GenreRegistry do
  @moduledoc """
  The single canonical genre vocabulary for the engine.

  Historically the engine carried four divergent genre vocabularies (a 9-atom
  CloudEvents set in the envelope builder/validation, a 9-key type→genre map in
  the classifier analyzer, a 17-entry regex set in the pipeline classifier, and
  a 5-skeleton set in the composer). The 143 genre templates under the OptimalOS
  taxonomy were inert docs, so ~134 genres collapsed to `:chat`/`:note`.

  This module loads the canonical registry generated from those templates
  (`priv/genres.exs`, shipped inside the engine so downloading apps are
  self-contained) and exposes:

    * `all/0`          — every genre entry
    * `genres/0`       — every genre name (string)
    * `fetch/1`        — lookup a genre entry by name
    * `valid?/1`       — membership check
    * `category/1`     — the genre's taxonomy category
    * `skeleton/1`     — the ordered section skeleton for composition
    * `detect/2`       — classify free text to the best-matching genre name

  Each entry is a map:

      %{
        genre: "spec",
        category: "technical",
        signal_type: "inform",
        mode: "mixed",
        purpose: "...",
        sections: [%{name: "Requirements", required: true}, ...]
      }

  The registry is read once at compile time so there is no runtime file IO and
  no dependency on the OptimalOS checkout at runtime.
  """

  @default_genre "note"

  @registry_path Path.join([:code.priv_dir(:optimal_engine), "genres.exs"])
  @external_resource @registry_path

  @genres (case File.read(@registry_path) do
             {:ok, contents} ->
               {term, _binding} = Code.eval_string(contents)
               term

             {:error, _} ->
               []
           end)

  @genre_index Map.new(@genres, fn g -> {g.genre, g} end)
  @genre_names @genres |> Enum.map(& &1.genre) |> Enum.sort()

  # High-signal keyword cues per genre, derived from the genre name and its
  # section headings. Used by `detect/1` as a graceful fallback after the
  # pipeline's high-precision regex set.
  @keyword_index Map.new(@genres, fn g ->
                   name_words =
                     g.genre
                     |> String.split("-", trim: true)
                     |> Enum.filter(&(String.length(&1) > 2))

                   section_words =
                     g.sections
                     |> Enum.flat_map(fn s ->
                       s.name |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)
                     end)
                     |> Enum.filter(&(String.length(&1) > 3))

                   {g.genre, Enum.uniq(name_words ++ section_words)}
                 end)

  # Words match whole, so "win" does not match "window"; a trailing plural "s"
  # is folded on both sides so "requirement" still matches "requirements".
  @plural ~r/^(.{2,}[^s])s$/

  # Per genre: folded name tokens (3 points each) and folded section words
  # (1 point each), precomputed so scoring is set lookups only.
  @scoring_index (for {genre, keywords} <- @keyword_index do
                    tokens = String.split(genre, "-", trim: true)
                    names = tokens |> Enum.filter(&(String.length(&1) > 2))

                    {genre, Enum.map(names, &Regex.replace(@plural, &1, "\\1")),
                     Enum.map(keywords -- tokens, &Regex.replace(@plural, &1, "\\1"))}
                  end)

  @doc "Returns every genre entry in the canonical registry."
  @spec all() :: [map()]
  def all, do: @genres

  @doc "Returns every genre name (sorted strings)."
  @spec genres() :: [String.t()]
  def genres, do: @genre_names

  @doc "Returns the number of genres in the registry."
  @spec count() :: non_neg_integer()
  def count, do: length(@genres)

  @doc "Returns the default genre name used when nothing matches."
  @spec default_genre() :: String.t()
  def default_genre, do: @default_genre

  @doc "Fetches a genre entry by name. Returns `{:ok, entry}` or `:error`."
  @spec fetch(String.t() | atom()) :: {:ok, map()} | :error
  def fetch(genre) when is_atom(genre), do: fetch(Atom.to_string(genre))

  def fetch(genre) when is_binary(genre) do
    case Map.fetch(@genre_index, genre) do
      {:ok, entry} -> {:ok, entry}
      :error -> :error
    end
  end

  @doc "True when the given genre name exists in the registry."
  @spec valid?(String.t() | atom()) :: boolean()
  def valid?(genre) when is_atom(genre), do: valid?(Atom.to_string(genre))
  def valid?(genre) when is_binary(genre), do: Map.has_key?(@genre_index, genre)
  def valid?(_), do: false

  @doc "Returns the taxonomy category for a genre, or nil."
  @spec category(String.t() | atom()) :: String.t() | nil
  def category(genre) do
    case fetch(genre) do
      {:ok, %{category: c}} -> c
      :error -> nil
    end
  end

  @doc """
  Returns the ordered section skeleton for a genre as a list of
  `%{name: String.t(), required: boolean()}`. Returns `[]` for unknown genres.
  """
  @spec skeleton(String.t() | atom()) :: [%{name: String.t(), required: boolean()}]
  def skeleton(genre) do
    case fetch(genre) do
      {:ok, %{sections: sections}} -> sections
      :error -> []
    end
  end

  @doc """
  Detects the best-matching genre for free text via keyword scoring across the
  full registry. Returns a genre name string, defaulting to `"note"` when no
  genre reaches `:min_score` (default 1, any positive score).

  This is intentionally a coarse fallback: `OptimalEngine.Signal.GenreDetector`
  first tries form and heading cues and only consults `detect/2` with a
  higher `:min_score` when those find nothing. Scoring rewards genre-name
  token hits over section-word hits so that, e.g., text mentioning "decision"
  maps to `decision-log`/`adr` rather than any genre that happens to contain a
  "Decision" section. Words match whole, so "win" does not match "window".
  """
  @spec detect(String.t(), keyword()) :: String.t()
  def detect(text, opts \\ [])

  def detect(text, opts) when is_binary(text) do
    words = word_set(text)
    min_score = Keyword.get(opts, :min_score, 1)

    {best, score} =
      Enum.reduce(@scoring_index, {@default_genre, 0}, fn {genre, names, sections}, {bg, bs} ->
        s =
          3 * Enum.count(names, &MapSet.member?(words, &1)) +
            Enum.count(sections, &MapSet.member?(words, &1))

        if s > bs, do: {genre, s}, else: {bg, bs}
      end)

    if score >= min_score, do: best, else: @default_genre
  end

  def detect(_, _opts), do: @default_genre

  defp word_set(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> MapSet.new(&Regex.replace(@plural, &1, "\\1"))
  end
end
