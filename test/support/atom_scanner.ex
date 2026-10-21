defmodule OptimalEngine.AtomScanner do
  @moduledoc """
  Test support: finds the calls in Elixir source that can create an atom from
  text, or run code (which creates atoms).

  The source is read as syntax, so comments, docs and strings never count. A
  finding is `%{file, kind, line, call, text}`: `call` is the offending call
  as written, `text` is its source line.

  | kind | what it is |
  | --- | --- |
  | `:string_to_atom`, `:list_to_atom`, `:binary_to_atom` | `String.to_atom`, `List.to_atom`, `:erlang.binary_to_atom`, `:erlang.list_to_atom`, called or captured. An interpolated atom `:"a_\#{x}"` compiles to `:erlang.binary_to_atom/2`. |
  | `:module_concat` | `Module.concat` |
  | `:atom_keys` | decoder options `keys: :atoms` and `atoms: true` (`keys: :atoms!` only looks atoms up and is not flagged) |
  | `:sigil_atoms` | `~w(...)a` with an interpolation |
  | `:binary_to_term` | `:erlang.binary_to_term` without `:safe` |
  | `:code_eval` | `Code.eval_*`, `Code.string_to_quoted*`, `Code.format_string!`, `Code.compile_*`, `Code.require_file`, `Code.load_file`, `EEx.eval_*` and `EEx.compile_*`, `:erl_scan`, `:erl_parse`, `:file.consult` and `:file.script`, `:io.fread` and `:io_lib.fread` with `~a` |
  | `:apply_atom_module`, `:apply_dynamic` | `apply/3`, `Kernel.apply/3`, `:erlang.apply/3` and `Function.capture/3` whose module is one of the modules above, or is not a literal |
  | `:dynamic_call` | `x.to_atom(...)`, `x.binary_to_atom(...)` or `x.list_to_atom(...)` on a receiver that is not a literal module |
  | `:import_atom_module` | `import` of one of the modules above that brings an atom-creating function in |

  Aliases of those modules (`alias String, as: S`) are followed within a file.
  """

  # A module is `{:ex, [:String]}` for an Elixir alias and `{:erl, :erlang}` for
  # an Erlang module.
  @code_eval [
    :eval_string,
    :eval_file,
    :eval_quoted,
    :eval_quoted_with_env,
    :string_to_quoted,
    :string_to_quoted!,
    :string_to_quoted_with_comments,
    :string_to_quoted_with_comments!,
    :format_string!,
    :format_file!,
    :compile_string,
    :compile_file,
    :compile_quoted,
    :require_file,
    :load_file
  ]

  @eex_eval [:eval_string, :eval_file, :compile_string, :compile_file]
  @file_eval [:consult, :script, :path_consult, :path_script]
  @atom_functions [:to_atom, :binary_to_atom, :list_to_atom]

  @risky_modules [
    {:ex, [:String]},
    {:ex, [:List]},
    {:ex, [:Module]},
    {:ex, [:Code]},
    {:ex, [:EEx]},
    {:ex, [:Kernel]},
    {:erl, :erlang},
    {:erl, :erl_scan},
    {:erl, :erl_parse},
    {:erl, :file},
    {:erl, :io},
    {:erl, :io_lib}
  ]

  # Functions of the risky modules an `import ..., only: [...]` could bring in.
  @risky_functions Enum.uniq(
                     [:to_atom, :concat, :binary_to_atom, :list_to_atom, :binary_to_term] ++
                       [:apply, :fread, :string, :tokens, :parse_form, :parse_exprs] ++
                       @code_eval ++ @eex_eval ++ @file_eval
                   )

  @doc "Findings in `source`, as read from `file`, ordered by line."
  @spec scan_source(String.t(), String.t()) :: [map()]
  def scan_source(source, file) do
    lines = String.split(source, "\n")
    {:ok, ast} = Code.string_to_quoted(source, file: file)
    aliases = collect_aliases(ast)

    {_ast, {_line, found}} =
      Macro.prewalk(ast, {1, []}, fn node, {line, acc} ->
        line = node_line(node) || line
        node = skip_declarations(node)
        new = Enum.map(classify(node, aliases), &{&1, line})
        {node, {line, new ++ acc}}
      end)

    found
    |> Enum.sort_by(fn {{_kind, _call}, line} -> line end)
    |> Enum.map(fn {{kind, call}, line} ->
      %{
        file: file,
        kind: kind,
        line: line,
        call: call,
        text: lines |> Enum.at(line - 1, "") |> String.trim()
      }
    end)
  end

  # ─── syntax helpers ──────────────────────────────────────────────────────

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_node), do: nil

  # The name in a function head, a `@spec` or a `@callback` is a declaration,
  # not a call: `def apply(a, b, c)` must not read as `apply/3`.
  defp skip_declarations({kind, meta, [head | rest]})
       when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate] do
    {kind, meta, [rename_head(head) | rest]}
  end

  defp skip_declarations({:@, meta, [{attr, attr_meta, _body}]})
       when attr in [:spec, :callback, :macrocallback, :type, :typep, :opaque] do
    {:@, meta, [{attr, attr_meta, []}]}
  end

  defp skip_declarations(node), do: node

  defp rename_head({:when, meta, [head | guards]}), do: {:when, meta, [rename_head(head) | guards]}
  defp rename_head({name, meta, args}) when is_atom(name), do: {:"$head", meta, args}
  defp rename_head(other), do: other

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [target, opts]} = node, acc when is_list(opts) ->
          case {module_ref(target, %{}), Keyword.get(opts, :as)} do
            {{_, _} = ref, {:__aliases__, _, [name]}} -> {node, Map.put(acc, name, ref)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp module_ref({:__MODULE__, _, context}, _aliases) when is_atom(context),
    do: {:ex, [:__MODULE__]}

  defp module_ref({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    case aliases do
      %{^first => {:ex, parts}} -> {:ex, parts ++ rest}
      %{^first => {:erl, _} = ref} when rest == [] -> ref
      _ -> {:ex, [first | rest]}
    end
  end

  defp module_ref(atom, _aliases) when is_atom(atom) and atom not in [nil, true, false],
    do: {:erl, atom}

  defp module_ref(_node, _aliases), do: :dynamic

  # ─── classification ──────────────────────────────────────────────────────

  defp classify({{:., _, [receiver, fun]}, _, args} = node, aliases) when is_atom(fun) do
    receiver |> module_ref(aliases) |> remote(fun, args, node, aliases)
  end

  defp classify({:apply, _, [_module, _fun, _args] = args} = node, aliases),
    do: apply_call(args, aliases, node)

  defp classify({:import, _, [module | opts]} = node, aliases) do
    ref = module_ref(module, aliases)

    if ref in @risky_modules and ref != {:ex, [:Kernel]} and imports_risky_function?(opts),
      do: [{:import_atom_module, call(node)}],
      else: []
  end

  defp classify({:sigil_w, _, [{:<<>>, _, parts}, modifiers]} = node, _aliases)
       when is_list(modifiers) do
    if ?a in modifiers and Enum.any?(parts, &(not is_binary(&1))),
      do: [{:sigil_atoms, call(node)}],
      else: []
  end

  defp classify({:keys, :atoms}, _aliases), do: [{:atom_keys, "keys: :atoms"}]
  defp classify({:atoms, true}, _aliases), do: [{:atom_keys, "atoms: true"}]
  defp classify(_node, _aliases), do: []

  defp remote({:ex, [:String]}, :to_atom, _args, node, _aliases),
    do: [{:string_to_atom, call(node)}]

  defp remote({:ex, [:List]}, :to_atom, _args, node, _aliases), do: [{:list_to_atom, call(node)}]
  defp remote({:ex, [:Module]}, :concat, _args, node, _aliases), do: [{:module_concat, call(node)}]

  defp remote({:ex, [:Code]}, fun, _args, node, _aliases) when fun in @code_eval,
    do: [{:code_eval, call(node)}]

  defp remote({:ex, [:EEx]}, fun, _args, node, _aliases) when fun in @eex_eval,
    do: [{:code_eval, call(node)}]

  defp remote({:erl, :erlang}, fun, _args, node, _aliases)
       when fun in [:binary_to_atom, :list_to_atom],
       do: [{fun, call(node)}]

  defp remote({:erl, :erlang}, :binary_to_term, args, node, _aliases) do
    if safe_term_options?(args), do: [], else: [{:binary_to_term, call(node)}]
  end

  defp remote({:erl, module}, _fun, _args, node, _aliases) when module in [:erl_scan, :erl_parse],
    do: [{:code_eval, call(node)}]

  defp remote({:erl, :file}, fun, _args, node, _aliases) when fun in @file_eval,
    do: [{:code_eval, call(node)}]

  defp remote({:erl, module}, :fread, args, node, _aliases) when module in [:io, :io_lib] do
    if fread_reads_atoms?(args), do: [{:code_eval, call(node)}], else: []
  end

  defp remote({:ex, [:Kernel]}, :apply, args, node, aliases), do: apply_call(args, aliases, node)
  defp remote({:erl, :erlang}, :apply, args, node, aliases), do: apply_call(args, aliases, node)

  defp remote({:ex, [:Function]}, :capture, args, node, aliases),
    do: apply_call(args, aliases, node)

  defp remote(:dynamic, fun, _args, node, _aliases) when fun in @atom_functions,
    do: [{:dynamic_call, call(node)}]

  defp remote(_module, _fun, _args, _node, _aliases), do: []

  defp apply_call([module, _fun, _args_or_arity], aliases, node) do
    case module_ref(module, aliases) do
      :dynamic -> [{:apply_dynamic, call(node)}]
      ref -> if ref in @risky_modules, do: [{:apply_atom_module, call(node)}], else: []
    end
  end

  defp apply_call(_args, _aliases, _node), do: []

  defp safe_term_options?([_binary, options]) when is_list(options), do: :safe in options
  defp safe_term_options?(_args), do: false

  # `:io.fread(prompt, format)` and `:io_lib.fread(format, input)`: the format
  # `~a` reads an atom. A format that is not a literal is flagged too.
  defp fread_reads_atoms?(args) do
    case Enum.flat_map(args, &literal_text/1) do
      [] -> true
      texts -> Enum.any?(texts, &String.contains?(&1, "~a"))
    end
  end

  defp literal_text(text) when is_binary(text), do: [text]

  defp literal_text({:sigil_c, _, [{:<<>>, _, [text]}, _modifiers]}) when is_binary(text),
    do: [text]

  defp literal_text(chars) when is_list(chars) and chars != [] do
    if Enum.all?(chars, &is_integer/1), do: [List.to_string(chars)], else: []
  end

  defp literal_text(_other), do: []

  # An import is risky unless it names only functions that are not.
  defp imports_risky_function?([opts]) when is_list(opts) do
    case Keyword.get(opts, :only) do
      only when is_list(only) ->
        Enum.any?(only, fn
          {name, _arity} -> name in @risky_functions
          _other -> true
        end)

      _other ->
        true
    end
  end

  defp imports_risky_function?(_opts), do: true

  defp call(node) do
    Macro.to_string(node)
  rescue
    _ -> "(call)"
  end
end
