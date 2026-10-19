defmodule OptimalEngine.API.AuthorityPlug do
  @moduledoc """
  Puts the Engine's own data routes behind Optimal Authority.

  Runs after `OptimalEngine.API.PermissionPlug`. When the tenant's mode
  (`OptimalEngine.Authority.Settings`) is `off` nothing changes. Otherwise
  each request is described as an authority request:

  * subject - the acting principal (`OptimalEngine.API.Actor`);
  * action - `read`, `search`, `write`, `erase`, `export`, `sync`, or
    `admin`, from the method and route;
  * resource - `optimal://<workspace>/<route path>`;
  * data class - the workspace's `metadata.data_class`, default `internal`.

  A request carrying `x-optimal-grant` is admitted against that grant (exact
  binding, one use). Otherwise the decision point answers. In `enforce` a
  refusal returns 403 with the reason; in `observe` it is recorded as
  evidence and the request continues.

  Authority, key, status, and version routes are never governed here: they
  have their own checks, and governing them could lock out the people who
  fix policy.
  """

  @behaviour Plug

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Authority.{Admission, Decision, Evidence, Settings}

  @ungoverned ~w(authority auth principals version status metrics)
  @search_roots ~w(search grep rag recall assemble reconstruct)
  @admin_roots ~w(backup maintenance)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "OPTIONS"} = conn, _opts), do: conn
  def call(%{halted: true} = conn, _opts), do: conn

  def call(%{path_info: ["api", root | _]} = conn, _opts) when root not in @ungoverned do
    tenant_id = conn.assigns[:current_tenant] || "default"

    case Settings.mode(tenant_id) do
      "off" -> conn
      mode -> govern(conn, tenant_id, mode)
    end
  end

  def call(conn, _opts), do: conn

  @doc "The authority request a connection describes."
  @spec describe(Plug.Conn.t(), String.t()) :: map()
  def describe(conn, tenant_id) do
    workspace_id = conn.assigns[:workspace_id]
    ["api" | route] = conn.path_info

    %{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      subject: Actor.of(conn),
      action: action(conn.method, route),
      resource: "optimal://#{workspace_id || "engine"}/#{Enum.join(route, "/")}",
      data_class: data_class(workspace_id)
    }
  end

  defp govern(conn, tenant_id, mode) do
    request = describe(conn, tenant_id)

    case get_req_header(conn, "x-optimal-grant") do
      [token | _] -> admit(conn, token, request, mode)
      [] -> decide(conn, request, mode)
    end
  end

  defp admit(conn, token, request, mode) do
    case Admission.admit(token, request) do
      {:ok, admission} ->
        assign(conn, :authority_admission, admission)

      {:error, reason} ->
        refuse(conn, mode, %{error: "grant_denied", reason: Atom.to_string(reason)})
    end
  end

  defp decide(conn, request, mode) do
    decision = Decision.decide(request)

    case decision.effect do
      :allow ->
        assign(conn, :authority_decision, decision)

      effect ->
        kind = if mode == "enforce", do: decision_kind(effect), else: "decision.observed"

        Evidence.append(request.tenant_id, kind, %{
          subject: request.subject,
          action: request.action,
          resource: request.resource,
          workspace_id: request.workspace_id,
          detail: %{
            "effect" => Atom.to_string(effect),
            "reason" => decision.reason,
            "rule" => decision.rule_id,
            "policy_sha256" => decision.policy_hash,
            "mode" => mode
          }
        })

        error = if effect == :ask, do: "approval_required", else: "authority_denied"
        refuse(conn, mode, %{error: error, reason: decision.reason, rule: decision.rule_id})
    end
  end

  defp refuse(conn, "enforce", body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(body))
    |> halt()
  end

  defp refuse(conn, _observe, body), do: assign(conn, :authority_observed, body)

  defp decision_kind(:deny), do: "decision.denied"
  defp decision_kind(:ask), do: "decision.ask"

  defp action(method, [root | _]) when root in @admin_roots and method != "GET", do: "admin"
  defp action("POST", ["data", "collections", _name, "query"]), do: "search"
  defp action(_method, ["data", "keys" | _]), do: "admin"
  defp action("POST", ["data", route]) when route in ["collections", "migrations"], do: "admin"

  defp action(method, ["data", "collections", _name]) when method in ["PATCH", "DELETE"],
    do: "admin"

  defp action(_method, ["storage", "workspaces", _id, segment | _])
       when segment in ["mutations", "cursors"],
       do: "sync"

  defp action(_method, ["sync" | _]), do: "sync"

  defp action("GET", ["batch", "export" | _]), do: "export"

  defp action(method, [root | _]) when root in @search_roots and method in ["GET", "POST"],
    do: "search"

  defp action(method, _route) when method in ["GET", "HEAD"], do: "read"
  defp action("DELETE", _route), do: "erase"
  defp action(_method, _route), do: "write"

  @doc """
  The data class of a workspace for authority decisions: its
  `metadata.data_class`, `restricted` for an unknown class, else `internal`.
  """
  @spec data_class(String.t() | nil) :: String.t()
  def data_class(nil), do: "internal"

  def data_class(workspace_id) do
    case OptimalEngine.Workspace.get(workspace_id) do
      {:ok, %{metadata: %{"data_class" => class}}} ->
        if class in OptimalEngine.Authority.Policy.data_classes(), do: class, else: "restricted"

      _ ->
        "internal"
    end
  end
end
