defmodule OptimalEngine.Health do
  @moduledoc """
  Liveness + readiness checks.

  Liveness is a boolean: "is the supervision tree up?". Readiness is
  richer: "can the engine actually serve traffic right now?" — SQLite
  writable, embedder reachable, credential key present if connectors
  are configured, migration state current, and the API not open to the
  network without authentication (`network_auth`, which warns
  `auth_open_on_network`; see `OptimalEngine.API.Exposure`).

  ## Usage

      iex> OptimalEngine.Health.live?()
      true

      iex> OptimalEngine.Health.ready()
      %{
        ok?: true,
        checks: %{
          store: :ok,
          migrations: :ok,
          credential_key: :ok,
          network_auth: :ok,
          embedder: :ok
        },
        degraded: []
      }

  Each check returns `:ok | {:warn, reason} | {:error, reason}`.
  `ok?` is `true` when no check returned `:error`. Warnings indicate
  degraded mode: the engine still serves, but operators should know;
  `warnings/1` names them.
  """

  alias OptimalEngine.Connectors.Credential
  alias OptimalEngine.Embed.Text, as: TextEmbedder
  alias OptimalEngine.Store

  @type check_result :: :ok | {:warn, term()} | {:error, term()}
  @type readiness :: %{
          ok?: boolean(),
          checks: %{atom() => check_result()},
          degraded: [atom()]
        }

  @doc "True when the top-level supervisor is up."
  @spec live?() :: boolean()
  def live? do
    case Process.whereis(OptimalEngine.Supervisor) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Run every readiness check and return a combined report.

  Callers that want to skip slow checks (e.g. Ollama) can pass
  `skip: [:embedder]`.
  """
  @spec ready(keyword()) :: readiness()
  def ready(opts \\ []) do
    skip = Keyword.get(opts, :skip, [])

    checks =
      [:store, :migrations, :credential_key, :network_auth, :embedder]
      |> Enum.reject(&(&1 in skip))
      |> Enum.map(fn name -> {name, run_check(name)} end)
      |> Enum.into(%{})

    errors = Enum.filter(checks, fn {_, v} -> match?({:error, _}, v) end)
    warns = Enum.filter(checks, fn {_, v} -> match?({:warn, _}, v) end)

    %{
      ok?: errors == [],
      checks: checks,
      degraded: Enum.map(warns, fn {name, _} -> name end)
    }
  end

  @doc """
  Terse summary for CLIs: `:up | :degraded | :down`. Takes the same options as
  `ready/1`, so a caller that reports a readiness it ran with `skip:` gets a
  status computed from that same report.
  """
  @spec status(keyword()) :: :up | :degraded | :down
  def status(opts \\ []) do
    if live?(), do: status_of(ready(opts)), else: :down
  end

  @doc "The status a readiness report implies (liveness is separate)."
  @spec status_of(readiness()) :: :up | :degraded | :down
  def status_of(%{ok?: true, degraded: []}), do: :up
  def status_of(%{ok?: true}), do: :degraded
  def status_of(_), do: :down

  @doc """
  The warning codes in a readiness report, such as `"auth_open_on_network"`:
  the first element of each `{:warn, reason}` (or the reason itself).
  """
  @spec warnings(readiness()) :: [String.t()]
  def warnings(%{checks: checks}) do
    checks
    |> Enum.flat_map(fn
      {_name, {:warn, reason}} when is_tuple(reason) -> [reason |> elem(0) |> to_string()]
      {_name, {:warn, reason}} -> [to_string(reason)]
      _ -> []
    end)
    |> Enum.sort()
  end

  # ─── checks ──────────────────────────────────────────────────────────────

  # An API with authentication off on a network interface still serves, but
  # anyone who can reach it acts as the local operator (OptimalEngine.API.Exposure).
  defp run_check(:network_auth) do
    case OptimalEngine.API.Exposure.unacknowledged_interface() do
      nil -> :ok
      interface -> {:warn, {:auth_open_on_network, interface}}
    end
  end

  defp run_check(:store) do
    case Store.raw_query("SELECT 1", []) do
      {:ok, [[1]]} -> :ok
      other -> {:error, {:store_unreachable, other}}
    end
  rescue
    e -> {:error, {:store_raised, Exception.message(e)}}
  end

  defp run_check(:migrations) do
    case Store.raw_query(
           "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wiki_pages'",
           []
         ) do
      {:ok, [[1]]} -> :ok
      {:ok, [[0]]} -> {:error, :migrations_pending}
      other -> {:error, {:migrations_unknown, other}}
    end
  rescue
    e -> {:error, {:migrations_raised, Exception.message(e)}}
  end

  defp run_check(:credential_key) do
    cond do
      Credential.ready?() ->
        :ok

      connectors_configured?() ->
        {:error, :connector_key_missing}

      true ->
        # No connectors registered yet + no key set — that's the default
        # dev state, not a degraded one. Credential encryption only
        # matters once a connector is wired up.
        :ok
    end
  end

  # Each failure is named for what the operator has to fix: "unreachable"
  # would send them to the network when the key, the credit or the model is
  # the problem.
  defp run_check(:embedder) do
    case safe_embed_ping() do
      :ok -> :ok
      {:error, reason} -> {:warn, embedder_problem(reason)}
    end
  end

  defp embedder_problem({:embed_unauthorized, status}), do: {:embedder_unauthorized, status}
  defp embedder_problem({:embed_unavailable, status}), do: {:embedder_unavailable, status}
  defp embedder_problem({:embed_api_key, reason}), do: {:embedder_key_unreadable, reason}

  defp embedder_problem({:embed_dimension_mismatch, got, want}),
    do: {:embedder_dimension_mismatch, got, want}

  defp embedder_problem(reason), do: {:embedder_unreachable, reason}

  defp safe_embed_ping do
    try do
      case TextEmbedder.embed("health", cache: false) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp connectors_configured? do
    case Store.raw_query("SELECT COUNT(*) FROM connectors WHERE enabled = 1", []) do
      {:ok, [[n]]} when is_integer(n) -> n > 0
      _ -> false
    end
  rescue
    _ -> false
  end
end
