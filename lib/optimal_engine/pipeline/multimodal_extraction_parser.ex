defmodule OptimalEngine.Pipeline.MultimodalExtractionParser do
  @moduledoc """
  Normalizes multimodal adapter output into Memory Core extraction projections.

  The runner records the adapter execution first. This parser only decides how a
  completed run's output should be projected: transcript segments, OCR spans,
  visual observations, or embedding references. The projection still remains
  evidence/context until a review path promotes text into Claims and Facts.
  """

  @type projection_opts :: keyword()

  @spec parse(map(), map(), keyword()) :: [projection_opts()]
  def parse(run, tool, opts \\ []) when is_map(run) and is_map(tool) do
    role = Keyword.get(opts, :adapter_role) || List.first(Map.get(tool, :roles, []))
    text = Keyword.get(opts, :content_text, run.output_text || "")
    ref = Keyword.get(opts, :content_ref) || Keyword.get(opts, :embedding_ref) || run.output_ref

    base =
      Keyword.merge(scope_opts(opts),
        actor_id: Keyword.get(opts, :actor_id),
        confidence: Keyword.get(opts, :confidence, run.confidence),
        precision: Keyword.get(opts, :precision, run.precision),
        content_ref: ref,
        metadata:
          %{
            auto_projected: true,
            adapter_id: run.adapter_id,
            adapter_role: role
          }
          |> Map.merge(Keyword.get(opts, :extraction_metadata, %{}))
      )

    cond do
      explicit_type = Keyword.get(opts, :extraction_type) ->
        explicit_projection(base, explicit_type, text, ref, run, opts)

      role in [:audio_transcription, "audio_transcription"] ->
        transcript_projections(base, text, opts)

      role in [:document_intelligence, "document_intelligence", :ocr, "ocr"] ->
        ocr_projections(base, text, opts)

      role in [:visual_reasoning, "visual_reasoning"] ->
        visual_projections(base, text, opts)

      role in [:video_processing, "video_processing"] ->
        media_observation_projections(base, text, opts)

      role in [:multimodal_embedding, "multimodal_embedding"] ->
        embedding_projection(base, ref, run, opts)

      true ->
        []
    end
  end

  defp explicit_projection(base, explicit_type, text, ref, run, opts) do
    base
    |> Keyword.put(:extraction_type, explicit_type)
    |> Keyword.put(:content_text, text)
    |> Keyword.put(:content_ref, ref)
    |> put_embedding_defaults(explicit_type, ref, run, opts)
    |> List.wrap()
  end

  defp transcript_projections(base, text, opts) do
    json = decode_json(text)

    segments =
      cond do
        is_list(json["segments"]) -> json["segments"]
        is_list(json["transcript_segments"]) -> json["transcript_segments"]
        is_list(json) -> json
        true -> parse_timestamped_lines(text)
      end

    projections =
      segments
      |> Enum.map(&transcript_segment(base, &1, json, opts))
      |> Enum.reject(&is_nil/1)

    if projections == [] and present?(text) do
      [
        base
        |> Keyword.put(:extraction_type, :transcript)
        |> Keyword.put(:content_text, text)
        |> Keyword.put(:language, Keyword.get(opts, :language) || json["language"])
        |> Keyword.put(:speaker, Keyword.get(opts, :speaker))
        |> Keyword.put(:start_ms, Keyword.get(opts, :start_ms))
        |> Keyword.put(:end_ms, Keyword.get(opts, :end_ms))
      ]
    else
      projections
    end
  end

  defp transcript_segment(base, segment, json, opts) when is_map(segment) do
    text = first_present([segment["text"], segment[:text], segment["transcript"]])

    if present?(text) do
      base
      |> Keyword.put(:extraction_type, :transcript)
      |> Keyword.put(:content_text, text)
      |> Keyword.put(
        :language,
        first_present([Keyword.get(opts, :language), segment["language"], json["language"]])
      )
      |> Keyword.put(
        :speaker,
        first_present([Keyword.get(opts, :speaker), segment["speaker"], segment["speaker_id"]])
      )
      |> Keyword.put(
        :start_ms,
        ms(first_present([segment["start_ms"], segment["start"], segment[:start]]))
      )
      |> Keyword.put(:end_ms, ms(first_present([segment["end_ms"], segment["end"], segment[:end]])))
      |> merge_metadata(%{segment_index: segment["id"] || segment["index"]})
    end
  end

  defp transcript_segment(_base, _segment, _json, _opts), do: nil

  defp ocr_projections(base, text, opts) do
    json = decode_json(text)

    spans =
      cond do
        is_list(json["pages"]) -> json["pages"]
        is_list(json["elements"]) -> json["elements"]
        is_list(json["chunks"]) -> json["chunks"]
        is_list(json) -> json
        true -> parse_page_markers(text)
      end

    projections =
      spans
      |> Enum.map(&ocr_span(base, &1, opts))
      |> Enum.reject(&is_nil/1)

    if projections == [] and present?(text) do
      [
        base
        |> Keyword.put(:extraction_type, :ocr_span)
        |> Keyword.put(:content_text, text)
        |> Keyword.put(:page_number, Keyword.get(opts, :page_number))
        |> Keyword.put(:bbox, Keyword.get(opts, :bbox, %{}))
      ]
    else
      projections
    end
  end

  defp ocr_span(base, span, opts) when is_map(span) do
    text = first_present([span["text"], span["content"], span["markdown"], span["span_text"]])

    if present?(text) do
      base
      |> Keyword.put(:extraction_type, :ocr_span)
      |> Keyword.put(:content_text, text)
      |> Keyword.put(
        :page_number,
        first_present([span["page_number"], span["page"], Keyword.get(opts, :page_number)])
      )
      |> Keyword.put(
        :bbox,
        first_present([span["bbox"], span["bounding_box"], Keyword.get(opts, :bbox, %{})]) || %{}
      )
      |> merge_metadata(%{element_type: span["type"], element_id: span["id"]})
    end
  end

  defp ocr_span(_base, _span, _opts), do: nil

  defp visual_projections(base, text, opts) do
    json = decode_json(text)

    observations =
      cond do
        is_list(json["observations"]) -> json["observations"]
        is_list(json["frames"]) -> json["frames"]
        is_list(json) -> json
        true -> []
      end

    projections =
      observations
      |> Enum.map(&visual_observation(base, &1, opts))
      |> Enum.reject(&is_nil/1)

    if projections == [] and present?(text) do
      [
        base
        |> Keyword.put(:extraction_type, :visual_observation)
        |> Keyword.put(:content_text, text)
        |> Keyword.put(:observation_type, Keyword.get(opts, :observation_type, "caption"))
        |> Keyword.put(:region, Keyword.get(opts, :region, %{}))
        |> Keyword.put(:frame_time_ms, Keyword.get(opts, :frame_time_ms))
      ]
    else
      projections
    end
  end

  defp visual_observation(base, observation, opts) when is_map(observation) do
    text = first_present([observation["text"], observation["caption"], observation["observation"]])

    if present?(text) do
      base
      |> Keyword.put(:extraction_type, :visual_observation)
      |> Keyword.put(:content_text, text)
      |> Keyword.put(
        :observation_type,
        first_present([observation["type"], Keyword.get(opts, :observation_type, "caption")])
      )
      |> Keyword.put(
        :region,
        first_present([observation["region"], observation["bbox"], Keyword.get(opts, :region, %{})]) ||
          %{}
      )
      |> Keyword.put(
        :frame_time_ms,
        ms(
          first_present([observation["frame_time_ms"], observation["time_ms"], observation["time"]])
        )
      )
    end
  end

  defp visual_observation(_base, _observation, _opts), do: nil

  defp media_observation_projections(base, text, opts) do
    if present?(text) do
      [
        base
        |> Keyword.put(:extraction_type, :visual_observation)
        |> Keyword.put(:content_text, text)
        |> Keyword.put(:observation_type, Keyword.get(opts, :observation_type, "media_metadata"))
        |> Keyword.put(:region, Keyword.get(opts, :region, %{}))
        |> Keyword.put(:frame_time_ms, Keyword.get(opts, :frame_time_ms))
      ]
    else
      []
    end
  end

  defp embedding_projection(base, ref, run, opts) do
    if present?(ref) do
      [
        base
        |> Keyword.put(:extraction_type, :embedding_ref)
        |> Keyword.put(:content_text, "")
        |> Keyword.put(:content_ref, ref)
        |> Keyword.put(:embedding_model_id, Keyword.get(opts, :embedding_model_id, run.model_id))
        |> Keyword.put(
          :embedding_model_version,
          Keyword.get(opts, :embedding_model_version, run.model_version)
        )
        |> Keyword.put(:embedding_ref, ref)
        |> Keyword.put(:embedding_dim, Keyword.get(opts, :embedding_dim))
        |> Keyword.put(:embedding_space, Keyword.get(opts, :embedding_space))
        |> Keyword.put(:target_ref, Keyword.get(opts, :target_ref, "asset:#{run.asset_id}"))
      ]
    else
      []
    end
  end

  defp put_embedding_defaults(opts, explicit_type, ref, run, extra_opts)
       when explicit_type in [:embedding_ref, "embedding_ref"] do
    opts
    |> Keyword.put(:content_text, "")
    |> Keyword.put(:content_ref, ref)
    |> Keyword.put(:embedding_model_id, Keyword.get(extra_opts, :embedding_model_id, run.model_id))
    |> Keyword.put(
      :embedding_model_version,
      Keyword.get(extra_opts, :embedding_model_version, run.model_version)
    )
    |> Keyword.put(:embedding_ref, ref)
    |> Keyword.put(:embedding_dim, Keyword.get(extra_opts, :embedding_dim))
    |> Keyword.put(:embedding_space, Keyword.get(extra_opts, :embedding_space))
    |> Keyword.put(:target_ref, Keyword.get(extra_opts, :target_ref, "asset:#{run.asset_id}"))
  end

  defp put_embedding_defaults(opts, _explicit_type, _ref, _run, _extra_opts), do: opts

  defp parse_timestamped_lines(text) do
    regex =
      ~r/^\s*\[?(?<start>\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?)\s*(?:-->|-|to)\s*(?<end>\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?)\]?\s*(?<text>.+)$/m

    Regex.scan(regex, text, capture: :all_names)
    |> Enum.map(fn [end_time, start_time, line_text] ->
      %{"start" => start_time, "end" => end_time, "text" => String.trim(line_text)}
    end)
  end

  defp parse_page_markers(text) do
    if String.contains?(text, "\f") do
      text
      |> String.split("\f")
      |> Enum.with_index(1)
      |> Enum.map(fn {page_text, page} ->
        %{"page_number" => page, "text" => String.trim(page_text)}
      end)
    else
      []
    end
  end

  defp decode_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _ -> %{}
    end
  end

  defp decode_json(_text), do: %{}

  defp ms(nil), do: nil
  defp ms(value) when is_integer(value), do: value
  defp ms(value) when is_float(value), do: round(value * 1000)

  defp ms(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      String.contains?(value, ":") ->
        value
        |> String.split(":")
        |> Enum.map(&Float.parse/1)
        |> Enum.map(fn
          {number, _} -> number
          :error -> 0.0
        end)
        |> time_parts_to_ms()

      true ->
        case Float.parse(value) do
          {number, _} -> round(number * 1000)
          :error -> nil
        end
    end
  end

  defp ms(_value), do: nil

  defp time_parts_to_ms([minutes, seconds]), do: round((minutes * 60 + seconds) * 1000)

  defp time_parts_to_ms([hours, minutes, seconds]),
    do: round((hours * 3600 + minutes * 60 + seconds) * 1000)

  defp time_parts_to_ms(_parts), do: nil

  defp merge_metadata(opts, extra) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(drop_nil(extra))

    Keyword.put(opts, :metadata, metadata)
  end

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp drop_nil(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp scope_opts(opts) do
    opts
    |> Keyword.take([:tenant_id, :workspace_id])
    |> Keyword.put_new(:tenant_id, "default")
    |> Keyword.put_new(:workspace_id, "default")
  end
end
