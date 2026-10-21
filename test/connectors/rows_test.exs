defmodule OptimalEngine.Connectors.RowsTest do
  @moduledoc """
  The operator's view of the connectors table: registering into a named,
  active workspace, changing a row without ever reading its credentials back,
  deleting it, and the evidence each change leaves.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Connectors.Rows
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    original_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    on_exit(fn ->
      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    tenant = "rows-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Rows #{tenant}"})

    {:ok,
     tenant: tenant,
     mail: insert_workspace("#{tenant}:mail", tenant, "active"),
     files: insert_workspace("#{tenant}:files", tenant, "active"),
     old: insert_workspace("#{tenant}:old", tenant, "archived")}
  end

  describe "register/2" do
    test "stores the row in the named workspace and never shows its credentials", ctx do
      assert {:ok, view} =
               Rows.register(
                 %{
                   id: "#{ctx.tenant}-gmail",
                   kind: "gmail",
                   tenant_id: ctx.tenant,
                   workspace_id: ctx.mail,
                   config: %{"user_email" => "ops@example.com", "routing_labels" => ["inbox"]},
                   credentials: %{
                     "oauth_refresh_token" => "example-refresh-token",
                     "client_id" => "example-client",
                     "client_secret" => "example-client-secret"
                   }
                 },
                 actor: "operator:test"
               )

      assert view.workspace_id == ctx.mail
      assert view.kind == "gmail"
      assert view.enabled
      assert view.credentials == "stored"
      assert view.cadence == %{interval_ms: 3_600_000, source: "kind"}
      assert view.config == %{"user_email" => "ops@example.com", "routing_labels" => ["inbox"]}

      encoded = Jason.encode!(view)
      refute encoded =~ "example-refresh-token"
      refute encoded =~ "example-client-secret"
      refute encoded =~ "credentials_ciphertext"

      {:ok, [[stored]]} =
        Store.raw_query("SELECT config FROM connectors WHERE id = ?1", ["#{ctx.tenant}-gmail"])

      refute stored =~ "example-refresh-token"
      assert stored =~ "credentials_ciphertext"
    end

    test "the workspace must be named, exist, belong to the tenant, and be active", ctx do
      base = %{id: "#{ctx.tenant}-x", kind: "sources_folder", tenant_id: ctx.tenant, config: %{}}

      assert {:error, :workspace_required} = Rows.register(base)

      assert {:error, :workspace_not_found} =
               Rows.register(Map.put(base, :workspace_id, "#{ctx.tenant}:missing"))

      assert {:error, :workspace_not_found} =
               Rows.register(Map.put(base, :workspace_id, "default"))

      assert {:error, :workspace_archived} = Rows.register(Map.put(base, :workspace_id, ctx.old))
    end

    test "refuses an unknown kind, an existing id, and secrets outside the envelope", ctx do
      base = %{id: "#{ctx.tenant}-y", kind: "gmail", tenant_id: ctx.tenant, workspace_id: ctx.mail}

      assert {:error, :unknown_kind} = Rows.register(%{base | kind: "carrier_pigeon"})

      assert {:error, :credentials_outside_envelope} =
               Rows.register(Map.put(base, :config, %{"client_secret" => "plain"}))

      assert {:ok, _view} =
               Rows.register(Map.put(base, :config, %{"user_email" => "a@example.com"}))

      assert {:error, :connector_exists} = Rows.register(Map.put(base, :config, %{}))

      assert {:error, :invalid_cadence} =
               Rows.register(
                 %{base | id: "#{ctx.tenant}-z"}
                 |> Map.put(:config, %{"cadence" => "often"})
               )
    end

    test "a broker connector carries no credentials", ctx do
      attrs = %{
        id: "#{ctx.tenant}-broker",
        kind: "gmail",
        tenant_id: ctx.tenant,
        workspace_id: ctx.mail,
        config: %{
          "user_email" => "ops@example.com",
          "credential_source" => "broker",
          "broker_url" => "https://connect.example.com/api/credentials",
          "broker_reference" => "conn_0000000001"
        }
      }

      assert {:ok, view} = Rows.register(attrs)
      assert view.credentials == "broker"
      assert view.credential_source == "broker"

      assert {:error, :broker_credentials_must_not_be_stored} =
               Rows.register(
                 %{attrs | id: "#{ctx.tenant}-broker-2"}
                 |> Map.put(:credentials, %{"x" => "y"})
               )
    end

    test "the broker reference is sealed, shown only as redacted, and removed with its seal",
         ctx do
      id = "#{ctx.tenant}-sealed"

      {:ok, view} =
        Rows.register(%{
          id: id,
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.mail,
          config: %{
            "user_email" => "ops@example.com",
            "credential_source" => "broker",
            "broker_url" => "https://connect.example.com/api/credentials",
            "broker_reference" => "conn_0000000003.example-signature"
          }
        })

      assert view.config["broker_reference"] == "[redacted]"
      refute Jason.encode!(view) =~ "conn_0000000003"
      refute Map.has_key?(view.config, "broker_reference_ciphertext")

      first = stored_config(id)
      refute Jason.encode!(first) =~ "conn_0000000003"
      assert first["broker_reference_ciphertext"]

      # Only the Engine writes the seal.
      assert {:error, :credentials_outside_envelope} =
               Rows.update(ctx.tenant, id, %{
                 "config" => %{"broker_reference_ciphertext" => "forged"}
               })

      # A new reference is sealed in place of the old one.
      {:ok, _view} =
        Rows.update(ctx.tenant, id, %{
          "config" => %{"broker_reference" => "conn_0000000004.example-signature"}
        })

      second = stored_config(id)
      refute Jason.encode!(second) =~ "conn_0000000004"
      refute second["broker_reference_ciphertext"] == first["broker_reference_ciphertext"]

      # Removing the reference removes its seal.
      {:ok, view} = Rows.update(ctx.tenant, id, %{"config" => %{"broker_reference" => nil}})
      refute Map.has_key?(view.config, "broker_reference")
      refute Map.has_key?(stored_config(id), "broker_reference_ciphertext")
    end

    test "a broker URL the Engine may not call is refused", ctx do
      assert {:error, :broker_url_not_allowed} =
               Rows.register(%{
                 id: "#{ctx.tenant}-elsewhere",
                 kind: "gmail",
                 tenant_id: ctx.tenant,
                 workspace_id: ctx.mail,
                 config: %{
                   "user_email" => "ops@example.com",
                   "credential_source" => "broker",
                   "broker_url" => "http://connect.example.com/api/credentials",
                   "broker_reference" => "conn_0000000005"
                 }
               })
    end

    test "a stray plaintext reference in a row is still never shown", ctx do
      id = "#{ctx.tenant}-legacy"

      config = %{
        "user_email" => "ops@example.com",
        "credential_source" => "broker",
        "broker_url" => "https://connect.example.com/api/credentials",
        "broker_reference" => "conn_0000000006"
      }

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled)
          VALUES (?1, ?2, ?3, 'gmail', ?4, 1)
          """,
          [id, ctx.tenant, ctx.mail, Jason.encode!(config)]
        )

      {:ok, view} = Rows.get(ctx.tenant, id)
      assert view.config["broker_reference"] == "[redacted]"
      refute Jason.encode!(Rows.list(ctx.tenant)) =~ "conn_0000000006"
    end

    test "records the registration in the evidence chain", ctx do
      id = "#{ctx.tenant}-evidence"

      {:ok, _} =
        Rows.register(
          %{
            id: id,
            kind: "sources_folder",
            tenant_id: ctx.tenant,
            workspace_id: ctx.files,
            config: %{}
          },
          actor: "operator:test"
        )

      assert [entry] = Evidence.list(ctx.tenant, kind: "connector.registered")
      assert entry["subject"] == "operator:test"
      assert entry["workspace_id"] == ctx.files
      assert entry["detail"]["connector_id"] == id
      assert entry["detail"]["kind"] == "sources_folder"
    end
  end

  describe "update/4" do
    setup ctx do
      id = "#{ctx.tenant}-mail"

      {:ok, _} =
        Rows.register(%{
          id: id,
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.mail,
          config: %{"user_email" => "ops@example.com"},
          credentials: %{
            "oauth_refresh_token" => "first-token",
            "client_id" => "c",
            "client_secret" => "s"
          }
        })

      {:ok, id: id}
    end

    test "disables, sets a cadence and routing fields, and keeps the stored credentials", ctx do
      assert {:ok, view} =
               Rows.update(ctx.tenant, ctx.id, %{
                 "enabled" => false,
                 "cadence" => "15m",
                 "config" => %{"routing_labels" => ["clients"], "review_workspace_id" => ctx.files}
               })

      refute view.enabled
      assert view.cadence == %{interval_ms: 900_000, source: "config"}
      assert view.config["routing_labels"] == ["clients"]
      assert view.config["user_email"] == "ops@example.com"
      assert view.credentials == "stored"

      # A null removes a field; interval_ms is understood as well.
      assert {:ok, view} =
               Rows.update(ctx.tenant, ctx.id, %{"cadence" => nil, "interval_ms" => 120_000})

      assert view.cadence == %{interval_ms: 120_000, source: "config"}
      refute Map.has_key?(view.config, "cadence")
    end

    test "replaces credentials, which stay unreadable", ctx do
      {:ok, [[before]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [ctx.id])

      assert {:ok, view} =
               Rows.update(ctx.tenant, ctx.id, %{
                 "credentials" => %{
                   "oauth_refresh_token" => "second-token",
                   "client_id" => "c",
                   "client_secret" => "s"
                 }
               })

      refute Jason.encode!(view) =~ "second-token"

      {:ok, [[after_change]]} =
        Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [ctx.id])

      refute after_change =~ "second-token"
      refute after_change == before
    end

    test "credentials cannot be smuggled in through config", ctx do
      assert {:error, :credentials_outside_envelope} =
               Rows.update(ctx.tenant, ctx.id, %{"config" => %{"credentials_ciphertext" => "x"}})

      assert {:error, :credentials_outside_envelope} =
               Rows.update(ctx.tenant, ctx.id, %{"config" => %{"access_token" => "x"}})
    end

    test "moves the connector to another active workspace, never to an archived one", ctx do
      assert {:ok, view} = Rows.update(ctx.tenant, ctx.id, %{"workspace" => ctx.files})
      assert view.workspace_id == ctx.files

      assert {:error, :workspace_archived} =
               Rows.update(ctx.tenant, ctx.id, %{"workspace" => ctx.old})
    end

    test "switching to the broker requires dropping the stored credentials", ctx do
      broker = %{
        "credential_source" => "broker",
        "broker_url" => "https://connect.example.com/api/credentials",
        "broker_reference" => "conn_0000000002"
      }

      assert {:error, :broker_credentials_must_not_be_stored} =
               Rows.update(ctx.tenant, ctx.id, %{"config" => broker})

      assert {:ok, view} =
               Rows.update(ctx.tenant, ctx.id, %{"config" => broker, "credentials" => nil})

      assert view.credentials == "broker"
    end

    test "another tenant's connector is not found, and each change is evidence", ctx do
      assert {:error, :not_found} = Rows.update("default", ctx.id, %{"enabled" => false})

      {:ok, _} = Rows.update(ctx.tenant, ctx.id, %{"enabled" => false}, actor: "operator:test")
      assert [entry] = Evidence.list(ctx.tenant, kind: "connector.changed")
      assert entry["detail"]["connector_id"] == ctx.id
      assert entry["detail"]["fields"] == ["enabled"]
      refute Jason.encode!(entry) =~ "first-token"
    end
  end

  describe "delete/3 and list/2" do
    test "lists rows by workspace with run status, and deletes one", ctx do
      {:ok, _} =
        Rows.register(%{
          id: "#{ctx.tenant}-m",
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.mail,
          config: %{}
        })

      {:ok, _} =
        Rows.register(%{
          id: "#{ctx.tenant}-f",
          kind: "drive",
          tenant_id: ctx.tenant,
          workspace_id: ctx.files,
          config: %{}
        })

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO connector_runs
            (tenant_id, workspace_id, connector_id, started_at, completed_at, status, signals_ingested, errors_encountered, error_detail)
          VALUES (?1, ?2, ?3, datetime('now', '-2 hours'), datetime('now', '-2 hours'), 'error', 0, 1, ':auth_expired'),
                 (?1, ?2, ?3, datetime('now', '-1 hours'), datetime('now', '-1 hours'), 'success', 7, 0, NULL)
          """,
          [ctx.tenant, ctx.mail, "#{ctx.tenant}-m"]
        )

      assert [mail] = Rows.list(ctx.tenant, workspace_ids: [ctx.mail])
      assert mail.id == "#{ctx.tenant}-m"
      assert mail.last_run.status == "success"
      assert mail.last_run.signals == 7
      assert mail.last_error.error == ":auth_expired"
      assert mail.signals_total == 7
      assert mail.runs == 2
      assert is_binary(mail.next_run_at)

      assert length(Rows.list(ctx.tenant)) == 2
      assert Rows.list("default", workspace_ids: [ctx.mail]) == []

      assert :ok = Rows.delete(ctx.tenant, "#{ctx.tenant}-m", actor: "operator:test")
      assert {:error, :not_found} = Rows.get(ctx.tenant, "#{ctx.tenant}-m")
      assert [_entry] = Evidence.list(ctx.tenant, kind: "connector.deleted")
      assert {:error, :not_found} = Rows.delete(ctx.tenant, "#{ctx.tenant}-m")
    end

    test "summary/2 counts what is failing and why", ctx do
      {:ok, _} =
        Rows.register(%{
          id: "#{ctx.tenant}-s",
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.mail,
          config: %{}
        })

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO connector_runs
            (tenant_id, workspace_id, connector_id, completed_at, status, errors_encountered, error_detail)
          VALUES (?1, ?2, ?3, datetime('now'), 'error', 1, ':broker_refused')
          """,
          [ctx.tenant, ctx.mail, "#{ctx.tenant}-s"]
        )

      summary = Rows.summary(ctx.tenant)
      assert summary.total == 1
      assert summary.enabled == 1
      assert summary.failing == 1
      assert [%{id: id, error: ":broker_refused"}] = summary.failing_connectors
      assert id == "#{ctx.tenant}-s"
      assert Rows.summary(ctx.tenant, workspace_ids: [ctx.files]).total == 0
    end
  end

  defp stored_config(id) do
    {:ok, [[config]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
    Jason.decode!(config)
  end

  defp insert_workspace(id, tenant, status) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, '{}')
        """,
        [id, tenant, id |> String.split(":") |> List.last(), "WS #{id}", status]
      )

    id
  end
end
