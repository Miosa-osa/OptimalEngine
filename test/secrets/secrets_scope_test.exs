defmodule OptimalEngine.Secrets.ScopeTest do
  @moduledoc """
  Only what the operator sets is resolved: `Secrets.fetch/1` reads an
  `openbao:` reference from the environment variables it names as Engine
  secrets, and nothing else. There is no entry point that resolves a value a
  caller hands it (a peer's api_key, a row of the database). A read keeps the
  one field asked for, in ETS, not the secret's whole data map.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Secrets
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_BACKUP_KEY OPTIMAL_SOMETHING_ELSE)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Secrets.flush_cache()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, bao} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(bao) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    %{bao: bao}
  end

  test "no function resolves a value given to it" do
    refute function_exported?(Secrets, :resolve_value, 2)
  end

  test "a variable that is not an Engine secret is never resolved", %{bao: bao} do
    OpenBaoStub.put_secret(bao, "optimal/engine", %{"backup_key" => "s3cret-value"})
    System.put_env("OPTIMAL_SOMETHING_ELSE", "openbao:optimal/engine#backup_key")

    assert Secrets.fetch("OPTIMAL_SOMETHING_ELSE") == {:error, :not_an_engine_secret}
    assert OpenBaoStub.requests(bao) == []
  end

  test "a read keeps the field asked for and no other, outside persistent_term", %{bao: bao} do
    OpenBaoStub.put_secret(bao, "optimal/engine", %{
      "backup_key" => "the-backup-key",
      "unrelated" => "an-unrelated-secret"
    })

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "the-backup-key"}

    kept = inspect(Secrets.cache_entries())
    assert kept =~ "the-backup-key"
    refute kept =~ "an-unrelated-secret"
    refute inspect(:persistent_term.get()) =~ "the-backup-key"
  end
end
