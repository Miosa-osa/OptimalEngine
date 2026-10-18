defmodule OptimalEngine.Authority.Requests do
  @moduledoc """
  Approval requests: how a subject obtains authority the policy says to ask
  for.

  A subject files a request for one action on one resource. If the policy
  allows it outright no request is kept; if it denies, the request is
  refused; if it asks, the request waits for an approver. Approval issues a
  grant to the requesting subject bound to the request. An approver may
  never approve their own request, and an approved request issues at most
  one grant.
  """

  alias OptimalEngine.Authority.Decision
  alias OptimalEngine.Store

  @fields ~w(subject action resource workspace_id data_class ttl_seconds command_sha256 justification)

  @doc "Files a request. Returns the stored request and the decision."
  @spec create(String.t(), map(), String.t()) ::
          {:ok, :allowed | map(), map()} | {:error, atom(), map()}
  def create(tenant_id, attrs, requested_by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    attrs =
      case Map.pop(attrs, "command") do
        {nil, attrs} ->
          attrs

        {command, attrs} ->
          Map.put(attrs, "command_sha256", OptimalEngine.Authority.Grants.command_hash(command))
      end

    decision =
      Decision.decide(%{
        tenant_id: tenant_id,
        workspace_id: attrs["workspace_id"],
        subject: attrs["subject"],
        action: attrs["action"],
        resource: attrs["resource"],
        data_class: attrs["data_class"]
      })

    cond do
      not Enum.all?(~w(subject action resource), &(is_binary(attrs[&1]) and attrs[&1] != "")) ->
        {:error, :subject_action_resource_required, %{decision: decision}}

      decision.effect == :allow ->
        {:ok, :allowed, decision}

      decision.effect == :deny ->
        {:error, :denied, %{decision: decision}}

      true ->
        id = "req_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
        row = Enum.map(@fields, &attrs[&1])

        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO authority_requests
              (id, tenant_id, subject, action, resource, workspace_id, data_class, ttl_seconds,
               command_sha256, justification, status, requested_by, decision)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?12)
            """,
            [id, tenant_id | row] ++
              [requested_by, Jason.encode!(Decision.to_map(decision))]
          )

        {:ok, request} = get(tenant_id, id)
        {:ok, request, decision}
    end
  end

  @doc """
  Approves a pending request. The approver must differ from both the subject
  and whoever filed it.
  """
  @spec approve(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def approve(tenant_id, id, approver), do: decide(tenant_id, id, approver, "approved", nil)

  @doc "Denies a pending request."
  @spec deny(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def deny(tenant_id, id, approver, reason \\ nil),
    do: decide(tenant_id, id, approver, "denied", reason)

  @doc "Whether an approved, unused request covers `request`."
  @spec approved_for?(String.t(), String.t(), map()) :: boolean()
  def approved_for?(tenant_id, id, request) do
    case get(tenant_id, id) do
      {:ok, %{status: "approved", grant_jti: nil} = approved} ->
        approved.subject == request.subject and approved.action == request.action and
          approved.resource == request.resource and approved.workspace_id == request.workspace_id and
          (approved.data_class || "internal") == request.data_class

      _ ->
        false
    end
  end

  @doc "Records which grant an approved request produced."
  @spec mark_used(String.t(), String.t(), String.t()) :: :ok
  def mark_used(tenant_id, id, jti) do
    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_requests SET grant_jti = ?3 WHERE tenant_id = ?1 AND id = ?2 AND grant_jti IS NULL",
        [tenant_id, id, jti]
      )

    :ok
  end

  @doc "One request."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id, id) do
    case Store.raw_query(select_sql("WHERE tenant_id = ?1 AND id = ?2"), [tenant_id, id]) do
      {:ok, [row]} -> {:ok, to_request(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Requests, newest first, optionally filtered by `:status`."
  @spec list(String.t(), keyword()) :: [map()]
  def list(tenant_id, opts \\ []) do
    {where, params} =
      case opts[:status] do
        nil -> {"WHERE tenant_id = ?1", [tenant_id]}
        status -> {"WHERE tenant_id = ?1 AND status = ?2", [tenant_id, status]}
      end

    {:ok, rows} =
      Store.raw_query(select_sql(where <> " ORDER BY requested_at DESC LIMIT 500"), params)

    Enum.map(rows, &to_request/1)
  end

  defp decide(tenant_id, id, approver, status, reason) do
    with {:ok, request} <- get(tenant_id, id),
         :ok <- not_self(request, approver),
         {:ok, 1} <-
           Store.transaction(fn txn ->
             Store.txn_execute(
               txn,
               """
               UPDATE authority_requests
               SET status = ?3, decided_by = ?4, decided_at = datetime('now'), decision_reason = ?5
               WHERE tenant_id = ?1 AND id = ?2 AND status = 'pending'
               """,
               [tenant_id, id, status, approver, reason]
             )
           end) do
      get(tenant_id, id)
    else
      {:ok, 0} -> {:error, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_self(request, approver) do
    if approver in [request.subject, request.requested_by],
      do: {:error, :self_approval},
      else: :ok
  end

  defp select_sql(where) do
    """
    SELECT id, tenant_id, subject, action, resource, workspace_id, data_class, ttl_seconds,
           command_sha256, justification, status, requested_by, requested_at, decided_by,
           decided_at, decision_reason, grant_jti
    FROM authority_requests #{where}
    """
  end

  defp to_request([
         id,
         tenant_id,
         subject,
         action,
         resource,
         workspace_id,
         data_class,
         ttl,
         command_sha256,
         justification,
         status,
         requested_by,
         requested_at,
         decided_by,
         decided_at,
         reason,
         grant_jti
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      subject: subject,
      action: action,
      resource: resource,
      workspace_id: workspace_id,
      data_class: data_class,
      ttl_seconds: ttl,
      command_sha256: command_sha256,
      justification: justification,
      status: status,
      requested_by: requested_by,
      requested_at: requested_at,
      decided_by: decided_by,
      decided_at: decided_at,
      decision_reason: reason,
      grant_jti: grant_jti
    }
  end
end
