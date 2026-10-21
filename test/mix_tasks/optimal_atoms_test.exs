defmodule Mix.Tasks.OptimalAtomsTest do
  @moduledoc """
  The CLI tasks that read a type, a modality, an intent or a connector kind from
  an argument look it up and never make an atom of the text.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import OptimalEngine.AtomProbe

  setup do
    Mix.Task.run("app.start")
    %{workspace: "mix-atoms-#{System.unique_integer([:positive])}"}
  end

  describe "mix optimal.grep" do
    test "a modality no atom exists for is passed on as text", %{workspace: workspace} do
      modality = never_seen("zz_modality")

      output =
        capture_io(fn ->
          Mix.Tasks.Optimal.Grep.run([
            "needle",
            "--workspace",
            workspace,
            "--modality",
            modality,
            "--intent",
            "record_fact",
            "--scale",
            "paragraph"
          ])
        end)

      assert output =~ "No matches found"
      refute_atom(modality)
    end

    test "a known intent and scale are still accepted", %{workspace: workspace} do
      output =
        capture_io(fn ->
          Mix.Tasks.Optimal.Grep.run([
            "needle",
            "--workspace",
            workspace,
            "--intent",
            "narrate",
            "--scale",
            "chunk",
            "--json"
          ])
        end)

      assert output =~ "[]"
    end
  end

  describe "mix optimal.search" do
    test "a type outside the known ones is ignored with a warning", %{workspace: workspace} do
      type = never_seen("zz_type")

      output =
        capture_io(fn ->
          Mix.Tasks.Optimal.Search.run(["needle", "--workspace", workspace, "--type", type])
        end)

      assert output =~ "unknown type '#{type}'"
      refute output =~ "Type filter"
      refute_atom(type)
    end

    test "a known type filters", %{workspace: workspace} do
      output =
        capture_io(fn ->
          Mix.Tasks.Optimal.Search.run(["needle", "--workspace", workspace, "--type", "memory"])
        end)

      assert output =~ "Type filter: memory"
    end
  end

  describe "mix optimal.ingest" do
    test "a type outside the known ones is refused with the accepted values" do
      type = never_seen("zz_type")

      assert_raise Mix.Error,
                   ~r/Unknown type '#{type}'. Use: signal, resource, memory, skill/,
                   fn ->
                     Mix.Tasks.Optimal.Ingest.run(["some text", "--type", type])
                   end

      refute_atom(type)
    end
  end

  describe "mix optimal.pull" do
    test "a connector kind that is not registered is reported and made no atom" do
      kind = never_seen("zz_kind")

      output =
        capture_io(fn ->
          capture_log(fn ->
            Mix.Tasks.Optimal.Pull.run(["--connector", kind])
          end)
        end)

      assert output =~ "connectors with errors: 1"
      assert output =~ kind
      assert output =~ "unknown_connector"
      refute_atom(kind)
    end
  end
end
