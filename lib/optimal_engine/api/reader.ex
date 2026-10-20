defmodule OptimalEngine.API.Reader do
  @moduledoc """
  The `OptimalEngine.ReadScope` of an HTTP request.

  A keyed caller reads with the grants in its verified key's metadata
  (`allowed_security_labels`, `allowed_partitions`), exactly where governed
  retrieval takes them from, and never from the request. A key with none
  reads only what carries no label and no partition. An anonymous local
  caller is the trusted operator: no scope, no filtering.
  """

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.ReadScope

  @spec scope(Plug.Conn.t()) :: ReadScope.t() | nil
  def scope(conn) do
    case conn.assigns[:current_api_key] do
      %ApiKey{} = key ->
        %ReadScope{
          tenant_id: conn.assigns[:current_tenant] || "default",
          principal: Actor.of(conn),
          labels: grant(key, "allowed_security_labels"),
          partitions: grant(key, "allowed_partitions"),
          acl_absent: :allow
        }

      _anonymous ->
        nil
    end
  end

  defp grant(%ApiKey{metadata: %{} = metadata}, name) do
    case Map.get(metadata, name) do
      grants when is_list(grants) -> Enum.map(grants, &to_string/1)
      _ -> []
    end
  end

  defp grant(_key, _name), do: []
end
