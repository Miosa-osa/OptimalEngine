defmodule OptimalEngine.UriRepair do
  @moduledoc """
  Separates contexts that share an `optimal://` URI, and gives every one of them
  its own file again.

  Before addresses were unique (`OptimalEngine.Pipeline.Intake.Address`), two
  contexts whose titles agreed on their first 60 characters, that had the same
  title on the same day, or that were untitled, were written to one file path
  and so received one URI. Each write replaced the file of the one before; every
  row survived under the same address, and the file held the last writer's text.
  What was lost is the file, not the context: `contexts.content` still holds the
  source text of each, and this job writes the files again from it.

  ## What a run does

  For each workspace, every set of active signal contexts that have a file and
  share a URI is one group:

    * the earliest context (`created_at`, then id) **keeps** the address;
    * every other context gets the address a new ingest would give it: the first
      8 characters of its id before the extension of its file name and of its
      URI (longer if that is taken), in its own folder;
    * a group in which any of these contexts has no text is **skipped** and
      reported: there is nothing to write for it;
    * a group with a path that is not inside its workspace's folder (a row's
      path is data, and a bundle import copies it as it is) is **skipped** and
      reported before any file is read or written;
    * the new files are written from the rows **before** anything else changes.
      Contexts routed to other nodes get their cross-reference copies written
      too, under the new name, and indexed as copies of the context;
    * the file at the kept address holds the last writer's text. When its body
      (everything after the frontmatter) is **byte for byte** the rendered body
      of another member of the group, it is replaced by the keeper's own text,
      after the old bytes are copied into the run's backups; the same is done
      for the keeper's cross-reference copies. A file whose body matches no
      member (edited by hand) is left alone and reported with the reason; a
      missing file is created;
    * last, in one transaction per group, the rows move: each repaired row
      records where it was in `metadata.uri_repair` (`previous_uri`,
      `previous_path`, `kept_by`, `repaired_at`), the `acls` rows of the shared
      URI are copied to its new URI, and the memories and open loops that name
      the context by id are moved to it.

  Because the rows move last, a group that has been separated has all its files.
  A run that stops at any point is resumed by running again: the files already
  written are recognised by their bytes, the kept file by its body, and the
  group is still a group until its transaction commits.

  ## What it records

  A real run writes an append-only journal and the backups of every file it
  replaced under `<root>/.system/uri-repair/<run id>/` (see
  `OptimalEngine.UriRepair.Journal`), and logs each group. Every file is written
  through `OptimalEngine.AtomicFile`: temporary file, flush, rename, flush of the
  folder.

  ## What it leaves alone, and counts

    * Archived contexts. Their rows may share an address with active ones
      (connectors left thousands of empty archived rows on one URI); a file is
      not written for a retired context.
    * Rows that index the same file as another row (`Address.file_index_id/1`
      names the row of a file): one document, indexed twice, not two documents.
    * Rows with no path (stored without a file) and contexts that are not
      signals.
    * Summary sidecars (`.abstract.md`, `.overview.md`): derived, written again
      by the next semantic pass under the new name.

  A context whose stored URI is not the address of its own path (an older URI
  scheme) is repaired like any other and counted under `uri_differs_from_path`,
  with the reason in the plan. A context that sits in another folder than the
  keeper gets its suffixed address in its own folder; the file it had there is
  not the kept file and is not removed, and the plan counts it under
  `old_files_left_in_place`.

  ## References by URI

  `events.target_uri`, the closing source of an open loop and `{{cite: uri}}`
  directives in wiki pages name a context by URI only. After the repair they
  resolve to the context that keeps the address. The plan counts them per group.

  Run it with ingest idle. `dry_run: true` reads and plans only.
  """

  require Logger

  alias OptimalEngine.AtomicFile
  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Indexer
  alias OptimalEngine.Pipeline.Intake.Address
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Store
  alias OptimalEngine.UriRepair.{Journal, References}
  alias OptimalEngine.URI
  alias OptimalEngine.Workspace.Filesystem

  @epoch ~U[1970-01-01 00:00:00Z]
  @steps [:member_files, :cross_copies, :kept_file, :kept_copies, :rows]

  @counters ~w(groups groups_remaining contexts kept repaired groups_skipped_empty_content
               groups_skipped_outside_workspace
               uri_differs_from_path old_files_left_in_place files_to_write files_to_rewrite files_left_alone
               files_already_correct files_already_written bytes_to_write files_written
               files_rewritten cross_copies_written cross_copies_rewritten backups acls_copied
               memories_moved open_loops_moved skipped_archived skipped_twins skipped_no_file
               skipped_not_signal)a

  @type report :: %{
          :dry_run => boolean(),
          :files_regenerated => non_neg_integer(),
          :errors => [map()],
          :groups_detail => [map()],
          :workspaces => [map()],
          :next_after => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Separates the contexts that share a URI.

  Options:

    * `:workspace_id` and `:tenant_id` restrict the run (default: every
      workspace);
    * `:dry_run` (default `false`) plans without writing;
    * `:limit` takes at most that many groups (default: all) and reports the
      rest as `groups_remaining`;
    * `:after` (a cursor from `cursor/1`, or the `next_after` of a report)
      starts after that group, so a plan is read in pages.

  The report has the totals as flat counters (`groups`, `contexts`, `repaired`,
  `files_to_write`, `files_to_rewrite`, `files_left_alone`, `bytes_to_write`,
  `skipped_*`, and for a real run `files_written`, `files_rewritten`, ...),
  `workspaces` (the same per workspace), and `groups_detail`: for every group
  its keeper, each context's old and new address and bytes, what happens to the
  kept file and why, and the records that name the shared URI.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    with {:ok, members} <- shared_members(opts),
         {:ok, journal} <- open_journal(dry_run?, opts) do
      groups = members |> Enum.chunk_by(&{&1.workspace_id, &1.uri}) |> Enum.map(&split_group/1)

      report =
        Enum.reduce(groups, new_report(dry_run?, journal), fn group, report ->
          report
          |> bump(:skipped_archived, length(group.archived))
          |> bump(:skipped_twins, length(group.file_rows))
          |> bump(:skipped_no_file, length(group.no_file))
          |> bump(:skipped_not_signal, length(group.not_signal))
        end)

      {batch, rest} =
        groups
        |> Enum.filter(&match?(%{addressed: [_, _ | _]}, &1))
        |> after_cursor(Keyword.get(opts, :after))
        |> take_groups(Keyword.get(opts, :limit))

      note(journal, %{event: "run_started", dry_run: false, options: inspect(opts)})

      report =
        Enum.reduce(batch, %{report | groups_remaining: length(rest)}, fn group, report ->
          repair(group, report, journal)
        end)

      report = finish(report, batch, rest)
      note(journal, %{event: "run_finished", counters: counters(report)})
      log_run(report)
      {:ok, report}
    end
  end

  @doc "The plan of a run, without writing anything. Same as `run(dry_run: true)`."
  @spec scan(keyword()) :: {:ok, report()} | {:error, term()}
  def scan(opts \\ []), do: run(Keyword.put(opts, :dry_run, true))

  @doc "The cursor that makes `:after` start after the group of `workspace_id` and `uri`."
  @spec cursor(String.t(), String.t()) :: String.t()
  def cursor(workspace_id, uri),
    do: Base.url_encode64(Jason.encode!([workspace_id, uri]), padding: false)

  @doc "Reads a cursor; `nil` for anything that is not one."
  @spec decode_cursor(term()) :: {String.t(), String.t()} | nil
  def decode_cursor(value) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [workspace_id, uri]} when is_binary(workspace_id) and is_binary(uri) <-
           Jason.decode(json) do
      {workspace_id, uri}
    else
      _ -> nil
    end
  end

  def decode_cursor({workspace_id, uri} = key) when is_binary(workspace_id) and is_binary(uri),
    do: key

  def decode_cursor(_), do: nil

  # -- the contexts that share an address -----------------------------------

  # Every row that shares its URI with another in the workspace; what each is
  # decides below whether it is part of a collision.
  defp shared_members(opts) do
    {filter, params} = scope_filter(opts)

    sql = """
    SELECT c.id, c.tenant_id, c.workspace_id, c.uri, c.type, c.path, c.created_at,
           c.archived_at IS NOT NULL
    FROM contexts c
    JOIN (
      SELECT workspace_id, uri FROM contexts
      WHERE uri != ''#{filter}
      GROUP BY workspace_id, uri
      HAVING COUNT(*) > 1
    ) d ON d.workspace_id = c.workspace_id AND d.uri = c.uri
    ORDER BY c.workspace_id, c.uri, (c.created_at IS NULL), c.created_at, c.id
    """

    with {:ok, rows} <- Store.raw_query(sql, params) do
      {:ok,
       Enum.map(rows, fn [id, tenant_id, workspace_id, uri, type, path, created_at, archived] ->
         %{
           id: id,
           tenant_id: tenant_id,
           workspace_id: workspace_id,
           uri: uri,
           type: type,
           path: path,
           created_at: created_at,
           archived: archived in [1, true]
         }
       end)}
    end
  end

  defp scope_filter(opts) do
    [workspace_id: "workspace_id", tenant_id: "tenant_id"]
    |> Enum.flat_map(fn {key, column} ->
      case Keyword.get(opts, key) do
        value when is_binary(value) and value != "" -> [{column, value}]
        _ -> []
      end
    end)
    |> Enum.with_index(1)
    |> Enum.reduce({"", []}, fn {{column, value}, n}, {sql, params} ->
      {sql <> " AND #{column} = ?#{n}", params ++ [value]}
    end)
  end

  # The members of one (workspace, URI) group by what they are, in order. Only
  # `addressed` contexts really share the address.
  defp split_group(members) do
    empty = %{archived: [], not_signal: [], no_file: [], file_rows: [], addressed: []}

    members
    |> Enum.reverse()
    |> Enum.reduce(empty, fn member, groups ->
      Map.update!(groups, kind(member), &[member | &1])
    end)
  end

  defp kind(%{archived: true}), do: :archived
  defp kind(%{type: type}) when type != "signal", do: :not_signal
  defp kind(%{path: path}) when path in [nil, ""], do: :no_file

  # The row the indexer keeps for a file is the same document as the row that
  # was written for it, indexed twice: not a second document.
  defp kind(%{id: id, path: path}) do
    if id == Address.file_index_id(path), do: :file_rows, else: :addressed
  end

  defp after_cursor(groups, nil), do: groups

  defp after_cursor(groups, cursor) do
    case decode_cursor(cursor) do
      nil -> groups
      key -> Enum.filter(groups, &(group_key(&1) > key))
    end
  end

  defp group_key(%{addressed: [first | _]}), do: {first.workspace_id, first.uri}

  defp take_groups(groups, limit) when is_integer(limit) and limit > 0,
    do: Enum.split(groups, limit)

  defp take_groups(groups, _limit), do: {groups, []}

  # -- one group ---------------------------------------------------------------

  defp repair(group, report, journal) do
    [keeper | repaired] = group.addressed

    report =
      report
      |> bump(:groups, 1)
      |> bump(:contexts, 1 + length(repaired))

    case plan_group(group) do
      {:ok, plan} ->
        report = count_plan(report, plan, journal == nil)

        if journal do
          apply_plan(plan, report, journal)
        else
          add_detail(report, public(plan))
        end

      {:skipped, :empty_content, detail} ->
        report
        |> bump(:groups_skipped_empty_content, 1)
        |> add_detail(detail)

      {:skipped, :outside_workspace, detail} ->
        report
        |> bump(:groups_skipped_outside_workspace, 1)
        |> add_detail(detail)

      {:error, reason} ->
        error(report, keeper.id, reason)
    end
  end

  defp load(%{id: id}) do
    case Store.get_context(id) do
      {:ok, %Context{} = ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, {:context_unreadable, id, reason}}
    end
  end

  defp load_all(members) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, acc} ->
      case load(member) do
        {:ok, ctx} -> {:cont, {:ok, [ctx | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # -- plan: what would happen to one group ------------------------------------

  defp plan_group(group) do
    [keeper | repaired] = group.addressed

    with {:ok, keeper_ctx} <- load(keeper),
         {:ok, contexts} <- load_all(repaired) do
      all = [keeper_ctx | contexts]

      with {:outside, []} <- {:outside, outside_workspace(all)},
           {:empty, []} <- {:empty, Enum.filter(all, &blank?(&1.content))} do
        plan_repair(group, keeper, keeper_ctx, repaired, contexts)
      else
        {:outside, outside} ->
          {:skipped, :outside_workspace, outside_detail(group, keeper_ctx, outside)}

        {:empty, empty} ->
          {:skipped, :empty_content, skipped_detail(group, keeper_ctx, empty)}
      end
    end
  end

  # Every path the repair would read or write for a group must lie in its
  # workspace's folder. A row's path is data (a bundle import copies it as it
  # is), so a crafted one could otherwise make the repair read or create files
  # in another tenant's folder. The check runs before any file is touched.
  defp outside_workspace(contexts) do
    contexts
    |> Enum.flat_map(fn %Context{} = ctx ->
      base = Path.expand(Filesystem.path(root_path(), ctx.workspace_id))
      copy_dirs = ctx |> cross_nodes() |> Enum.map(&signals_dir(&1, ctx.workspace_id))

      for path <- [ctx.path | copy_dirs],
          is_binary(path),
          not inside?(path, base),
          do: path
    end)
    |> Enum.uniq()
  end

  defp inside?(path, base), do: String.starts_with?(Path.expand(path), base <> "/")

  defp root_path, do: Application.get_env(:optimal_engine, :root_path, "")

  defp plan_repair(group, keeper, keeper_ctx, repaired, contexts) do
    with {:ok, moves} <- plan_moves(keeper, Enum.zip(repaired, contexts)) do
      others = Enum.map(moves, & &1.context)
      kept_file = plan_kept_file(keeper_ctx, others, group.archived)

      {:ok,
       %{
         keeper: keeper,
         keeper_ctx: keeper_ctx,
         moves: moves,
         kept_file: kept_file,
         kept_copies: plan_kept_copies(keeper_ctx, others, group.archived),
         keeper_differs: keeper.uri != URI.from_path(keeper.path),
         references: References.counts(keeper.tenant_id, keeper.workspace_id, keeper.uri),
         archived: length(group.archived)
       }}
    end
  end

  defp plan_moves(keeper, pairs) do
    pairs
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {member, ctx}, {:ok, moves, reserved} ->
      case plan_move(keeper, member, ctx, reserved) do
        {:ok, move} -> {:cont, {:ok, [move | moves], MapSet.put(reserved, move.to_path)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, moves, _reserved} -> {:ok, Enum.reverse(moves)}
      {:error, _} = error -> error
    end
  end

  # The first suffix of the id, shortest first, whose file name and URI no
  # other context holds in the workspace.
  defp plan_move(keeper, member, ctx, reserved) do
    text = text_of(ctx)
    dir = Path.dirname(member.path)

    free =
      Enum.find_value(Address.candidate_suffixes(member.id), fn suffix ->
        to_path = Path.join(dir, Address.suffixed(Path.basename(member.path), suffix))
        to_uri = Address.suffixed(member.uri, suffix)

        unless MapSet.member?(reserved, to_path) or
                 Address.taken?(to_path, member.id, member.workspace_id, text) or
                 uri_taken?(member, to_uri) do
          {to_path, to_uri}
        end
      end)

    case free do
      nil ->
        {:error, {:no_free_name, member.id}}

      {to_path, to_uri} ->
        {:ok,
         %{
           id: member.id,
           tenant_id: member.tenant_id,
           workspace_id: member.workspace_id,
           from_uri: member.uri,
           from_path: member.path,
           to_uri: to_uri,
           to_path: to_path,
           kept_by: keeper.id,
           context: ctx,
           text: text,
           target: file_state(to_path, text),
           uri_differs_from_path: member.uri != URI.from_path(member.path),
           old_file_stays: member.path != keeper.path and File.exists?(member.path),
           from_sha256: sha_of_file(member.path),
           copies: plan_copies(ctx, to_path)
         }}
    end
  end

  defp uri_taken?(member, uri) do
    case Store.raw_query(
           "SELECT 1 FROM contexts WHERE workspace_id = ?1 AND uri = ?2 AND id != ?3 LIMIT 1",
           [member.workspace_id, uri, member.id]
         ) do
      {:ok, []} -> false
      _ -> true
    end
  end

  # The cross-reference copies of a repaired context, under its new name.
  defp plan_copies(%Context{} = ctx, primary_path) do
    Enum.flat_map(cross_nodes(ctx), fn node ->
      signal = %{signal_of(ctx) | node: node}
      text = Writer.render(signal, cross_ref_from: ctx.node)
      dir = signals_dir(node, ctx.workspace_id)

      case Address.resolve(signal, dir, Path.basename(primary_path), text,
             workspace_id: ctx.workspace_id
           ) do
        {:ok, name} ->
          path = Path.join(dir, name)
          [%{node: node, path: path, bytes: byte_size(text), target: file_state(path, text)}]

        {:error, _} ->
          []
      end
    end)
  end

  # What the kept address's file is, and what is done about it. Only a file
  # whose body is byte for byte another member's text is replaced.
  defp plan_kept_file(%Context{} = keeper, others, archived) do
    classify_file(keeper.path, keeper, others, archived, text_of(keeper))
  end

  defp plan_kept_copies(%Context{} = keeper, others, archived) do
    keeper
    |> cross_nodes()
    |> Enum.map(fn node ->
      path = Path.join(signals_dir(node, keeper.workspace_id), Path.basename(keeper.path))
      text = Writer.render(%{signal_of(keeper) | node: node}, cross_ref_from: keeper.node)

      case File.read(path) do
        {:error, :enoent} ->
          %{node: node, path: path, action: "left_alone", reason: "there is no copy there"}

        _ ->
          Map.put(classify_file(path, keeper, others, archived, text), :node, node)
      end
    end)
  end

  defp classify_file(path, %Context{} = keeper, others, archived, new_text) do
    base = %{path: path, bytes: byte_size(new_text), holds: nil, text: new_text}

    case File.read(path) do
      {:error, :enoent} ->
        Map.merge(base, %{action: "create", reason: "there is no file at the kept address"})

      {:error, reason} ->
        Map.merge(base, %{action: "left_alone", reason: "the file cannot be read: #{reason}"})

      {:ok, found} ->
        keeper_body = body_of(keeper)

        case Writer.body_of_file(found) do
          :no_frontmatter ->
            Map.merge(base, %{action: "left_alone", reason: "the file has no frontmatter"})

          {:ok, ^keeper_body} ->
            Map.merge(base, %{action: "unchanged", reason: "it holds the keeper's own text"})

          {:ok, body} ->
            case holder(body, keeper, others, archived) do
              nil ->
                Map.merge(base, %{
                  action: "left_alone",
                  reason: "its body is the text of no context of the group (edited?)"
                })

              id ->
                Map.merge(base, %{
                  action: "rewrite",
                  holds: id,
                  holder_body: body,
                  reason: "its body is exactly the text of context #{id}"
                })
            end
        end
    end
  end

  # The id of the member of the group whose rendered body is `body`: a context
  # still in the group, an archived one, or one that an earlier run of this
  # repair already moved away from the keeper's address.
  defp holder(body, keeper, others, archived) do
    Enum.find_value(others, fn ctx -> if body_of(ctx) == body, do: ctx.id end) ||
      Enum.find_value(archived, &body_of_member(&1, body)) ||
      Enum.find_value(moved_siblings(keeper), &body_of_member(&1, body))
  end

  defp body_of_member(member, body) do
    case load(member) do
      {:ok, ctx} -> if body_of(ctx) == body, do: ctx.id
      {:error, _} -> nil
    end
  end

  # Contexts that `metadata.uri_repair` says were separated from this keeper.
  defp moved_siblings(%Context{} = keeper) do
    pattern = "%\"kept_by\":\"" <> escape_like(keeper.id) <> "\"%"

    case Store.raw_query(
           "SELECT id FROM contexts WHERE workspace_id = ?1 AND metadata LIKE ?2 ESCAPE '\\'",
           [keeper.workspace_id, pattern]
         ) do
      {:ok, rows} -> Enum.map(rows, fn [id] -> %{id: id} end)
      _ -> []
    end
  end

  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp skipped_detail(group, keeper_ctx, empty) do
    ids = Enum.map(empty, & &1.id)

    %{
      workspace_id: keeper_ctx.workspace_id,
      uri: keeper_ctx.uri,
      status: "skipped",
      skip: "empty_content",
      reason: "a context of the group has no text to write: #{Enum.join(ids, ", ")}",
      contexts: Enum.map(group.addressed, &Map.take(&1, [:id, :path, :created_at])),
      empty_contexts: ids
    }
  end

  defp outside_detail(group, keeper_ctx, outside) do
    %{
      workspace_id: keeper_ctx.workspace_id,
      uri: keeper_ctx.uri,
      status: "skipped",
      skip: "outside_workspace",
      reason:
        "a path of the group is not inside the folder of workspace #{keeper_ctx.workspace_id}, " <>
          "so nothing is read or written for it: #{Enum.join(outside, ", ")}",
      contexts: Enum.map(group.addressed, &Map.take(&1, [:id, :path, :created_at])),
      paths_outside_workspace: outside
    }
  end

  # -- the public view of a plan -------------------------------------------------

  defp public(plan) do
    keeper = plan.keeper_ctx

    %{
      workspace_id: keeper.workspace_id,
      uri: keeper.uri,
      status: "repair",
      keeper: %{
        id: keeper.id,
        title: keeper.title,
        path: keeper.path,
        uri: keeper.uri,
        uri_differs_from_path: plan.keeper_differs
      },
      contexts:
        Enum.map(plan.moves, fn move ->
          %{
            id: move.id,
            title: move.context.title,
            from_uri: move.from_uri,
            from_path: move.from_path,
            to_uri: move.to_uri,
            to_path: move.to_path,
            bytes: byte_size(move.text),
            sha256: AtomicFile.sha256(move.text),
            file: move.target,
            uri_differs_from_path: move.uri_differs_from_path,
            old_file_stays: move.old_file_stays,
            uri_differs_reason:
              if(move.uri_differs_from_path,
                do: "the stored URI is not the address of its path (an older URI scheme)"
              ),
            cross_copies: Enum.map(move.copies, &Map.take(&1, [:node, :path, :bytes, :target])),
            acl_rows: plan.references.acls
          }
        end),
      kept_file: Map.drop(plan.kept_file, [:text, :holder_body]),
      kept_cross_copies: Enum.map(plan.kept_copies, &Map.drop(&1, [:text, :holder_body])),
      references: plan.references,
      archived_ignored: plan.archived
    }
  end

  defp count_plan(report, plan, dry_run?) do
    moves = plan.moves
    writes = Enum.filter(moves, &(&1.target == "absent"))
    copies = Enum.flat_map(moves, & &1.copies)
    copy_writes = Enum.filter(copies, &(&1.target == "absent"))
    keeper_files = [plan.kept_file | plan.kept_copies]
    action = fn name -> Enum.filter(keeper_files, &(&1.action == name)) end

    bytes =
      Enum.sum(Enum.map(writes, &byte_size(&1.text))) +
        Enum.sum(Enum.map(copy_writes, & &1.bytes)) +
        Enum.sum(Enum.map(action.("create") ++ action.("rewrite"), & &1.bytes))

    report
    |> bump(:kept, 1)
    |> bump(:repaired, if(dry_run?, do: length(moves), else: 0))
    |> bump(
      :uri_differs_from_path,
      Enum.count(moves, & &1.uri_differs_from_path) + if(plan.keeper_differs, do: 1, else: 0)
    )
    |> bump(:old_files_left_in_place, Enum.count(moves, & &1.old_file_stays))
    |> bump(:files_to_write, length(writes) + length(copy_writes) + length(action.("create")))
    |> bump(:files_to_rewrite, length(action.("rewrite")))
    |> bump(:files_left_alone, length(action.("left_alone")))
    |> bump(:files_already_correct, length(action.("unchanged")))
    |> bump(
      :files_already_written,
      Enum.count(moves, &(&1.target == "present_same_bytes")) +
        Enum.count(copies, &(&1.target == "present_same_bytes"))
    )
    |> bump(:bytes_to_write, bytes)
  end

  # -- apply: one group, rows last ---------------------------------------------

  defp apply_plan(plan, report, journal) do
    detail = public(plan)
    note(journal, %{event: "group_started", workspace_id: detail.workspace_id, uri: detail.uri})

    case execute(plan, journal) do
      {:ok, done} ->
        Logger.info(
          "[UriRepair] #{detail.workspace_id} #{detail.uri}: kept #{plan.keeper.id}, " <>
            "#{done.repaired} contexts given their own address, " <>
            "#{done.files_written + done.cross_copies_written} files written"
        )

        report |> add_done(done) |> add_detail(Map.put(detail, :done, done))

      {:error, step, reason, done} ->
        Logger.warning(
          "[UriRepair] #{detail.workspace_id} #{detail.uri}: stopped at #{step}: #{inspect(reason)}"
        )

        report
        |> add_done(done)
        |> error(plan.keeper.id, {step, reason})
        |> add_detail(Map.put(detail, :done, Map.put(done, :stopped_at, step)))
    end
  end

  defp execute(plan, journal) do
    checkpoint(:started)

    Enum.reduce_while(@steps, {:ok, new_done()}, fn step, {:ok, done} ->
      with {:ok, delta} <- run_step(step, plan, journal),
           :ok <- checkpoint(step) do
        {:cont, {:ok, merge_done(done, delta)}}
      else
        {:error, reason} -> {:halt, {:error, step, reason, done}}
      end
    end)
  end

  # 1. The new files of the repaired contexts.
  defp run_step(:member_files, plan, journal) do
    plan.moves
    |> Enum.reduce_while({:ok, %{}}, fn move, {:ok, delta} ->
      case create_file(move.to_path, move.text) do
        {:ok, written} ->
          note(journal, %{
            event: "file_written",
            context_id: move.id,
            workspace_id: move.workspace_id,
            old_uri: move.from_uri,
            new_uri: move.to_uri,
            old_path: move.from_path,
            new_path: move.to_path,
            old_sha256: nil,
            new_sha256: AtomicFile.sha256(move.text),
            already_there: written == :same
          })

          {:cont,
           {:ok,
            bump_delta(
              delta,
              if(written == :same, do: :files_already_written, else: :files_written)
            )}}

        {:error, reason} ->
          {:halt, {:error, {:file_not_written, move.id, reason}}}
      end
    end)
  end

  # 2. Their cross-reference copies, indexed as copies of the context.
  defp run_step(:cross_copies, plan, journal) do
    Enum.reduce_while(plan.moves, {:ok, %{}}, fn move, {:ok, delta} ->
      ctx = %{move.context | path: move.to_path, uri: move.to_uri}
      nodes = cross_nodes(ctx)

      if nodes == [] do
        {:cont, {:ok, delta}}
      else
        opts = [workspace_id: ctx.workspace_id, primary_path: move.to_path]

        with {:ok, paths} <- Writer.write_cross_references(signal_of(ctx), nodes, opts),
             :ok <- index_copies(ctx, paths) do
          Enum.each(paths, fn path ->
            note(journal, %{
              event: "cross_copy_written",
              context_id: ctx.id,
              workspace_id: ctx.workspace_id,
              new_path: path,
              new_sha256: sha_of_file(path)
            })
          end)

          {:cont, {:ok, bump_delta(delta, :cross_copies_written, length(paths))}}
        else
          {:error, reason} -> {:halt, {:error, {:cross_copy_not_written, ctx.id, reason}}}
        end
      end
    end)
  end

  # 3. The kept address's file: restored to the keeper's text, old bytes first
  # copied into the run's backups.
  defp run_step(:kept_file, plan, journal) do
    restore_file(plan.kept_file, plan.keeper_ctx, journal, "kept_file", :files_rewritten, false)
  end

  # 4. The keeper's own cross-reference copies, the same way.
  defp run_step(:kept_copies, plan, journal) do
    Enum.reduce_while(plan.kept_copies, {:ok, %{}}, fn copy, {:ok, delta} ->
      case restore_file(
             copy,
             plan.keeper_ctx,
             journal,
             "kept_cross_copy",
             :cross_copies_rewritten,
             true
           ) do
        {:ok, more} ->
          {:cont, {:ok, merge_done(delta, more)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # 5. The commit point: every file of the group exists. One transaction.
  defp run_step(:rows, plan, journal) do
    moves = plan.moves
    repaired_at = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(moves, fn move ->
      note(journal, %{
        event: "rows_planned",
        context_id: move.id,
        workspace_id: move.workspace_id,
        old_uri: move.from_uri,
        new_uri: move.to_uri,
        old_path: move.from_path,
        new_path: move.to_path,
        old_sha256: move.from_sha256,
        new_sha256: AtomicFile.sha256(move.text)
      })
    end)

    result = Store.transaction(fn txn -> update_rows(txn, moves, repaired_at) end)

    case result do
      {:ok, %{updated: updated, stale: stale} = outcome} ->
        Store.evict_cached(updated)

        Enum.each(updated, fn id ->
          note(journal, %{event: "row_committed", context_id: id})
        end)

        {:ok,
         outcome
         |> Map.put(:repaired, length(updated))
         |> Map.put(:stale, stale)}

      {:error, reason} ->
        note(journal, %{event: "rows_failed", reason: inspect(reason)})
        {:error, {:rows_not_updated, reason}}
    end
  end

  # -- rows ------------------------------------------------------------------

  defp update_rows(txn, moves, repaired_at) do
    start = %{updated: [], stale: [], acls_copied: 0, memories_moved: 0, open_loops_moved: 0}

    with {:ok, outcome} <- update_each(txn, moves, repaired_at, start) do
      {:ok, %{outcome | updated: Enum.reverse(outcome.updated), stale: Enum.reverse(outcome.stale)}}
    end
  end

  defp update_each(_txn, [], _repaired_at, outcome), do: {:ok, outcome}

  defp update_each(txn, [move | rest], repaired_at, outcome) do
    with {:ok, changes} <- update_row(txn, move, repaired_at),
         {:ok, outcome} <- after_update(txn, move, changes, outcome) do
      update_each(txn, rest, repaired_at, outcome)
    end
  end

  # A row that no longer has the shared URI (another process changed it) is
  # left as it is and reported.
  defp after_update(_txn, move, 0, outcome),
    do: {:ok, %{outcome | stale: [move.id | outcome.stale]}}

  defp after_update(txn, move, 1, outcome) do
    with {:ok, moved} <-
           References.move(
             txn,
             move.tenant_id,
             move.workspace_id,
             move.id,
             move.from_uri,
             move.to_uri
           ) do
      {:ok,
       %{
         outcome
         | updated: [move.id | outcome.updated],
           acls_copied: outcome.acls_copied + moved.acls_copied,
           memories_moved: outcome.memories_moved + moved.memories_moved,
           open_loops_moved: outcome.open_loops_moved + moved.open_loops_moved
       }}
    end
  end

  defp update_row(txn, move, repaired_at) do
    with {:ok, [[metadata]]} <-
           Store.txn_query(txn, "SELECT metadata FROM contexts WHERE id = ?1", [move.id]) do
      merged =
        metadata
        |> decode_map()
        |> Map.put("uri_repair", %{
          "previous_uri" => move.from_uri,
          "previous_path" => move.from_path,
          "kept_by" => move.kept_by,
          "repaired_at" => repaired_at
        })

      Store.txn_execute(
        txn,
        """
        UPDATE contexts SET uri = ?1, path = ?2, metadata = ?3
        WHERE id = ?4 AND workspace_id = ?5 AND uri = ?6
        """,
        [
          move.to_uri,
          move.to_path,
          Jason.encode!(merged),
          move.id,
          move.workspace_id,
          move.from_uri
        ]
      )
    else
      {:ok, []} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  # -- files -------------------------------------------------------------------

  # A new file: written unless something is already there; a file that holds
  # exactly this text is a file written by an earlier, interrupted run.
  defp create_file(path, text) do
    case AtomicFile.create(path, text) do
      :ok ->
        {:ok, :written}

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^text} -> {:ok, :same}
          _ -> {:error, :exists_with_other_text}
        end

      {:error, _} = error ->
        error
    end
  end

  defp restore_file(%{action: "create"} = file, _keeper, journal, event, _counter, _index) do
    case create_file(file.path, file.text) do
      {:ok, written} ->
        note(journal, %{
          event: event <> "_created",
          new_path: file.path,
          new_sha256: AtomicFile.sha256(file.text),
          already_there: written == :same
        })

        {:ok, %{files_written: if(written == :same, do: 0, else: 1)}}

      {:error, reason} ->
        {:error, {:kept_file_not_created, file.path, reason}}
    end
  end

  defp restore_file(%{action: "rewrite"} = file, keeper, journal, event, counter, index?) do
    with {:ok, found} <- File.read(file.path),
         {:ok, body} <- Writer.body_of_file(found),
         true <- body == file.holder_body,
         {:ok, backup} <- Journal.backup(journal, file.path) do
      note(journal, %{
        event: event <> "_backup",
        context_id: keeper.id,
        old_path: file.path,
        old_sha256: backup.sha256,
        backup: backup.path
      })

      _ = checkpoint(:kept_file_backed_up)

      with :ok <- AtomicFile.write(file.path, file.text),
           :ok <- if(index?, do: index_copy(keeper, file.path), else: :ok) do
        note(journal, %{
          event: event <> "_rewritten",
          context_id: keeper.id,
          holds: file.holds,
          old_path: file.path,
          new_path: file.path,
          old_sha256: backup.sha256,
          new_sha256: AtomicFile.sha256(file.text),
          backup: backup.path
        })

        {:ok, %{counter => 1, backups: 1}}
      else
        {:error, reason} ->
          {:error, {:kept_file_not_written, file.path, reason}}
      end
    else
      # The file is not what the plan read: not ours to replace any more.
      false ->
        note(journal, %{event: event <> "_changed_since_plan", old_path: file.path})
        {:ok, %{}}

      :no_frontmatter ->
        note(journal, %{event: event <> "_changed_since_plan", old_path: file.path})
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:kept_file_not_backed_up, file.path, reason}}
    end
  end

  defp restore_file(file, _keeper, journal, event, _counter, _index) do
    note(journal, %{
      event: event <> "_" <> file.action,
      old_path: file.path,
      reason: file.reason
    })

    {:ok, %{}}
  end

  defp index_copies(%Context{} = ctx, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case index_copy(ctx, path) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Marked as a copy of this context, so writing the context again updates it.
  defp index_copy(%Context{} = ctx, path) do
    case Indexer.index_file(path,
           workspace_id: ctx.workspace_id,
           metadata: Address.copy_metadata(ctx.id, ctx.metadata)
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:not_indexed, path, reason}}
    end
  catch
    :exit, reason -> {:error, {:not_indexed, path, reason}}
  end

  defp file_state(path, text) do
    case File.read(path) do
      {:ok, ^text} -> "present_same_bytes"
      {:ok, _other} -> "present_other_bytes"
      {:error, _} -> "absent"
    end
  end

  defp sha_of_file(path) do
    case File.read(path) do
      {:ok, bytes} -> AtomicFile.sha256(bytes)
      {:error, _} -> nil
    end
  end

  # -- cross-reference copies ----------------------------------------------------

  # The copies intake wrote for a context: one per routed node whose folder is
  # not the context's own.
  defp cross_nodes(%Context{} = ctx) do
    scope = [workspace_id: ctx.workspace_id]
    own = Writer.node_to_folder(ctx.node, scope)

    Enum.reject(ctx.routed_to || [], &(Writer.node_to_folder(&1, scope) == own))
  end

  defp signals_dir(node, workspace_id) do
    Path.join([root_path(), Writer.node_to_folder(node, workspace_id: workspace_id), "signals"])
  end

  # -- file text -----------------------------------------------------------------

  # The signal of a row, rendered the same way every time: a row without a
  # creation time is not given the time of the run, or a resumed run would
  # render other bytes than the interrupted one wrote.
  defp signal_of(%Context{} = ctx) do
    signal = Context.to_signal(ctx)
    %{signal | created_at: signal.created_at || signal.modified_at || @epoch}
  end

  defp text_of(%Context{} = ctx), do: ctx |> signal_of() |> Writer.render()

  # What identifies a text: the body (title, genre and content), which a later
  # change of the summaries or entities in the frontmatter does not touch.
  defp body_of(%Context{} = ctx), do: ctx |> signal_of() |> Writer.body()

  # -- journal and checkpoints ------------------------------------------------------

  defp open_journal(true, _opts), do: {:ok, nil}
  defp open_journal(false, opts), do: Journal.open(Keyword.take(opts, [:root, :run_id]))

  defp note(nil, _entry), do: :ok

  defp note(journal, entry) do
    case Journal.append(journal, entry) do
      :ok -> :ok
      {:error, reason} -> raise "the repair journal cannot be written: #{inspect(reason)}"
    end
  end

  # A point between two steps at which a test can stop the run, as a crash
  # would. Production configures nothing.
  defp checkpoint(step) do
    case Application.get_env(:optimal_engine, :uri_repair_checkpoint) do
      fun when is_function(fun, 1) ->
        case fun.(step) do
          {:error, reason} -> {:error, {:checkpoint, step, reason}}
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # -- report ----------------------------------------------------------------------

  defp new_report(dry_run?, journal) do
    Map.merge(
      Map.new(@counters, &{&1, 0}),
      %{
        dry_run: dry_run?,
        run_id: journal && journal.run_id,
        journal: journal && journal.path,
        files_regenerated: 0,
        errors: [],
        groups_detail: [],
        workspaces: [],
        next_after: nil
      }
    )
  end

  defp new_done do
    %{
      repaired: 0,
      files_written: 0,
      files_already_written: 0,
      files_rewritten: 0,
      cross_copies_written: 0,
      cross_copies_rewritten: 0,
      backups: 0,
      acls_copied: 0,
      memories_moved: 0,
      open_loops_moved: 0,
      stale: []
    }
  end

  defp merge_done(done, delta) do
    Enum.reduce(delta, done, fn
      {:stale, stale}, acc -> %{acc | stale: acc.stale ++ stale}
      {:updated, _}, acc -> acc
      {key, value}, acc -> Map.update(acc, key, value, &(&1 + value))
    end)
  end

  defp bump_delta(delta, key, by \\ 1), do: Map.update(delta, key, by, &(&1 + by))

  # What a real run did.
  defp add_done(report, done) do
    report =
      Enum.reduce(
        ~w(repaired files_written files_rewritten cross_copies_written cross_copies_rewritten
           backups acls_copied memories_moved open_loops_moved)a,
        report,
        fn key, report -> bump(report, key, Map.fetch!(done, key)) end
      )

    Enum.reduce(done.stale, report, &error(&2, &1, :changed_while_repairing))
  end

  defp add_detail(report, detail), do: %{report | groups_detail: [detail | report.groups_detail]}

  defp finish(report, batch, rest) do
    details = Enum.reverse(report.groups_detail)

    regenerated =
      report.files_written + report.files_rewritten + report.cross_copies_written +
        report.cross_copies_rewritten

    next_after =
      if rest != [] and batch != [] do
        {workspace_id, uri} = group_key(List.last(batch))
        cursor(workspace_id, uri)
      end

    %{
      report
      | groups_detail: details,
        files_regenerated: regenerated,
        workspaces: workspaces(details),
        next_after: next_after
    }
  end

  # The totals again, per workspace, for an owner who reads one workspace at a time.
  defp workspaces(details) do
    details
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.sort_by(fn {workspace_id, _} -> workspace_id end)
    |> Enum.map(fn {workspace_id, groups} ->
      repairs = Enum.filter(groups, &(&1.status == "repair"))
      files = Enum.flat_map(repairs, fn g -> [g.kept_file | g.kept_cross_copies] end)
      copies = Enum.flat_map(repairs, fn g -> Enum.flat_map(g.contexts, & &1.cross_copies) end)
      moved = Enum.flat_map(repairs, & &1.contexts)
      action = fn name -> Enum.count(files, &(&1.action == name)) end

      writes =
        Enum.count(moved, &(&1.file == "absent")) + Enum.count(copies, &(&1.target == "absent")) +
          action.("create")

      bytes =
        Enum.sum(for c <- moved, c.file == "absent", do: c.bytes) +
          Enum.sum(for c <- copies, c.target == "absent", do: c.bytes) +
          Enum.sum(for f <- files, f.action in ["create", "rewrite"], do: f.bytes)

      skipped = fn kind -> Enum.count(groups, &(&1.status == "skipped" and &1.skip == kind)) end

      %{
        workspace_id: workspace_id,
        groups: length(groups),
        groups_skipped_empty_content: skipped.("empty_content"),
        groups_skipped_outside_workspace: skipped.("outside_workspace"),
        contexts_to_repair: length(moved),
        old_files_left_in_place: Enum.count(moved, & &1.old_file_stays),
        files_to_write: writes,
        files_to_rewrite: action.("rewrite"),
        files_left_alone: action.("left_alone"),
        bytes_to_write: bytes
      }
    end)
  end

  defp counters(report), do: Map.take(report, @counters ++ [:files_regenerated])

  defp log_run(%{dry_run: true}), do: :ok

  defp log_run(report) do
    Logger.info(
      "[UriRepair] run #{report.run_id}: #{report.repaired} contexts of #{report.groups} groups " <>
        "given their own address, #{report.files_regenerated} files regenerated, " <>
        "#{length(report.errors)} errors, #{report.groups_remaining} groups left"
    )
  end

  defp bump(report, key, by), do: Map.update!(report, key, &(&1 + by))

  defp error(report, id, reason) do
    Logger.warning("[UriRepair] #{id}: #{inspect(reason)}")
    %{report | errors: report.errors ++ [%{id: id, reason: inspect(reason)}]}
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_map(_), do: %{}
end
