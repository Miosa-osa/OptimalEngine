defmodule OptimalEngine.Authority.Policy do
  @moduledoc """
  Policy packs: the written rules authority decides from (VSM System 5).

  A pack is a versioned, hash-identified document attached to one scope in a
  tenant: the whole tenant, one workspace, or one subject (a person, agent,
  or app principal). Publishing a new version supersedes the previous one in
  the same scope; old versions are kept so every decision can name the exact
  pack and hash it used.

      name: workspace-default
      rules:
        - id: members-read
          effect: allow            # allow | ask | deny
          subjects: ["user:*", "agent:*"]
          actions: [read, search]
          resources: ["optimal://default:example/**"]
          data_classes: [public, internal]
          max_ttl_seconds: 900
          ceiling: {records: 500}
          delegable: false
        - id: exports-need-approval
          effect: ask
          actions: [export]
        - id: no-restricted-for-agents
          effect: deny
          subjects: ["agent:*"]
          data_classes: [restricted]

  An absent matcher matches anything. Patterns use `*` for any run of
  characters except `/` and `**` for any run including `/`. Data classes are
  `public`, `internal`, `confidential`, and `restricted`.
  """

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Store

  @effects ~w(allow ask deny)
  @scope_types ~w(tenant workspace subject)
  @data_classes ~w(public internal confidential restricted)
  @matchers ~w(subjects actions resources data_classes)
  @rule_fields @matchers ++ ~w(id effect max_ttl_seconds ceiling delegable description)

  @type t :: %{
          id: String.t(),
          tenant_id: String.t(),
          scope_type: String.t(),
          scope_id: String.t(),
          name: String.t(),
          version: pos_integer(),
          hash: String.t(),
          document: map(),
          status: String.t(),
          published_by: String.t() | nil,
          published_at: String.t() | nil
        }

  @doc "The data classes, least to most sensitive."
  @spec data_classes() :: [String.t()]
  def data_classes, do: @data_classes

  @doc "Validates and normalizes a pack document (string keys, sorted lists)."
  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(%{} = document) do
    document = stringify(document)
    rules = Map.get(document, "rules")

    errors =
      []
      |> check(is_binary(document["name"]) and document["name"] != "", "name is required")
      |> check(is_list(rules), "rules must be a list")
      |> then(fn errors -> if is_list(rules), do: errors ++ rule_errors(rules), else: errors end)

    case errors do
      [] ->
        {:ok,
         %{
           "name" => document["name"],
           "rules" => Enum.map(rules, &normalize_rule/1)
         }}

      errors ->
        {:error, errors}
    end
  end

  def validate(_document), do: {:error, ["pack must be an object"]}

  @doc "The content hash of a normalized pack document."
  @spec hash(map()) :: String.t()
  def hash(document), do: CanonicalJSON.hash(document)

  @doc """
  Publishes `document` as the next version for the scope and supersedes the
  previous active version. Returns `{:ok, policy, previous}` where
  `previous` is the superseded pack or nil.
  """
  @spec publish(String.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, t(), t() | nil} | {:error, term()}
  def publish(tenant_id, scope_type, scope_id, document, published_by)
      when scope_type in @scope_types and is_binary(scope_id) do
    with {:ok, normalized} <- validate(document) do
      previous = active(tenant_id, scope_type, scope_id)
      version = next_version(tenant_id, scope_type, scope_id)
      id = "pol_" <> random_id()
      hash = hash(normalized)

      result =
        Store.transaction(fn txn ->
          with {:ok, _} <-
                 Store.txn_execute(
                   txn,
                   """
                   UPDATE authority_policies SET status = 'superseded'
                   WHERE tenant_id = ?1 AND scope_type = ?2 AND scope_id = ?3 AND status = 'active'
                   """,
                   [tenant_id, scope_type, scope_id]
                 ),
               {:ok, 1} <-
                 Store.txn_execute(
                   txn,
                   """
                   INSERT INTO authority_policies
                     (id, tenant_id, scope_type, scope_id, name, version, hash, document, status, published_by)
                   VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'active', ?9)
                   """,
                   [
                     id,
                     tenant_id,
                     scope_type,
                     scope_id,
                     normalized["name"],
                     version,
                     hash,
                     CanonicalJSON.encode(normalized),
                     published_by
                   ]
                 ) do
            {:ok, id}
          end
        end)

      with {:ok, ^id} <- result, {:ok, policy} <- get(tenant_id, id) do
        {:ok, policy, previous}
      end
    end
  end

  def publish(_tenant_id, _scope_type, _scope_id, _document, _published_by),
    do: {:error, ["scope must be tenant, workspace, or subject"]}

  @doc "One pack by id within a tenant."
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(tenant_id, id) do
    case Store.raw_query(select_sql("WHERE tenant_id = ?1 AND id = ?2"), [tenant_id, id]) do
      {:ok, [row]} -> {:ok, to_policy(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "The active pack for one scope, or nil."
  @spec active(String.t(), String.t(), String.t()) :: t() | nil
  def active(tenant_id, scope_type, scope_id) do
    case Store.raw_query(
           select_sql(
             "WHERE tenant_id = ?1 AND scope_type = ?2 AND scope_id = ?3 AND status = 'active'"
           ),
           [tenant_id, scope_type, scope_id]
         ) do
      {:ok, [row | _]} -> to_policy(row)
      _ -> nil
    end
  end

  @doc """
  The packs that govern a request, broadest first: the tenant pack, the
  workspace pack, then the subject pack.
  """
  @spec applicable(String.t(), String.t() | nil, String.t() | nil) :: [t()]
  def applicable(tenant_id, workspace_id, subject) do
    [
      active(tenant_id, "tenant", tenant_id),
      workspace_id && active(tenant_id, "workspace", workspace_id),
      subject && active(tenant_id, "subject", subject)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Every pack in the tenant, newest first, optionally only active ones."
  @spec list(String.t(), keyword()) :: [t()]
  def list(tenant_id, opts \\ []) do
    where =
      if Keyword.get(opts, :active_only, false),
        do: "WHERE tenant_id = ?1 AND status = 'active'",
        else: "WHERE tenant_id = ?1"

    {:ok, rows} =
      Store.raw_query(select_sql(where <> " ORDER BY published_at DESC, version DESC"), [tenant_id])

    Enum.map(rows, &to_policy/1)
  end

  @doc "Whether `rule` matches the request."
  @spec matches?(map(), map()) :: boolean()
  def matches?(rule, request) do
    match_any?(rule["subjects"], request.subject) and
      match_any?(rule["actions"], request.action) and
      match_any?(rule["resources"], request.resource) and
      class_matches?(rule["data_classes"], request.data_class)
  end

  @doc "Glob match: `*` stops at `/`, `**` crosses it."
  @spec glob?(String.t(), String.t() | nil) :: boolean()
  def glob?(_pattern, nil), do: false

  def glob?(pattern, value) do
    regex =
      pattern
      |> String.split("**")
      |> Enum.map(fn part ->
        part |> String.split("*") |> Enum.map(&Regex.escape/1) |> Enum.join("[^/]*")
      end)
      |> Enum.join(".*")

    Regex.match?(~r/\A#{regex}\z/su, value)
  end

  @doc """
  The ways `new` loosens `old` (nil means no previous pack): rules that move
  toward allow, matchers that widen on allow or ask rules, deny or ask rules
  that disappear or narrow, and limits that grow or vanish.
  """
  @spec loosening(map() | nil, map()) :: [map()]
  def loosening(old, new) do
    old_rules = index_rules(old)
    new_rules = index_rules(new)

    removed =
      for {id, rule} <- old_rules, not Map.has_key?(new_rules, id), rule["effect"] != "allow" do
        %{"rule" => id, "change" => "removed_#{rule["effect"]}_rule"}
      end

    added =
      for {id, rule} <- new_rules, not Map.has_key?(old_rules, id), rule["effect"] != "deny" do
        %{"rule" => id, "change" => "added_#{rule["effect"]}_rule"}
      end

    changed =
      for {id, new_rule} <- new_rules,
          Map.has_key?(old_rules, id),
          change <- rule_loosening(old_rules[id], new_rule) do
        %{"rule" => id, "change" => change}
      end

    removed ++ added ++ changed
  end

  # ---------------------------------------------------------------------------

  defp rule_loosening(old, new) do
    effect =
      if rank(new["effect"]) > rank(old["effect"]),
        do: ["effect_#{old["effect"]}_to_#{new["effect"]}"],
        else: []

    matchers =
      for field <- @matchers,
          widened_or_narrowed?(field, old, new) do
        "#{field}_#{if new["effect"] == "deny", do: "narrowed", else: "widened"}"
      end

    limits =
      []
      |> add_if(grew?(old["max_ttl_seconds"], new["max_ttl_seconds"]), "max_ttl_increased")
      |> add_if(ceiling_grew?(old["ceiling"], new["ceiling"]), "ceiling_increased")
      |> add_if(old["delegable"] != true and new["delegable"] == true, "delegation_enabled")

    effect ++ matchers ++ limits
  end

  # A deny rule loosens when it matches less; an allow or ask rule loosens
  # when it matches more. An absent matcher matches everything.
  defp widened_or_narrowed?(field, old, new) do
    old_values = old[field]
    new_values = new[field]

    if new["effect"] == "deny",
      do: covers?(old_values, new_values) and old_values != new_values,
      else: covers?(new_values, old_values) and old_values != new_values
  end

  # Whether matcher `a` matches at least everything `b` does.
  defp covers?(nil, _b), do: true
  defp covers?(_a, nil), do: false
  defp covers?(a, b), do: MapSet.subset?(MapSet.new(b), MapSet.new(a))

  defp grew?(_old, nil), do: false
  defp grew?(nil, _new), do: false
  defp grew?(old, new), do: new > old

  defp ceiling_grew?(old, new) when is_map(old) do
    new = new || %{}
    Enum.any?(old, fn {key, limit} -> not Map.has_key?(new, key) or new[key] > limit end)
  end

  defp ceiling_grew?(_old, _new), do: false

  defp add_if(list, true, item), do: list ++ [item]
  defp add_if(list, false, _item), do: list

  defp rank("deny"), do: 0
  defp rank("ask"), do: 1
  defp rank("allow"), do: 2

  defp index_rules(nil), do: %{}
  defp index_rules(%{"rules" => rules}), do: Map.new(rules, &{&1["id"], &1})

  defp match_any?(nil, _value), do: true
  defp match_any?(patterns, value), do: Enum.any?(patterns, &glob?(&1, value))

  defp class_matches?(nil, _class), do: true
  defp class_matches?(classes, class), do: "*" in classes or class in classes

  defp rule_errors(rules) do
    duplicate_ids =
      rules
      |> Enum.map(&(is_map(&1) && stringify(&1)["id"]))
      |> Enum.frequencies()
      |> Enum.filter(fn {id, count} -> is_binary(id) and count > 1 end)
      |> Enum.map(fn {id, _count} -> "duplicate rule id #{id}" end)

    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, index} -> single_rule_errors(rule, index) end)
    |> Kernel.++(duplicate_ids)
  end

  defp single_rule_errors(rule, index) when is_map(rule) do
    rule = stringify(rule)
    label = "rule #{rule["id"] || index}"

    []
    |> check(is_binary(rule["id"]) and rule["id"] != "", "#{label}: id is required")
    |> check(rule["effect"] in @effects, "#{label}: effect must be allow, ask, or deny")
    |> check(
      Map.keys(rule) -- @rule_fields == [],
      "#{label}: unknown fields #{inspect(Map.keys(rule) -- @rule_fields)}"
    )
    |> then(fn errors ->
      Enum.reduce(@matchers, errors, fn field, acc ->
        check(
          acc,
          valid_matcher?(rule[field]),
          "#{label}: #{field} must be a non-empty list of strings"
        )
      end)
    end)
    |> check(
      is_nil(rule["data_classes"]) or
        (is_list(rule["data_classes"]) and
           Enum.all?(rule["data_classes"], &(&1 in ["*" | @data_classes]))),
      "#{label}: unknown data class"
    )
    |> check(
      is_nil(rule["max_ttl_seconds"]) or
        (is_integer(rule["max_ttl_seconds"]) and rule["max_ttl_seconds"] > 0),
      "#{label}: max_ttl_seconds must be a positive integer"
    )
    |> check(
      valid_ceiling?(rule["ceiling"]),
      "#{label}: ceiling must map names to non-negative integers"
    )
    |> check(
      is_nil(rule["delegable"]) or is_boolean(rule["delegable"]),
      "#{label}: delegable must be a boolean"
    )
  end

  defp single_rule_errors(_rule, index), do: ["rule #{index}: must be an object"]

  defp valid_matcher?(nil), do: true
  defp valid_matcher?([_ | _] = values), do: Enum.all?(values, &(is_binary(&1) and &1 != ""))
  defp valid_matcher?(_values), do: false

  defp valid_ceiling?(nil), do: true

  defp valid_ceiling?(%{} = ceiling),
    do:
      Enum.all?(ceiling, fn {key, value} -> is_binary(key) and is_integer(value) and value >= 0 end)

  defp valid_ceiling?(_ceiling), do: false

  defp normalize_rule(rule) do
    rule = stringify(rule)

    rule
    |> Map.take(@rule_fields)
    |> Enum.map(fn
      {field, values} when field in @matchers -> {field, values |> Enum.uniq() |> Enum.sort()}
      other -> other
    end)
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp check(errors, true, _message), do: errors
  defp check(errors, _false, message), do: errors ++ [message]

  defp stringify(%{} = map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_value/1)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)

  defp stringify_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify_value(value), do: value

  defp next_version(tenant_id, scope_type, scope_id) do
    case Store.raw_query(
           "SELECT COALESCE(MAX(version), 0) FROM authority_policies WHERE tenant_id = ?1 AND scope_type = ?2 AND scope_id = ?3",
           [tenant_id, scope_type, scope_id]
         ) do
      {:ok, [[version]]} -> version + 1
      _ -> 1
    end
  end

  defp select_sql(where) do
    """
    SELECT id, tenant_id, scope_type, scope_id, name, version, hash, document, status,
           published_by, published_at
    FROM authority_policies #{where}
    """
  end

  defp to_policy([
         id,
         tenant_id,
         scope_type,
         scope_id,
         name,
         version,
         hash,
         document,
         status,
         by,
         at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      scope_type: scope_type,
      scope_id: scope_id,
      name: name,
      version: version,
      hash: hash,
      document: Jason.decode!(document),
      status: status,
      published_by: by,
      published_at: at
    }
  end

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
