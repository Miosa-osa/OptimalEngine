defmodule OptimalEngine.CorpusOrganizerTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.CorpusOrganizer

  test "routes canonical workspace markers with a clear margin" do
    result = CorpusOrganizer.classify("redacted onboarding with redacted and redacted")
    assert result.confidence == :high
    assert result.workspace_id == "default:clinic-iq"
  end

  test "keeps mixed or marker-free records in routing review" do
    assert CorpusOrganizer.classify("general weekly discussion").confidence == :unresolved

    result = CorpusOrganizer.classify("BusinessOS module for redacted")
    assert result.confidence == :review
    assert is_nil(result.workspace_id)
  end
end
