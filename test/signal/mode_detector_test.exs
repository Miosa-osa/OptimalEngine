defmodule OptimalEngine.Signal.ModeDetectorTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Signal.ModeDetector

  defp mode(text), do: text |> ModeDetector.detect() |> elem(0)

  describe "prose stays linguistic" do
    test "prose that uses code keywords" do
      assert mode("We require a first class fix before the import of new accounts.") == :linguistic

      assert mode("Let me know if the function of this team is clear => happy to talk.") ==
               :linguistic

      assert mode("Please return the laptop and the class notes by Friday.") == :linguistic
    end

    test "a transcript with bracketed timestamps" do
      text = """
      [00:00:05] Alice: Thanks for joining, we review the export timeline.
      [00:00:21] Bob: Staging is done and production is scheduled for the 14th.
      [00:01:02] Alice: Then we require a dry run first.
      """

      assert mode(text) == :linguistic
    end

    test "subtitles keep their timing lines out of the evidence" do
      text = """
      1
      00:00:01,000 --> 00:00:04,200
      Welcome to the weekly planning call.

      2
      00:00:04,500 --> 00:00:08,900
      Today we cover hiring and the offsite.
      """

      assert mode(text) == :linguistic
    end

    test "a markdown spec with checklists" do
      text = """
      # Export Spec

      ## Requirements
      - Exports finish within thirty minutes.

      ## Acceptance Criteria
      - [ ] An archive exists for every workspace.
      """

      assert mode(text) == :linguistic
    end

    test "arrow flows in notes" do
      assert mode("signup -> verify email -> onboarding => first project created") == :linguistic
    end

    test "an email with header lines" do
      text = """
      From: dana@example.com
      Subject: Renewal

      Hi team,

      I will import the usage numbers before our call on Friday.

      Best,
      Dana
      """

      assert mode(text) == :linguistic
    end
  end

  describe "code" do
    test "source code in several languages" do
      assert mode("defmodule Foo do\n  def bar(x), do: x + 1\nend") == :code

      assert mode(
               "import csv\n\ndef load(path):\n    with open(path) as f:\n        return list(csv.reader(f))"
             ) == :code

      assert mode(
               "const total = items.reduce((sum, i) => sum + i.amount, 0);\nexport default total;"
             ) == :code

      assert mode("func main() {\n\tfmt.Println(\"ok\")\n}") == :code

      assert mode("SELECT region, COUNT(*)\nFROM orders\nWHERE amount > 10\nGROUP BY region;") ==
               :code

      assert mode("find . -name '*.log' -mtime +7 -print0 | xargs -0 rm -f") == :code
    end

    test "single-line snippets" do
      assert ModeDetector.code?("require Logger")
      assert ModeDetector.code?("{key: value}")
      assert ModeDetector.code?("data |> transform()")
      refute ModeDetector.code?("This is a plain sentence about a class trip.")
    end
  end

  describe "data" do
    test "delimited tables" do
      assert mode("date,region,orders\n2026-01-01,north,120\n2026-01-02,south,98") == :data
      assert mode("name\tvalue\nalpha\t1\nbeta\t2") == :data
      assert mode("datum;menge;preis\n2026-03-01;12;0,45\n2026-03-02;20;0,45") == :data
      assert mode("ID|NAME|BALANCE\n001|Mila|1520.75\n002|Arjun|0.00") == :data

      assert mode("id,comment\n1,\"Great, would recommend\"\n2,\"Late.\nFriendly driver.\"\n3,Fine") ==
               :data
    end

    test "JSON, JSON Lines and JSON with comments" do
      assert mode(~s({"event": "order.created", "items": [{"sku": "A-1"}]})) == :data
      assert mode(~s({"a": 1}\n{"a": 2})) == :data
      assert mode("{\n  // shared settings\n  \"tabSize\": 2\n}") == :data
    end

    test "config documents" do
      assert mode("service: worker\nreplicas: 3\nenv:\n  - name: LOG_LEVEL\n    value: info") ==
               :data

      assert mode("[server]\nhost = \"0.0.0.0\"\nport = 8080\n\n[[backends]]\nname = \"primary\"") ==
               :data

      assert mode("; printers\n[general]\ndefault = floor2\nretry_seconds = 30") == :data
      assert mode("APP_ENV=production\nLOG_LEVEL=info\nPORT=8080") == :data

      assert mode(
               "checkout.title=Review your order\ncheckout.pay=Pay now\ncheckout.error=Card declined"
             ) == :data
    end

    test "XML payloads, markdown tables and logs" do
      assert mode("<?xml version=\"1.0\"?>\n<orders>\n  <order id=\"1\"/>\n</orders>") == :data
      assert mode("| Region | Orders |\n|---|---|\n| North | 12 |\n| South | 9 |") == :data

      assert mode("""
             2026-06-18 09:41:12 INFO  [main] Starting scheduler
             2026-06-18 09:41:15 ERROR [worker-3] Job failed: timeout
             """) == :data

      assert mode(
               "time=2026-09-03T14:22:01Z level=info msg=\"started\" job=reminders\ntime=2026-09-03T14:22:09Z level=info msg=\"done\" job=reminders"
             ) ==
               :data
    end
  end

  describe "visual" do
    test "images, SVG and diagram definitions" do
      assert mode("![Lobby](lobby.jpg)\n![Room](room.jpg)") == :visual

      assert mode("<svg width=\"10\" height=\"10\">\n  <rect width=\"10\" height=\"10\"/>\n</svg>") ==
               :visual

      assert mode("flowchart LR\n  A[Request] --> B[Export]") == :visual
      assert mode("```mermaid\ngraph TD\n  A --> B\n```") == :visual
      assert mode("digraph deploy {\n  build -> test;\n}") == :visual
    end
  end

  describe "mixed" do
    test "prose that embeds a code block, a table or an image" do
      assert mode("""
             Install the client first.

             ```sh
             npm install client
             export CLIENT_KEY=changeme
             ```

             Then call the records endpoint and print the count.
             """) == :mixed

      assert mode("""
             The rate improved everywhere except the west.

             | Region | Value |
             |---|---|
             | North | 12 |
             | West | 4 |

             We expect the west to recover next month.
             """) == :mixed

      assert mode(
               "The new layout groups settings.\n\n![Layout](layout.png)\n\nPilot feedback was positive."
             ) ==
               :mixed
    end
  end

  describe "confidence and resolution" do
    test "short or structureless text is weak evidence" do
      assert ModeDetector.detect("ok") == {:linguistic, :weak}
      assert ModeDetector.detect("") == {:linguistic, :weak}

      assert ModeDetector.detect("We shipped the export fix this morning.") ==
               {:linguistic, :strong}
    end

    test "a valid declared mode wins over the content" do
      assert ModeDetector.resolve("plain words here and there", declared: "code") == :code
      assert ModeDetector.resolve("a,b\n1,2\n3,4", declared: :linguistic) == :linguistic
    end

    test "an invalid declared mode is ignored" do
      assert ModeDetector.resolve("a,b\n1,2\n3,4", declared: "dark") == :data
    end

    test "weak evidence falls back to the genre registry's single mode" do
      assert ModeDetector.resolve("Q3 budget", genre: "budget") == :data
      assert ModeDetector.resolve("ok", genre: "transcript") == :linguistic
      # "mixed" genres name a combination, not a mode the text can show alone
      assert ModeDetector.resolve("Spec draft", genre: "spec") == :linguistic
      assert ModeDetector.resolve("ok", genre: "not-a-genre") == :linguistic
    end

    test "strong content evidence beats the genre" do
      assert ModeDetector.resolve("a,b\n1,2\n3,4", genre: "note") == :data

      assert ModeDetector.resolve("The budget for the offsite is approved and final.",
               genre: "budget"
             ) ==
               :linguistic
    end
  end
end
