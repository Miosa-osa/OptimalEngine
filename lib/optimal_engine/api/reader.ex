defmodule OptimalEngine.API.Reader do
  @moduledoc """
  The `OptimalEngine.ReadScope` of an HTTP request.

  A keyed caller reads with the grants in its verified key's metadata
  (`allowed_security_labels`, `allowed_partitions`), exactly where governed
  retrieval takes them from, and never from the request. A key with none
  reads only what carries no label and no partition. An anonymous local
  caller is the trusted operator: no scope, no filtering.

  The routes that dump rows (exports, conflicts) pass `ceiling: true`: besides
  its grants, a key without a `"*"` label grant is shown nothing above the
  Engine's own ceiling for what it hands out, `config :optimal_engine,
  :sync_serve_max_class` (default `confidential`), as a replication peer is.
  """

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.ReadScope
  alias OptimalEngine.Sync
  alias OptimalEngine.Sync.Gate

  @spec scope(Plug.Conn.t(), keyword()) :: ReadScope.t() | nil
  def scope(conn, opts \\ []) do
    case conn.assigns[:current_api_key] do
      %ApiKey{} = key ->
        %ReadScope{
          tenant_id: conn.assigns[:current_tenant] || "default",
          principal: Actor.of(conn),
          labels: grant(key, "allowed_security_labels"),
          partitions: grant(key, "allowed_partitions"),
          acl_absent: :allow,
          ceiling: if(opts[:ceiling], do: Gate.class_rank(Sync.serve_max_class()))
        }

      _anonymous ->
        nil
    end
  end

  # An element that is not a string grants nothing (a map or a list in the
  # metadata of a key is not a label), instead of failing the request.
  defp grant(%ApiKey{metadata: %{} = metadata}, name) do
    case Map.get(metadata, name) do
      grants when is_list(grants) -> for grant <- grants, is_binary(grant), do: grant
      _ -> []
    end
  end

  defp grant(_key, _name), do: []
end
