defmodule OptimalEngine.AtomGuardTest do
  @moduledoc """
  Keeps atom-creating calls out of `lib/`, `config/` and `mix.exs`.

  The BEAM atom table is finite (about a million entries by default) and is
  never garbage collected. An atom created from data a caller, a peer or a
  file supplies is a denial of service that outlives a restart when the data
  persists. This test reads every file as syntax (so comments, docs and strings
  never count) and fails on a call that can create an atom from text, or run
  code, which creates atoms. `OptimalEngine.AtomScanner` documents what it
  finds: `String.to_atom`, `List.to_atom`, `:erlang.binary_to_atom` and
  `list_to_atom` (the interpolated atom `:"prefix_\#{text}"` included),
  `Module.concat`, decoder options that turn keys into atoms, `~w(...)a` with
  an interpolation, `:erlang.binary_to_term` without `:safe`, the `Code`, `EEx`,
  `:erl_scan`, `:erl_parse`, `:file.consult` and `:io.fread` families that parse
  text, and `apply/3`, `spawn` with a module, function and arguments, a
  `defdelegate` or an `import` that reaches any of them.

  What to do about a failure:

    1. The text comes from a request, a stored row, a file, a peer or a model:
       do not create the atom. Look it up in an explicit list with
       `OptimalEngine.SafeAtom`, keep it as text, or reject it.
    2. The text is a compile-time literal or boot configuration: add an entry
       to `@reviewed` below with a one-line reason.

  An entry names the file, the kind of finding, the call as written, and how
  many such calls the file holds. It fails when the file holds more or fewer,
  so a new call next to a reviewed one is caught, and an entry is deleted when
  its call goes.

  `@pending` lists calls that are known to be unsafe and are fixed by another
  change. It is held to the same counts: the change that fixes them deletes the
  entries.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.AtomScanner

  @root Path.expand("..", __DIR__)

  # Reviewed calls that stay.
  @reviewed [
    %{
      file: "config/runtime.exs",
      kind: :string_to_atom,
      call: "String.to_atom(claim_promotion_mode)",
      count: 1,
      reason:
        "boot configuration: OPTIMAL_CLAIM_PROMOTION_MODE, checked against its three accepted values just above"
    },
    %{
      file: "lib/optimal_engine/architecture/registry.ex",
      kind: :string_to_atom,
      call: "String.to_atom(a.name)",
      count: 1,
      reason: "the name of a built-in architecture, defined in code"
    },
    %{
      file: "lib/optimal_engine/knowledge/backend/mnesia.ex",
      kind: :binary_to_atom,
      call: ~S(:"mk_#{store_id}_#{suffix}"),
      count: 1,
      reason:
        "mnesia names tables with atoms; init/2 accepts only a short lowercase store id and a bounded number of stores"
    },
    %{
      file: "lib/optimal_engine/signal/genre_registry.ex",
      kind: :code_eval,
      call: "Code.eval_string(contents)",
      count: 1,
      reason: "compile time: evaluates priv/genres.exs, which ships in the repository"
    },
    %{
      file: "lib/optimal_engine/conformance/checks.ex",
      kind: :code_eval,
      call: "Code.eval_file(path)",
      count: 1,
      reason: "operator CLI: the extra checks file named by mix optimal.conformance --extra-checks"
    },
    %{
      file: "lib/optimal_engine/connectors/runner.ex",
      kind: :apply_dynamic,
      call: "apply(mod, callback, [])",
      count: 1,
      reason:
        "calls a no-argument function of a registered adapter module by a name written in code"
    },
    %{
      file: "lib/optimal_engine/signal/dispatcher.ex",
      kind: :apply_dynamic,
      call: "apply(mod, fun, [signal | args])",
      count: 1,
      reason: "invokes a handler that a caller registered in code as {module, function, args}"
    },
    %{
      file: "lib/optimal_engine/memory/versioned.ex",
      kind: :string_to_atom,
      call: "String.to_atom(str)",
      count: 1,
      reason:
        "stored relation text, turned into an atom only when it is one of the fixed relation names"
    }
  ]

  # Known unsafe, owned by another change. The change that fixes a call deletes
  # its entry.
  @pending []

  describe "the repository" do
    test "creates no atom from text outside the reviewed list" do
      unexpected = Enum.reject(scan_repository(), &covered?(@reviewed ++ @pending, &1))

      assert unexpected == [], failure_message(unexpected)
    end

    test "every reviewed exemption still matches exactly the calls it names" do
      assert_counts(@reviewed, "delete or correct it in @reviewed")
    end

    test "every pending entry still matches exactly the calls it names" do
      assert_counts(@pending, "delete or correct it in @pending when its fix lands")
    end

    test "every reviewed exemption states its reason in one line" do
      for entry <- @reviewed do
        assert is_binary(entry.reason) and String.trim(entry.reason) != "",
               "#{entry.file}: reason is empty"

        refute String.contains?(entry.reason, "\n"), "#{entry.file}: reason is more than a line"
      end
    end
  end

  describe "the scanner finds" do
    test "each call that creates an atom from text" do
      for {source, kind} <- [
            {"String.to_atom(x)", :string_to_atom},
            {"Enum.map(xs, &String.to_atom/1)", :string_to_atom},
            {"List.to_atom(x)", :list_to_atom},
            {":erlang.binary_to_atom(x, :utf8)", :binary_to_atom},
            {":erlang.list_to_atom(x)", :list_to_atom},
            {~S(:"prefix_#{x}"), :binary_to_atom},
            {"Module.concat(A, x)", :module_concat},
            {"Jason.decode!(x, keys: :atoms)", :atom_keys},
            {"YamlElixir.read_from_string(x, atoms: true)", :atom_keys},
            {"Plug.Parsers.init(json_decoder: {Jason, :decode!, [[keys: :atoms]]})", :atom_keys},
            {~S|~w(a#{x} b)a|, :sigil_atoms},
            {":erlang.binary_to_term(x)", :binary_to_term},
            {":erlang.binary_to_term(x, [])", :binary_to_term}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end
    end

    test "each call that parses text or runs code" do
      for source <- [
            "Code.eval_string(x)",
            "Code.eval_file(x)",
            "Code.eval_quoted(x)",
            "Code.string_to_quoted!(x)",
            "Code.string_to_quoted_with_comments(x)",
            "Code.format_string!(x)",
            "Code.compile_string(x)",
            "Code.require_file(x)",
            "Code.load_file(x)",
            "EEx.eval_string(x)",
            "EEx.eval_file(x)",
            "EEx.compile_string(x)",
            "EEx.compile_file(x)",
            ":erl_scan.string(x)",
            ":erl_parse.parse_form(x)",
            ":file.consult(x)",
            ":file.script(x)",
            ~S[:io.fread(~c"prompt", ~c"~a")],
            ~S[:io_lib.fread(~c"~a", x)],
            ":io.fread(prompt, format)"
          ] do
        assert [%{kind: :code_eval}] = scan("def f(x), do: #{source}"), source
      end
    end

    test "apply and its relatives when they can reach a risky module or a module held in a variable" do
      for {source, kind} <- [
            {"apply(String, :to_atom, [x])", :apply_atom_module},
            {"Kernel.apply(String, :to_atom, [x])", :apply_atom_module},
            {"apply(:erlang, :binary_to_atom, [x, :utf8])", :apply_atom_module},
            {":erlang.apply(Module, :concat, [x])", :apply_atom_module},
            {"Function.capture(List, :to_atom, 1)", :apply_atom_module},
            {"apply(Code, :eval_string, [x])", :apply_atom_module},
            {"apply(mod, fun, [x])", :apply_dynamic},
            {"Kernel.apply(@handler, fun, [x])", :apply_dynamic},
            {"Function.capture(mod, fun, 1)", :apply_dynamic},
            {"spawn(String, :to_atom, [x])", :apply_atom_module},
            {"spawn_link(mod, fun, [x])", :apply_dynamic},
            {"spawn_monitor(mod, fun, [x])", :apply_dynamic},
            {"Kernel.spawn(node, mod, fun, [x])", :apply_dynamic},
            {":erlang.spawn(Code, :eval_string, [x])", :apply_atom_module},
            {":erlang.spawn_opt(mod, fun, [x], [])", :apply_dynamic},
            {":erlang.spawn_opt(node, List, :to_atom, [x], [])", :apply_atom_module}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end
    end

    test "spawn with a module that is a literal and safe, or with a function, is not flagged" do
      assert [] = scan("def f(x), do: spawn(MyApp.Worker, :run, [x])")
      assert [] = scan("def f(x), do: spawn(fn -> x end)")
      assert [] = scan("def f(x), do: spawn_link(fn -> x end)")
      assert [] = scan("def f(x), do: :erlang.spawn(node, MyApp.Worker, :run, [x])")
    end

    test "an atom-creating option put into a keyword list or a map" do
      for source <- [
            "Keyword.put(opts, :keys, :atoms)",
            "Keyword.put_new(opts, :keys, :atoms)",
            "Keyword.replace!(opts, :atoms, true)",
            "Map.put(opts, :keys, :atoms)"
          ] do
        assert [%{kind: :atom_keys}] = scan("def f(opts), do: #{source}"), source
      end

      for source <- [
            "Keyword.put(opts, :keys, :atoms!)",
            "Keyword.put(opts, :keys, :strings)",
            "Keyword.put(opts, :atoms, false)",
            "Map.put(opts, :other, :atoms)"
          ] do
        assert [] = scan("def f(opts), do: #{source}"), source
      end
    end

    test "a delegate to a function that creates an atom or runs code" do
      for {source, kind} <- [
            {"defdelegate to_atom(text), to: String", :string_to_atom},
            {"defdelegate make(text), to: String, as: :to_atom", :string_to_atom},
            {"defdelegate to_atom(list), to: List", :list_to_atom},
            {"defdelegate binary_to_atom(text, enc), to: :erlang", :binary_to_atom},
            {"defdelegate concat(a, b), to: Module", :module_concat},
            {"defdelegate eval_string(text), to: Code", :code_eval},
            {"defdelegate to_atom(text), to: @target", :dynamic_call},
            {"defdelegate run(m, f, a), to: :erlang, as: :apply", :apply_dynamic},
            {"defdelegate run(m, f, a), to: Kernel, as: :apply", :apply_dynamic},
            {"defdelegate go(m, f, a), to: :erlang, as: :spawn", :apply_dynamic},
            {"defdelegate go(m, f, a), to: Task, as: :async", :apply_dynamic},
            {"defdelegate cap(m, f, a), to: Function, as: :capture", :apply_dynamic},
            {"defdelegate to_term(bin), to: :erlang, as: :binary_to_term", :binary_to_term}
          ] do
        assert [%{kind: ^kind}] = scan(source), source
      end

      # The list form defines several functions; each head is read.
      assert [%{kind: :string_to_atom}] =
               scan("defdelegate [to_atom(x), length(y)], to: String")

      assert [%{kind: :code_eval}, %{kind: :code_eval}] =
               scan("defdelegate [eval_string(x), eval_file(y)], to: Code")

      alias_source = "alias String, as: S\ndefdelegate to_atom(text), to: S"
      assert [%{kind: :string_to_atom}] = scan(alias_source)

      assert [] = scan("defdelegate length(text), to: String")
      assert [] = scan("defdelegate [length(x), upcase(y)], to: String")
      assert [] = scan("defdelegate go(f), to: :erlang, as: :spawn")
      assert [] = scan("defdelegate run(a, b), to: :erlang, as: :apply")
      assert [] = scan("defdelegate go(m, f, a), to: MyApp.Runner, as: :spawn")
      assert [] = scan("defdelegate start(opts), to: MyApp.Worker, as: :to_atom")
    end

    test "a piped call is read with the piped value as its first argument" do
      for {source, kind} <- [
            {"opts |> Keyword.put(:keys, :atoms)", :atom_keys},
            {"opts |> Keyword.put_new(:keys, :atoms)", :atom_keys},
            {"opts |> Map.put(:atoms, true)", :atom_keys},
            {"x |> String.to_atom()", :string_to_atom},
            {"x |> String.trim() |> String.to_atom()", :string_to_atom},
            {"x |> Code.eval_string()", :code_eval},
            {"String |> apply(:to_atom, [x])", :apply_atom_module},
            {"mod |> apply(fun, [x])", :apply_dynamic},
            {"mod |> Kernel.apply(fun, [x])", :apply_dynamic},
            {"mod |> spawn(fun, [x])", :apply_dynamic}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end

      for source <- [
            "opts |> Keyword.put(:keys, :atoms!)",
            "opts |> Map.put(:other, true)",
            "x |> String.trim() |> String.length()",
            "x |> Enum.map(fn y -> y end)",
            "MyApp.Worker |> apply(:run, [x])"
          ] do
        assert [] = scan("def f(x), do: #{source}"), source
      end
    end

    test "the module, function, arguments calls of Task, Node, :erpc, :rpc, :proc_lib and :timer" do
      for {source, kind} <- [
            {"Task.async(String, :to_atom, [x])", :apply_atom_module},
            {"Task.start(mod, fun, [x])", :apply_dynamic},
            {"Task.start_link(mod, fun, [x])", :apply_dynamic},
            {"Task.async_stream(xs, mod, fun, [x])", :apply_dynamic},
            {"Task.Supervisor.async(sup, mod, fun, [x])", :apply_dynamic},
            {"Task.Supervisor.async_nolink(sup, Code, :eval_string, [x])", :apply_atom_module},
            {"Task.Supervisor.start_child(sup, mod, fun, [x])", :apply_dynamic},
            {"Task.Supervisor.async_stream(sup, xs, mod, fun, [x])", :apply_dynamic},
            {"Node.spawn(node, mod, fun, [x])", :apply_dynamic},
            {"Node.spawn_link(node, String, :to_atom, [x])", :apply_atom_module},
            {":erpc.call(node, mod, fun, [x])", :apply_dynamic},
            {":erpc.cast(node, String, :to_atom, [x])", :apply_atom_module},
            {":rpc.call(node, mod, fun, [x])", :apply_dynamic},
            {":rpc.call(node, mod, fun, [x], 1000)", :apply_dynamic},
            {":rpc.multicall(nodes, mod, fun, [x])", :apply_dynamic},
            {":rpc.multicall(mod, fun, [x])", :apply_dynamic},
            {":proc_lib.spawn(mod, fun, [x])", :apply_dynamic},
            {":proc_lib.start_link(mod, fun, [x])", :apply_dynamic},
            {":proc_lib.spawn_opt(mod, fun, [x], [])", :apply_dynamic},
            {":timer.apply_after(1000, mod, fun, [x])", :apply_dynamic},
            {":erlang.spawn_request(mod, fun, [x], [])", :apply_dynamic}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end

      assert [%{kind: :apply_dynamic}] =
               scan("alias Task.Supervisor, as: TS\ndef f(x), do: TS.async(sup, mod, fun, [x])")
    end

    test "those calls with a literal module that is safe, or with a function, are not flagged" do
      for source <- [
            "Task.async(MyApp.Worker, :run, [x])",
            "Task.async(fn -> x end)",
            "Task.async_stream(xs, fn y -> y end, [])",
            "Task.Supervisor.async(sup, fn -> x end)",
            "Task.Supervisor.start_child(sup, MyApp.Worker, :run, [x])",
            "Node.spawn(node, fn -> x end)",
            ":erpc.call(node, MyApp.Worker, :run, [x])",
            ":rpc.call(node, MyApp.Worker, :run, [x])",
            ":proc_lib.spawn(MyApp.Worker, :run, [x])",
            ":timer.apply_after(1000, MyApp.Worker, :run, [x])",
            ":timer.tc(fun, args, :millisecond)",
            ":erlang.spawn_request(fun, opts)"
          ] do
        assert [] = scan("def f(x), do: #{source}"), source
      end
    end

    test ":rpc.multicall/4 is read as both of its forms" do
      for {source, kind} <- [
            # (Module, Function, Args, Timeout)
            {":rpc.multicall(mod, :run, [x], 1000)", :apply_dynamic},
            {":rpc.multicall(mod, fun, [x], :infinity)", :apply_dynamic},
            {":rpc.multicall(String, :to_atom, [x], 5000)", :apply_atom_module},
            # (Nodes, Module, Function, Args)
            {":rpc.multicall(nodes, mod, fun, [x])", :apply_dynamic},
            {":rpc.multicall([node()], Code, :eval_string, [x])", :apply_atom_module},
            # nothing tells them apart: either position counts
            {":rpc.multicall(a, b, c, d)", :apply_dynamic}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end

      for source <- [
            ":rpc.multicall(MyApp.Worker, :run, [x], 1000)",
            ":rpc.multicall(nodes, MyApp.Worker, :run, [x])",
            ":rpc.multicall([node()], MyApp.Worker, :run, [x])",
            ":rpc.multicall(MyApp.Worker, :run, [x])"
          ] do
        assert [] = scan("def f(x), do: #{source}"), source
      end
    end

    test ":erlang.hibernate/3, :proc_lib.hibernate/3 and :timer.tc with a module, function, arguments" do
      for {source, kind} <- [
            {":erlang.hibernate(mod, fun, [x])", :apply_dynamic},
            {":erlang.hibernate(Code, :eval_string, [x])", :apply_atom_module},
            {":proc_lib.hibernate(mod, fun, [x])", :apply_dynamic},
            {":timer.tc(mod, fun, [x])", :apply_dynamic},
            {":timer.tc(mod, :run, args)", :apply_dynamic},
            {":timer.tc(String, :to_atom, [x])", :apply_atom_module},
            {":timer.tc(mod, fun, [x], :millisecond)", :apply_dynamic}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end

      for source <- [
            ":erlang.hibernate(MyApp.Worker, :loop, [x])",
            ":timer.tc(MyApp.Worker, :run, [x])",
            # (Fun, Args, TimeUnit) runs no named function
            ":timer.tc(fun, args, :millisecond)",
            ":timer.tc(fn -> x end, [], :second)",
            ":timer.tc(fun, args, unit)",
            ":timer.tc(fun, args)"
          ] do
        assert [] = scan("def f(x), do: #{source}"), source
      end
    end

    test "a child spec's {module, function, args} start tuple is read like apply/3" do
      for {source, kind} <- [
            {"%{id: 1, start: {mod, :start_link, [x]}}", :apply_dynamic},
            {"[start: {mod, fun, args}]", :apply_dynamic},
            {"%{start: {String, :to_atom, [x]}}", :apply_atom_module}
          ] do
        assert [%{kind: ^kind}] = scan("def f(x), do: #{source}"), source
      end

      for source <- [
            "%{id: 1, start: {MyApp.Worker, :start_link, [x]}}",
            "%{start: {__MODULE__, :start_link, [x]}}",
            "%{start: start}",
            "%{stop: {mod, :stop, []}}",
            "{mod, :start_link, [x]}"
          ] do
        assert [] = scan("def f(x), do: #{source}"), source
      end
    end

    test "a plain alias, a grouped alias and an alias with options name their modules" do
      call = "def f(x), do: Supervisor.async(sup, mod, fun, [x])"

      for header <- [
            "alias Task.Supervisor",
            "alias Task.{Supervisor, Other}",
            "alias Task.Supervisor, warn: false"
          ] do
        assert [%{kind: :apply_dynamic}] = scan(header <> "\n" <> call), header
      end

      # Without the alias, Supervisor is Elixir's and has no such call.
      assert [] = scan(call)

      assert [] =
               scan("alias Task.Supervisor\ndef f(x), do: Supervisor.async(sup, fn -> x end)")
    end

    test "an alias cannot hide a standard library module the file also uses" do
      source = "alias MyApp.String\ndef f(x), do: String.to_atom(x)"
      assert [%{kind: :string_to_atom}] = scan(source)

      source = "alias MyApp.{Code, List}\ndef f(x), do: [Code.eval_string(x), List.to_atom(x)]"
      assert [:code_eval, :list_to_atom] = source |> scan() |> Enum.map(& &1.kind) |> Enum.sort()

      # Naming the module itself is harmless.
      assert [%{kind: :string_to_atom}] =
               scan("alias String\ndef f(x), do: String.to_atom(x)")
    end

    test "a to_atom-like function called on a module held in a variable" do
      for source <- ["mod.to_atom(x)", "@mod.binary_to_atom(x, :utf8)", "mod.list_to_atom(x)"] do
        assert [%{kind: :dynamic_call}] = scan("def f(x), do: #{source}"), source
      end
    end

    test "a risky module reached through an alias or an import" do
      assert [%{kind: :string_to_atom}] =
               scan("alias String, as: S\ndef f(x), do: S.to_atom(x)")

      assert [%{kind: :list_to_atom}] =
               scan("alias List, as: L\ndef f(x), do: L.to_atom(x)")

      assert [%{kind: :binary_to_atom}] =
               scan("alias :erlang, as: Erl\ndef f(x), do: Erl.binary_to_atom(x, :utf8)")

      assert [%{kind: :code_eval}] = scan("alias Code, as: C\ndef f(x), do: C.eval_string(x)")

      assert [%{kind: :apply_atom_module}] =
               scan("alias String, as: S\ndef f(x), do: apply(S, :to_atom, [x])")

      for source <- [
            "import String",
            "import String, only: [to_atom: 1]",
            "import String, except: [trim: 1]",
            "import :erlang",
            "import :erlang, only: [binary_to_atom: 2]",
            "import Module",
            "import Code, only: [eval_string: 1]"
          ] do
        assert [%{kind: :import_atom_module}] = scan(source), source
      end
    end

    test "the line and the call as written" do
      source = "defmodule M do\n  def f(x) do\n    String.to_atom(x)\n  end\nend\n"

      assert [%{file: "m.ex", line: 3, call: "String.to_atom(x)", text: "String.to_atom(x)"}] =
               AtomScanner.scan_source(source, "m.ex")
    end
  end

  describe "the scanner ignores" do
    test "calls that cannot create an atom, and text that only mentions them" do
      source = ~S'''
      defmodule M do
        @moduledoc """
        Never call String.to_atom(x) or :erlang.binary_to_atom(x, :utf8) on data.
        """

        # String.to_atom(x) in a comment
        @words ~w(a b c)a
        @fixed ~w(a b c)

        @spec apply(a, b, c) :: d
        @callback apply(a, b, c) :: d

        def apply(a, b, c), do: {a, b, c}
        defp apply(a, b, c) when is_atom(a), do: {a, b, c}

        def f(x), do: String.to_existing_atom(x)
        def g(x), do: :erlang.binary_to_term(x, [:safe])
        def h(x), do: Jason.decode!(x, keys: :strings)
        def i(x), do: Module.safe_concat(A, x)
        def j, do: :"a literal atom"
        def k, do: "String.to_atom(x)"
        def l(x), do: YamlElixir.read_from_string(x, atoms: false)
        def m(x), do: Registry.start_link(keys: :unique, name: x)
        def n(x), do: Jason.decode!(x, keys: :atoms!)
        def o(x), do: Architecture.apply(x, %{}, [])
        def p(x), do: apply(OptimalEngine.Workspace.Config, :get_section, [x, :grep, %{}])
        def q(x), do: apply(__MODULE__, :f, [x])
        def r(x), do: apply(fn y -> y end, [x])
        def s(x), do: :io.fread(~c"prompt", ~c"~d")
        def t(x), do: S.to_atom(x)
        def u(x), do: Foo.to_atom(x)
        def v(x), do: x.name
      end

      import String, only: [trim: 1]
      import Enum
      import Kernel, except: [inspect: 1]
      '''

      assert scan_all(source) == [], inspect(scan_all(source))
    end
  end

  # ─── scanning ────────────────────────────────────────────────────────────

  defp scan(source), do: scan_all("defmodule M do\n#{source}\nend\n")

  defp scan_all(source), do: AtomScanner.scan_source(source, "m.ex")

  defp scan_repository do
    files =
      Path.wildcard(Path.join(@root, "lib/**/*.{ex,exs}")) ++
        Path.wildcard(Path.join(@root, "config/**/*.exs")) ++ [Path.join(@root, "mix.exs")]

    files
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> AtomScanner.scan_source(Path.relative_to(path, @root))
    end)
  end

  defp covers?(entry, finding) do
    entry.file == finding.file and entry.kind == finding.kind and
      String.contains?(finding.call, entry.call)
  end

  defp covered?(entries, finding), do: Enum.any?(entries, &covers?(&1, finding))

  defp assert_counts(entries, advice) do
    findings = scan_repository()

    wrong =
      for entry <- entries,
          found = Enum.count(findings, &covers?(entry, &1)),
          found != entry.count do
        "  #{entry.file}: #{entry.call} is listed #{entry.count} time(s), found #{found}"
      end

    assert wrong == [],
           "These entries do not match the code; #{advice}:\n" <> Enum.join(wrong, "\n")
  end

  defp failure_message(unexpected) do
    """
    These calls can create an atom from text, or run code. The atom table is finite
    and never garbage collected, so text from a request, a stored row, a file, a
    peer or a model must not become an atom.

    #{Enum.map_join(unexpected, "\n", &"  #{&1.file}:#{&1.line}  #{&1.kind}  #{&1.call}")}

    Look the text up with OptimalEngine.SafeAtom, keep it as text, or reject it.
    If the text is a compile-time literal or boot configuration, add the call to
    @reviewed in test/atom_guard_test.exs with a one-line reason.
    """
  end
end
