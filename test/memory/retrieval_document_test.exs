defmodule OptimalEngine.Memory.Versioned.RetrievalDocumentTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.RetrievalDocument

  test "parses benchmark headers into contextual fields without evaluation leakage" do
    memory = %Versioned{
      content: "[D9:7] [2024-01-12] John to Tim: Barcelona is a must-visit",
      metadata: %{
        "benchmark" => "locomo",
        "category" => 1,
        "evidence_tag" => "D9:7",
        "session" => "January trip"
      }
    }

    assert RetrievalDocument.serialize(memory) ==
             "profile: retrieval-document-v1\n" <>
               "speaker: John\n" <>
               "recipient: Tim\n" <>
               "date: 2024-01-12\n" <>
               "session: January trip\n" <>
               "content: Barcelona is a must-visit"

    document = RetrievalDocument.serialize(memory)
    refute document =~ "D9:7"
    refute document =~ "locomo"
    refute document =~ "category"
  end

  test "ordinary memories retain useful governed metadata fields" do
    memory = %Versioned{
      content: "my new vintage camera",
      metadata: %{
        speaker: "Dave",
        recipient: "Alice",
        timestamp: "2024-02-04",
        evidence_tag: "forbidden"
      }
    }

    document = RetrievalDocument.serialize(memory)

    assert document =~ "speaker: Dave"
    assert document =~ "recipient: Alice"
    assert document =~ "date: 2024-02-04"
    assert document =~ "content: my new vintage camera"
    refute document =~ "forbidden"
  end

  test "hash changes when searchable metadata changes" do
    first = %Versioned{content: "same content", metadata: %{speaker: "Dave"}}
    second = %Versioned{content: "same content", metadata: %{speaker: "Alice"}}

    refute RetrievalDocument.hash(first) == RetrievalDocument.hash(second)
  end

  test "serialization is stable across atom and string metadata keys" do
    atoms = %Versioned{content: "same content", metadata: %{speaker: "Dave"}}
    strings = %Versioned{content: "same content", metadata: %{"speaker" => "Dave"}}

    assert RetrievalDocument.serialize(atoms) == RetrievalDocument.serialize(strings)
  end

  test "multimodal profile includes governed extraction text but not benchmark labels" do
    memory = %Versioned{
      content: "Take a look at this.",
      metadata: %{
        modality_text: "a painting of a sunset over a lake",
        query: "painting sunrise",
        evidence_tag: "D1:12"
      }
    }

    document = RetrievalDocument.serialize(memory, RetrievalDocument.multimodal_profile())

    assert document =~ "modality_text: a painting of a sunset over a lake"
    refute document =~ "painting sunrise"
    refute document =~ "D1:12"
  end
end
