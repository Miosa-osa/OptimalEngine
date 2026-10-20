defmodule OptimalEngine.Topology.Portable do
  @moduledoc """
  Imports and exports a tenant's organizations, workspaces, and people as one
  portable document, so the same file can seed an Engine, be edited by
  hand, and drive a platform's `org apply`.

      schema_version: 1
      organizations:
        - slug: example-co
          name: Example Co
          status: active           # active | dormant | archived
          role: Operating company   # any other fields are kept as metadata
          workspaces: [sales, delivery, {slug: revenue, id: "example:old-sales"}]
      people:
        - id: user:jane
          kind: user               # user | agent | service
          display_name: Jane Example
          workspaces: [sales]

  A workspace is listed by its slug. A renamed workspace keeps the id its
  first slug derived, so it is listed as `{slug, id}`; an import creates it
  with that id when the id belongs to the importing tenant and is free. An
  Engine from before workspaces could be renamed rejects a document that
  carries a `{slug, id}` entry (`invalid workspace entry`); a document it
  exported imports here unchanged.

  A workspace slug is lowercase letters, digits and dashes (at most 128
  characters) and not the name of a directory of the engine root, as for
  `OptimalEngine.Workspace.create/1`; a document that names another is
  refused whole, before anything is written. An import stops at the first
  workspace that cannot be created and names it (`invalid_document`); what it
  applied before stays, so the corrected document continues from there.

  Import is idempotent: existing organizations and workspaces (matched by
  id, else by any slug they hold) are updated, missing ones created, and
  nothing is deleted. Fields the
  Engine does not model are stored in metadata and exported back, so an
  import followed by an export returns the same document, plus the tenant's
  compatibility organization: every tenant owns one with slug `default`, which
  holds workspaces created before organizations were first-class, and it is
  exported even when it is empty.
  """

  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Identity.Principal

  @org_fields ~w(slug name status description workspaces)
  @person_fields ~w(id kind display_name external_id workspaces)

  @doc "Imports `document` into `tenant_id`. Returns a summary of changes."
  @spec import(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import(tenant_id, %{} = document) do
    organizations = Map.get(document, "organizations", [])
    people = Map.get(document, "people", [])

    with :ok <- validate(organizations, people) do
      summary = %{
        organizations_created: 0,
        organizations_updated: 0,
        workspaces_created: 0,
        workspaces_moved: 0,
        people: 0
      }

      with {:ok, summary} <- import_organizations(tenant_id, organizations, summary) do
        summary =
          Enum.reduce(people, summary, fn person, acc ->
            :ok = upsert_person(tenant_id, person)
            %{acc | people: acc.people + 1}
          end)

        {:ok,
         Map.put(
           summary,
           :extra,
           Map.drop(document, ["organizations", "people", "schema_version"]) |> map_size()
         )}
      end
    end
  end

  def import(_tenant_id, _document), do: {:error, :invalid_document}

  @doc "Exports `tenant_id` in the import format."
  @spec export(String.t()) :: map()
  def export(tenant_id) do
    {:ok, organizations} = Organization.list(tenant_id: tenant_id, status: :all)
    {:ok, workspaces} = Workspace.list(tenant_id: tenant_id, status: :all)
    by_org = Enum.group_by(workspaces, & &1.organization_id)

    orgs =
      organizations
      |> Enum.reject(&(&1.id == Organization.default_id() and Map.get(by_org, &1.id, []) == []))
      |> Enum.sort_by(&Map.get(&1.metadata, "portable_order", 1_000_000))
      |> Enum.map(fn org ->
        extra = Map.drop(org.metadata, ["portable_order", "workspace_order"])
        order = Map.get(org.metadata, "workspace_order", [])

        entries =
          by_org
          |> Map.get(org.id, [])
          |> Enum.reject(&(&1.slug == "default" and &1.id == "default"))
          |> Enum.sort_by(&(Enum.find_index(order, fn s -> s == &1.slug end) || 1_000_000))
          |> Enum.map(&workspace_entry(tenant_id, &1))

        %{"slug" => org.slug, "name" => org.name, "status" => Atom.to_string(org.status)}
        |> maybe_put("description", org.description)
        |> Map.merge(extra)
        |> Map.put("workspaces", entries)
      end)

    people =
      tenant_id
      |> Principal.list()
      |> Enum.filter(&(Map.get(&1.metadata, "portable") == true))
      |> Enum.map(fn person ->
        %{
          "id" => person.id,
          "kind" => Atom.to_string(person.kind),
          "display_name" => person.display_name
        }
        |> maybe_put("external_id", person.external_id)
        |> Map.merge(Map.drop(person.metadata, ["portable"]))
        |> Map.put("workspaces", member_slugs(tenant_id, person.id))
      end)

    %{"schema_version" => 1, "organizations" => orgs}
    |> then(fn doc -> if people == [], do: doc, else: Map.put(doc, "people", people) end)
  end

  # ---------------------------------------------------------------------------

  # Stops at the first workspace that cannot be created and says which. What
  # was applied before it stays (an import is idempotent), so importing the
  # corrected document continues from there.
  defp import_organizations(tenant_id, organizations, summary) do
    Enum.reduce_while(organizations, {:ok, summary}, fn org, {:ok, acc} ->
      {org_id, acc} = upsert_organization(tenant_id, org, acc)

      case import_workspaces(tenant_id, org, org_id, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp import_workspaces(tenant_id, org, org_id, acc) do
    Enum.reduce_while(org["workspaces"] || [], {:ok, acc}, fn entry, {:ok, acc} ->
      case ensure_workspace(tenant_id, org_id, entry, acc) do
        {:ok, acc} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          message =
            "organization #{org["slug"]}: workspace #{entry_slug(entry)} was not created (#{inspect(reason)})"

          {:halt, {:error, {:invalid_document, [message]}}}
      end
    end)
  end

  defp validate(organizations, people) when is_list(organizations) and is_list(people) do
    errors =
      Enum.flat_map(organizations, fn
        %{"slug" => slug, "name" => name} = org when is_binary(slug) and is_binary(name) ->
          cond do
            not slug?(slug) ->
              ["organization #{slug}: slug must be lowercase letters, digits and dashes"]

            (org["status"] || "active") not in ~w(active dormant archived) ->
              ["organization #{slug}: invalid status"]

            not Enum.all?(org["workspaces"] || [], &workspace_entry?/1) ->
              ["organization #{slug}: invalid workspace entry"]

            true ->
              workspace_slug_errors(slug, org["workspaces"] || [])
          end

        other ->
          ["organization entry needs slug and name: #{inspect(other)}"]
      end) ++
        Enum.flat_map(people, fn
          %{"id" => id, "kind" => kind} when is_binary(id) and kind in ~w(user agent service) -> []
          other -> ["person entry needs id and kind user|agent|service: #{inspect(other)}"]
        end)

    if errors == [], do: :ok, else: {:error, {:invalid_document, errors}}
  end

  defp validate(_organizations, _people),
    do: {:error, {:invalid_document, ["organizations and people must be lists"]}}

  defp slug?(value), do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, value)

  # A workspace's slug must be one `Workspace.create/1` accepts, so a document
  # that names one it cannot create is refused before anything is written.
  defp workspace_slug_errors(org_slug, entries) do
    Enum.flat_map(entries, fn entry ->
      slug = entry_slug(entry)

      case Workspace.check_slug(slug) do
        :ok ->
          []

        {:error, :slug_reserved} ->
          [
            "organization #{org_slug}: workspace slug #{slug} is reserved (a directory of the engine root)"
          ]

        {:error, :invalid_slug} ->
          [
            "organization #{org_slug}: workspace slug #{inspect(slug)} must be lowercase letters, digits and dashes, at most 128 characters"
          ]
      end
    end)
  end

  defp upsert_organization(tenant_id, org, acc) do
    position = Map.get(acc, :position, 0)

    metadata =
      org
      |> Map.drop(@org_fields)
      |> Map.put("portable_order", position)
      |> Map.put("workspace_order", Enum.map(org["workspaces"] || [], &entry_slug/1))

    status = String.to_existing_atom(org["status"] || "active")
    id = organization_id(tenant_id, org["slug"])
    acc = Map.put(acc, :position, position + 1)

    case Organization.get(id) do
      {:ok, _existing} ->
        {:ok, _} =
          Store.raw_query(
            "UPDATE organizations SET name = ?2, description = ?3, status = ?4, metadata = ?5 WHERE id = ?1 AND tenant_id = ?6",
            [
              id,
              org["name"],
              org["description"],
              Atom.to_string(status),
              Jason.encode!(metadata),
              tenant_id
            ]
          )

        {id, %{acc | organizations_updated: acc.organizations_updated + 1}}

      {:error, :not_found} ->
        {:ok, _} =
          Organization.create(%{
            id: id,
            tenant_id: tenant_id,
            slug: org["slug"],
            name: org["name"],
            description: org["description"],
            status: status,
            metadata: metadata
          })

        {id, %{acc | organizations_created: acc.organizations_created + 1}}
    end
  end

  defp ensure_workspace(tenant_id, org_id, entry, acc) do
    slug = entry_slug(entry)
    id = entry_id(entry, tenant_id)

    case existing_workspace(tenant_id, id, slug) do
      {:ok, %{organization_id: ^org_id}} ->
        {:ok, acc}

      {:ok, workspace} ->
        with {:ok, _} <- Workspace.assign_organization(workspace.id, org_id),
             do: {:ok, %{acc | workspaces_moved: acc.workspaces_moved + 1}}

      {:error, :not_found} ->
        attrs = %{tenant_id: tenant_id, organization_id: org_id, slug: slug, name: slug}
        attrs = if id, do: Map.put(attrs, :id, id), else: attrs

        with {:ok, _} <- Workspace.create(attrs),
             do: {:ok, %{acc | workspaces_created: acc.workspaces_created + 1}}
    end
  end

  defp existing_workspace(tenant_id, id, slug) do
    case id && Workspace.get(id) do
      {:ok, %{tenant_id: ^tenant_id} = workspace} -> {:ok, workspace}
      _ -> Workspace.get_by_handle(slug, tenant_id)
    end
  end

  # A workspace whose id is not the one its slug derives is listed with it.
  defp workspace_entry(tenant_id, workspace) do
    if workspace.id == Workspace.derive_id(tenant_id, workspace.slug),
      do: workspace.slug,
      else: %{"slug" => workspace.slug, "id" => workspace.id}
  end

  defp workspace_entry?(slug) when is_binary(slug), do: slug?(slug)

  defp workspace_entry?(%{"slug" => slug} = entry) when is_binary(slug),
    do: slug?(slug) and (is_nil(entry["id"]) or is_binary(entry["id"]))

  defp workspace_entry?(_entry), do: false

  defp entry_slug(%{"slug" => slug}), do: slug
  defp entry_slug(slug), do: slug

  # An id from the document is used only inside the tenant it names.
  defp entry_id(%{"id" => id}, tenant_id) when is_binary(id) do
    if match?([^tenant_id, _slug], String.split(id, ":", parts: 2)), do: id
  end

  defp entry_id(_entry, _tenant_id), do: nil

  defp upsert_person(tenant_id, person) do
    kind = String.to_existing_atom(person["kind"])
    metadata = person |> Map.drop(@person_fields) |> Map.put("portable", true)

    {:ok, _} =
      Principal.upsert(%{
        id: person["id"],
        tenant_id: tenant_id,
        kind: kind,
        display_name: person["display_name"] || person["id"],
        external_id: person["external_id"],
        metadata: metadata
      })

    Enum.each(person["workspaces"] || [], fn slug ->
      case Workspace.get_by_handle(slug, tenant_id) do
        {:ok, workspace} -> Workspace.add_member(workspace.id, person["id"])
        _ -> :ok
      end
    end)

    :ok
  end

  defp member_slugs(tenant_id, principal_id) do
    case Workspace.workspaces_of(principal_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(fn {workspace, _role} -> workspace end)
        |> Enum.filter(&(&1.tenant_id == tenant_id))
        |> Enum.map(& &1.slug)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # Matches Organization's own id convention.
  defp organization_id("default", slug), do: slug
  defp organization_id(tenant_id, slug), do: "#{tenant_id}:#{slug}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
