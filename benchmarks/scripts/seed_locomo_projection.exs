#!/usr/bin/env elixir

alias OptimalEngine.Memory.Versioned
alias OptimalEngine.Workspace

[prepared_path, run_id] = System.argv()
Application.put_env(:optimal_engine, :root_path, System.tmp_dir!())

prepared_path
|> File.stream!()
|> Stream.map(&Jason.decode!/1)
|> Enum.with_index()
|> Enum.each(fn {conversation, conversation_index} ->
  slug = "benchmark-truememory-locomo-r#{run_id}-c#{conversation_index}"
  workspace_id = "default:#{slug}"

  case Workspace.create(%{
         id: workspace_id,
         slug: slug,
         name: "TrueMemory benchmark #{slug}",
         description: "Isolated, reproducible TrueMemory compatibility fixture workspace."
       }) do
    {:ok, _workspace} -> :ok
    {:error, _already_exists} -> :ok
  end

  conversation["messages"]
  |> Enum.with_index()
  |> Enum.each(fn {message, index} ->
    evidence_tag = message["evidence_tag"] || "message:#{index + 1}"

    content =
      "[#{evidence_tag}] [#{message["timestamp"] || ""}] " <>
        "#{message["speaker"] || "?"} to #{message["recipient"] || "?"}: " <>
        message["content"]

    {:ok, _memory} =
      Versioned.create(%{
        workspace_id: workspace_id,
        audience: "benchmark",
        content: content,
        dedup: :return_existing,
        metadata: %{
          "benchmark" => "truememory-compatible",
          "conversation_id" => conversation["conversation_id"],
          "evidence_tag" => evidence_tag,
          "timestamp" => message["timestamp"],
          "speaker" => message["speaker"],
          "recipient" => message["recipient"],
          "session" => message["session"],
          "turn_index" => message["turn_index"] || index,
          "modality_text" => message["modality_text"] || ""
        }
      })
  end)

  IO.puts("seeded #{length(conversation["messages"])} messages into #{workspace_id}")
end)
