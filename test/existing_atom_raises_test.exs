defmodule OptimalEngine.ExistingAtomRaisesTest do
  @moduledoc """
  Text that names no atom is a refusal or a documented default, never a crash.

  Each test feeds text no atom exists for to a place that read stored or
  requested text with `String.to_existing_atom/1`, which raises `ArgumentError`
  on it. It asserts the documented result (a validation error, a skipped row, a
  default) and that the text is still not an atom afterwards.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors.CredentialSource
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Memory.Learning
  alias OptimalEngine.MemoryCore.ScopeEnvelope
  alias OptimalEngine.Retrieval.Receiver
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology.Portable
  alias OptimalEngine.WorkspaceTopology

  # Lowercase letters and underscores only, so it passes identifier checks.
  defp never_seen(prefix) do
    text = prefix <> "_" <> letters(System.unique_integer([:positive])) <> "_" <> random_letters()
    refute_atom(text)
    text
  end

  defp refute_atom(text) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(text) end
  end

  defp letters(n) when n < 26, do: <<?a + n>>
  defp letters(n), do: letters(div(n, 26)) <> <<?a + rem(n, 26)>>

  defp random_letters do
    for <<byte <- :crypto.strong_rand_bytes(8)>>, into: "", do: <<?a + rem(byte, 26)>>
  end

  describe "topology change requests" do
    setup do
      suffix = System.unique_integer([:positive])
      tmp_dir = Path.join(System.tmp_dir!(), "existing_atom_raises_#{suffix}")
      original_root = Application.get_env(:optimal_engine, :root_path)
      Application.put_env(:optimal_engine, :root_path, tmp_dir)

      on_exit(fn ->
        if original_root,
          do: Application.put_env(:optimal_engine, :root_path, original_root),
          else: Application.delete_env(:optimal_engine, :root_path)

        File.rm_rf(tmp_dir)
      end)

      %{workspace_id: "existing-atom-#{suffix}", tmp_dir: tmp_dir, suffix: suffix}
    end

    defp propose(workspace_id, request_type, payload, extra \\ %{}) do
      {:ok, request} =
        WorkspaceTopology.propose_change(
          Map.merge(
            %{
              workspace_id: workspace_id,
              request_type: request_type,
              target_object_type: "node",
              proposed_payload: payload
            },
            extra
          )
        )

      request
    end

    defp apply_request(request, workspace_id) do
      WorkspaceTopology.review_change_request(request.id, :approve,
        workspace_id: workspace_id,
        reviewed_by: "human:test",
        apply: true
      )
    end

    defp still_pending?(request, workspace_id) do
      {:ok, current} = WorkspaceTopology.get_change_request(request.id, workspace_id: workspace_id)
      current.review_status == "pending"
    end

    test "a node kind outside the known ones is refused and the request stays pending", ctx do
      kind = never_seen("zz_kind")

      request =
        propose(ctx.workspace_id, "create_node", %{
          "slug" => "probe",
          "name" => "Probe",
          "kind" => kind
        })

      assert {:error, {:invalid_kind, ^kind}} = apply_request(request, ctx.workspace_id)
      assert still_pending?(request, ctx.workspace_id)
      refute_atom(kind)
    end

    test "a kind that is an atom but not a node kind is refused too", ctx do
      request =
        propose(ctx.workspace_id, "create_node", %{
          "slug" => "probe",
          "name" => "Probe",
          "kind" => "user"
        })

      assert {:error, {:invalid_kind, "user"}} = apply_request(request, ctx.workspace_id)
    end

    test "a known kind still creates the node", ctx do
      request =
        propose(ctx.workspace_id, "create_node", %{
          "slug" => "probe",
          "name" => "Probe",
          "kind" => "team"
        })

      assert {:ok, %{applied: %{slug: "probe", kind: :team}}} =
               apply_request(request, ctx.workspace_id)
    end

    test "a relationship type outside the known ones is refused", ctx do
      type = never_seen("zz_relationship")

      request =
        propose(ctx.workspace_id, "link_nodes", %{
          "source_node_id" => "a",
          "target_node_id" => "b",
          "relationship_type" => type
        })

      assert {:error, {:invalid_relationship_type, ^type}} =
               apply_request(request, ctx.workspace_id)

      assert still_pending?(request, ctx.workspace_id)
      refute_atom(type)
    end

    test "a membership outside the known ones is refused", ctx do
      membership = never_seen("zz_membership")

      request =
        propose(ctx.workspace_id, "add_node_member", %{
          "node_id" => "n",
          "principal_id" => "p",
          "membership" => membership
        })

      assert {:error, {:invalid_membership, ^membership}} =
               apply_request(request, ctx.workspace_id)

      assert still_pending?(request, ctx.workspace_id)
      refute_atom(membership)
    end

    test "a setup document with a node kind outside the known ones is refused", ctx do
      kind = never_seen("zz_kind")

      assert {:error, {:invalid_kind, ^kind}} =
               WorkspaceTopology.setup_workspace(%{
                 slug: ctx.workspace_id,
                 name: "Existing atom #{ctx.suffix}",
                 root: ctx.tmp_dir,
                 actor_id: "test",
                 write_files: false,
                 nodes: [%{"slug" => "custom", "name" => "Custom", "kind" => kind}]
               })

      refute_atom(kind)
    end

    test "a setup document with a relationship type outside the known ones is refused", ctx do
      type = never_seen("zz_relationship")

      assert {:error, {:invalid_relationship_type, ^type}} =
               WorkspaceTopology.setup_workspace(%{
                 slug: ctx.workspace_id,
                 name: "Existing atom #{ctx.suffix}",
                 root: ctx.tmp_dir,
                 actor_id: "test",
                 write_files: false,
                 relationships: [
                   %{"source" => "inbox", "target" => "first-project", "relationship_type" => type}
                 ]
               })

      refute_atom(type)
    end
  end

  describe "topology documents" do
    setup do
      n = System.unique_integer([:positive])
      tenant = "existing-atom-doc-#{n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Existing atom #{n}"})
      %{tenant: tenant}
    end

    test "an organization status outside the known ones is an invalid document", %{tenant: tenant} do
      status = never_seen("zz_status")

      assert {:error, {:invalid_document, [message]}} =
               Portable.import(tenant, %{
                 "organizations" => [%{"slug" => "acme", "name" => "Acme", "status" => status}]
               })

      assert message =~ "invalid status"
      refute_atom(status)
    end

    test "a person kind outside the known ones is an invalid document", %{tenant: tenant} do
      kind = never_seen("zz_kind")

      assert {:error, {:invalid_document, [message]}} =
               Portable.import(tenant, %{"people" => [%{"id" => "user:probe", "kind" => kind}]})

      assert message =~ "kind"
      refute_atom(kind)
    end

    test "every known status and kind imports and exports back", %{tenant: tenant} do
      document = %{
        "organizations" => [
          %{"slug" => "one", "name" => "One", "status" => "active"},
          %{"slug" => "two", "name" => "Two", "status" => "dormant"},
          %{"slug" => "three", "name" => "Three", "status" => "archived"}
        ],
        "people" => [
          %{"id" => "user:ada", "kind" => "user"},
          %{"id" => "agent:bot", "kind" => "agent"},
          %{"id" => "service:sync", "kind" => "service"}
        ]
      }

      assert {:ok, %{people: 3}} = Portable.import(tenant, document)

      exported = Portable.export(tenant)
      statuses = for org <- exported["organizations"], into: %{}, do: {org["slug"], org["status"]}
      kinds = for person <- exported["people"], into: %{}, do: {person["id"], person["kind"]}

      assert %{"one" => "active", "two" => "dormant", "three" => "archived"} = statuses
      assert %{"user:ada" => "user", "agent:bot" => "agent", "service:sync" => "service"} = kinds
    end
  end

  describe "principals" do
    setup do
      n = System.unique_integer([:positive])
      tenant = "existing-atom-principal-#{n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Existing atom #{n}"})

      {:ok, _} =
        Principal.upsert(%{
          id: "user:good-#{n}",
          tenant_id: tenant,
          kind: :user,
          display_name: "Good"
        })

      %{tenant: tenant, n: n}
    end

    defp insert_principal(tenant, id, kind) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO principals (id, tenant_id, kind, display_name) VALUES (?1, ?2, ?3, 'Odd')",
          [id, tenant, kind]
        )
    end

    test "a stored row with a kind outside the known ones reads as not found", ctx do
      kind = never_seen("zz_kind")
      insert_principal(ctx.tenant, "odd:one-#{ctx.n}", kind)

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Principal.get("odd:one-#{ctx.n}", ctx.tenant)
        end)

      assert log =~ "odd:one-#{ctx.n}"
      refute_atom(kind)
    end

    test "a listing leaves such a row out and keeps the others", ctx do
      kind = never_seen("zz_kind")
      insert_principal(ctx.tenant, "odd:two-#{ctx.n}", kind)

      capture_log(fn ->
        assert [%Principal{id: id, kind: :user}] = Principal.list(ctx.tenant)
        assert id == "user:good-#{ctx.n}"
        assert [%Principal{kind: :user}] = Principal.list(ctx.tenant, kind: :user)
      end)

      refute_atom(kind)
    end

    test "a known row reads back with its kind atom", ctx do
      assert {:ok, %Principal{kind: :user}} = Principal.get("user:good-#{ctx.n}", ctx.tenant)
    end
  end

  describe "scope envelopes" do
    test "text keys outside the scope keys are ignored without creating atoms" do
      key = never_seen("zz_scope_key")

      scope =
        ScopeEnvelope.resolve(%{
          "actor_id" => "agent:probe",
          "tenant_id" => "default",
          "node" => "inbox",
          key => "ignored"
        })

      assert scope.actor == "agent:probe"
      assert scope.node_hints == ["inbox"]
      refute_atom(key)
    end

    test "every scope key given as text is read" do
      scope =
        ScopeEnvelope.resolve(%{
          "created_by" => "user:probe",
          "workspace_id" => "ws",
          "operation_class" => "intake.test",
          "node_hints" => ["a"],
          "permissions" => ["read"]
        })

      assert scope.actor == "user:probe"
      assert scope.workspace_id == "ws"
      assert scope.operation_class == "intake.test"
      assert scope.node_hints == ["a"]
      assert scope.permissions == ["read"]
    end
  end

  describe "receivers" do
    defp principal(kind, metadata),
      do: %Principal{id: "#{kind}:probe", kind: kind, metadata: metadata}

    test "metadata that names an unknown bandwidth, format or mode reads as the kind's defaults" do
      bandwidth = never_seen("zz_bandwidth")
      format = never_seen("zz_format")
      mode = never_seen("zz_mode")

      receiver =
        Receiver.from_principal_struct(
          principal(:agent, %{"bandwidth" => bandwidth, "format" => format, "mode" => mode})
        )

      assert receiver.bandwidth == :large
      assert receiver.token_budget == 24_000
      assert receiver.format == :claude
      assert receiver.mode == :linguistic

      for text <- [bandwidth, format, mode], do: refute_atom(text)
    end

    test "known metadata is read as before" do
      receiver =
        Receiver.from_principal_struct(
          principal(:user, %{"bandwidth" => "small", "format" => "openai", "mode" => "code"})
        )

      assert receiver.bandwidth == :small
      assert receiver.token_budget == 1_500
      assert receiver.format == :openai
      assert receiver.mode == :code
    end

    test "an override that is unknown falls back to the metadata" do
      override = never_seen("zz_bandwidth")

      receiver =
        Receiver.from_principal_struct(
          principal(:user, %{"bandwidth" => "large"}),
          %{bandwidth: override}
        )

      assert receiver.bandwidth == :large
      refute_atom(override)
    end

    test "overrides given as atoms still win" do
      receiver =
        Receiver.from_principal_struct(
          principal(:user, %{"bandwidth" => "large"}),
          %{bandwidth: :small, format: :plain, mode: :visual}
        )

      assert {receiver.bandwidth, receiver.format, receiver.mode} == {:small, :plain, :visual}
    end
  end

  describe "connector credential sources" do
    test "a source name outside the known ones is refused" do
      source = never_seen("zz_source")

      assert {:error, :invalid_credential_source} =
               CredentialSource.source(%{"credential_source" => source})

      assert {:error, :invalid_credential_source} =
               CredentialSource.hydrate(%{"credential_source" => source})

      refute_atom(source)
    end

    test "a config with keys of its own is read without creating atoms" do
      key = never_seen("zz_config_key")
      config = %{"credential_source" => "broker", "credentials" => %{key => "x"}, key => 1}

      assert {:error, :broker_credentials_must_not_be_stored} =
               CredentialSource.check_persistable(config)

      assert {:error, :broker_not_configured} = CredentialSource.hydrate(config)
      refute_atom(key)
    end
  end

  describe "learning files" do
    @describetag :tmp_dir

    test "a solution whose source names no atom loads with the loaded source", %{tmp_dir: dir} do
      source = never_seen("zz_source")
      original = Application.get_env(:optimal_engine, :learning_dir)
      Application.put_env(:optimal_engine, :learning_dir, dir)

      on_exit(fn ->
        if original,
          do: Application.put_env(:optimal_engine, :learning_dir, original),
          else: Application.delete_env(:optimal_engine, :learning_dir)
      end)

      File.write!(
        Path.join(dir, "solutions.json"),
        Jason.encode!([
          %{"key" => "odd", "correction" => "fix it", "source" => source},
          %{"key" => "plain", "correction" => "fix too"}
        ])
      )

      assert {:ok, state} = Learning.init([])

      assert %{source: :loaded, correction: "fix it"} = state.solutions["odd"]
      assert %{source: :loaded} = state.solutions["plain"]
      refute_atom(source)
    end
  end

  describe "mix optimal.rag" do
    test "an unknown --bandwidth or --format is refused with the accepted values" do
      bandwidth = never_seen("zz_bandwidth")
      format = never_seen("zz_format")

      assert_raise Mix.Error, ~r/Unknown bandwidth.*large, medium, small/, fn ->
        Mix.Tasks.Optimal.Rag.run(["a question", "--bandwidth", bandwidth])
      end

      assert_raise Mix.Error, ~r/Unknown format.*claude, markdown, openai, plain, text/, fn ->
        Mix.Tasks.Optimal.Rag.run(["a question", "--format", format])
      end

      for text <- [bandwidth, format], do: refute_atom(text)
    end
  end
end
