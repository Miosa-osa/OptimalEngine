defmodule OptimalEngine.Connectors.CredentialVault.Migration do
  @moduledoc """
  Moves connector credentials sealed into the Engine database (a
  `CONNECTOR_KEY` envelope in `credentials_ciphertext`) into OpenBao, once
  the operator has opted in with `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`.

  For each row, in order:

    1. the envelope is opened with `CONNECTOR_KEY`;
    2. the credentials are written to the row's own OpenBao path
       (`OptimalEngine.Connectors.CredentialVault.path/2`);
    3. they are read back and compared with what was written;
    4. only then is the row rewritten to the marker, and only if it is still
       the row that was read (compare and set on the stored config).

  A failure at any step leaves the row as it was, still readable with
  `CONNECTOR_KEY`. Running it again is safe: a marked row is
  `already_migrated`, and a row whose secret was written but not yet marked
  (a crash between steps 3 and 4) finds exactly those credentials and is
  marked.

  A credential changed while the migration runs is never lost. The row is
  read again just before its copy (`row_changed` when it moved), and the copy
  is a KV check-and-set at version 0, written only where nothing is stored: a
  secret a rotation in OpenBao mode wrote meanwhile is newer, so the row is
  skipped (`secret_exists`) and both are left as they are, unless that secret
  was last written more than 15 minutes ago while the row is still unmarked:
  that is an orphan an earlier run left, and it is written over. A copy that
  does not read back, or whose row moved or could not be marked, is released
  by destroying the one version this run wrote, so a newer version a rotation
  wrote meanwhile stays the secret; a secret an earlier run wrote is adopted
  and never destroyed.

  A connector this VM is running is skipped (`running`) and moves on the next
  run. That check sees only this VM's runs: `bin/optimal eval` starts a VM of
  its own, so it does not see the Engine's syncs. The guards above are what
  keep a migration safe beside them.

  `dry_run: true` opens every envelope (so a wrong `CONNECTOR_KEY` shows up
  as `failed`), writes nothing to OpenBao or the database, and lists the rows
  in `would_migrate`. `tenant: id` limits the run to one tenant.

  Run it with `mix optimal.connector migrate-credentials [--dry-run]`, or in a
  release with
  `bin/optimal eval 'OptimalEngine.Release.migrate_connector_credentials(dry_run: true)'`.
  The report names connector ids and reasons, never a credential.
  """

  require Logger

  alias OptimalEngine.Connectors.{Credential, CredentialVault, Runner}
  alias OptimalEngine.Storage.OpenBao
  alias OptimalEngine.Store

  @type report :: %{
          dry_run: boolean(),
          migrated: [String.t()],
          would_migrate: [String.t()],
          already_migrated: [String.t()],
          skipped: [{String.t(), atom()}],
          failed: [{String.t(), term()}]
        }

  @envelope "credentials_ciphertext"

  @doc """
  Runs the migration. `{:error, reason}` when the store is not opted in
  (`:credential_store_not_openbao`) or OpenBao is not configured.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with :ok <- opted_in(),
         {:ok, rows} <- rows(Keyword.get(opts, :tenant)) do
      empty = %{
        dry_run: dry_run,
        migrated: [],
        would_migrate: [],
        already_migrated: [],
        skipped: [],
        failed: []
      }

      report =
        rows
        |> Enum.reduce(empty, fn row, report -> step(row, dry_run, report) end)
        |> Map.new(fn
          {:dry_run, value} -> {:dry_run, value}
          {key, list} -> {key, Enum.reverse(list)}
        end)

      Logger.info(
        "Connector credentials to OpenBao#{if dry_run, do: " (dry run)", else: ""}: " <>
          "#{length(report.migrated)} migrated, #{length(report.would_migrate)} would migrate, " <>
          "#{length(report.already_migrated)} already there, #{length(report.skipped)} skipped, " <>
          "#{length(report.failed)} failed."
      )

      {:ok, report}
    end
  end

  defp opted_in do
    cond do
      CredentialVault.mode() != :openbao -> {:error, :credential_store_not_openbao}
      not OpenBao.configured?() -> {:error, :openbao_not_configured}
      true -> :ok
    end
  end

  defp rows(tenant) do
    {sql, params} =
      if tenant,
        do:
          {"SELECT id, tenant_id, config FROM connectors WHERE tenant_id = ?1 ORDER BY id",
           [tenant]},
        else: {"SELECT id, tenant_id, config FROM connectors ORDER BY id", []}

    case Store.raw_query(sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  defp step([id, tenant_id, raw], dry_run, report) do
    case classify(raw) do
      :stored ->
        push(report, :already_migrated, id)

      :no_credentials ->
        report

      {:invalid, reason} ->
        push(report, :failed, {id, reason})

      {:sealed, config, envelope} ->
        cond do
          Runner.running?(id) -> push(report, :skipped, {id, :running})
          dry_run -> dry_run_step(id, envelope, report)
          true -> migrate_row(id, tenant_id, raw, config, envelope, report)
        end
    end
  end

  defp classify(raw) do
    case Jason.decode(raw || "") do
      {:ok, config} when is_map(config) ->
        cond do
          CredentialVault.stored?(config) -> :stored
          is_binary(config[@envelope]) -> {:sealed, config, config[@envelope]}
          true -> :no_credentials
        end

      _not_a_map ->
        {:invalid, :config_not_json}
    end
  end

  defp dry_run_step(id, envelope, report) do
    case Credential.decrypt(envelope) do
      {:ok, _credentials} -> push(report, :would_migrate, id)
      {:error, reason} -> push(report, :failed, {id, {:envelope, reason}})
    end
  end

  defp migrate_row(id, tenant_id, raw, config, envelope, report) do
    with {:ok, path} <- CredentialVault.path(tenant_id, id),
         {:ok, credentials} <- open_envelope(envelope),
         :ok <- still_unchanged(id, tenant_id, raw),
         {:ok, copied} <- copy(path, credentials),
         :ok <- verify_and_mark(id, tenant_id, raw, config, path, credentials, copied) do
      push(report, :migrated, id)
    else
      {:error, :secret_exists} ->
        # Something else (a rotation in OpenBao mode) wrote this connector's
        # secret after the row was read: it is newer than the envelope, so it
        # is left exactly as it is, and the row with it.
        push(report, :skipped, {id, :secret_exists})

      {:error, :row_changed} ->
        # The row changed (or went) after it was read. Whatever this run
        # copied is already released (verify_and_mark/7); the next run
        # migrates whatever the row holds by then.
        push(report, :skipped, {id, :row_changed})

      {:error, reason} ->
        Logger.warning(
          "Connector #{id}: credentials not migrated to OpenBao: #{OptimalEngine.Secrets.describe(reason)}. The row is unchanged."
        )

        push(report, :failed, {id, reason})
    end
  end

  # Read again just before the copy, so a row rotated since it was listed is
  # not copied at all.
  defp still_unchanged(id, tenant_id, raw) do
    case Store.raw_query("SELECT config FROM connectors WHERE id = ?1 AND tenant_id = ?2", [
           id,
           tenant_id
         ]) do
      {:ok, [[^raw]]} -> :ok
      {:ok, _changed_or_gone} -> {:error, :row_changed}
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  # Check-and-set at version 0: written only where nothing is stored, so a
  # secret a rotation wrote meanwhile is never overwritten with the older
  # credentials. Answers `{:created, version}` for a version this run wrote
  # (the only kind a release may destroy) or `:adopted` for a secret already
  # holding exactly these credentials (an earlier run that stopped before
  # marking the row), which is finished, never destroyed.
  #
  # A secret holding other credentials while the row (just read again) is
  # still unmarked is either a rotation in OpenBao mode between its write and
  # its mark, which takes milliseconds, or an orphan an earlier run left (a
  # crash, a failed release) after which the row was rotated in engine mode.
  # One last written more than @orphan_age_s ago is the orphan: it is
  # written over at the version it is at, so it never blocks its row for
  # good. A newer one is `secret_exists`, tried again on the next run. A path
  # whose latest version an earlier run destroyed is written over the same way.
  @orphan_age_s 900

  defp copy(path, credentials) do
    case OpenBao.kv_write_version(path, credentials, cas: 0) do
      {:ok, version} ->
        {:ok, {:created, version}}

      {:error, :openbao_cas_mismatch} ->
        case OpenBao.kv_read_version(path) do
          {:ok, ^credentials, _version} -> {:ok, :adopted}
          {:ok, _other, _version} -> copy_over(path, credentials, :orphan_only)
          {:error, :not_found} -> copy_over(path, credentials, :released)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_over(path, credentials, kind) do
    with {:ok, meta} <- OpenBao.kv_metadata(path) do
      if kind == :released or orphan?(meta) do
        case OpenBao.kv_write_version(path, credentials, cas: meta.current_version) do
          {:ok, version} -> {:ok, {:created, version}}
          {:error, :openbao_cas_mismatch} -> {:error, :secret_exists}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :secret_exists}
      end
    end
  end

  defp orphan?(%{updated_time: %DateTime{} = written}),
    do: DateTime.diff(DateTime.utc_now(), written) > @orphan_age_s

  defp orphan?(_meta), do: false

  # A copy that does not read back, or whose row could not be marked (moved,
  # or the store failed), holds credentials no row points at: the version
  # this run wrote is destroyed, and only that one, so a newer version a
  # rotation wrote meanwhile stays the secret whatever order the two land in.
  # An adopted secret, or a version nobody can say (an old server), is left.
  defp verify_and_mark(id, tenant_id, raw, config, path, credentials, copied) do
    with :ok <- verify(path, credentials),
         :ok <- mark(id, tenant_id, raw, config) do
      :ok
    else
      error ->
        release(id, path, copied)
        error
    end
  end

  defp release(id, path, {:created, version}) when is_integer(version) do
    case OpenBao.kv_destroy_version(path, version) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Connector #{id}: the copy of credentials no row points at was not removed from OpenBao: #{OptimalEngine.Secrets.describe(reason)}. The next run writes over it."
        )
    end
  end

  defp release(_id, _path, _copied), do: :ok

  defp open_envelope(envelope) do
    case Credential.decrypt(envelope) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, reason} -> {:error, {:envelope, reason}}
    end
  end

  defp verify(path, credentials) do
    case OpenBao.kv_read(path) do
      {:ok, ^credentials} -> :ok
      {:ok, _other} -> {:error, :verify_mismatch}
      {:error, :not_found} -> {:error, :verify_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  # Compare and set: the row is rewritten only while it still holds the
  # config that was copied.
  defp mark(id, tenant_id, raw, config) do
    marked =
      config
      |> Map.delete(@envelope)
      |> Map.put(CredentialVault.marker_key(), "openbao")
      |> Jason.encode!()

    case Store.raw_query(
           "UPDATE connectors SET config = ?1 WHERE id = ?2 AND tenant_id = ?3 AND config = ?4 RETURNING id",
           [marked, id, tenant_id, raw]
         ) do
      {:ok, [[^id]]} -> :ok
      {:ok, []} -> {:error, :row_changed}
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  defp push(report, key, value), do: Map.update!(report, key, &[value | &1])
end
