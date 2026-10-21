defmodule OptimalEngine.DataSteward.HierarchyRepair do
  @moduledoc """
  Repairs a tenant's workspace owners and node kinds from a mapping the
  caller supplies.

  Nothing here knows a name: which workspaces move to which organization, and
  which nodes take which kind, is the caller's. Every statement is bound to
  the caller's tenant. A target organization must belong to the tenant (the
  invariant `organization.tenant_id == workspace.tenant_id` holds after the
  repair as it did before), and a workspace named by the mapping must be an
  active workspace of the tenant.

  The mapping has two parts, both optional but not both empty. Keys are
  strings, as they arrive in JSON.

      %{
        "organizations" => [
          %{
            "organization_id" => "acme:ventures",        # the owner to move to
            "from_organization_id" => "acme:default",    # optional, the tenant's default organization
            "name_contains" => "Alpha",                  # a workspace whose name has this text
            "description_contains" => "Alpha"            # or whose description has it
          }
        ],
        "node_kinds" => [
          %{
            "workspace_id" => "acme:main",
            "from_kind" => "workspace",                  # optional, "workspace"
            "kinds" => %{"tasks" => "operation"}         # node slug => new kind
          }
        ]
      }

  An organization rule moves the tenant's active workspaces that are now in
  `from_organization_id` and whose name or description contains the text,
  compared without regard to case (ASCII letters), as the text and not as a
  pattern. It needs at least one of the two texts, so a rule never matches
  everything.

  A node rule retypes the active nodes of the workspace that have the slug
  and the current kind: the kind changes and the node takes the workspace's
  active node type of that name. A workspace with no such type leaves the
  node as it was.

  Returns `{:ok, %{workspace_owners_updated: n, nodes_retyped: n, actor_id: id}}`,
  `{:error, :mapping_required}`, `{:error, {:invalid_mapping, why}}`,
  `{:error, :organization_not_found}` or `{:error, :workspace_not_found}`.
  """

  alias OptimalEngine.{Organization, Store}

  @node_slug ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @kind ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  # A mapping runs in one Store transaction, which holds the Store while it
  # does; a mapping is a handful of rules, not a table.
  @max_rules 50
  @max_kinds 500

  @doc "Runs a mapping. Options: `:actor_id`, `:tenant_id`, `:mapping`."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    with {:ok, mapping} <- parse(Keyword.get(opts, :mapping)),
         {:ok, mapping} <- check(tenant_id, mapping) do
      Store.transaction(fn txn ->
        with {:ok, owners} <- move_workspaces(txn, mapping.organizations, tenant_id, actor_id),
             {:ok, nodes} <- retype_nodes(txn, mapping.node_kinds, tenant_id, actor_id) do
          {:ok, %{workspace_owners_updated: owners, nodes_retyped: nodes, actor_id: actor_id}}
        end
      end)
    end
  end

  # -- the mapping --------------------------------------------------------------

  defp parse(nil), do: {:error, :mapping_required}

  defp parse(mapping) when is_map(mapping) do
    mapping = stringify(mapping)
    organizations = List.wrap(mapping["organizations"])
    node_kinds = List.wrap(mapping["node_kinds"])

    cond do
      organizations == [] and node_kinds == [] ->
        {:error, :mapping_required}

      length(organizations) > @max_rules or length(node_kinds) > @max_rules ->
        invalid("a mapping has at most #{@max_rules} rules of each kind")

      true ->
        with {:ok, organizations} <- all(organizations, &organization_rule/1),
             {:ok, node_kinds} <- all(node_kinds, &node_rule/1),
             :ok <- check_size(node_kinds) do
          {:ok, %{organizations: organizations, node_kinds: node_kinds}}
        end
    end
  end

  defp parse(_), do: invalid("the mapping is an object")

  defp organization_rule(%{"organization_id" => owner} = rule)
       when is_binary(owner) and owner != "" do
    texts = Enum.map(~w(from_organization_id name_contains description_contains), &rule[&1])

    cond do
      not Enum.all?(texts, &optional_text?/1) ->
        invalid("organization rule texts are non-empty strings")

      is_nil(rule["name_contains"]) and is_nil(rule["description_contains"]) ->
        invalid("an organization rule needs name_contains or description_contains")

      true ->
        {:ok,
         %{
           organization_id: owner,
           from_organization_id: rule["from_organization_id"],
           name_contains: rule["name_contains"],
           description_contains: rule["description_contains"]
         }}
    end
  end

  defp organization_rule(_), do: invalid("an organization rule names an organization_id")

  defp node_rule(%{"workspace_id" => workspace_id, "kinds" => kinds} = rule)
       when is_binary(workspace_id) and is_map(kinds) and map_size(kinds) > 0 do
    from_kind = Map.get(rule, "from_kind", "workspace")

    if kind?(from_kind) and
         Enum.all?(kinds, fn {slug, kind} -> Regex.match?(@node_slug, slug) and kind?(kind) end) do
      {:ok, %{workspace_id: workspace_id, from_kind: from_kind, kinds: Map.to_list(kinds)}}
    else
      invalid("a node rule maps node slugs to kinds, from a kind")
    end
  end

  defp node_rule(_), do: invalid("a node rule names a workspace_id and its kinds")

  defp check_size(node_kinds) do
    if node_kinds |> Enum.map(&length(&1.kinds)) |> Enum.sum() > @max_kinds,
      do: invalid("a mapping retypes at most #{@max_kinds} nodes"),
      else: :ok
  end

  defp kind?(value), do: is_binary(value) and Regex.match?(@kind, value)
  defp optional_text?(value), do: is_nil(value) or (is_binary(value) and value != "")
  defp invalid(why), do: {:error, {:invalid_mapping, why}}

  defp all(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  # -- what the tenant owns --------------------------------------------------------

  # The organizations a rule names are the tenant's, and so are the
  # workspaces; one of another tenant is absent as far as the caller can tell.
  # Read before the transaction, because a tenant's default organization is
  # created on first use.
  defp check(tenant_id, mapping) do
    with {:ok, organizations} <- all(mapping.organizations, &check_organizations(tenant_id, &1)),
         :ok <- check_workspaces(tenant_id, mapping.node_kinds) do
      {:ok, %{mapping | organizations: organizations}}
    end
  end

  defp check_organizations(tenant_id, rule) do
    from = rule.from_organization_id || Organization.default_for(tenant_id)

    with :ok <- check_organization(tenant_id, rule.organization_id),
         :ok <- check_organization(tenant_id, from) do
      {:ok, %{rule | from_organization_id: from}}
    end
  end

  defp check_organization(tenant_id, organization_id) do
    case Store.raw_query("SELECT tenant_id, status FROM organizations WHERE id = ?1", [
           organization_id
         ]) do
      {:ok, [[^tenant_id, "active"]]} -> :ok
      {:ok, _} -> {:error, :organization_not_found}
      error -> error
    end
  end

  defp check_workspaces(tenant_id, rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case Store.raw_query("SELECT tenant_id FROM workspaces WHERE id = ?1 AND status = 'active'", [
             rule.workspace_id
           ]) do
        {:ok, [[^tenant_id]]} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :workspace_not_found}}
        error -> {:halt, error}
      end
    end)
  end

  # -- the statements ----------------------------------------------------------------

  defp move_workspaces(txn, rules, tenant_id, actor_id) do
    sum(rules, fn rule ->
      Store.txn_execute(
        txn,
        """
        UPDATE workspaces
        SET organization_id=?1,
            metadata=json_set(COALESCE(metadata,'{}'),'$.hierarchy_repaired_by',?2)
        WHERE tenant_id=?3 AND status='active' AND organization_id=?4
          AND EXISTS (
            SELECT 1 FROM organizations o
            WHERE o.id=?1 AND o.tenant_id=workspaces.tenant_id AND o.status='active'
          )
          AND (name LIKE ?5 ESCAPE '\\' OR description LIKE ?6 ESCAPE '\\')
        """,
        [
          rule.organization_id,
          actor_id,
          tenant_id,
          rule.from_organization_id,
          contains(rule.name_contains),
          contains(rule.description_contains)
        ]
      )
    end)
  end

  defp retype_nodes(txn, rules, tenant_id, actor_id) do
    sum(rules, fn rule ->
      sum(rule.kinds, fn {slug, kind} ->
        Store.txn_execute(
          txn,
          """
          UPDATE nodes
          SET kind=?1,
              node_type_id=(
                SELECT t.id FROM node_types t
                WHERE t.workspace_id=nodes.workspace_id AND t.tenant_id=nodes.tenant_id
                  AND t.slug=?1 AND t.lifecycle_state='active' LIMIT 1
              ),
              updated_at=datetime('now'),
              metadata=json_set(COALESCE(metadata,'{}'),'$.hierarchy_repaired_by',?2)
          WHERE tenant_id=?3 AND workspace_id=?4 AND slug=?5 AND kind=?6
            AND lifecycle_state='active'
            AND workspace_id IN (SELECT id FROM workspaces WHERE tenant_id=?3 AND status='active')
            AND EXISTS (
              SELECT 1 FROM node_types t
              WHERE t.workspace_id=nodes.workspace_id AND t.tenant_id=nodes.tenant_id
                AND t.slug=?1 AND t.lifecycle_state='active'
            )
          """,
          [kind, actor_id, tenant_id, rule.workspace_id, slug, rule.from_kind]
        )
      end)
    end)
  end

  defp sum(items, fun) do
    Enum.reduce_while(items, {:ok, 0}, fn item, {:ok, total} ->
      case fun.(item) do
        {:ok, changed} -> {:cont, {:ok, total + changed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The text as a LIKE pattern that matches it literally, anywhere.
  defp contains(nil), do: nil

  defp contains(text) do
    "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
  end
end
