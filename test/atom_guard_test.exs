defmodule OptimalEngine.AtomGuardTest do
  @moduledoc """
  Keeps atom-creating calls out of `lib/`.

  The BEAM atom table is finite (about a million entries by default) and is
  never garbage collected. An atom created from data a caller, a peer or a
  file supplies is a denial of service that outlives a restart when the data
  persists. This test reads every file under `lib/` as syntax (so comments,
  docs and strings never count) and fails on a call that can create an atom
  from text:

    * `String.to_atom/1`, `List.to_atom/1`, `:erlang.binary_to_atom/2` and
      `:erlang.list_to_atom/1`, called or captured, and the interpolated atom
      `:"prefix_\#{text}"`, which compiles to `:erlang.binary_to_atom/2`;
    * `Module.concat/1,2`;
    * decoder options that turn keys into atoms: `keys: :atoms`,
      `keys: :atoms!` (Jason, Poison, Toml) and `atoms: true` (YamlElixir);
    * `:erlang.binary_to_term` without `:safe`;
    * `Code.eval_*`, `Code.string_to_quoted*` and `Code.compile_*`, which
      create atoms and run code.

  What to do about a failure:

    1. The text comes from a request, a stored row, a file, a peer or a model:
       do not create the atom. Look it up in an explicit list with
       `OptimalEngine.SafeAtom`, keep it as text, or reject it.
    2. The text is a compile-time literal or boot configuration: add an entry
       to `@reviewed` below with a one-line reason.

  `@pending` lists calls that are known to be unsafe and are fixed by another
  change. An entry there is not a decision: delete it when that change lands.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)

  @code_eval [
    :eval_string,
    :eval_file,
    :eval_quoted,
    :string_to_quoted,
    :string_to_quoted!,
    :compile_string,
    :compile_file,
    :compile_quoted
  ]

  # Reviewed calls that stay. `text` is part of the source line, so a new call
  # in the same file does not inherit the exemption.
  @reviewed [
    %{
      file: "lib/optimal_engine/architecture/registry.ex",
      kind: :string_to_atom,
      text: "String.to_atom(a.name)",
      reason: "the name of a built-in architecture, defined in code"
    },
    %{
      file: "lib/optimal_engine/knowledge/backend/mnesia.ex",
      kind: :binary_to_atom,
      text: ~S(:"mk_#{store_id}_#{suffix}"),
      reason:
        "mnesia names tables with atoms; store_id is the argument of Knowledge.open/2 and every caller in lib/ passes a literal"
    },
    %{
      file: "lib/optimal_engine/signal/genre_registry.ex",
      kind: :code_eval,
      text: "Code.eval_string(contents)",
      reason: "compile time: evaluates priv/genres.exs, which ships in the repository"
    },
    %{
      file: "lib/optimal_engine/conformance/checks.ex",
      kind: :code_eval,
      text: "Code.eval_file(path)",
      reason: "operator CLI: the extra checks file named by mix optimal.conformance --extra-checks"
    }
  ]

  # Known unsafe, owned by another change. Remove an entry when it is fixed.
  @pending [
    %{
      file: "lib/optimal_engine/context.ex",
      kind: :string_to_atom,
      text: "String.to_atom(str)",
      owner: "stored context text (mode, genre, type) read back as atoms; contexts replicate"
    },
    %{
      file: "lib/optimal_engine/signal.ex",
      kind: :string_to_atom,
      text: "String.to_atom(str)",
      owner: "stored signal text read back as atoms"
    },
    %{
      file: "lib/optimal_engine/bridge/signal.ex",
      kind: :string_to_atom,
      text: "String.to_atom(signal.structure)",
      owner: "a signal's structure text becomes an atom in the envelope"
    },
    %{
      file: "lib/optimal_engine/workspace.ex",
      kind: :string_to_atom,
      text: "String.to_atom(",
      owner: "stored role and status text (sync allow-list change)"
    },
    %{
      file: "lib/optimal_engine/memory/subscription.ex",
      kind: :string_to_atom,
      text: "String.to_atom",
      owner: "stored category, scope and status text (sync allow-list change)"
    },
    %{
      file: "lib/optimal_engine/memory/versioned.ex",
      kind: :string_to_atom,
      text: "String.to_atom(str)",
      owner: "stored relation text (sync allow-list change)"
    }
  ]

  describe "lib/" do
    test "creates no atom from text outside the reviewed list" do
      unexpected =
        Enum.reject(scan_lib(), fn finding ->
          Enum.any?(@reviewed ++ @pending, &covers?(&1, finding))
        end)

      assert unexpected == [], failure_message(unexpected)
    end

    test "every reviewed exemption still matches a call" do
      findings = scan_lib()

      stale = Enum.reject(@reviewed, fn entry -> Enum.any?(findings, &covers?(entry, &1)) end)

      assert stale == [],
             "These exemptions no longer match any call; delete them from @reviewed:\n" <>
               Enum.map_join(stale, "\n", &"  #{&1.file}: #{&1.text}")
    end

    test "every reviewed exemption states its reason in one line" do
      for entry <- @reviewed do
        assert is_binary(entry.reason) and String.trim(entry.reason) != "",
               "#{entry.file}: reason is empty"

        refute String.contains?(entry.reason, "\n"), "#{entry.file}: reason is more than a line"
      end
    end
  end

  describe "the scanner" do
    test "finds each call that can create an atom from text" do
      for {source, kind} <- [
            {"String.to_atom(x)", :string_to_atom},
            {"Enum.map(xs, &String.to_atom/1)", :string_to_atom},
            {"List.to_atom(x)", :list_to_atom},
            {":erlang.binary_to_atom(x, :utf8)", :binary_to_atom},
            {":erlang.list_to_atom(x)", :list_to_atom},
            {~S(:"prefix_#{x}"), :binary_to_atom},
            {"Module.concat(A, x)", :module_concat},
            {"Jason.decode!(x, keys: :atoms)", :atom_keys},
            {"Jason.decode(x, keys: :atoms!)", :atom_keys},
            {"YamlElixir.read_from_string(x, atoms: true)", :atom_keys},
            {"Plug.Parsers.init(json_decoder: {Jason, :decode!, [[keys: :atoms]]})", :atom_keys},
            {":erlang.binary_to_term(x)", :binary_to_term},
            {":erlang.binary_to_term(x, [])", :binary_to_term},
            {"Code.eval_string(x)", :code_eval},
            {"Code.string_to_quoted!(x)", :code_eval}
          ] do
        assert [%{kind: ^kind}] =
                 scan_source("defmodule M do\n  def f(x), do: #{source}\nend\n", "m.ex"),
               source
      end
    end

    test "ignores calls that cannot create an atom and text that only mentions them" do
      source = ~S'''
      defmodule M do
        @moduledoc """
        Never call String.to_atom(x) or :erlang.binary_to_atom(x, :utf8) on data.
        """

        # String.to_atom(x) in a comment
        @words ~w(a b c)a

        def f(x), do: String.to_existing_atom(x)
        def g(x), do: :erlang.binary_to_term(x, [:safe])
        def h(x), do: Jason.decode!(x, keys: :strings)
        def i(x), do: Module.safe_concat(A, x)
        def j, do: :"a literal atom"
        def k, do: "String.to_atom(x)"
        def l(x), do: YamlElixir.read_from_string(x, atoms: false)
        def m(x), do: Registry.start_link(keys: :unique, name: x)
      end
      '''

      assert scan_source(source, "m.ex") == []
    end

    test "reports the line and the text of the call" do
      source = "defmodule M do\n  def f(x) do\n    String.to_atom(x)\n  end\nend\n"

      assert [%{file: "m.ex", line: 3, text: "String.to_atom(x)"}] = scan_source(source, "m.ex")
    end
  end

  # ─── scanning ────────────────────────────────────────────────────────────

  defp scan_lib do
    root = Path.dirname(@lib)

    @lib
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> scan_source(Path.relative_to(path, root))
    end)
  end

  defp scan_source(source, file) do
    lines = String.split(source, "\n")

    {:ok, ast} = Code.string_to_quoted(source, file: file)

    {_ast, {_line, found}} =
      Macro.prewalk(ast, {1, []}, fn node, {line, acc} ->
        line = node_line(node) || line
        {node, {line, classify(node, line) ++ acc}}
      end)

    found
    |> Enum.sort_by(fn {_kind, line} -> line end)
    |> Enum.map(fn {kind, line} ->
      %{file: file, kind: kind, line: line, text: lines |> Enum.at(line - 1, "") |> String.trim()}
    end)
  end

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_node), do: nil

  defp classify({{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _, _}, line),
    do: [{:string_to_atom, line}]

  defp classify({{:., _, [{:__aliases__, _, [:List]}, :to_atom]}, _, _}, line),
    do: [{:list_to_atom, line}]

  defp classify({{:., _, [:erlang, fun]}, _, _}, line) when fun in [:binary_to_atom, :list_to_atom],
    do: [{fun, line}]

  defp classify({{:., _, [:erlang, :binary_to_term]}, _, args}, line) do
    if safe_term_options?(args), do: [], else: [{:binary_to_term, line}]
  end

  defp classify({{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, _}, line),
    do: [{:module_concat, line}]

  defp classify({{:., _, [{:__aliases__, _, [:Code]}, fun]}, _, _}, line) when fun in @code_eval,
    do: [{:code_eval, line}]

  defp classify({:keys, mode}, line) when mode in [:atoms, :atoms!], do: [{:atom_keys, line}]
  defp classify({:atoms, true}, line), do: [{:atom_keys, line}]
  defp classify(_node, _line), do: []

  defp safe_term_options?([_binary, options]) when is_list(options), do: :safe in options
  defp safe_term_options?(_args), do: false

  defp covers?(entry, finding) do
    entry.file == finding.file and entry.kind == finding.kind and
      String.contains?(finding.text, entry.text)
  end

  defp failure_message(unexpected) do
    """
    These calls can create an atom from text. The atom table is finite and never
    garbage collected, so text from a request, a stored row, a file, a peer or a
    model must not become an atom.

    #{Enum.map_join(unexpected, "\n", &"  #{&1.file}:#{&1.line}  #{&1.kind}  #{&1.text}")}

    Look the text up with OptimalEngine.SafeAtom, keep it as text, or reject it.
    If the text is a compile-time literal or boot configuration, add the call to
    @reviewed in test/atom_guard_test.exs with a one-line reason.
    """
  end
end
