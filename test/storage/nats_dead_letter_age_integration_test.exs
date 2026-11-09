defmodule OptimalEngine.Storage.NATSDeadLetterAgeIntegrationTest do
  @moduledoc """
  Against a real JetStream server (`OPTIMAL_TEST_NATS_URL`, `nats -js`): the
  dead-letter stream's age limit purges a letter once it is older than the
  limit, and an intake removal deletes a workspace's queued Signal and dead
  letter from real streams. Skipped without a server; every stream is the
  test's own namespace and is deleted afterwards.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.NATS.{Connection, DeadLetters, IntakeQueue, JetStream}

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    n = System.unique_integer([:positive])
    conn = :"nats_dla_#{n}"
    start_supervised!({Connection, name: conn, url: @url, backoff: {50, 500}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)
    namespace = "dla" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(4)))

    on_exit(fn ->
      name = :"nats_dla_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Connection.start_link(name: name, url: @url)
      wait_for(fn -> Connection.connected?(name) end)

      for suffix <- ~w(INTAKE DEAD_LETTERS),
          do: JetStream.api(name, "STREAM.DELETE.#{String.upcase(namespace)}_#{suffix}")

      GenServer.stop(pid)
    end)

    %{conn: conn, namespace: namespace, n: n}
  end

  defp wait_for(fun, tries \\ 150) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp letter(ctx, payload) do
    JetStream.publish(ctx.conn, "#{ctx.namespace}.dead.intake", Jason.encode!(payload),
      msg_id: "dla-#{System.unique_integer([:positive])}"
    )
  end

  test "a letter older than the age limit is purged by the server", ctx do
    assert :ok = DeadLetters.ensure(ctx.conn, ctx.namespace, max_age_ms: 1_000)
    assert {:ok, _} = letter(ctx, %{"tenant_id" => "t", "workspace_id" => "t:w"})
    assert %{total: 1} = DeadLetters.summary(ctx.conn, ctx.namespace)

    assert wait_for(fn -> DeadLetters.summary(ctx.conn, ctx.namespace).total == 0 end, 250)
  end

  test "an existing stream takes the configured limit", ctx do
    assert :ok = DeadLetters.ensure(ctx.conn, ctx.namespace, max_age_ms: 0)
    assert :ok = DeadLetters.ensure(ctx.conn, ctx.namespace)

    {:ok, %{"config" => config}} =
      JetStream.api(ctx.conn, "STREAM.INFO." <> DeadLetters.stream(ctx.namespace))

    assert config["max_age"] == DeadLetters.max_age_ms() * 1_000_000
  end

  test "an intake removal deletes the workspace's queued Signal and dead letter", ctx do
    stream = String.upcase(ctx.namespace) <> "_INTAKE"

    {:ok, _, _} =
      JetStream.ensure_stream(ctx.conn, %{
        name: stream,
        subjects: ["#{ctx.namespace}.intake.>"],
        retention: "workqueue"
      })

    assert :ok = DeadLetters.ensure(ctx.conn, ctx.namespace)
    tenant = "dla#{ctx.n}"

    for {ws, i} <- [{"#{tenant}:gone", 1}, {"#{tenant}:kept", 2}] do
      payload =
        Jason.encode!(%{"tenant_id" => tenant, "workspace_id" => ws, "connector_id" => "c#{i}"})

      {:ok, _} =
        JetStream.publish(ctx.conn, "#{ctx.namespace}.intake.#{tenant}.c#{i}", payload,
          msg_id: "q#{i}"
        )

      {:ok, _} = letter(ctx, Jason.decode!(payload))
    end

    assert {:ok, %{queued_purged: 1, dead_letters_removed: 1}} =
             IntakeQueue.forget_workspace(tenant, "#{tenant}:gone", "archived",
               connection: ctx.conn,
               namespace: ctx.namespace
             )

    assert {:ok, %{"state" => %{"messages" => 1}}} =
             JetStream.api(ctx.conn, "STREAM.INFO." <> stream)

    assert %{total: 1} = DeadLetters.summary(ctx.conn, ctx.namespace)
  end
end
