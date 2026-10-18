defmodule OptimalEngine.Operating.Protocol do
  @moduledoc """
  Operating documents: the agent operating protocol and other shared text an
  org edits once and every agent reads.

  `get/3` resolves a document for a workspace: the workspace's own version,
  else the tenant's, else the Engine default. The default protocol carries no
  tenant-specific text; an org replaces it with `put/6`.
  """

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Store

  @default_protocol """
  # Agent operating protocol

  1. Boot first: read the day, the open loops, recent decisions, and today's rhythm for the workspace before acting.
  2. Search before answering questions about past work, people, decisions, or commitments, and read the source when the summary is not enough.
  3. Cite what you use with its optimal:// address; never present memory as fact without its source.
  4. Keep scope: work inside the workspace you were given; ask before reading or writing another one.
  5. Capture as you go: new facts, corrections, and outcomes go back into the Engine with their source and date.
  6. Record decisions and tasks with an owner and a due date; a commitment without both is not recorded.
  7. Ask for authority you do not have instead of working around it; approvals are recorded.
  8. Match the receiver: brief for people who decide, full specification for people who build.
  9. Close with evidence: say what changed, how it was verified, and what is still unverified.
  """

  @defaults %{"protocol" => @default_protocol}

  @doc "The document kinds with an Engine default."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@defaults)

  @doc """
  Resolves a document for `workspace_id` (nil for the tenant). Returns
  `%{kind, content, source, hash}` where `source` is `workspace`, `tenant`,
  or `default`.
  """
  @spec get(String.t(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id, workspace_id, kind \\ "protocol") do
    candidates =
      [workspace_id && {"workspace", workspace_id}, {"tenant", tenant_id}]
      |> Enum.reject(&is_nil/1)

    stored =
      Enum.find_value(candidates, fn {scope_type, scope_id} ->
        case Store.raw_query(
               "SELECT content, updated_by, updated_at FROM operating_documents WHERE tenant_id = ?1 AND scope_type = ?2 AND scope_id = ?3 AND kind = ?4",
               [tenant_id, scope_type, scope_id, kind]
             ) do
          {:ok, [[content, by, at]]} -> {scope_type, content, by, at}
          _ -> nil
        end
      end)

    case {stored, @defaults[kind]} do
      {{source, content, by, at}, _default} ->
        {:ok,
         %{
           kind: kind,
           content: content,
           source: source,
           hash: CanonicalJSON.hash(content),
           updated_by: by,
           updated_at: at
         }}

      {nil, nil} ->
        {:error, :not_found}

      {nil, default} ->
        {:ok,
         %{
           kind: kind,
           content: default,
           source: "default",
           hash: CanonicalJSON.hash(default),
           updated_by: nil,
           updated_at: nil
         }}
    end
  end

  @doc "Stores a tenant or workspace version of a document."
  @spec put(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def put(tenant_id, scope_type, scope_id, kind, content, updated_by)
      when scope_type in ["tenant", "workspace"] and is_binary(content) do
    if String.trim(content) == "" do
      {:error, :empty_document}
    else
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO operating_documents (tenant_id, scope_type, scope_id, kind, content, hash, updated_by)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
          ON CONFLICT(tenant_id, scope_type, scope_id, kind) DO UPDATE SET
            content = excluded.content, hash = excluded.hash, updated_by = excluded.updated_by,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          """,
          [tenant_id, scope_type, scope_id, kind, content, CanonicalJSON.hash(content), updated_by]
        )

      get(tenant_id, if(scope_type == "workspace", do: scope_id), kind)
    end
  end

  def put(_tenant_id, _scope_type, _scope_id, _kind, _content, _updated_by),
    do: {:error, :invalid_scope}

  @doc "Removes a stored version so the next broader one applies again."
  @spec reset(String.t(), String.t(), String.t(), String.t()) :: :ok
  def reset(tenant_id, scope_type, scope_id, kind) do
    {:ok, _} =
      Store.raw_query(
        "DELETE FROM operating_documents WHERE tenant_id = ?1 AND scope_type = ?2 AND scope_id = ?3 AND kind = ?4",
        [tenant_id, scope_type, scope_id, kind]
      )

    :ok
  end
end
