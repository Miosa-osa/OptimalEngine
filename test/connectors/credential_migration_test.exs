defmodule OptimalEngine.Connectors.CredentialMigrationTest do
  @moduledoc """
  Opting into `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao` moves the
  credentials already sealed into connector rows with `CONNECTOR_KEY`:
  each is written to OpenBao, read back and compared, and only then is the row
  rewritten to the marker. A dry run says what would move and changes nothing;
  a second run finds nothing left to move.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.CredentialVault
  alias OptimalEngine.{Secrets, Store}
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT
          OPTIMAL_CONNECTOR_CREDENTIAL_STORE CONNECTOR_KEY)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Secrets.flush_cache()
    end)

    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
    prefix = "migrate-#{System.unique_integer([:positive])}"

    # Written before the opt-in, so sealed into the rows.
    ids =
      for n <- 1..2 do
        id = "#{prefix}-#{n}"

        {:ok, ^id} =
          Connectors.register(%{
            id: id,
            kind: :slack,
            config: %{
              "workspace_id" => "T01",
              "channels" => ["C01"],
              "credentials" => %{"bot_token" => "xoxb-#{n}", "oauth" => %{"refresh" => "r-#{n}"}}
            }
          })

        id
      end

    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")

    %{stub: stub, ids: ids, prefix: prefix}
  end

  defp config(id) do
    {:ok, [[json]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
    Jason.decode!(json)
  end

  defp mine(report, key, prefix),
    do: report |> Map.fetch!(key) |> Enum.filter(&String.starts_with?(id_of(&1), prefix))

  defp id_of({id, _reason}), do: id
  defp id_of(id), do: id

  test "a secret written while the migration runs is never overwritten by the old credentials",
       ctx do
    # A rotation in OpenBao mode got its secret in before this run's copy.
    [rotated_id, _other] = ctx.ids
    path = "optimal/connectors/default/#{rotated_id}"
    OpenBaoStub.put_secret(ctx.stub, path, %{"bot_token" => "xoxb-rotated"})
    before = config(rotated_id)

    assert {:ok, report} = CredentialVault.migrate()
    assert {rotated_id, :secret_exists} in report.skipped
    assert OpenBaoStub.secrets(ctx.stub)[path] == %{"bot_token" => "xoxb-rotated"}
    assert config(rotated_id) == before
  end

  test "a rotation that lands while a stale copy is released keeps its secret", ctx do
    # The copy is written and verified, then the row moves (a refresh rewrote
    # its envelope), so the mark misses and the copy is stale. While that copy
    # is released, a rotation in OpenBao mode writes its secret and marks the
    # row: releasing must take only the stale copy, never the rotation's.
    [id, _other] = ctx.ids
    path = "optimal/connectors/default/#{id}"
    data_path = "/v1/secret/data/#{path}"
    {:ok, fired} = Agent.start_link(fn -> MapSet.new() end)

    once = fn step, fun ->
      unless Agent.get_and_update(fired, &{MapSet.member?(&1, step), MapSet.put(&1, step)}),
        do: fun.()
    end

    set_config = fn config ->
      {:ok, _} =
        Store.raw_query("UPDATE connectors SET config = ?1 WHERE id = ?2", [
          Jason.encode!(config),
          id
        ])
    end

    OpenBaoStub.on_request(ctx.stub, fn
      # The verify read: the copy is in, the mark is next.
      {"GET", ^data_path} ->
        once.(:refresh, fn -> set_config.(Map.put(config(id), "refreshed", "1")) end)

      # The release, whichever call it starts with.
      {method, "/v1/secret/" <> rest} when method in ["DELETE", "POST"] ->
        if not String.starts_with?(rest, "data/") do
          once.(:rotate, fn ->
            OpenBaoStub.put_secret(ctx.stub, path, %{"bot_token" => "xoxb-rotated"})

            set_config.(
              config(id)
              |> Map.delete("credentials_ciphertext")
              |> Map.put(CredentialVault.marker_key(), "openbao")
            )
          end)
        end

      _other ->
        :ok
    end)

    assert {:ok, report} = CredentialVault.migrate()
    assert {id, :row_changed} in report.skipped
    assert OpenBaoStub.secrets(ctx.stub)[path] == %{"bot_token" => "xoxb-rotated"}
    assert CredentialVault.stored?(config(id))
  end

  test "an orphaned copy with older credentials does not block its row for good", ctx do
    # An earlier run copied, then crashed (or its release failed), and the row
    # was rotated in engine mode since: the secret is old, the row unmarked.
    [id, _other] = ctx.ids
    path = "optimal/connectors/default/#{id}"
    an_hour_ago = DateTime.add(DateTime.utc_now(), -3600)

    OpenBaoStub.put_secret(ctx.stub, path, %{"bot_token" => "xoxb-before"}, written_at: an_hour_ago)

    assert {:ok, report} = CredentialVault.migrate()
    assert id in report.migrated

    assert OpenBaoStub.secrets(ctx.stub)[path] == %{
             "bot_token" => "xoxb-1",
             "oauth" => %{"refresh" => "r-1"}
           }

    assert CredentialVault.stored?(config(id))
  end

  test "a copy that does not read back is released, and the row is unchanged", ctx do
    {:ok, tampered} = OpenBaoStub.start(read: :tampered)
    on_exit(fn -> OpenBaoStub.stop(tampered) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", tampered.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", tampered.token)
    Secrets.flush_cache()
    [id, _other] = ctx.ids
    before = config(id)

    assert {:ok, report} = CredentialVault.migrate()
    assert id in Enum.map(report.failed, &id_of/1)
    assert OpenBaoStub.secrets(tampered)["optimal/connectors/default/#{id}"] == nil
    assert config(id) == before
  end

  test "a copy this run adopted is never destroyed when its row moves", ctx do
    # The secret was already there with exactly the row's credentials (an
    # earlier run): this run did not write it, so it does not take it.
    [id, _other] = ctx.ids
    path = "optimal/connectors/default/#{id}"
    creds = %{"bot_token" => "xoxb-1", "oauth" => %{"refresh" => "r-1"}}
    OpenBaoStub.put_secret(ctx.stub, path, creds)
    data_path = "/v1/secret/data/#{path}"
    {:ok, fired} = Agent.start_link(fn -> false end)

    OpenBaoStub.on_request(ctx.stub, fn
      {"GET", ^data_path} ->
        # The verify read: the row moves before the mark.
        unless Agent.get_and_update(fired, &{&1, true}) do
          {:ok, _} =
            Store.raw_query("UPDATE connectors SET config = ?1 WHERE id = ?2", [
              Jason.encode!(Map.put(config(id), "refreshed", "1")),
              id
            ])
        end

      _other ->
        :ok
    end)

    assert {:ok, report} = CredentialVault.migrate()
    assert {id, :row_changed} in report.skipped
    assert OpenBaoStub.secrets(ctx.stub)[path] == creds
  end

  test "a copy an interrupted run already wrote is finished, not refused", ctx do
    [id, _other] = ctx.ids
    path = "optimal/connectors/default/#{id}"

    OpenBaoStub.put_secret(ctx.stub, path, %{
      "bot_token" => "xoxb-1",
      "oauth" => %{"refresh" => "r-1"}
    })

    assert {:ok, report} = CredentialVault.migrate()
    assert id in report.migrated
    assert CredentialVault.stored?(config(id))
  end

  test "a dry run names the rows it would move and changes nothing", ctx do
    before = Enum.map(ctx.ids, &config/1)

    assert {:ok, report} = CredentialVault.migrate(dry_run: true)
    assert report.dry_run
    assert Enum.sort(mine(report, :would_migrate, ctx.prefix)) == ctx.ids
    assert mine(report, :migrated, ctx.prefix) == []

    assert Enum.map(ctx.ids, &config/1) == before
    assert OpenBaoStub.secrets(ctx.stub) == %{}
  end

  test "each row is copied, read back and compared before it is marked, once", ctx do
    assert {:ok, report} = CredentialVault.migrate()
    assert Enum.sort(mine(report, :migrated, ctx.prefix)) == ctx.ids
    assert mine(report, :failed, ctx.prefix) == []

    for {id, n} <- Enum.with_index(ctx.ids, 1) do
      row = config(id)
      assert CredentialVault.stored?(row)
      refute Map.has_key?(row, "credentials_ciphertext")

      assert OpenBaoStub.secrets(ctx.stub)["optimal/connectors/default/#{id}"] ==
               %{"bot_token" => "xoxb-#{n}", "oauth" => %{"refresh" => "r-#{n}"}}

      assert {:ok, %{"bot_token" => token}} = CredentialVault.get(row, "default", id)
      assert token == "xoxb-#{n}"
    end

    # Idempotent: a second run moves nothing and writes nothing.
    writes = Enum.count(OpenBaoStub.requests(ctx.stub), &(elem(&1, 0) == "POST"))
    assert {:ok, again} = CredentialVault.migrate()
    assert mine(again, :migrated, ctx.prefix) == []
    assert Enum.sort(mine(again, :already_migrated, ctx.prefix)) == ctx.ids
    assert Enum.count(OpenBaoStub.requests(ctx.stub), &(elem(&1, 0) == "POST")) == writes
  end

  test "a copy that does not read back the same leaves the row as it was", ctx do
    {:ok, tampered} = OpenBaoStub.start(read: :tampered)
    on_exit(fn -> OpenBaoStub.stop(tampered) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", tampered.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", tampered.token)
    before = Enum.map(ctx.ids, &config/1)

    assert {:ok, report} = CredentialVault.migrate()
    assert mine(report, :migrated, ctx.prefix) == []

    assert Enum.sort(mine(report, :failed, ctx.prefix)) ==
             Enum.map(ctx.ids, &{&1, :verify_mismatch})

    assert Enum.map(ctx.ids, &config/1) == before
  end

  test "a sealed OpenBao fails each row and leaves it sealed in the Engine", ctx do
    OpenBaoStub.seal(ctx.stub)
    before = Enum.map(ctx.ids, &config/1)

    assert {:ok, report} = CredentialVault.migrate()
    assert Enum.sort(mine(report, :failed, ctx.prefix)) == Enum.map(ctx.ids, &{&1, :openbao_sealed})
    assert Enum.map(ctx.ids, &config/1) == before
  end

  # Rows other tests left behind were sealed with other CONNECTOR_KEYs, so they
  # fail to open here and the task exits non-zero for them; ours still move.
  defp run_task(args) do
    ExUnit.CaptureIO.capture_io(fn ->
      try do
        Mix.Tasks.Optimal.Connector.run(args)
      rescue
        error in Mix.Error -> IO.puts(Exception.message(error))
      end
    end)
  end

  test "the mix task runs the dry run and the migration", ctx do
    dry = run_task(["migrate-credentials", "--dry-run"])

    assert dry =~ "dry run, nothing changed"
    assert dry =~ hd(ctx.ids)
    refute dry =~ "xoxb-"
    assert OpenBaoStub.secrets(ctx.stub) == %{}

    out = run_task(["migrate-credentials"])

    assert out =~ "migrated:"
    assert CredentialVault.stored?(config(hd(ctx.ids)))
  end

  test "without the opt-in nothing is migrated" do
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "engine")
    assert CredentialVault.migrate() == {:error, :credential_store_not_openbao}
  end
end
