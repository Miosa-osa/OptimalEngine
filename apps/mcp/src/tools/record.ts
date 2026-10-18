import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

const LABELS = {
  note: "Note",
  lesson: "Lesson",
  decision: "Decision",
  task: "Task",
  close: "Close-loop",
} as const;
type Kind = keyof typeof LABELS;

const workspaceParam = z
  .string()
  .optional()
  .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`);

// The same memory shape the optimal CLI writes, so chat and CLI agents
// produce the same records.
async function rememberKind(
  kind: Kind,
  text: string,
  workspace: string | undefined,
  extra: { owner?: string; due?: string } = {},
) {
  const metadata: Record<string, string> = { kind, source: "optimal-mcp" };
  if (extra.owner) metadata["owner"] = extra.owner;
  if (extra.due) metadata["due"] = extra.due;
  return engine.remember({
    content: `${LABELS[kind]}: ${text}`,
    workspace: workspace ?? config.defaultWorkspace,
    force: true,
    metadata,
  });
}

export function registerRecord(server: McpServer): void {
  server.tool(
    "capture",
    "Capture a raw signal (meeting note, message, correction, temporal update) as source evidence. The Engine classifies it and proposes claims for review.",
    {
      text: z.string().min(1).describe("The raw text, with enough context to stand alone."),
      workspace: workspaceParam,
      genre: z
        .string()
        .optional()
        .describe("e.g. note, transcript, email, observation."),
      title: z.string().optional(),
      node: z.string().optional().describe("Topology node slug, if known."),
    },
    async ({ text, workspace, genre, title, node }) => {
      try {
        return jsonResult(
          await engine.capture({
            text,
            workspace: workspace ?? config.defaultWorkspace,
            genre,
            title,
            node,
            extract_claims: true,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "record",
    "Record a note, lesson, decision, or task as durable memory. Give decisions and tasks an owner and a due date.",
    {
      kind: z.enum(["note", "lesson", "decision", "task"]),
      text: z.string().min(1),
      workspace: workspaceParam,
      owner: z.string().optional().describe("e.g. user:jane."),
      due: z.string().optional().describe("ISO date."),
    },
    async ({ kind, text, workspace, owner, due }) => {
      try {
        return jsonResult(await rememberKind(kind, text, workspace, { owner, due }));
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "close",
    "End-of-work checkpoint: what changed, how it was verified, and what remains.",
    {
      summary: z.string().min(1),
      workspace: workspaceParam,
    },
    async ({ summary, workspace }) => {
      try {
        return jsonResult(await rememberKind("close", summary, workspace));
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
