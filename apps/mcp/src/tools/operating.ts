import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

const workspaceParam = z
  .string()
  .optional()
  .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`);

const LOOP_KINDS = [
  "commitment",
  "owed_reply",
  "follow_up",
  "payment_due",
  "payment_owed",
  "decision_needed",
] as const;

export function registerOperating(server: McpServer): void {
  server.tool(
    "boot",
    "Start of session: the actual day in the workspace's time zone, today's rhythm note, fires (overdue and due-today loops), open loop counts, recent decisions, stale items, the brief, and the operating protocol. Call this first.",
    {
      workspace: workspaceParam,
      timezone: z
        .string()
        .optional()
        .describe("IANA time zone to override the workspace's own."),
    },
    async ({ workspace, timezone }) => {
      try {
        return jsonResult(
          await engine.boot({
            workspace: workspace ?? config.defaultWorkspace,
            timezone,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "brief",
    "Ranked items that need a decision today, each with sources and a next action.",
    {
      workspace: workspaceParam,
      workspaces: z
        .string()
        .optional()
        .describe(
          'Comma-separated workspace ids, or "*" for every workspace the key covers. Overrides workspace.',
        ),
      limit: z.number().int().min(1).max(200).optional(),
    },
    async ({ workspace, workspaces, limit }) => {
      try {
        return jsonResult(
          await engine.brief(
            workspaces
              ? { workspaces, limit }
              : { workspace: workspace ?? config.defaultWorkspace, limit },
          ),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "protocol",
    "The agent operating protocol for the workspace: how to boot, search before answering, capture, record, and close.",
    { workspace: workspaceParam },
    async ({ workspace }) => {
      try {
        return jsonResult(
          await engine.protocol({
            workspace: workspace ?? config.defaultWorkspace,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "loops_list",
    "Open loops: commitments, owed replies, follow-ups, money due or owed, decisions needed.",
    {
      workspace: workspaceParam,
      workspaces: z
        .string()
        .optional()
        .describe('Comma-separated workspace ids, or "*". Overrides workspace.'),
      state: z.enum(["open", "closed", "dropped"]).optional(),
      owner: z.string().optional(),
      kind: z.enum(LOOP_KINDS).optional(),
      due_before: z
        .string()
        .optional()
        .describe("ISO date; only loops due before it."),
      limit: z.number().int().min(1).max(1000).optional(),
    },
    async ({ workspace, workspaces, ...filters }) => {
      try {
        return jsonResult(
          await engine.listLoops(
            workspaces
              ? { workspaces, ...filters }
              : { workspace: workspace ?? config.defaultWorkspace, ...filters },
          ),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "loops_add",
    "Record an open loop with an owner and a due date. Adding the same loop twice returns the existing one.",
    {
      title: z.string().min(1).describe("What is owed, in one line."),
      workspace: workspaceParam,
      kind: z.enum(LOOP_KINDS).optional().describe("Default commitment."),
      owner: z.string().optional().describe("Who owes it, e.g. user:jane."),
      counterparty: z.string().optional(),
      due_at: z.string().optional().describe("ISO date or date-time."),
      source_uri: z
        .string()
        .optional()
        .describe("optimal:// URI of the evidence."),
    },
    async ({ workspace, ...loop }) => {
      try {
        return jsonResult(
          await engine.addLoop({
            workspace: workspace ?? config.defaultWorkspace,
            ...loop,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "loops_close",
    "Close (done), drop (will not happen), or reopen a loop by id.",
    {
      id: z.string().regex(/^[A-Za-z0-9_-]+$/).describe("Loop id."),
      action: z.enum(["close", "drop", "reopen"]).optional(),
      workspace: workspaceParam,
      reason: z.string().optional(),
      source_uri: z.string().optional(),
    },
    async ({ id, action, workspace, reason, source_uri }) => {
      try {
        return jsonResult(
          await engine.transitionLoop(id, action ?? "close", {
            workspace: workspace ?? config.defaultWorkspace,
            reason,
            source_uri,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
