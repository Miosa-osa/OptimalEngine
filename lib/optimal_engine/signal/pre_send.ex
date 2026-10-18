defmodule OptimalEngine.Signal.PreSend do
  @moduledoc """
  Pre-send check for drafts agents write: encodes the draft against its
  receiver before it goes out, and suggests a re-encoding when it would fail.

  The receiver is a channel (`sms`, `whatsapp`, `chat`, `slack`, `email`,
  `brief`, `document`), a bandwidth (`low`, `medium`, `high`), or both; the
  channel decides when both are given.

  | Channel | Words | Genres it expects |
  | --- | --- | --- |
  | sms | 60 | message |
  | whatsapp, chat, slack | 150 | message, announcement, standup |
  | email | 400 | email, message, brief, proposal, announcement, status-report |
  | brief | 300 | brief, status-report, decision-log |
  | document | 5,000 | any |

  Checks, each with a suggestion:

    * `bandwidth_overload` (Shannon) - longer than the receiver takes; the
      suggestion is a shorter version that keeps the opening sentences and
      any explicit ask;
    * `genre_mismatch` (Ashby) - the draft reads as a genre the channel does
      not expect, or not as the genre declared for it;
    * `missing_type` (Wiener) - a draft declared as a request carries no ask;
    * `routing_failure` (Shannon) - no receiver is named.

  Checks suggest; sending stays with the approval policy. With a workspace,
  each check records a `genre_checked` Signal event (`value` 1 fit, 0
  mismatch) that the genre recognition rate reads.
  """

  alias OptimalEngine.Signal.{GenreDetector, GenreRegistry, ModeDetector}
  alias OptimalEngine.Viability.SignalEvents

  @channels %{
    "sms" => %{words: 60, genres: ~w(message)},
    "whatsapp" => %{words: 150, genres: ~w(message announcement standup)},
    "chat" => %{words: 150, genres: ~w(message announcement standup)},
    "slack" => %{words: 150, genres: ~w(message announcement standup)},
    "email" => %{words: 400, genres: ~w(email message brief proposal announcement status-report)},
    "brief" => %{words: 300, genres: ~w(brief status-report decision-log)},
    "document" => %{words: 5_000, genres: :any}
  }

  @bandwidths %{"low" => 150, "medium" => 400, "high" => 2_000}

  # Genres that read as a conversational message in any short channel.
  @conversational ~w(message note email)

  @doc "The channel profiles."
  @spec channels() :: map()
  def channels, do: @channels

  @doc """
  Checks `draft` for `receiver` (`%{"channel" => ..., "bandwidth" => ...}`).
  Options: `:genre` and `:type` declared for the draft, `:tenant_id` and
  `:workspace_id` to record the check, `:actor`.
  """
  @spec check(String.t(), map(), keyword()) :: map()
  def check(draft, receiver, opts \\ []) when is_binary(draft) do
    receiver = Map.new(receiver || %{}, fn {key, value} -> {to_string(key), value} end)
    profile = profile(receiver)
    words = word_count(draft)
    genre = GenreDetector.detect(draft)
    {mode, _confidence} = ModeDetector.detect(draft)
    type = infer_type(draft)

    flags =
      [
        routing(profile),
        bandwidth(profile, words, draft),
        genre_fit(profile, genre, opts[:genre], draft),
        type_fit(opts[:type], type)
      ]
      |> Enum.reject(&is_nil/1)

    record(flags, genre, opts)

    %{
      ok: flags == [],
      words: words,
      receiver: Map.take(profile, [:channel, :bandwidth, :words, :genres]),
      detected: %{genre: genre, mode: Atom.to_string(mode), type: type},
      flags: flags
    }
  end

  # -- checks ------------------------------------------------------------------

  defp routing(%{channel: nil, bandwidth: nil}) do
    %{
      code: "routing_failure",
      constraint: "shannon",
      message: "No receiver is named, so the draft cannot be encoded for one.",
      suggestion:
        "Name the channel (sms, whatsapp, chat, slack, email, brief, document) or the bandwidth."
    }
  end

  defp routing(_profile), do: nil

  defp bandwidth(%{words: limit} = profile, words, draft)
       when is_integer(limit) and words > limit do
    %{
      code: "bandwidth_overload",
      constraint: "shannon",
      message: "#{words} words for a receiver that takes about #{limit}#{on(profile)}.",
      suggestion: "Send the short version and offer the rest on request.",
      shorter: shorten(draft, limit)
    }
  end

  defp bandwidth(_profile, _words, _draft), do: nil

  defp genre_fit(profile, genre, declared, draft) do
    cond do
      declared_mismatch?(declared, genre, draft) ->
        %{
          code: "genre_mismatch",
          constraint: "ashby",
          message: "Declared as #{declared} but reads as #{genre}.",
          suggestion: skeleton_hint(declared)
        }

      is_list(profile.genres) and genre not in profile.genres and genre not in @conversational ->
        expected = hd(profile.genres)

        %{
          code: "genre_mismatch",
          constraint: "ashby",
          message:
            "Reads as #{genre}, which #{profile.channel || "this receiver"} does not expect.",
          suggestion: skeleton_hint(expected)
        }

      true ->
        nil
    end
  end

  # A declared genre is contradicted when the draft reads as another genre,
  # or reads as nothing in particular and carries none of the declared
  # genre's required parts.
  defp declared_mismatch?(declared, genre, draft) when is_binary(declared) do
    cond do
      not GenreRegistry.valid?(declared) or declared == genre -> false
      genre != GenreRegistry.default_genre() -> true
      true -> required_parts(declared) != [] and not has_any_part?(declared, draft)
    end
  end

  defp declared_mismatch?(_declared, _genre, _draft), do: false

  defp required_parts(genre),
    do: genre |> GenreRegistry.skeleton() |> Enum.filter(& &1.required) |> Enum.map(& &1.name)

  defp has_any_part?(declared, draft) do
    text = String.downcase(draft)
    Enum.any?(required_parts(declared), &String.contains?(text, String.downcase(&1)))
  end

  defp type_fit("direct", type) when type != "direct" do
    %{
      code: "missing_type",
      constraint: "wiener",
      message: "Declared as a request but the draft asks for nothing.",
      suggestion: "State the ask and the date it is needed by in the first sentence."
    }
  end

  defp type_fit(_declared, _type), do: nil

  # -- helpers -----------------------------------------------------------------

  defp profile(receiver) do
    channel = receiver["channel"] |> to_s() |> String.downcase()
    bandwidth = receiver["bandwidth"] |> to_s() |> String.downcase()

    case {Map.get(@channels, channel), Map.get(@bandwidths, bandwidth)} do
      {%{} = known, _} ->
        %{
          channel: channel,
          bandwidth: nonempty(bandwidth),
          words: known.words,
          genres: known.genres
        }

      {nil, limit} when is_integer(limit) ->
        %{channel: nonempty(channel), bandwidth: bandwidth, words: limit, genres: :any}

      _ ->
        %{channel: nonempty(channel), bandwidth: nil, words: nil, genres: :any}
    end
  end

  # Keeps whole sentences from the top up to 80 percent of the budget, and
  # the first explicit ask if it was cut.
  defp shorten(draft, limit) do
    sentences =
      draft
      |> String.replace(~r/\s+/u, " ")
      |> String.split(~r/(?<=[.!?])\s+/u, trim: true)

    budget = max(round(limit * 0.8), 10)

    {kept, _used} =
      Enum.reduce_while(sentences, {[], 0}, fn sentence, {acc, used} ->
        n = word_count(sentence)

        if used + n <= budget or acc == [],
          do: {:cont, {[sentence | acc], used + n}},
          else: {:halt, {acc, used}}
      end)

    kept = Enum.reverse(kept)
    ask = Enum.find(sentences, &ask?/1)
    kept = if ask && ask not in kept, do: kept ++ [ask], else: kept
    Enum.join(kept, " ") <> " The full version is available on request."
  end

  defp infer_type(draft) do
    cond do
      ask?(draft) -> "direct"
      Regex.match?(~r/\b(I|we)('ll| will| shall)\b/i, draft) -> "commit"
      Regex.match?(~r/\b(we decided|decision:|approved|we agreed)\b/i, draft) -> "decide"
      true -> "inform"
    end
  end

  defp ask?(text) do
    String.contains?(text, "?") or
      Regex.match?(
        ~r/\b(please|can you|could you|would you|let me know|confirm|send me|need you to)\b/i,
        text
      )
  end

  defp skeleton_hint(genre) do
    case required_parts(genre) do
      [] -> "Re-encode as a #{genre}."
      sections -> "Re-encode as a #{genre}: #{Enum.join(sections, ", ")}."
    end
  end

  defp record(flags, genre, opts) do
    with tenant when is_binary(tenant) <- opts[:tenant_id],
         workspace when is_binary(workspace) <- opts[:workspace_id] do
      fit = if Enum.any?(flags, &(&1.code == "genre_mismatch")), do: 0, else: 1

      SignalEvents.note(
        tenant,
        %{
          "workspace_id" => workspace,
          "kind" => "genre_checked",
          "value" => fit,
          "genre" => genre,
          "metadata" => %{"source" => "pre_send", "flags" => Enum.map(flags, & &1.code)}
        },
        opts[:actor]
      )
    end
  end

  defp on(%{channel: nil}), do: ""
  defp on(%{channel: channel}), do: " on #{channel}"

  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()

  defp to_s(nil), do: ""
  defp to_s(value), do: to_string(value)

  defp nonempty(""), do: nil
  defp nonempty(value), do: value
end
