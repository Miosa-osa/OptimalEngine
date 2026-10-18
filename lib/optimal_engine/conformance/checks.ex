defmodule OptimalEngine.Conformance.Checks do
  @moduledoc """
  The conformance checks, grouped by area.

  A check is a map:

      %{
        id: "version.contract",
        group: "version",
        description: "one sentence a reader can act on",
        run: fn client, context -> {:ok, evidence} | {:fail, evidence} | {:skip, reason} end
      }

  `evidence` is any JSON-encodable term. It records what was requested, what
  came back, and the expectation that was not met, so a failing run explains
  itself without a rerun.

  `context` carries `:url`, `:key`, `:transport`, `:run_id`, `:primary` and
  `:other` workspace ids, `:ephemeral` (true when this run created them),
  `:anonymous` (a keyless client) and `:expected_stores` (the store families
  this build declares).

  Add a check by adding it to a group below. Add checks that live outside this
  repository with `--extra-checks <path>`: the file is evaluated and must
  return a list of check maps (`OptimalEngine.Conformance.Checks.external/1`).
  """

  alias OptimalEngine.Conformance.Client

  @type evidence :: term()
  @type result :: {:ok, evidence()} | {:fail, evidence()} | {:skip, String.t()}
  @type check :: %{
          id: String.t(),
          group: String.t(),
          description: String.t(),
          run: (Client.t(), map() -> result())
        }

  @doc "Every built-in check, in report order."
  @spec all() :: [check()]
  def all do
    version() ++
      auth() ++
      scope() ++
      authority() ++
      stores() ++
      storage() ++
      setup() ++
      signal() ++
      analyses() ++
      sync() ++ viability() ++ operating()
  end

  @doc """
  Loads extra checks from an Elixir file.

  The file is evaluated in a fresh binding and must return a list of check
  maps. A file that fails to load or returns something else becomes one
  failing check, so a broken extension is visible instead of silent.
  """
  @spec external(String.t()) :: [check()]
  def external(path) do
    case File.exists?(path) do
      false ->
        [unloadable(path, "no such file")]

      true ->
        case Code.eval_file(path) do
          {checks, _binding} when is_list(checks) ->
            Enum.map(checks, &normalize_external(&1, path))

          {other, _binding} ->
            [unloadable(path, "expected a list of checks, got #{inspect(other)}")]
        end
    end
  rescue
    error -> [unloadable(path, Exception.message(error))]
  end

  defp unloadable(path, reason) do
    %{
      id: "external.load",
      group: "external",
      description: "the extra checks at #{path} load",
      run: fn _client, _context -> {:fail, %{path: path, error: reason}} end
    }
  end

  # ---------------------------------------------------------------------------
  # version
  # ---------------------------------------------------------------------------

  defp version do
    [
      %{
        id: "version.contract",
        group: "version",
        description:
          "the Engine reports one complete release identity and matches the tracked contract",
        run: fn client, _context ->
          case Client.get(client, "/api/version") do
            {:ok, %{status: 200, body: body}} when is_map(body) ->
              required =
                ~w(application repository version release_channel git_sha build_timestamp api_version contract_version expected_migration capabilities components)

              missing = missing_keys(body, required)
              drift = contract_drift(body)

              evidence = %{
                url: "/api/version",
                status: 200,
                identity: Map.take(body, required),
                missing_fields: missing,
                contract_drift: drift
              }

              if missing == [] and drift == [] and valid_channel?(body["release_channel"]) do
                {:ok, evidence}
              else
                {:fail,
                 Map.put(evidence, :expectation, %{
                   required_fields: required,
                   release_channels: OptimalEngine.Version.release_channels(),
                   contract_source: "engine-contract.json of the running checkout, when present"
                 })}
              end

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "/api/version",
                 status: status,
                 body: body,
                 expectation: "200 with the release identity"
               }}

            {:error, reason} ->
              {:fail,
               %{url: "/api/version", error: inspect(reason), expectation: "a reachable Engine"}}
          end
        end
      },
      %{
        id: "version.health_agrees",
        group: "version",
        description:
          "the health and status routes report the same release identity as /api/version",
        run: fn client, _context ->
          with {:ok, version} <- fetch_json(client, "/api/version"),
               {:ok, health} <- fetch_json(client, "/api/health"),
               {:ok, status} <- fetch_json(client, "/api/status") do
            identities = %{
              "/api/version" => version.body["version"],
              "/api/health" => get_in(health.body, ["release", "version"]),
              "/api/status" => get_in(status.body, ["release", "version"])
            }

            evidence = %{
              statuses: %{
                "/api/version" => version.status,
                "/api/health" => health.status,
                "/api/status" => status.status
              },
              versions: identities,
              health_ok: Map.get(health.body, "ok?"),
              health_degraded: Map.get(health.body, "degraded")
            }

            if version.status == 200 and health.status == 200 and status.status == 200 and
                 length(Enum.uniq(Map.values(identities))) == 1 do
              {:ok, evidence}
            else
              {:fail,
               Map.put(evidence, :expectation, "all three routes answer 200 with the same version")}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # auth
  # ---------------------------------------------------------------------------

  defp auth do
    [
      %{
        id: "auth.anonymous_denied",
        group: "auth",
        description: "an anonymous request is refused, so the Engine is not serving an open API",
        run: fn _client, context ->
          case Client.get(context.anonymous, "/api/workspaces") do
            {:ok, %{status: 401, body: body}} ->
              {:ok, %{url: "/api/workspaces", status: 401, error: error_of(body)}}

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "/api/workspaces",
                 status: status,
                 body: body,
                 expectation: "401 missing_api_key while OPTIMAL_AUTH_REQUIRED is true"
               }}

            {:error, reason} ->
              {:fail,
               %{url: "/api/workspaces", error: inspect(reason), expectation: "a reachable Engine"}}
          end
        end
      },
      %{
        id: "auth.keyed_allowed",
        group: "auth",
        description: "the supplied key is accepted on a global route",
        run: fn client, _context ->
          case Client.get(client, "/api/version") do
            {:ok, %{status: 200} = response} ->
              {:ok, %{url: "/api/version", status: response.status}}

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "/api/version",
                 status: status,
                 body: body,
                 expectation: "200 with a valid key"
               }}

            {:error, reason} ->
              {:fail, %{url: "/api/version", error: inspect(reason)}}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # scope
  # ---------------------------------------------------------------------------

  defp scope do
    [
      %{
        id: "scope.key_confined_to_workspace",
        group: "scope",
        description: "a key scoped to one workspace cannot read another workspace",
        run: fn client, context ->
          name = "conformance-#{context.run_id}"

          case Client.post(client, "/api/auth/keys", %{
                 name: name,
                 workspace_scope: [context.primary]
               }) do
            {:ok, %{status: 201, body: %{"id" => id, "key" => key}}} ->
              scoped = Client.new(url: context.url, key: key, transport: context.transport)

              allowed =
                Client.get(scoped, "/api/search",
                  query: [q: context.run_id, workspace: context.primary, limit: 1]
                )

              denied =
                Client.get(scoped, "/api/search",
                  query: [q: context.run_id, workspace: context.other, limit: 1]
                )

              revocation = Client.delete(client, "/api/auth/keys/#{id}")

              evidence = %{
                minted_workspace_scope: [context.primary],
                own_workspace: describe_search(allowed),
                other_workspace: describe(denied),
                revocation: describe(revocation)
              }

              cond do
                not ok_status?(allowed, 200) ->
                  {:fail,
                   Map.put(
                     evidence,
                     :expectation,
                     "a key scoped to its own workspace reads it (200)"
                   )}

                denied_status(denied) != 403 ->
                  {:fail,
                   Map.put(evidence, :expectation, "403 workspace_scope_denied on #{context.other}")}

                true ->
                  {:ok, evidence}
              end

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "POST /api/auth/keys",
                 status: status,
                 body: body,
                 expectation:
                   "201 when the supplied key may mint (admin scope); a scoped key cannot be minted otherwise"
               }}

            {:error, reason} ->
              {:fail, %{url: "POST /api/auth/keys", error: inspect(reason)}}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # authority
  # ---------------------------------------------------------------------------

  defp authority do
    [
      %{
        id: "authority.decide",
        group: "authority",
        description: "the authority answers a decision request with one effect and a reason",
        run: fn client, context ->
          body = %{
            action: "conformance.probe",
            resource: "optimal://conformance/probe",
            workspace_id: context.primary
          }

          case Client.post(client, "/api/authority/decide", body) do
            {:ok, %{status: 200, body: decision}} when is_map(decision) ->
              evidence = %{
                url: "POST /api/authority/decide",
                request: body,
                effect: decision["effect"],
                reason: decision["reason"],
                rule_id: decision["rule_id"]
              }

              if decision["effect"] in ["allow", "ask", "deny"] and is_binary(decision["reason"]) do
                {:ok, evidence}
              else
                {:fail,
                 Map.put(evidence, :expectation, "an effect of allow, ask, or deny with a reason")}
              end

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "POST /api/authority/decide",
                 status: status,
                 body: body,
                 expectation: "200 with a decision"
               }}

            {:error, reason} ->
              {:fail, %{url: "POST /api/authority/decide", error: inspect(reason)}}
          end
        end
      },
      %{
        id: "authority.evidence_chain",
        group: "authority",
        description: "the evidence ledger reads and its chain verifies",
        run: fn client, _context ->
          with {:ok, verify} <- fetch_json(client, "/api/authority/evidence/verify"),
               {:ok, entries} <- fetch_json(client, "/api/authority/evidence", query: [limit: 5]) do
            listed = entries.body["entries"]

            evidence = %{
              verify_status: verify.status,
              valid: verify.body["valid"],
              failure: verify.body["failure"],
              entries_status: entries.status,
              entries_returned: if(is_list(listed), do: length(listed), else: nil),
              entries: if(is_list(listed), do: Enum.take(listed, 2), else: listed)
            }

            cond do
              verify.status != 200 or verify.body["valid"] != true ->
                {:fail,
                 Map.put(
                   evidence,
                   :expectation,
                   "GET /api/authority/evidence/verify answers 200 with valid true"
                 )}

              entries.status != 200 or not is_list(listed) ->
                {:fail,
                 Map.put(
                   evidence,
                   :expectation,
                   "GET /api/authority/evidence answers 200 with an entry list"
                 )}

              true ->
                {:ok, evidence}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # stores
  # ---------------------------------------------------------------------------

  defp stores do
    [
      %{
        id: "stores.families_reachable",
        group: "stores",
        description: "every store family this build declares is listed and individually reachable",
        run: fn client, context ->
          with {:ok, index} <- fetch_json(client, "/api/stores") do
            listed = store_ids(index.body)
            expected = context.expected_stores
            reached = Enum.map(listed, fn id -> {id, store_probe(client, id)} end)
            unreachable = for {_id, probe} <- reached, probe.status != 200, do: probe

            evidence = %{
              url: "/api/stores",
              listed: listed,
              declared_by_this_build: expected,
              missing_from_api: if(is_list(expected), do: expected -- listed, else: nil),
              unreachable: unreachable
            }

            cond do
              index.status != 200 ->
                {:fail,
                 %{
                   url: "/api/stores",
                   status: index.status,
                   body: index.body,
                   expectation: "200 with the store inventory"
                 }}

              unreachable != [] ->
                {:fail,
                 Map.put(
                   evidence,
                   :expectation,
                   "GET /api/stores/<id> answers 200 for every listed family"
                 )}

              is_list(expected) and Enum.sort(expected) != Enum.sort(listed) ->
                {:fail,
                 Map.put(
                   evidence,
                   :expectation,
                   "the listed families equal the families this build declares"
                 )}

              true ->
                {:ok, evidence}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      },
      %{
        id: "stores.audit_verdict",
        group: "stores",
        description: "the store audit answers with a verdict and names what it flagged",
        run: fn client, _context ->
          case Client.get(client, "/api/stores/audit") do
            {:ok, %{status: status, body: body}} when status in [200, 503] and is_map(body) ->
              failures = body["checks"] |> List.wrap() |> Enum.reject(& &1["ok"])

              evidence = %{
                url: "/api/stores/audit",
                status: status,
                ok: body["ok"],
                checks: length(List.wrap(body["checks"])),
                failures: Enum.map(failures, &Map.take(&1, ["name", "detail"]))
              }

              if Map.has_key?(body, "ok") and Map.has_key?(body, "failures") do
                {:ok, evidence}
              else
                {:fail,
                 Map.put(evidence, :expectation, "a verdict with ok, checks, and failures fields")}
              end

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "/api/stores/audit",
                 status: status,
                 body: body,
                 expectation: "200 or 503 with a verdict"
               }}

            {:error, reason} ->
              {:fail, %{url: "/api/stores/audit", error: inspect(reason)}}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # storage
  # ---------------------------------------------------------------------------

  defp storage do
    [
      %{
        id: "storage.usage",
        group: "storage",
        description: "the size profile, its gauges, and the boot time answer for this Engine",
        run: fn client, _context ->
          with {:ok, response} <- fetch_json(client, "/api/storage") do
            gauges = List.wrap(get_in(response.body, ["gauges"]))
            names = gauges |> Enum.map(&Map.get(&1, "name")) |> Enum.reject(&is_nil/1)
            unread = Enum.filter(gauges, &(is_nil(&1["used"]) or is_nil(&1["percent"])))

            evidence = %{
              url: "/api/storage",
              status: response.status,
              profile: get_in(response.body, ["profile", "id"]),
              gauges: names,
              worst: get_in(response.body, ["worst"]),
              recommendation: get_in(response.body, ["recommendation"]),
              boot_ms: response.body["boot_ms"],
              missing_gauge_readings: unread
            }

            cond do
              response.status != 200 ->
                {:fail, Map.put(evidence, :expectation, "200 with the size gauges")}

              is_nil(evidence.profile) or names == [] ->
                {:fail, Map.put(evidence, :expectation, "a profile and at least one gauge")}

              unread != [] ->
                {:fail, Map.put(evidence, :expectation, "every gauge reports used and percent")}

              not is_integer(evidence.boot_ms) ->
                {:fail, Map.put(evidence, :expectation, "a boot time in milliseconds")}

              true ->
                {:ok, evidence}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      },
      %{
        id: "storage.profiles",
        group: "storage",
        description: "the size profiles are listed and one of them is active",
        run: fn client, _context ->
          with {:ok, response} <- fetch_json(client, "/api/storage/profiles") do
            ids =
              response.body
              |> Map.get("profiles", [])
              |> List.wrap()
              |> Enum.map(&Map.get(&1, "id"))
              |> Enum.reject(&is_nil/1)

            active = response.body["active"]

            evidence = %{
              url: "/api/storage/profiles",
              status: response.status,
              profile_ids: ids,
              active: active
            }

            if response.status == 200 and active in ids and length(ids) > 1 do
              {:ok, evidence}
            else
              {:fail,
               Map.put(evidence, :expectation, "200 listing the profiles with one of them active")}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # setup
  # ---------------------------------------------------------------------------

  defp setup do
    [
      %{
        id: "setup.preset_applies",
        group: "setup",
        description: "a listed use-case preset builds a workspace, and the run removes it again",
        run: fn client, context ->
          case Client.get(client, "/api/init/presets") do
            {:ok, %{status: 200, body: %{"presets" => presets}}}
            when is_list(presets) and presets != [] ->
              case presets
                   |> Enum.map(&Map.get(&1, "id"))
                   |> Enum.reject(&is_nil/1)
                   |> List.first() do
                nil ->
                  {:fail,
                   %{
                     url: "/api/init/presets",
                     presets: presets,
                     expectation: "each preset names an id"
                   }}

                preset ->
                  apply_preset(client, preset, context)
              end

            {:ok, %{status: status, body: body}} ->
              {:fail,
               %{
                 url: "/api/init/presets",
                 status: status,
                 body: body,
                 expectation: "200 listing at least one use-case preset"
               }}

            {:error, reason} ->
              {:fail, %{url: "/api/init/presets", error: inspect(reason)}}
          end
        end
      }
    ]
  end

  defp apply_preset(client, preset, context) do
    slug = "#{context.prefix}-#{context.run_id}-preset"

    case Client.post(client, "/api/init", %{"for" => preset, "slug" => slug, "name" => slug}) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        workspace = body["workspace_id"] || slug
        listed = workspace_listed?(client, slug)
        archived = Client.post(client, "/api/workspaces/#{URI.encode_www_form(workspace)}/archive")

        evidence = %{
          url: "POST /api/init",
          preset: preset,
          workspace: workspace,
          response_keys: map_keys(body),
          created: Map.get(body, "created"),
          listed_as_a_workspace: listed,
          archive: describe(archived)
        }

        if not is_nil(Map.get(body, "workspace_id")) and listed and ok_status?(archived, 204) do
          {:ok, evidence}
        else
          {:fail,
           Map.put(
             evidence,
             :expectation,
             "200 naming the new workspace, the workspace is listed, and the run archives it"
           )}
        end

      {:ok, %{status: status, body: body}} ->
        {:fail,
         %{
           url: "POST /api/init",
           preset: preset,
           status: status,
           body: body,
           expectation: "200 applying a preset (the key needs the admin scope)"
         }}

      {:error, reason} ->
        {:fail, %{url: "POST /api/init", preset: preset, error: inspect(reason)}}
    end
  end

  defp workspace_listed?(client, slug) do
    case Client.get(client, "/api/workspaces", query: [status: "all", limit: 500]) do
      {:ok, %{status: 200, body: body}} ->
        body |> Map.get("workspaces", []) |> List.wrap() |> Enum.any?(&(&1["slug"] == slug))

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # signal
  # ---------------------------------------------------------------------------

  defp signal do
    [
      %{
        id: "signal.pre_send_check",
        group: "signal",
        description: "a draft is checked before it is sent, and the verdict names its flags",
        run: fn client, context ->
          drafts = [
            %{
              "draft" =>
                "Delivery update: the supplier renewal moved to the 14th. The contract review is still open, and I will close it on Friday.",
              "genre" => "note",
              "type" => "inform"
            },
            %{"draft" => "hey quick q", "genre" => "note", "type" => "inform"}
          ]

          # The check records a signal event when it is given a workspace, so it
          # is given the disposable one when this run has one.
          results =
            Enum.map(drafts, fn draft ->
              body =
                draft
                |> Map.put("receiver", %{})
                |> maybe_put("workspace", context.write_target)

              {draft["draft"], Client.post(client, "/api/signals/check", body)}
            end)

          failures =
            for {_draft, result} <- results, not ok_status?(result, 200), do: describe(result)

          evidence = %{
            url: "POST /api/signals/check",
            workspace: context.write_target,
            results: Enum.map(results, &describe_check/1)
          }

          if failures == [] do
            {:ok, evidence}
          else
            {:fail, Map.put(evidence, :expectation, "200 with a check report for every draft")}
          end
        end
      }
    ]
  end

  defp describe_check({draft, {:ok, %{status: status, body: body}}}) do
    %{
      draft: String.slice(draft, 0, 60),
      status: status,
      ok: body["ok"],
      words: body["words"],
      detected: body["detected"],
      flags: body |> Map.get("flags", []) |> List.wrap() |> Enum.map(&Map.get(&1, "code"))
    }
  end

  defp describe_check({draft, {:error, reason}}),
    do: %{draft: String.slice(draft, 0, 60), error: inspect(reason)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # analyses and jobs
  # ---------------------------------------------------------------------------

  defp analyses do
    [
      %{
        id: "analyses.reports",
        group: "analyses",
        description: "the analysis reports for a workspace are listed with the kinds that can run",
        run: fn client, context ->
          with {:ok, response} <-
                 fetch_json(client, "/api/analyses", query: [workspace: context.primary]) do
            reports = List.wrap(response.body["reports"])
            kinds = List.wrap(response.body["kinds"])

            evidence = %{
              url: "/api/analyses",
              workspace: context.primary,
              status: response.status,
              reports: length(reports),
              kinds: kinds
            }

            cond do
              response.status != 200 ->
                {:fail, Map.put(evidence, :expectation, "200 with the analysis reports")}

              not is_list(response.body["reports"]) or kinds == [] ->
                {:fail,
                 Map.put(evidence, :expectation, "a report list and the runnable analysis kinds")}

              Enum.any?(kinds, &(not is_binary(&1))) ->
                {:fail, Map.put(evidence, :expectation, "each runnable analysis kind is named")}

              true ->
                {:ok, evidence}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      },
      %{
        id: "jobs.queue",
        group: "analyses",
        description: "the job queue and its dead letters answer for a workspace",
        run: fn client, context ->
          with {:ok, jobs} <- fetch_json(client, "/api/jobs", query: [workspace: context.primary]),
               {:ok, dead} <-
                 fetch_json(client, "/api/jobs/dead", query: [workspace: context.primary]) do
            evidence = %{
              jobs_url: "/api/jobs",
              jobs_status: jobs.status,
              jobs: length(List.wrap(jobs.body["jobs"])),
              dead_status: dead.status,
              dead_letters: length(List.wrap(dead.body["dead_letters"]))
            }

            if jobs.status == 200 and dead.status == 200 and is_list(jobs.body["jobs"]) and
                 is_list(dead.body["dead_letters"]) do
              {:ok, evidence}
            else
              {:fail, Map.put(evidence, :expectation, "200 with a job list and a dead letter list")}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # sync
  # ---------------------------------------------------------------------------

  defp sync do
    [
      %{
        id: "sync.status",
        group: "sync",
        description: "the replication status of a workspace reports its ledger and peers",
        run: fn client, context ->
          with {:ok, response} <-
                 fetch_json(client, "/api/sync/status", query: [workspace: context.primary]) do
            required =
              ~w(workspace_id enabled replica_id ledger_sequence open_conflicts append_only_tables peers)

            missing = missing_keys(response.body, required)

            evidence = %{
              url: "/api/sync/status",
              workspace: context.primary,
              status: response.status,
              missing_fields: missing,
              enabled: get_in(response.body, ["enabled"]),
              ledger_sequence: get_in(response.body, ["ledger_sequence"]),
              open_conflicts: get_in(response.body, ["open_conflicts"])
            }

            if response.status == 200 and missing == [] do
              {:ok, evidence}
            else
              {:fail, Map.put(evidence, :expectation, "200 reporting #{Enum.join(required, ", ")}")}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # viability
  # ---------------------------------------------------------------------------

  defp viability do
    [
      %{
        id: "viability.report",
        group: "viability",
        description:
          "the viability report for a workspace carries the systems, metrics, and trajectory sections",
        run: fn client, context ->
          with {:ok, response} <-
                 fetch_json(client, "/api/viability", query: [workspace: context.primary]) do
            required =
              ~w(scope tenant_id workspace_ids as_of window signals_received summary systems metrics variety trajectory)

            missing = missing_keys(response.body, required)

            evidence = %{
              url: "/api/viability",
              workspace: context.primary,
              status: response.status,
              missing_fields: missing,
              scope: get_in(response.body, ["scope"]),
              summary_keys: response.body |> Map.get("summary", %{}) |> map_keys(),
              systems: length(List.wrap(Map.get(response.body, "systems")))
            }

            if response.status == 200 and missing == [] do
              {:ok, evidence}
            else
              {:fail, Map.put(evidence, :expectation, "200 reporting #{Enum.join(required, ", ")}")}
            end
          else
            {:error, evidence} -> {:fail, evidence}
          end
        end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # operating layer
  # ---------------------------------------------------------------------------

  defp operating do
    [
      %{
        id: "operating.boot",
        group: "operating",
        description: "boot answers with the day, rhythm, fires, open loops, brief, and protocol",
        run: fn client, context ->
          shape_check(
            client,
            "/api/boot",
            [workspace: context.primary],
            ~w(workspace_id date weekday timezone rhythm fires open_loops recent_decisions stale brief protocol)
          )
        end
      },
      %{
        id: "operating.brief",
        group: "operating",
        description: "the brief answers with ranked items and their counts",
        run: fn client, context ->
          shape_check(
            client,
            "/api/brief",
            [workspace: context.primary],
            ~w(date scope items counts)
          )
        end
      },
      %{
        id: "operating.loops_list",
        group: "operating",
        description: "the loop list answers with loops and a count",
        run: fn client, context ->
          shape_check(client, "/api/loops", [workspace: context.primary], ~w(loops count))
        end
      },
      %{
        id: "operating.loop_lifecycle",
        group: "operating",
        description: "a loop can be opened, found in the open list, and closed",
        run: fn client, context ->
          case context.write_target do
            nil ->
              {:skip,
               "the run was given workspaces to read, so a probe loop would persist in one of them"}

            workspace ->
              loop_lifecycle(client, workspace, context)
          end
        end
      }
    ]
  end

  defp loop_lifecycle(client, workspace, context) do
    title = "conformance probe #{context.run_id}"

    case Client.post(client, "/api/loops", %{
           workspace_id: workspace,
           title: title,
           kind: "follow_up"
         }) do
      {:ok, %{status: 201, body: %{"id" => id} = loop}} ->
        listed =
          Client.get(client, "/api/loops", query: [workspace: workspace, state: "open", limit: 200])

        found = listed_loop?(listed, id)
        closed = Client.post(client, "/api/loops/#{id}/close", %{workspace_id: workspace})

        evidence = %{
          created: %{id: id, kind: loop["kind"], title: loop["title"]},
          listed_as_open: found,
          close: describe(closed)
        }

        if found and ok_status?(closed, 200) do
          {:ok, evidence}
        else
          {:fail,
           Map.put(evidence, :expectation, "201 on create, present in the open list, 200 on close")}
        end

      {:ok, %{status: status, body: body}} ->
        {:fail,
         %{
           url: "POST /api/loops",
           status: status,
           body: body,
           expectation: "201 with the created loop"
         }}

      {:error, reason} ->
        {:fail, %{url: "POST /api/loops", error: inspect(reason)}}
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup
  # ---------------------------------------------------------------------------

  @doc """
  The teardown check: after the run archives what it created, nothing carrying
  the run identifier is left behind.
  """
  @spec cleanup() :: check()
  def cleanup do
    %{
      id: "cleanup.no_leftovers",
      group: "cleanup",
      description: "the run leaves no workspace or key behind",
      run: fn client, context ->
        workspaces = Client.get(client, "/api/workspaces", query: [status: "all", limit: 500])
        keys = Client.get(client, "/api/auth/keys", query: [limit: 500])

        leftovers = %{
          workspaces:
            matching_names(workspaces, "workspaces", context.run_id, ["id", "slug", "name"]),
          keys: matching_names(keys, "keys", context.run_id, ["id", "name", "prefix"])
        }

        evidence = %{
          run_id: context.run_id,
          archived_workspaces: context.archived,
          leftovers: leftovers,
          listed: %{
            workspaces: count_of(workspaces, "workspaces"),
            keys: count_of(keys, "keys")
          }
        }

        cond do
          not ok_status?(workspaces, 200) or not ok_status?(keys, 200) ->
            {:fail,
             Map.put(
               evidence,
               :expectation,
               "the run can list workspaces and keys to prove it left nothing"
             )}

          leftovers.workspaces == [] and leftovers.keys == [] ->
            {:ok, evidence}

          true ->
            {:fail,
             Map.put(
               evidence,
               :expectation,
               "no active workspace or key named with the run identifier"
             )}
        end
      end
    }
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp shape_check(client, path, query, required) do
    with {:ok, response} <- fetch_json(client, path, query: query) do
      missing = missing_keys(response.body, required)

      evidence = %{
        url: path,
        query: Enum.into(query, %{}),
        status: response.status,
        missing_fields: missing,
        keys: map_keys(response.body)
      }

      if response.status == 200 and missing == [] do
        {:ok, evidence}
      else
        {:fail, Map.put(evidence, :expectation, "200 reporting #{Enum.join(required, ", ")}")}
      end
    else
      {:error, evidence} -> {:fail, evidence}
    end
  end

  defp fetch_json(client, path, opts \\ []) do
    case Client.get(client, path, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, %{url: path, error: inspect(reason), expectation: "a reachable Engine"}}
    end
  end

  defp store_probe(client, id) do
    case Client.get(client, "/api/stores/#{URI.encode_www_form(id)}") do
      {:ok, %{status: status, body: body}} ->
        %{id: id, status: status, reported_id: if(is_map(body), do: body["id"])}

      {:error, reason} ->
        %{id: id, status: nil, error: inspect(reason)}
    end
  end

  defp store_ids(body) do
    body
    |> Map.get("stores", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"id" => id} -> id
      other -> inspect(other)
    end)
  end

  defp contract_drift(identity) do
    case contract() do
      nil ->
        []

      contract ->
        fields = [
          "repository",
          "version",
          "api_version",
          "contract_version",
          "expected_migration",
          "capabilities"
        ]

        for field <- fields,
            Map.has_key?(contract, field),
            contract[field] != identity[field] do
          %{field: field, engine: identity[field], checkout: contract[field]}
        end
    end
  end

  defp contract do
    path = Path.expand("../../../engine-contract.json", __DIR__)

    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, _} -> nil
    end
  end

  defp valid_channel?(channel), do: channel in OptimalEngine.Version.release_channels()

  defp missing_keys(body, keys) when is_map(body), do: Enum.reject(keys, &Map.has_key?(body, &1))
  defp missing_keys(_body, keys), do: keys

  defp map_keys(body) when is_map(body), do: body |> Map.keys() |> Enum.sort()
  defp map_keys(_body), do: nil

  defp error_of(body) when is_map(body), do: body["error"]
  defp error_of(body), do: body

  defp ok_status?(response, expected) do
    match?({:ok, %{status: ^expected}}, response)
  end

  defp denied_status(response) do
    case response do
      {:ok, %{status: status, body: body}} ->
        if is_map(body) and body["error"] == "workspace_scope_denied", do: 403, else: status

      {:error, _reason} ->
        nil
    end
  end

  defp describe({:ok, %{status: status, body: body}}), do: %{status: status, body: body}
  defp describe({:error, reason}), do: %{error: inspect(reason)}

  defp listed_loop?({:ok, %{status: 200, body: body}}, id) when is_map(body) do
    body |> Map.get("loops", []) |> List.wrap() |> Enum.any?(&(is_map(&1) and &1["id"] == id))
  end

  defp listed_loop?(_response, _id), do: false

  # Search bodies can be long; evidence keeps the envelope and the first result.
  defp describe_search({:ok, %{status: status, body: body}}) when is_map(body) do
    results = Map.get(body, "results", Map.get(body, "memories", []))

    %{
      status: status,
      result_count: if(is_list(results), do: length(results), else: nil),
      first_result:
        results |> List.wrap() |> Enum.take(1) |> Enum.map(&Map.take(&1, ["id", "uri", "title"]))
    }
  end

  defp describe_search(response), do: describe(response)

  defp count_of({:ok, %{body: body}}, key), do: body |> Map.get(key, []) |> List.wrap() |> length()
  defp count_of(_response, _key), do: nil

  defp matching_names({:ok, %{body: body}}, key, run_id, fields) do
    body
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(fn entry ->
      is_map(entry) and active?(entry) and
        Enum.any?(fields, fn field -> to_string(entry[field] || "") =~ run_id end)
    end)
    |> Enum.map(&Map.take(&1, fields))
  end

  defp matching_names(_response, _key, _run_id, _fields), do: []

  # An archived workspace or a revoked key is spent; the run left nothing that
  # still operates, which is what the check is about.
  defp active?(entry) do
    entry["status"] in [nil, "active"] and is_nil(entry["revoked_at"])
  end

  defp normalize_external(check, path) when is_map(check) do
    check
    |> Map.put_new(:group, "external")
    |> Map.put_new(:description, "extra check from #{path}")
    |> Map.put_new(:run, fn _client, _context ->
      {:fail, %{path: path, error: "check has no run function"}}
    end)
    |> Map.update(:id, "external.#{Path.basename(path)}", fn id -> id end)
  end

  defp normalize_external(other, path) do
    %{
      id: "external.invalid",
      group: "external",
      description: "extra checks from #{path} are check maps",
      run: fn _client, _context ->
        {:fail, %{path: path, error: "not a check map", got: inspect(other)}}
      end
    }
  end
end
