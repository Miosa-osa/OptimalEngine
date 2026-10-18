defmodule OptimalEngine.API.Actor do
  @moduledoc """
  Resolves who is acting on an HTTP request.

  An authenticated request always acts as its API key's principal:
  `OptimalEngine.API.PermissionPlug` binds the body's actor fields to that
  principal before any handler runs, and rejects a body that names someone
  else. An anonymous request (auth not required and no key) is a trusted
  local caller: it may name an actor in the body, and otherwise acts as the
  configured local operator.

  The local operator defaults to `"local:operator"` and is set per deployment
  with the `OPTIMAL_LOCAL_OPERATOR` environment variable
  (`config :optimal_engine, :local_operator_id`).
  """

  @default_local_operator "local:operator"

  @doc "The acting principal for the request, ignoring any body field."
  @spec of(Plug.Conn.t()) :: String.t()
  def of(conn) do
    case conn.assigns[:current_principal_id] do
      id when is_binary(id) and id != "" -> id
      _ -> local_operator()
    end
  end

  @doc """
  The acting principal for the request. Keyed requests always resolve to the
  key's principal; anonymous local requests may name an actor in `body`.
  """
  @spec of(Plug.Conn.t(), map() | nil) :: String.t()
  def of(conn, body) do
    case conn.assigns[:current_principal_id] do
      id when is_binary(id) and id != "" -> id
      _ -> body_actor(body) || local_operator()
    end
  end

  @doc "The configured local operator id used for anonymous local requests."
  @spec local_operator() :: String.t()
  def local_operator do
    case Application.get_env(:optimal_engine, :local_operator_id) do
      id when is_binary(id) and id != "" -> id
      _ -> @default_local_operator
    end
  end

  defp body_actor(%{"actor_id" => actor}) when is_binary(actor) and actor != "", do: actor
  defp body_actor(_body), do: nil
end
