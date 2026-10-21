defmodule OptimalEngine.Bridge.SignalTest do
  use ExUnit.Case, async: true

  import OptimalEngine.AtomProbe

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

  describe "structure from frontmatter" do
    defp complete(fields),
      do: signal([mode: :linguistic, genre: "spec", type: :inform, format: :markdown] ++ fields)

    defp structure_of(sig), do: Bridge.to_cloud_event(sig)["miosa_signal_structure"]

    test "text outside the known structure templates reads as the default, not as an atom" do
      structure = never_seen("zz_structure")
      sig = complete(structure: structure)

      assert structure_of(sig) == "default"
      refute_atom(structure)
    end

    test "such a signal audits like one with the default structure" do
      structure = never_seen("zz_structure")

      assert Bridge.audit(complete(structure: structure)) ==
               Bridge.audit(complete(structure: "default"))

      assert Bridge.measure_sn(complete(structure: structure)) ==
               Bridge.measure_sn(complete(structure: "default"))

      refute_atom(structure)
    end

    test "a structure is not left unresolved just because the analyzer does not know it" do
      structure = never_seen("zz_structure")

      resolved = Bridge.measure_sn(complete(structure: structure))
      unresolved = Bridge.measure_sn(complete(structure: nil))

      assert resolved > unresolved
    end

    test "a known template stays itself and an empty structure stays unresolved" do
      assert structure_of(complete(structure: "specification")) == "specification"
      assert structure_of(complete(structure: "")) == nil
      assert structure_of(complete(structure: nil)) == nil
    end
  end
end
