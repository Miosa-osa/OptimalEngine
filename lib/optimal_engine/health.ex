defmodule OptimalEngine.Health do
  @moduledoc """
  Liveness + readiness checks.

  Liveness is a boolean: "is the supervision tree up?". Readiness is
  richer: "can the engine actually serve traffic right now?" — SQLite
  writable, embedder reachable, credential key present if connectors
  are configured, migration state current, the API not open to the
  network without authentication (`network_auth`, which warns
  `auth_open_on_network`; see `OptimalEngine.API.Exposure`), and OpenBao
  able to answer when the Engine takes secrets from it (`secrets`), and the
  change ledger in order and published (`ledger`: a PostgreSQL ledger sequence
  that caches values the Engine could not set back, or a NATS ledger publisher
  whose passes keep failing, warns).

  A sealed or unreachable OpenBao is a warning (`openbao_unavailable`), not
  an error: the Engine boots and serves without it, the features that need a
  secret fail with the reason until it is unsealed, and an orchestrator that
  restarted an Engine reported down would not unseal OpenBao.

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
          secrets: :ok,
          ledger: :ok,
          embedder: :ok
        },
        degraded: []
      }

  Each check returns `:ok | {:warn, reason} | {:error, reason}`.
  `ok?` is `true` when no check returned `:error`. Warnings indicate
  degraded mode: the engine still serves, but operators should know;
  `warnings/1` names them.
  """

  alias OptimalEngine.Connectors.{Credential, CredentialVault}
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao
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
  `skip: [:embedder]`. With `embedder: :recent` the embedder check reads the
  outcome of the latest real embedding request (`OptimalEngine.Embed.Text.status/0`)
  and probes only when there is none or it is old, so a health endpoint
  reports a broken embedder as degraded without a probe on every call. The
  default, `embedder: :probe`, always asks the embedder.
  """
  @spec ready(keyword()) :: readiness()
  def ready(opts \\ []) do
    skip = Keyword.get(opts, :skip, [])
    embedder = Keyword.get(opts, :embedder, :probe)

    checks =
      [
        :store,
        :migrations,
        :credential_key,
        :network_auth,
        :secrets,
        :ledger,
        :intake_removals,
        :connector_ids,
        :embedder
      ]
      |> Enum.reject(&(&1 in skip))
      |> Enum.map(fn
        :embedder -> {:embedder, embedder_check(embedder)}
        name -> {name, run_check(name)}
      end)
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

  # Intake removals (OptimalEngine.Storage.NATS.IntakeQueue) waiting more than
  # a week: an Engine down or NATS unreachable, so text that was to be erased
  # is still on the stream. A count, never what they name.
  defp run_check(:intake_removals), do: OptimalEngine.Storage.NATS.IntakeQueue.pending_check()

  # Connector rows an older build wrote with an id outside the form ids take:
  # their credentials name no OpenBao path. A count, never the ids.
  defp run_check(:connector_ids) do
    case CredentialVault.invalid_ids() do
      {:ok, []} -> :ok
      {:ok, ids} -> {:warn, {:connector_ids_invalid, length(ids)}}
      {:error, _reason} -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # An API with authentication off on a network interface still serves, but
  # anyone who can reach it acts as the local operator (OptimalEngine.API.Exposure).
  defp run_check(:network_auth) do
    case OptimalEngine.API.Exposure.unacknowledged_interface() do
      nil -> :ok
      interface -> {:warn, {:auth_open_on_network, interface}}
    end
  end

  # The change ledger: on PostgreSQL its sequence must draw in order
  # (`Sync.Postgres.ensure_ledger_sequence/1`), and the NATS ledger publisher,
  # when on, must not keep failing its passes. Either is a warning: the Engine
  # serves, and what it writes is kept.
  defp run_check(:ledger) do
    with :ok <- OptimalEngine.Sync.Postgres.ledger_order(),
         :ok <- OptimalEngine.Storage.NATS.LedgerPublisher.health() do
      :ok
    else
      {:degraded, failures, last_error} -> {:warn, {:nats_ledger_failing, failures, last_error}}
      other -> other
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
    if OptimalEngine.Store.Catalog.table_exists?("wiki_pages"),
      do: :ok,
      else: {:error, :migrations_pending}
  rescue
    e -> {:error, {:migrations_raised, Exception.message(e)}}
  end

  defp run_check(:credential_key) do
    cond do
      Credential.ready?() ->
        :ok

      # The key is in OpenBao and OpenBao cannot answer: the `secrets` check
      # names why. Connector runs fail until it does; the Engine is not down.
      Secrets.source("CONNECTOR_KEY") == "openbao" ->
        {:warn, :connector_key_unavailable}

      # Set but not a key, or not set: the check names which.
      connectors_configured?() ->
        Credential.key_status()

      true ->
        # No connectors registered yet + no key set — that's the default
        # dev state, not a degraded one. Credential encryption only
        # matters once a connector is wired up.
        :ok
    end
  end

  # Only when the Engine takes something from OpenBao: a secret reference,
  # connector credentials, or the backup transit key.
  defp run_check(:secrets) do
    if Secrets.references() != [] or CredentialVault.mode() == :openbao or
         OpenBao.transit_key() != nil do
      with :ok <- OpenBao.availability(),
           :ok <- references_resolve() do
        :ok
      else
        {:error, {:secret_unavailable, _name, _reason} = reason} -> {:warn, reason}
        {:error, reason} -> {:warn, {:openbao_unavailable, reason}}
      end
    else
      :ok
    end
  rescue
    e -> {:warn, {:openbao_unavailable, Exception.message(e)}}
  end

  # Each failure is named for what the operator has to fix: "unreachable"
  # would send them to the network when the key, the credit or the model is
  # the problem.
  defp run_check(:embedder), do: embedder_check(:probe)

  defp embedder_check(mode) do
    result = if mode == :recent, do: safe_status(), else: safe_embed_ping()

    case result do
      :ok -> :ok
      {:error, reason} -> {:warn, embedder_problem(reason)}
    end
  end

  defp safe_status do
    TextEmbedder.status()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
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

  defp references_resolve do
    Enum.reduce_while(Secrets.references(), :ok, fn name, :ok ->
      case Secrets.fetch(name) do
        {:ok, _value} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
