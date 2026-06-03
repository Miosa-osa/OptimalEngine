defmodule OptimalEngine.WorkspaceTopology do
  @moduledoc """
  Lifecycle facade for workspace topology.

  This is the entry point callers should use when they are defining the shape
  of a workspace: Nodes, Node Types, and Node Relationships. The lower-level
  modules still own their persistence details, but this facade names the
  workspace operation instead of exposing raw tables.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology.{Node, NodeMember, NodeRelationship, NodeType}
  alias OptimalEngine.Workspace

  @standard_node_types [
    {"entity", "Entity", "Business, organization, institution, or operating entity."},
    {"department", "Department", "Functional area inside an entity."},
    {"team", "Team", "Group of people or agents working together."},
    {"project", "Project", "Bounded initiative with a target outcome."},
    {"operation", "Operation", "Ongoing process or business function."},
    {"learning", "Learning", "Knowledge acquisition or capability development."},
    {"person", "Person", "Individual human, agent, partner, customer, or stakeholder."},
    {"product", "Product", "Product, platform, system, or offer."},
    {"partnership", "Partnership",
     "Collaboration, joint venture, or external working relationship."},
    {"context", "Context", "Reference context with a lifecycle and relationships."}
  ]

  @type topology_change_request :: %{
          id: String.t(),
          tenant_id: String.t(),
          workspace_id: String.t(),
          request_type: String.t(),
          target_object_type: String.t(),
          target_object_id: String.t() | nil,
          proposed_payload: map(),
          reason: String.t() | nil,
          requested_by: String.t() | nil,
          review_status: String.t(),
          lifecycle_state: String.t(),
          audit_event_links: [map()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @doc "Create a workspace and seed the standard Node Types it needs to operate."
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, term()}
  def create_workspace(attrs) when is_map(attrs) do
    with {:ok, workspace} <- Workspace.create(attrs),
         :ok <- ensure_standard_node_types(workspace) do
      {:ok, workspace}
    end
  end

  @doc "Fetch a workspace by id."
  @spec get_workspace(String.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id), do: Workspace.get(id)

  @doc "Ensure a workspace has the standard Node Types."
  @spec ensure_standard_node_types(Workspace.t() | map()) :: :ok | {:error, term()}
  def ensure_standard_node_types(%{id: workspace_id, tenant_id: tenant_id}) do
    @standard_node_types
    |> Enum.reduce_while(:ok, fn {slug, name, description}, :ok ->
      case create_node_type(%{
             tenant_id: tenant_id,
             workspace_id: workspace_id,
             slug: slug,
             name: name,
             category: "standard",
             description: description
           }) do
        {:ok, _type} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Create or update a Node Type inside a workspace."
  @spec create_node_type(map()) :: {:ok, NodeType.t()} | {:error, term()}
  def create_node_type(attrs), do: NodeType.upsert(attrs)

  @doc "Create or update a Node inside a workspace."
  @spec create_node(map()) :: {:ok, Node.t()} | {:error, term()}
  def create_node(attrs), do: Node.upsert(attrs)

  @doc "Return a nested Node tree for a workspace."
  @spec node_tree(keyword()) :: {:ok, [map()]} | {:error, term()}
  def node_tree(opts \\ []), do: Node.tree(opts)

  @doc "Fetch a Node Type by slug within a workspace."
  @spec get_node_type(String.t(), keyword()) :: {:ok, NodeType.t()} | {:error, :not_found}
  def get_node_type(slug, opts \\ []), do: NodeType.get_by_slug(slug, opts)

  @doc "List Node Types in a workspace."
  @spec list_node_types(keyword()) :: {:ok, [NodeType.t()]} | {:error, term()}
  def list_node_types(opts \\ []), do: NodeType.list(opts)

  @doc "Create or update a typed relationship between two Nodes."
  @spec link_nodes(String.t(), String.t(), NodeRelationship.relationship_type(), keyword()) ::
          {:ok, NodeRelationship.t()} | {:error, term()}
  def link_nodes(source_node_id, target_node_id, relationship_type, opts \\ [])
      when is_binary(source_node_id) and is_binary(target_node_id) and is_atom(relationship_type) do
    opts
    |> Map.new()
    |> Map.merge(%{
      source_node_id: source_node_id,
      target_node_id: target_node_id,
      relationship_type: relationship_type
    })
    |> NodeRelationship.upsert()
  end

  @doc "Return topology relationships touching a Node."
  @spec relationships_for_node(String.t(), keyword()) ::
          {:ok, [NodeRelationship.t()]} | {:error, term()}
  def relationships_for_node(node_id, opts \\ []), do: NodeRelationship.for_node(node_id, opts)

  @doc "Attach a human, agent, team, service account, or tool principal to a Node."
  @spec add_node_member(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def add_node_member(node_id, principal_id, opts \\ []) do
    NodeMember.add(node_id, principal_id, opts)
  end

  @doc "List active members of a Node."
  @spec node_members(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def node_members(node_id, opts \\ []) do
    NodeMember.members_of(node_id, opts)
  end

  @doc "List active Nodes for a principal."
  @spec nodes_for_principal(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def nodes_for_principal(principal_id, opts \\ []) do
    NodeMember.nodes_of(principal_id, opts)
  end

  @doc """
  Record a proposed topology mutation that still needs review.

  This is the write path for agent-suggested or projection-edit-suggested
  workspace structure changes. It creates a pending request instead of silently
  mutating durable topology.
  """
  @spec propose_change(map()) :: {:ok, topology_change_request()} | {:error, term()}
  def propose_change(%{request_type: request_type, target_object_type: target_object_type} = attrs)
      when is_binary(request_type) and is_binary(target_object_type) do
    tenant_id = Map.get(attrs, :tenant_id, Tenant.default_id())
    workspace_id = Map.get(attrs, :workspace_id, "default")
    target_object_id = Map.get(attrs, :target_object_id)
    proposed_payload = Map.get(attrs, :proposed_payload, %{})
    reason = Map.get(attrs, :reason)
    requested_by = Map.get(attrs, :requested_by) || Map.get(attrs, :actor_id)
    review_status = Map.get(attrs, :review_status, "pending")
    lifecycle_state = Map.get(attrs, :lifecycle_state, "open")
    audit_event_links = Map.get(attrs, :audit_event_links, [])

    id =
      Map.get(attrs, :id) ||
        deterministic_id("topology_change", [
          workspace_id,
          request_type,
          target_object_type,
          target_object_id || "",
          Jason.encode!(proposed_payload),
          Integer.to_string(System.unique_integer([:positive]))
        ])

    sql = """
    INSERT INTO topology_change_requests (
      id, tenant_id, workspace_id, request_type, target_object_type,
      target_object_id, proposed_payload, reason, requested_by, review_status,
      lifecycle_state, audit_event_links
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    """

    with :ok <-
           Store.raw_execute(sql, [
             id,
             tenant_id,
             workspace_id,
             request_type,
             target_object_type,
             target_object_id,
             Jason.encode!(proposed_payload),
             reason,
             requested_by,
             review_status,
             lifecycle_state,
             Jason.encode!(audit_event_links)
           ]) do
      get_change_request(id, tenant_id: tenant_id, workspace_id: workspace_id)
    end
  end

  @doc "Fetch a topology change request by id."
  @spec get_change_request(String.t(), keyword()) ::
          {:ok, topology_change_request()} | {:error, :not_found}
  def get_change_request(id, opts \\ []) when is_binary(id) do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    workspace_id = Keyword.get(opts, :workspace_id)

    case Store.raw_query(
           "SELECT id, tenant_id, workspace_id, request_type, target_object_type, target_object_id, proposed_payload, reason, requested_by, review_status, lifecycle_state, audit_event_links, created_at, updated_at FROM topology_change_requests WHERE id = ?1 AND tenant_id = ?2" <>
             workspace_clause(workspace_id, 3),
           scoped_params([id, tenant_id], workspace_id)
         ) do
      {:ok, [row]} -> {:ok, row_to_change_request(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Review a pending topology change.

  `decision` may be `:approve` or `:reject`. By default, approval records the
  review decision only. Pass `apply: true` to apply supported request types:

    * `create_node`
    * `link_nodes`
    * `add_node_member` / `change_node_owner`

  Unsupported request types remain reviewed but unapplied.
  """
  @spec review_change_request(String.t(), :approve | :reject, keyword()) ::
          {:ok, %{request: topology_change_request(), applied: term() | nil}} | {:error, term()}
  def review_change_request(id, decision, opts \\ [])
      when is_binary(id) and decision in [:approve, :reject] do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    workspace_id = Keyword.get(opts, :workspace_id)
    reviewed_by = Keyword.get(opts, :reviewed_by) || Keyword.get(opts, :actor_id)
    apply? = Keyword.get(opts, :apply, false)
    review_status = if decision == :approve, do: "approved", else: "rejected"
    lifecycle_state = if decision == :approve, do: "reviewed", else: "closed"

    with {:ok, request} <- get_change_request(id, tenant_id: tenant_id, workspace_id: workspace_id),
         {:ok, applied} <- maybe_apply_change(request, decision, apply?),
         :ok <-
           Store.raw_execute(
             "UPDATE topology_change_requests SET review_status = ?1, lifecycle_state = ?2, reviewed_by = ?3, reviewed_at = datetime('now'), updated_at = datetime('now') WHERE id = ?4 AND tenant_id = ?5",
             [review_status, lifecycle_state, reviewed_by, id, tenant_id]
           ),
         {:ok, reviewed} <- get_change_request(id, tenant_id: tenant_id, workspace_id: workspace_id) do
      {:ok, %{request: reviewed, applied: applied}}
    end
  end

  defp maybe_apply_change(_request, :reject, _apply?), do: {:ok, nil}
  defp maybe_apply_change(_request, :approve, false), do: {:ok, nil}

  defp maybe_apply_change(%{request_type: "create_node"} = request, :approve, true) do
    payload = request.proposed_payload

    attrs =
      %{
        tenant_id: request.tenant_id,
        workspace_id: request.workspace_id,
        slug: fetch_payload!(payload, "slug"),
        name: fetch_payload!(payload, "name"),
        kind: parse_kind(Map.get(payload, "kind", "project")),
        parent_id: Map.get(payload, "parent_id"),
        description: Map.get(payload, "description"),
        metadata: Map.get(payload, "metadata", %{})
      }

    create_node(attrs)
  end

  defp maybe_apply_change(%{request_type: "link_nodes"} = request, :approve, true) do
    payload = request.proposed_payload

    link_nodes(
      fetch_payload!(payload, "source_node_id"),
      fetch_payload!(payload, "target_node_id"),
      parse_relationship_type(Map.get(payload, "relationship_type", "references")),
      tenant_id: request.tenant_id,
      workspace_id: request.workspace_id,
      metadata: Map.get(payload, "metadata", %{})
    )
  end

  defp maybe_apply_change(%{request_type: request_type} = request, :approve, true)
       when request_type in ["add_node_member", "change_node_owner"] do
    payload = request.proposed_payload
    node_id = Map.get(payload, "node_id") || request.target_object_id
    principal_id = Map.get(payload, "principal_id") || Map.get(payload, "owner_id")

    membership =
      if request_type == "change_node_owner",
        do: :owner,
        else: parse_membership(Map.get(payload, "membership", "internal"))

    case add_node_member(node_id, principal_id,
           tenant_id: request.tenant_id,
           workspace_id: request.workspace_id,
           membership: membership,
           role: Map.get(payload, "role")
         ) do
      :ok -> {:ok, %{node_id: node_id, principal_id: principal_id, membership: membership}}
      other -> other
    end
  end

  defp maybe_apply_change(_request, :approve, true), do: {:ok, nil}

  defp row_to_change_request([
         id,
         tenant_id,
         workspace_id,
         request_type,
         target_object_type,
         target_object_id,
         proposed_payload,
         reason,
         requested_by,
         review_status,
         lifecycle_state,
         audit_event_links,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      request_type: request_type,
      target_object_type: target_object_type,
      target_object_id: target_object_id,
      proposed_payload: decode_map(proposed_payload),
      reason: reason,
      requested_by: requested_by,
      review_status: review_status,
      lifecycle_state: lifecycle_state,
      audit_event_links: decode_list(audit_event_links),
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp fetch_payload!(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "missing required topology payload field #{inspect(key)}"
    end
  end

  defp parse_kind(value) when is_atom(value), do: value
  defp parse_kind(value) when is_binary(value), do: String.to_existing_atom(value)

  defp parse_relationship_type(value) when is_atom(value), do: value
  defp parse_relationship_type(value) when is_binary(value), do: String.to_existing_atom(value)

  defp parse_membership(value) when is_atom(value), do: value
  defp parse_membership(value) when is_binary(value), do: String.to_existing_atom(value)

  defp deterministic_id(prefix, parts) do
    hash =
      :crypto.hash(:sha256, Enum.join(parts, "|"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{hash}"
  end

  defp workspace_clause(nil, _position), do: ""
  defp workspace_clause(_workspace_id, position), do: " AND workspace_id = ?#{position}"

  defp scoped_params(params, nil), do: params
  defp scoped_params(params, workspace_id), do: params ++ [workspace_id]

  defp decode_map(nil), do: %{}
  defp decode_map(""), do: %{}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_list(nil), do: []
  defp decode_list(""), do: []

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end
end
