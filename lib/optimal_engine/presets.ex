defmodule OptimalEngine.Presets do
  @moduledoc """
  Use-case presets: one step that sets an Engine up for what it is for
  (`optimal init --for <preset>`, `POST /api/init`, `mix optimal.init`).

  | Preset | Size profile | Engine scope | Data class | Storage use cases | Recipe |
  | --- | --- | --- | --- | --- | --- |
  | `agent` | agent | workspace | internal | desktop_local | agent memory |
  | `workspace` | workspace | workspace | internal | desktop_local | workspace brain |
  | `business` | business | org | confidential | desktop_local | org brain |
  | `app` | platform | workspace | internal | cloud_team | app database, search and RAG |
  | `tenant-per-customer` | workspace | workspace | confidential | desktop_local | one Engine per customer |

  Applying a preset, each part only when it is not already set (a preset
  never overwrites what an operator chose):

    1. creates the workspace (`slug`, `name`) with its data class, or marks an
       existing one;
    2. sets the workspace storage policy to the preset's use cases;
    3. publishes the default policy pack by data class for the tenant;
    4. turns authority on in `observe` (refusals are recorded, nothing is
       blocked; move to `enforce` after reviewing the evidence);
    5. declares the preset's genre repertoire (System 2 and the variety
       ratio, `OptimalEngine.Viability`).

  The machine size, Engine scope, and authentication are deployment settings;
  the result names the environment to set for them.
  """

  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.Settings
  alias OptimalEngine.Operating.Protocol
  alias OptimalEngine.Sizing
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace

  @presets [
    %{
      id: "agent",
      label: "Agent memory",
      profile: "agent",
      scope: "workspace",
      data_class: "internal",
      use_cases: ~w(desktop_local),
      repertoire: ~w(note message decision-log plan),
      recipe: "agent-memory",
      summary: "One agent's or one end user's memory in its own small Engine that scales to zero."
    },
    %{
      id: "workspace",
      label: "Workspace brain",
      profile: "workspace",
      scope: "workspace",
      data_class: "internal",
      use_cases: ~w(desktop_local),
      repertoire: ~w(email message transcript brief status-report plan decision-log),
      recipe: "workspace-brain",
      summary: "One client or team workspace with its Signals, loops, rhythm and agents."
    },
    %{
      id: "business",
      label: "Org brain",
      profile: "business",
      scope: "org",
      data_class: "confidential",
      use_cases: ~w(desktop_local),
      repertoire:
        ~w(email message transcript brief status-report plan decision-log proposal invoice contract report roadmap),
      recipe: "org-brain",
      summary: "A whole company in one Engine: every workspace, federated reads, the org view."
    },
    %{
      id: "app",
      label: "App database, search and RAG",
      profile: "platform",
      scope: "workspace",
      data_class: "internal",
      use_cases: ~w(cloud_team),
      repertoire: ~w(spec api-doc changelog ticket bug-report release-notes),
      recipe: "app-database",
      summary: "The data, search, and retrieval layer behind an application."
    },
    %{
      id: "tenant-per-customer",
      label: "One Engine per customer",
      profile: "workspace",
      scope: "workspace",
      data_class: "confidential",
      use_cases: ~w(desktop_local),
      repertoire: ~w(email message note brief),
      recipe: "engine-per-customer",
      summary:
        "White-label: each customer gets an Engine of their own, with its own keys and evidence."
    }
  ]

  @doc "Every preset."
  @spec list() :: [map()]
  def list, do: Enum.map(@presets, &Map.put(&1, :size, Sizing.fetch(&1.profile) |> elem(1)))

  @doc "A preset by id."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_preset}
  def fetch(id) do
    case Enum.find(@presets, &(&1.id == id)) do
      nil -> {:error, :unknown_preset}
      preset -> {:ok, preset}
    end
  end

  @doc """
  Applies a preset in `tenant_id`. Options: `:slug` and `:name` (the
  workspace; without a slug the tenant's default workspace is used when it
  exists), `:actor`.
  """
  @spec apply_preset(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_preset(tenant_id, preset_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, "local:operator")

    with {:ok, preset} <- fetch(preset_id),
         {:ok, workspace, workspace_step} <- workspace(tenant_id, preset, opts) do
      steps =
        [workspace_step] ++
          if(workspace,
            do: [
              storage_policy(workspace, preset, actor),
              repertoire(tenant_id, workspace, preset, actor)
            ],
            else: []
          ) ++
          [policy_pack(tenant_id, actor), authority_mode(tenant_id, actor)]

      {:ok,
       %{
         preset: Map.take(preset, [:id, :label, :summary]),
         workspace_id: workspace && workspace.id,
         applied: for({:applied, text} <- steps, do: text),
         skipped: for({:skipped, text} <- steps, do: text),
         size:
           Sizing.fetch(preset.profile)
           |> elem(1)
           |> Map.take([:id, :machine, :disk_gib, :scale_to_zero, :limits]),
         env: env(preset, workspace),
         recipe: "docs/guides/recipes.md##{preset.recipe}"
       }}
    end
  end

  # -- steps -------------------------------------------------------------------

  defp workspace(tenant_id, preset, opts) do
    case opts[:slug] do
      nil ->
        case Workspace.get(default_workspace(tenant_id)) do
          {:ok, workspace} ->
            mark(workspace, preset)

          _ ->
            {:ok, nil,
             {:skipped, "No workspace named and no default workspace; tenant settings only."}}
        end

      slug ->
        case Workspace.get_by_slug(slug, tenant_id) do
          {:ok, workspace} ->
            mark(workspace, preset)

          {:error, :not_found} ->
            create(tenant_id, slug, opts[:name] || slug, preset)
        end
    end
  end

  defp create(tenant_id, slug, name, preset) do
    case Workspace.create(%{
           tenant_id: tenant_id,
           organization_id: OptimalEngine.Organization.default_for(tenant_id),
           slug: slug,
           name: name,
           metadata: %{"data_class" => preset.data_class, "preset" => preset.id}
         }) do
      {:ok, workspace} ->
        {:ok, workspace,
         {:applied, "Created workspace #{workspace.id} (data class #{preset.data_class})."}}

      {:error, reason} ->
        {:error, {:workspace_failed, reason}}
    end
  end

  defp mark(workspace, preset) do
    metadata = workspace.metadata || %{}

    if Map.has_key?(metadata, "data_class") do
      {:ok, workspace,
       {:skipped, "Workspace #{workspace.id} keeps its data class #{metadata["data_class"]}."}}
    else
      metadata = Map.merge(metadata, %{"data_class" => preset.data_class, "preset" => preset.id})
      {:ok, updated} = Workspace.update(workspace.id, %{metadata: metadata})

      {:ok, updated,
       {:applied, "Workspace #{workspace.id} data class set to #{preset.data_class}."}}
    end
  end

  defp storage_policy(workspace, preset, actor) do
    case PolicyStore.get_policy(workspace.id) do
      {:ok, %{use_cases: use_cases}} when use_cases != [] ->
        {:skipped, "Storage policy keeps its use cases (#{Enum.join(use_cases, ", ")})."}

      _ ->
        case PolicyStore.put_policy(workspace.id, preset.use_cases, actor_id: actor) do
          {:ok, _policy} ->
            {:applied, "Storage policy set to #{Enum.join(preset.use_cases, ", ")}."}

          {:error, reason} ->
            {:skipped, "Storage policy not set: #{inspect(reason)}."}
        end
    end
  end

  defp repertoire(tenant_id, workspace, preset, actor) do
    case Protocol.get(tenant_id, workspace.id, "repertoire") do
      {:ok, %{source: source}} when source != "default" ->
        {:skipped, "A genre repertoire is already declared."}

      _ ->
        content = Enum.map_join(preset.repertoire, "\n", &("- " <> &1))
        {:ok, _} = Protocol.put(tenant_id, "workspace", workspace.id, "repertoire", content, actor)
        {:applied, "Declared the genre repertoire (#{length(preset.repertoire)} genres)."}
    end
  end

  defp policy_pack(tenant_id, actor) do
    {:ok, [[active]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM authority_policies WHERE tenant_id = ?1 AND scope_type = 'tenant' AND status = 'active'",
        [tenant_id]
      )

    if active > 0 do
      {:skipped, "A tenant policy pack is already active."}
    else
      case Authority.publish_policy(tenant_id, "tenant", tenant_id, Authority.default_pack(), actor) do
        {:ok, _policy} -> {:applied, "Published the default policy pack by data class."}
        {:error, reason} -> {:skipped, "Policy pack not published: #{inspect(reason)}."}
      end
    end
  end

  defp authority_mode(tenant_id, actor) do
    case Settings.mode(tenant_id) do
      "off" ->
        :ok = Authority.set_mode(tenant_id, "observe", actor)
        {:applied, "Authority on in observe: refusals are recorded, nothing is blocked."}

      mode ->
        {:skipped, "Authority stays in #{mode}."}
    end
  end

  defp env(preset, workspace) do
    %{
      "OPTIMAL_SIZE_PROFILE" => preset.profile,
      "OPTIMAL_ENGINE_SCOPE" => preset.scope,
      "OPTIMAL_AUTH_REQUIRED" => "true"
    }
    |> then(fn env ->
      if preset.scope == "workspace" and workspace,
        do: Map.put(env, "OPTIMAL_ENGINE_WORKSPACE", workspace.id),
        else: env
    end)
  end

  defp default_workspace("default"), do: Workspace.default_id()
  defp default_workspace(tenant_id), do: tenant_id <> ":default"
end
