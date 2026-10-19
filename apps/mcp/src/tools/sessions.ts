import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

const workspaceParam = z
  .string()
  .optional()
  .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`);

const LEARNED_CATEGORIES = [
  "fact",
  "decision",
  "task",
  "correction",
  "preference",
  "relationship",
  "context",
  "skill",
] as const;

export function registerSessions(server: McpServer): void {
  server.tool(
    "session_commit",
    "At the end of a chat, store the whole transcript as an Engine episode in the workspace: a searchable session, and what the chat learned as proposed claims for review. Safe to retry with the same correlation_id (the chat id); a different transcript under the same id is refused.",
    {
      correlation_id: z
        .string()
        .min(1)
        .max(200)
        .describe("The chat's own id; the same id never stores the chat twice."),
      messages: z
        .array(
          z.object({
            role: z.enum(["user", "assistant", "system", "tool"]),
            content: z.string().min(1),
            at: z.string().optional().describe("ISO 8601 date-time."),
          }),
        )
        .min(1),
      workspace: workspaceParam,
      title: z.string().optional(),
      summary: z
        .string()
        .optional()
        .describe("The chat's summary; the Engine writes one when omitted."),
      learned: z
        .array(
          z.object({
            content: z.string().min(1),
            category: z.enum(LEARNED_CATEGORIES).optional(),
            owner: z.string().optional().describe("For a task, e.g. user:jane."),
            due: z.string().optional().describe("For a task, an ISO date."),
          }),
        )
        .max(50)
        .optional()
        .describe("Decisions, tasks, corrections and facts to propose for review."),
    },
    async ({ workspace, ...session }) => {
      try {
        return jsonResult(
          await engine.commitSession({
            workspace: workspace ?? config.defaultWorkspace,
            source: "optimal-mcp",
            ...session,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "sessions_list",
    "Chat sessions committed in the workspace, newest first, each with its summary and how many items it proposed.",
    {
      workspace: workspaceParam,
      correlation_id: z.string().optional().describe("Only the session of this chat id."),
      limit: z.number().int().min(1).max(200).optional(),
    },
    async ({ workspace, correlation_id, limit }) => {
      try {
        return jsonResult(
          await engine.listSessions({
            workspace: workspace ?? config.defaultWorkspace,
            correlation_id,
            limit,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "session_get",
    "One committed chat session: summary, episode, and what it learned with each item's review status (pending, promoted, rejected).",
    {
      id: z.string().regex(/^[A-Za-z0-9_-]+$/).describe("Session id (ses_...)."),
      workspace: workspaceParam,
      include_transcript: z.boolean().optional(),
    },
    async ({ id, workspace, include_transcript }) => {
      try {
        return jsonResult(
          await engine.getSession(id, {
            workspace: workspace ?? config.defaultWorkspace,
            include: include_transcript ? "transcript" : undefined,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "org_policy",
    "The policy every workspace of the organization follows, read from its org section; each item names the workspace it came from. Read-only from other workspaces.",
    { workspace: workspaceParam },
    async ({ workspace }) => {
      try {
        return jsonResult(
          await engine.orgPolicy({ workspace: workspace ?? config.defaultWorkspace }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
