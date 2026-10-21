defmodule Mix.Tasks.Optimal.Authority do
  @shortdoc "Manage Optimal Authority: policy packs, mode, grants, evidence"

  @moduledoc """
  Manage Optimal Authority on the local Engine store. These commands act as
  the local operator; HTTP clients use `/api/authority` instead.

  ## Usage

      mix optimal.authority init [--tenant default]
      mix optimal.authority publish <pack.yaml|pack.json> [--scope tenant|workspace|subject] [--id <scope id>]
      mix optimal.authority mode [off|observe|enforce]
      mix optimal.authority decide --subject agent:x --action read --resource optimal://ws/path [--workspace ws] [--class internal]
      mix optimal.authority issue --subject agent:x --action read --resource optimal://ws/path [--workspace ws] [--ttl 300] [--uses 1]
      mix optimal.authority revoke <jti> [--reason text]
      mix optimal.authority effective <subject> [--workspace ws]
      mix optimal.authority verify
      mix optimal.authority checkpoint [--anchor text]
      mix optimal.authority export [--until <seq>] [--format json|ndjson] [--out evidence.json]
      mix optimal.authority integrity [--record]
      mix optimal.authority keys

  `init` publishes the default pack by data class for the tenant (only when
  the tenant has no pack yet). Every command that changes state is recorded
  in the evidence chain.
  """

  use Mix.Task

  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.{Decision, Evidence, Integrity, Keys, Policy, Settings}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          tenant: :string,
          scope: :string,
          id: :string,
          subject: :string,
          action: :string,
          resource: :string,
          workspace: :string,
          class: :string,
          ttl: :integer,
          uses: :integer,
          reason: :string,
          anchor: :string,
          out: :string,
          until: :integer,
          format: :string,
          record: :boolean
        ],
        aliases: [t: :tenant, w: :workspace]
      )

    tenant = opts[:tenant] || "default"
    actor = OptimalEngine.API.Actor.local_operator()

    case rest do
      ["init" | _] -> init(tenant, actor)
      ["publish", path | _] -> publish(tenant, path, opts, actor)
      ["mode"] -> Mix.shell().info(Settings.mode(tenant))
      ["mode", mode | _] -> mode(tenant, mode, actor)
      ["decide" | _] -> decide(tenant, opts)
      ["issue" | _] -> issue(tenant, opts, actor)
      ["revoke", jti | _] -> revoke(tenant, jti, opts, actor)
      ["effective", subject | _] -> print(Authority.effective(tenant, subject, opts[:workspace]))
      ["verify" | _] -> verify(tenant)
      ["checkpoint" | _] -> print_result(Evidence.checkpoint(tenant, opts[:anchor]))
      ["export" | _] -> export(tenant, opts)
      ["integrity" | _] -> print(Integrity.scan(tenant, record: opts[:record] == true))
      ["keys" | _] -> print(Keys.jwks(tenant))
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  defp init(tenant, actor) do
    if Policy.active(tenant, "tenant", tenant) do
      Mix.shell().info("Tenant #{tenant} already has a tenant pack; nothing published.")
    else
      print_result(
        Authority.publish_policy(tenant, "tenant", tenant, Authority.default_pack(), actor)
      )
    end
  end

  defp publish(tenant, path, opts, actor) do
    scope = opts[:scope] || "tenant"
    scope_id = if scope == "tenant", do: tenant, else: opts[:id]

    with {:ok, content} <- File.read(path),
         {:ok, document} <- parse(path, content) do
      print_result(Authority.publish_policy(tenant, scope, scope_id || "", document, actor))
    else
      {:error, reason} -> Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp parse(path, content) do
    if String.ends_with?(path, ".json"),
      do: Jason.decode(content),
      else: YamlElixir.read_from_string(content)
  end

  defp mode(tenant, mode, actor) do
    case Authority.set_mode(tenant, mode, actor) do
      :ok -> Mix.shell().info("Authority mode for #{tenant}: #{mode}")
      {:error, :invalid_mode} -> Mix.raise("mode must be off, observe, or enforce")
    end
  end

  defp decide(tenant, opts) do
    tenant
    |> request(opts)
    |> Authority.decide()
    |> Decision.to_map()
    |> print()
  end

  defp issue(tenant, opts, actor) do
    attrs =
      tenant
      |> request(opts)
      |> Map.take([:subject, :action, :resource, :workspace_id, :data_class])
      |> Map.merge(%{ttl_seconds: opts[:ttl], max_uses: opts[:uses]})
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Authority.issue_grant(tenant, attrs, actor) do
      {:ok, grant} -> print(%{"jti" => grant.jti, "token" => grant.token, "claims" => grant.claims})
      {:error, reason, _detail} -> Mix.raise("Grant refused: #{reason}")
    end
  end

  defp revoke(tenant, jti, opts, actor) do
    print_result(Authority.revoke_grant(tenant, jti, actor, opts[:reason]))
  end

  defp verify(tenant) do
    case Evidence.verify(tenant) do
      {:ok, result} ->
        Mix.shell().info("Evidence chain valid: #{result.entries} entries, head #{result.head}")

      {:error, failure} ->
        Mix.raise("Evidence chain broken: #{inspect(failure)}")
    end
  end

  # The bundle is written as the entries are read, a page at a time, so a chain of any
  # length is exported whole in bounded memory: one bundle `Evidence.export/2` would
  # return with every entry through the head (the chain's last entry when the export
  # starts, or the one at --until), and so complete. JSON is pretty-printed, as the other
  # subcommands print; --format ndjson writes the lines `Evidence.to_ndjson/1` writes for
  # a page, one record a line.
  defp export(tenant, opts) do
    ndjson? =
      case opts[:format] || "json" do
        "json" -> false
        "ndjson" -> true
        _other -> Mix.raise("--format must be json or ndjson")
      end

    head =
      case Evidence.head(tenant, until: opts[:until]) do
        {:ok, head} -> head
        {:error, :until_out_of_range} -> Mix.raise("--until must name an entry of the chain")
      end

    through = if head, do: head["seq"], else: 0
    device = if opts[:out], do: File.open!(opts[:out], [:write]), else: :stdio

    unless ndjson? do
      IO.binwrite(device, [~s({\n  "tenant_id": ), Jason.encode!(tenant), ~s(,\n  "entries": [)])
    end

    {count, last} =
      tenant
      |> Evidence.stream("tenant_seq <= ?2", [through])
      |> Enum.reduce({0, 0}, fn entry, {written, _last} ->
        line =
          cond do
            ndjson? -> Evidence.ndjson_entry(entry)
            written > 0 -> [",\n    ", pretty(entry, "    ")]
            true -> ["\n    ", pretty(entry, "    ")]
          end

        IO.binwrite(device, line)
        {written + 1, entry["seq"]}
      end)

    rest = %{
      "tenant_id" => tenant,
      "complete" => last == through,
      "total" => count,
      "head" => head,
      "head_signature" => Evidence.head_signature(tenant, head),
      "next_after" => nil,
      "keys" => Keys.jwks(tenant),
      "checkpoints" => Evidence.checkpoints(tenant)
    }

    if ndjson? do
      IO.binwrite(device, Evidence.ndjson_end(rest))
    else
      # The rest of the object, its closing brace included.
      "{\n" <> fields = rest |> Map.delete("tenant_id") |> Jason.encode!(pretty: true)
      IO.binwrite(device, [if(count > 0, do: "\n  ]", else: "]"), ",\n", fields, "\n"])
    end

    if opts[:out] do
      File.close(device)
      Mix.shell().info("Wrote #{count} entries to #{opts[:out]}")
    end
  end

  # `value` as pretty JSON, every line after the first indented by `indent`.
  defp pretty(value, indent),
    do: value |> Jason.encode!(pretty: true) |> String.replace("\n", "\n" <> indent)

  defp request(tenant, opts) do
    %{
      tenant_id: tenant,
      subject: opts[:subject],
      action: opts[:action],
      resource: opts[:resource],
      workspace_id: opts[:workspace],
      data_class: opts[:class]
    }
  end

  defp print_result({:ok, value}), do: print(value)
  defp print_result({:error, reason}), do: Mix.raise("Failed: #{inspect(reason)}")

  defp print(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))
end
