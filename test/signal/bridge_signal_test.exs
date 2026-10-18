defmodule OptimalEngine.Bridge.SignalTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Bridge.Signal, as: Bridge
  alias OptimalEngine.Signal

  defp signal(fields), do: struct(Signal, Keyword.merge([title: "t", node: "inbox"], fields))

  describe "enhance_classification/2" do
    test "never replaces a resolved mode, including :linguistic" do
      sig = signal(mode: :linguistic, genre: "note", type: :inform)
      assert Bridge.enhance_classification(sig, "a,b\n1,2\n3,4").mode == :linguistic
    end

    test "never replaces a resolved genre, including \"note\"" do
      sig = signal(mode: :linguistic, genre: "note", type: :inform)
      assert Bridge.enhance_classification(sig, "Observed the export ran long.").genre == "note"
    end

    test "fills an unresolved mode from the text, not from a wrapper" do
      assert Bridge.enhance_classification(signal(mode: nil), "a,b\n1,2\n3,4").mode == :data

      assert Bridge.enhance_classification(signal(mode: nil), "We require a first class fix.").mode ==
               :linguistic

      assert Bridge.enhance_classification(signal(mode: nil), "defmodule A do\n  def b, do: 1\nend").mode ==
               :code
    end

    test "leaves an unresolved genre alone rather than defaulting it to chat" do
      assert Bridge.enhance_classification(signal(genre: nil), "hello there").genre == nil
    end
  end
end
