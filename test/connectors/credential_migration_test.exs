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
