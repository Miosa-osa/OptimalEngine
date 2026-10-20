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

  For each workspace, every set of active, file-addressed signal contexts that
  share a URI is one group:

    * the earliest context (`created_at`, then id) **keeps** the address;
    * every other context gets the address a new ingest would give it: its own
      file name with the first 8 characters of its id before the extension
      (longer if that is taken), in the same folder;
    * the new files are written from the rows **before** the rows change, so no
      text is lost at any point. Contexts routed to other nodes get their
      cross-reference copies written too, under the new name, and indexed as
      copies of the context;
    * the file at the kept address holds the last writer's text. When its body
      is the text of another member it is rewritten from the keeper's own row,
      once that member has a file of its own; the same is done for the keeper's
      cross-reference copies. A file whose body matches no member (edited by
      hand) is left alone and counted;
    * each repaired row records where it was in `metadata.uri_repair`
      (`previous_uri`, `previous_path`, `kept_by`, `repaired_at`) and the read
      cache is evicted.

  The old shared address keeps resolving, to the earliest context, so a redirect
  from it would only repeat what the address already says; the record on each
  repaired row is how the old address is traced to its new one.

  ## What it leaves alone, and counts

    * Archived contexts. Their rows may share an address with active ones
      (connectors left thousands of empty archived rows on one URI); a file is
      not written for a retired context.
    * Rows that index the same file as another row (`Address.file_index_id/1`
      names the row of a file): one document, not a collision.
    * Rows whose URI is not the address of their own file (a caller-chosen
      `source_uri`): the address belongs to the caller.
    * Rows with no path (stored without a file) and contexts that are not
      signals.
    * Summary sidecars (`.abstract.md`, `.overview.md`): derived, written again
      by the next semantic pass under the new name.

  ## Safety

  Every write is addition or restoration: a new file at a name no other context
  holds, or a kept file rewritten with its own text after the text it held has a
  file of its own. A text is recognised by the body of the file (title, genre
  and content, which survive later changes of the summaries), never by the
  frontmatter alone, so contexts that share a title and a creation time are told
  apart. A run that stops half way is resumed by running again: written files
  are recognised by their bytes, and groups that were separated are no longer
  groups. `dry_run: true` reads and plans only.
  """

  require Logger

  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Indexer
  alias OptimalEngine.Pipeline.Intake.Address
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Store
  alias OptimalEngine.URI

  @counters ~w(groups groups_remaining contexts kept repaired files_written files_rewritten
               files_unchanged files_left_alone cross_copies_written cross_copies_rewritten
               without_content skipped_archived skipped_not_signal skipped_no_file skipped_twins
               skipped_not_file_addressed)a

  @type change :: %{
          id: String.t(),
          workspace_id: String.t(),
          title: String.t(),
          from: String.t(),
          to: String.t(),
          path: String.t(),
          kept_by: String.t()
        }

  @type report :: %{
          :dry_run => boolean(),
          :files_regenerated => non_neg_integer(),
          :errors => [map()],
          :changes => [change()],
          optional(atom()) => non_neg_integer()
        }

  @doc """
  Separates the contexts that share a URI.

  Options: `:workspace_id` and `:tenant_id` restrict the run (default: every
  workspace); `:dry_run` (default `false`) plans without writing; `:limit`
  separates at most that many groups in this run (default: all) and reports the
  rest as `groups_remaining`, so a large store is repaired in bounded requests.

  `changes` lists every context given a new address in the groups of the run
  (`limit` bounds it). The report counts `groups`, `contexts` in them, `kept` and `repaired`
  contexts, `files_written` (new files of repaired contexts), `files_rewritten`
  (kept files restored), `cross_copies_written` and `cross_copies_rewritten`,
  their sum as `files_regenerated`, `without_content` (repaired contexts whose
  row has no text to write), and the contexts left alone: `skipped_archived`,
  `skipped_not_signal`, `skipped_no_file`, `skipped_twins` and
  `skipped_not_file_addressed`.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    with {:ok, members} <- shared_members(opts) do
      groups = members |> Enum.chunk_by(&{&1.workspace_id, &1.uri}) |> Enum.map(&split_group/1)

      report =
        Enum.reduce(groups, new_report(dry_run?), fn group, report ->
          report
          |> bump(:skipped_archived, length(group.archived))
          |> bump(:skipped_not_signal, length(group.not_signal))
          |> bump(:skipped_no_file, length(group.no_file))
          |> bump(:skipped_twins, length(group.file_rows))
          |> bump(:skipped_not_file_addressed, length(group.foreign))
        end)

      {batch, rest} =
        groups
        |> Enum.filter(&match?(%{addressed: [_, _ | _]}, &1))
        |> take_groups(Keyword.get(opts, :limit))

      report =
        Enum.reduce(batch, %{report | groups_remaining: length(rest)}, fn group, report ->
          repair(group, report, dry_run?)
        end)

      report = finish(report)
      log_run(report)
      {:ok, report}
    end
  end

  @doc "The plan of a run, without writing anything. Same as `run(dry_run: true)`."
  @spec scan(keyword()) :: {:ok, report()} | {:error, term()}
  def scan(opts \\ []), do: run(Keyword.put(opts, :dry_run, true))

  # -- the contexts that share an address -----------------------------------

  # Every row that shares its URI with another in the workspace; what each is
  # decides below whether it is part of a collision.
  defp shared_members(opts) do
    {filter, params} = scope_filter(opts)

    sql = """
    SELECT c.id, c.workspace_id, c.uri, c.type, c.path, c.created_at, c.archived_at IS NOT NULL
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
       Enum.map(rows, fn [id, workspace_id, uri, type, path, created_at, archived] ->
         %{
           id: id,
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
    empty = %{
      archived: [],
      not_signal: [],
      no_file: [],
      file_rows: [],
      foreign: [],
      addressed: []
    }

    members
    |> Enum.reverse()
    |> Enum.reduce(empty, fn member, groups ->
      Map.update!(groups, kind(member), &[member | &1])
    end)
  end

  defp kind(%{archived: true}), do: :archived
  defp kind(%{type: type}) when type != "signal", do: :not_signal
  defp kind(%{path: path}) when path in [nil, ""], do: :no_file

  defp kind(%{id: id, path: path, uri: uri}) do
    cond do
      # The row the indexer keeps for a file: the same document as the row
      # that was written for it, not another one.
      id == Address.file_index_id(path) -> :file_rows
      uri != URI.from_path(path) -> :foreign
      true -> :addressed
    end
  end

  defp take_groups(groups, limit) when is_integer(limit) and limit > 0,
    do: Enum.split(groups, limit)

  defp take_groups(groups, _limit), do: {groups, []}

  # -- one group ---------------------------------------------------------------

  defp repair(%{addressed: [keeper | repaired], archived: archived}, report, dry_run?) do
    report =
      report
      |> bump(:groups, 1)
      |> bump(:contexts, 1 + length(repaired))
      |> bump(:kept, 1)

    with {:ok, keeper_ctx} <- load(keeper),
         {:ok, plans} <- plan(keeper, repaired) do
      report =
        plans
        |> Enum.reduce(report, &note_change/2)
        |> bump(:without_content, Enum.count(plans, &blank?(&1.context.content)))

      if dry_run? do
        bump(report, :repaired, length(plans))
      else
        execute(keeper_ctx, plans, archived, report)
      end
    else
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

  # -- plan: where every repaired context goes ---------------------------------

  defp plan(keeper, repaired) do
    repaired
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn member, {:ok, plans, reserved} ->
      case plan_one(keeper, member, reserved) do
        {:ok, plan} ->
          {:cont, {:ok, [plan | plans], MapSet.put(reserved, plan.to_path)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, plans, _reserved} -> {:ok, Enum.reverse(plans)}
      {:error, _} = error -> error
    end
  end

  defp plan_one(keeper, member, reserved) do
    with {:ok, ctx} <- load(member) do
      dir = Path.dirname(member.path)
      text = text_of(ctx)

      name =
        Address.choose(Path.basename(member.path), member.id, fn candidate ->
          path = Path.join(dir, candidate)

          MapSet.member?(reserved, path) or
            Address.taken?(path, member.id, member.workspace_id, text)
        end)

      to_path = Path.join(dir, name)

      {:ok,
       %{
         id: member.id,
         workspace_id: member.workspace_id,
         from_uri: member.uri,
         from_path: member.path,
         to_uri: URI.from_path(to_path),
         to_path: to_path,
         kept_by: keeper.id,
         context: ctx
       }}
    end
  end

  defp note_change(plan, report) do
    change = %{
      id: plan.id,
      workspace_id: plan.workspace_id,
      title: plan.context.title,
      from: plan.from_uri,
      to: plan.to_uri,
      path: plan.to_path,
      kept_by: plan.kept_by
    }

    %{report | changes: [change | report.changes]}
  end

  # -- execute: files first, then rows, then the kept address's files ----------

  defp execute(keeper_ctx, plans, archived, report) do
    {written, report} =
      Enum.reduce(plans, {[], report}, fn plan, {ok, report} ->
        case write_file(plan) do
          {:ok, :written} -> {[plan | ok], bump(report, :files_written, 1)}
          {:ok, :unchanged} -> {[plan | ok], bump(report, :files_unchanged, 1)}
          {:error, reason} -> {ok, error(report, plan.id, {:file_not_written, reason})}
        end
      end)

    case update_rows(Enum.reverse(written)) do
      {:ok, updated_ids, stale_ids} ->
        Store.evict_cached(updated_ids)

        report =
          report
          |> bump(:repaired, length(updated_ids))
          |> then(fn r -> Enum.reduce(stale_ids, r, &error(&2, &1, :changed_while_repairing)) end)

        report =
          plans
          |> Enum.filter(&(&1.id in updated_ids))
          |> Enum.reduce(report, &write_cross_copies/2)

        # The kept address's files are restored only when every other member
        # of the group has a file of its own and an address of its own.
        if length(updated_ids) == length(plans) do
          report
          |> restore_kept_file(keeper_ctx, plans, archived)
          |> restore_kept_cross_copies(keeper_ctx, plans, archived)
        else
          report
        end

      {:error, reason} ->
        error(report, keeper_ctx.id, {:rows_not_updated, reason})
    end
  end

  defp write_file(plan) do
    text = text_of(plan.context)

    case File.read(plan.to_path) do
      {:ok, ^text} ->
        {:ok, :unchanged}

      {:ok, _other} ->
        {:error, :exists_with_other_text}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(plan.to_path)),
             :ok <- File.write(plan.to_path, text) do
          {:ok, :written}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One transaction for the group: every repaired row moves, or none does.
  # A row that no longer has the shared URI (another process changed it)
  # is left as it is and reported.
  defp update_rows([]), do: {:ok, [], []}

  defp update_rows(plans) do
    repaired_at = DateTime.utc_now() |> DateTime.to_iso8601()

    result =
      Store.transaction(fn txn ->
        with {:ok, outcomes} <- update_each(txn, plans, repaired_at, []) do
          {updated, stale} = Enum.split_with(outcomes, fn {_id, changes} -> changes == 1 end)
          {:ok, {Enum.map(updated, &elem(&1, 0)), Enum.map(stale, &elem(&1, 0))}}
        end
      end)

    case result do
      {:ok, {updated, stale}} -> {:ok, updated, stale}
      {:error, _} = error -> error
    end
  end

  defp update_each(_txn, [], _repaired_at, outcomes), do: {:ok, Enum.reverse(outcomes)}

  defp update_each(txn, [plan | rest], repaired_at, outcomes) do
    case update_row(txn, plan, repaired_at) do
      {:ok, changes} -> update_each(txn, rest, repaired_at, [{plan.id, changes} | outcomes])
      {:error, _} = error -> error
    end
  end

  defp update_row(txn, plan, repaired_at) do
    with {:ok, [[metadata]]} <-
           Store.txn_query(txn, "SELECT metadata FROM contexts WHERE id = ?1", [plan.id]) do
      merged =
        metadata
        |> decode_map()
        |> Map.put("uri_repair", %{
          "previous_uri" => plan.from_uri,
          "previous_path" => plan.from_path,
          "kept_by" => plan.kept_by,
          "repaired_at" => repaired_at
        })

      Store.txn_execute(
        txn,
        """
        UPDATE contexts SET uri = ?1, path = ?2, metadata = ?3
        WHERE id = ?4 AND workspace_id = ?5 AND uri = ?6
        """,
        [
          plan.to_uri,
          plan.to_path,
          Jason.encode!(merged),
          plan.id,
          plan.workspace_id,
          plan.from_uri
        ]
      )
    else
      {:ok, []} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  # -- cross-reference copies --------------------------------------------------

  # The copies intake wrote for a context: one per routed node whose folder is
  # not the context's own.
  defp cross_nodes(%Context{} = ctx) do
    scope = [workspace_id: ctx.workspace_id]
    own = Writer.node_to_folder(ctx.node, scope)

    Enum.reject(ctx.routed_to || [], &(Writer.node_to_folder(&1, scope) == own))
  end

  # The copies of a repaired context, under its new name.
  defp write_cross_copies(plan, report) do
    ctx = %{plan.context | path: plan.to_path, uri: plan.to_uri}

    case cross_nodes(ctx) do
      [] ->
        report

      nodes ->
        opts = [workspace_id: ctx.workspace_id, primary_path: plan.to_path]
        {:ok, paths} = Writer.write_cross_references(Context.to_signal(ctx), nodes, opts)

        paths
        |> Enum.reduce(bump(report, :cross_copies_written, length(paths)), fn path, report ->
          index_copy(report, ctx, path)
        end)
    end
  end

  # Marked as a copy of this context, so writing the context again updates it.
  defp index_copy(report, %Context{} = ctx, path) do
    case Indexer.index_file(path,
           workspace_id: ctx.workspace_id,
           metadata: %{"cross_ref_of" => ctx.id}
         ) do
      {:ok, _} -> report
      {:error, reason} -> error(report, ctx.id, {:cross_copy_not_indexed, path, reason})
    end
  catch
    :exit, reason -> error(report, ctx.id, {:cross_copy_not_indexed, path, reason})
  end

  # The copy at the kept address's name holds the last writer's text; it is
  # the keeper's own again once the others have copies under their new names.
  # A copy that is not there is not created: it may have been removed since.
  defp restore_kept_cross_copies(report, %Context{} = keeper, plans, archived) do
    scope = [workspace_id: keeper.workspace_id]
    root = Application.get_env(:optimal_engine, :root_path, "")

    keeper
    |> cross_nodes()
    |> Enum.reduce(report, fn node, report ->
      path =
        Path.join([root, Writer.node_to_folder(node, scope), "signals", Path.basename(keeper.path)])

      case File.read(path) do
        {:ok, found} ->
          if text_is_other_member?(found, keeper, plans, archived) do
            text =
              Writer.render(%{Context.to_signal(keeper) | node: node}, cross_ref_from: keeper.node)

            with :ok <- File.write(path, text) do
              report |> bump(:cross_copies_rewritten, 1) |> index_copy(keeper, path)
            else
              {:error, reason} -> error(report, keeper.id, {:cross_copy_not_written, path, reason})
            end
          else
            report
          end

        {:error, _} ->
          report
      end
    end)
  end

  # -- the kept address's file -------------------------------------------------

  # The file at the kept address holds whoever wrote last. Once the others have
  # files of their own, restore the keeper's text there if the file holds one
  # of theirs. A file that matches nobody is not ours to replace.
  defp restore_kept_file(report, %Context{} = keeper, plans, archived) do
    case File.read(keeper.path) do
      {:ok, text} ->
        cond do
          same_body?(text, keeper) -> bump(report, :files_unchanged, 1)
          text_is_other_member?(text, keeper, plans, archived) -> rewrite_kept_file(report, keeper)
          true -> bump(report, :files_left_alone, 1)
        end

      {:error, :enoent} ->
        rewrite_kept_file(report, keeper)

      {:error, reason} ->
        error(report, keeper.id, {:kept_file_unreadable, reason})
    end
  end

  defp rewrite_kept_file(report, keeper) do
    case File.write(keeper.path, text_of(keeper)) do
      :ok -> bump(report, :files_rewritten, 1)
      {:error, reason} -> error(report, keeper.id, {:kept_file_not_written, reason})
    end
  end

  # -- file text ---------------------------------------------------------------

  defp text_of(%Context{} = ctx), do: ctx |> Context.to_signal() |> Writer.render()

  # What identifies a text: the body (title, genre and content), which a later
  # change of the summaries or entities in the frontmatter does not touch.
  defp body_of(%Context{} = ctx), do: ctx |> Context.to_signal() |> Writer.body() |> String.trim()

  defp file_body(text) do
    case Regex.run(~r/\A---\r?\n.*?\r?\n---\r?\n?(.*)\z/s, text) do
      [_, body] -> String.trim(body)
      _ -> String.trim(text)
    end
  end

  defp same_body?(text, %Context{} = ctx), do: file_body(text) == body_of(ctx)

  # Whether a file holds the text of another member of the group: one that was
  # repaired, or one that is archived (its file is not written again, but the
  # kept address must not keep holding its text).
  defp text_is_other_member?(text, %Context{} = keeper, plans, archived) do
    found = file_body(text)

    found != body_of(keeper) and
      (Enum.any?(plans, &(body_of(&1.context) == found)) or
         Enum.any?(archived, &member_body?(&1, found)))
  end

  defp member_body?(member, found) do
    case load(member) do
      {:ok, ctx} -> body_of(ctx) == found
      {:error, _} -> false
    end
  end

  # -- report ------------------------------------------------------------------

  defp new_report(dry_run?) do
    Map.merge(
      Map.new(@counters, &{&1, 0}),
      %{dry_run: dry_run?, files_regenerated: 0, errors: [], changes: []}
    )
  end

  defp finish(report) do
    regenerated =
      report.files_written + report.files_rewritten + report.cross_copies_written +
        report.cross_copies_rewritten

    %{report | changes: Enum.reverse(report.changes), files_regenerated: regenerated}
  end

  defp log_run(%{dry_run: true}), do: :ok

  defp log_run(report) do
    Logger.info(
      "[UriRepair] #{report.repaired} contexts of #{report.groups} groups given their own " <>
        "address, #{report.files_regenerated} files regenerated, " <>
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
