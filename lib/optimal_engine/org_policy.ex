defmodule OptimalEngine.OrgPolicy do
  @moduledoc """
  A tenant's org section and the policy that flows down from it.

  The org section is the workspace of a tenant that holds memory spanning
  workspaces: priorities, policy, people and relationships across the
  business (`docs/guides/recipes.md`, "Org brain"). It is designated with a
  tenant setting (`tenants.metadata.org_section`), so a tenant has at most
  one; designating or clearing it needs the `admin` scope and is recorded in
  the authority evidence chain.

  A versioned memory in the org section whose `metadata.kind` is `"policy"`
  (latest version, not forgotten) is org policy. Every workspace of the
  tenant reads it, labeled with `source_workspace_id` and `inherited: true`:
  in boot, in context assembly, in `GET /api/org-policy`, and by id
  (`GET /api/memory/:id`). Nothing else of the org section is readable from
  another workspace, and policy is written only with a key that can write
  the org section itself: the memory routes check the memory's own workspace
  against the key.

  Deny wins:

  * an org section that does not share upward (`share_up: "none"`,
    `OptimalEngine.Scope`) keeps its policy inside;
  * an Engine that does not serve the org section (workspace scope) has no
    org policy;
  * when Optimal Authority governs the tenant (`observe` or `enforce`), each
    inherited read is decided as `read` on `optimal://<org>/memory/<id>` in
    the org section, and a local deny matching the reading workspace applies
    too. Under `enforce` a refused item is withheld and counted; under
    `observe` it is shown. Either way the refusal is recorded as evidence.
  """

  alias OptimalEngine.API.{Actor, AuthorityPlug}
  alias OptimalEngine.Authority.{Decision, Evidence, LocalDeny, Settings}
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.{Scope, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @setting "org_section"
  @kind "policy"
  @max_memories 100

  @doc "The `metadata.kind` that marks a memory as policy."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "Whether a memory is marked as policy."
  @spec policy?(map()) :: boolean()
  def policy?(%{metadata: %{"kind" => @kind}}), do: true
  def policy?(_memory), do: false

  @doc """
  The tenant's org section as designated (`nil` when none): its workspace id,
  who designated it, and when.
  """
  @spec section(String.t()) :: map() | nil
  def section(tenant_id) do
    case Tenant.get(tenant_id) do
      {:ok, %{metadata: %{@setting => %{"workspace_id" => id} = section}}} when is_binary(id) ->
        section

      _ ->
        nil
    end
  end

  @doc """
  The workspace id of the tenant's org section when it can flow: designated,
  active, of this tenant, and served by this Engine. Otherwise `nil`.
  """
  @spec org_workspace(String.t()) :: String.t() | nil
  def org_workspace(tenant_id) do
    with %{"workspace_id" => id} <- section(tenant_id),
         {:ok, workspace} <- Workspace.get(id),
         true <- workspace.tenant_id == tenant_id and workspace.status == :active,
         true <- Scope.serves?(id) do
      id
    else
      _ -> nil
    end
  end

  @doc "The designation as `GET /api/org-section` reports it."
  @spec status(String.t()) :: map()
  def status(tenant_id) do
    section = section(tenant_id) || %{}
    org = org_workspace(tenant_id)
    share_up = if org, do: Scope.share_up(org)

    %{
      tenant_id: tenant_id,
      workspace_id: section["workspace_id"],
      designated_by: section["designated_by"],
      designated_at: section["designated_at"],
      active: not is_nil(org),
      share_up: share_up,
      flows_down: share_up == "read"
    }
  end

  @doc "Designates `workspace_id` (active, of this tenant) as the org section."
  @spec designate(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :archived | term()}
  def designate(tenant_id, workspace_id, by) do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found},
         true <- workspace.status == :active || {:error, :archived} do
      previous = (section(tenant_id) || %{})["workspace_id"]

      value = %{
        "workspace_id" => workspace_id,
        "designated_by" => by,
        "designated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      with {:ok, _metadata} <- Tenant.put_metadata(tenant_id, @setting, value) do
        record_change(tenant_id, workspace_id, previous, by)
        {:ok, Map.put(status(tenant_id), :previous, previous)}
      end
    end
  end

  @doc "Clears the tenant's org section. Policy stops flowing down."
  @spec clear(String.t(), String.t()) :: :ok | {:error, term()}
  def clear(tenant_id, by) do
    previous = (section(tenant_id) || %{})["workspace_id"]

    with {:ok, _metadata} <- Tenant.put_metadata(tenant_id, @setting, nil) do
      if previous, do: record_change(tenant_id, nil, previous, by)
      :ok
    end
  end

  @doc """
  The org policy `workspace_id` reads. Options: `:actor` (the reading
  principal, for authority decisions; default the local operator).

  Returns `%{org_workspace_id, inherited, count, memories, withheld,
  withheld_reason}`. Each memory carries `source_workspace_id` and
  `inherited`. For the org section itself the memories are its own
  (`inherited: false`).
  """
  @spec for_workspace(String.t(), String.t(), keyword()) :: map()
  def for_workspace(tenant_id, workspace_id, opts \\ []) do
    actor = Keyword.get(opts, :actor) || Actor.local_operator()

    case org_workspace(tenant_id) do
      nil ->
        result(nil, false, [], 0, nil)

      ^workspace_id ->
        result(workspace_id, false, label_all(memories(tenant_id, workspace_id), false), 0, nil)

      org ->
        if Scope.share_up(org) == "none" do
          result(org, true, [], 0, "org_section_not_shared")
        else
          {shown, withheld} =
            authorize(tenant_id, workspace_id, org, actor, memories(tenant_id, org))

          result(org, true, label_all(shown, true), length(withheld), nil)
        end
    end
  end

  @doc """
  Whether a memory read from `workspace_id` is org policy that workspace may
  read: a live policy memory of the tenant's org section, flowing down, and
  admitted by authority.
  """
  @spec readable?(String.t(), String.t(), map(), keyword()) :: boolean()
  def readable?(tenant_id, workspace_id, memory, opts \\ []) do
    org = org_workspace(tenant_id)

    with true <- not is_nil(org) and memory.workspace_id == org and workspace_id != org,
         true <- memory.tenant_id == tenant_id and policy?(memory),
         true <- memory.is_latest and not memory.is_forgotten,
         true <- Scope.share_up(org) != "none" do
      actor = Keyword.get(opts, :actor) || Actor.local_operator()
      match?({[_], []}, authorize(tenant_id, workspace_id, org, actor, [memory]))
    else
      _ -> false
    end
  end

  @doc "The `optimal://` address of a memory."
  @spec uri(map()) :: String.t()
  def uri(memory), do: "optimal://#{memory.workspace_id}/memory/#{memory.id}"

  @doc "A memory as policy views show it, labeled with its source."
  @spec label(map(), boolean()) :: map()
  def label(memory, inherited) do
    %{
      id: memory.id,
      uri: uri(memory),
      content: memory.content,
      version: memory.version,
      audience: memory.audience,
      citation_uri: memory.citation_uri,
      metadata: memory.metadata,
      created_at: memory.created_at,
      updated_at: memory.updated_at,
      source_workspace_id: memory.workspace_id,
      inherited: inherited
    }
  end

  defp label_all(memories, inherited), do: Enum.map(memories, &label(&1, inherited))

  defp memories(tenant_id, workspace_id) do
    case Versioned.list_by_kind(tenant_id, workspace_id, @kind, limit: @max_memories) do
      {:ok, memories} -> memories
      _ -> []
    end
  end

  defp result(org, inherited, memories, withheld, reason) do
    %{
      org_workspace_id: org,
      inherited: inherited,
      count: length(memories),
      memories: memories,
      withheld: withheld,
      withheld_reason: reason
    }
  end

  # Each inherited read is decided in the org section, and a local deny
  # scoped to the reading workspace applies as well. Refusals are recorded
  # once per read; under `observe` nothing is withheld.
  defp authorize(tenant_id, workspace_id, org, actor, memories) do
    case Settings.mode(tenant_id) do
      "off" ->
        {memories, []}

      mode ->
        data_class = AuthorityPlug.data_class(org)

        {allowed, refused} =
          Enum.split_with(memories, fn memory ->
            request = %{
              tenant_id: tenant_id,
              subject: actor,
              action: "read",
              resource: uri(memory),
              workspace_id: org,
              data_class: data_class
            }

            Decision.decide(request).effect == :allow and
              is_nil(LocalDeny.matching(tenant_id, %{request | workspace_id: workspace_id}))
          end)

        if refused != [] do
          Evidence.append(
            tenant_id,
            if(mode == "enforce", do: "decision.denied", else: "decision.observed"),
            %{
              subject: actor,
              action: "read",
              resource: "optimal://#{org}/memory",
              workspace_id: workspace_id,
              detail: %{
                "org_policy" => Enum.map(refused, & &1.id),
                "org_workspace_id" => org,
                "mode" => mode
              }
            }
          )
        end

        if mode == "enforce", do: {allowed, refused}, else: {memories, []}
    end
  end

  defp record_change(tenant_id, workspace_id, previous, by) do
    Evidence.append(tenant_id, "settings.changed", %{
      workspace_id: workspace_id || previous,
      detail: %{"org_section" => workspace_id, "previous" => previous, "by" => by}
    })
  end
end
