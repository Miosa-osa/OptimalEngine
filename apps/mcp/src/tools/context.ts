import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

export function registerContext(server: McpServer): void {
  server.tool(
    "assemble",
    "Assemble a tiered context package for a topic (summary, facts, memory) with the sources it came from. Use before answering about past work, people, decisions, or commitments.",
    {
      query: z.string().min(1).describe("Topic or question."),
      workspace: z
        .string()
        .optional()
        .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`),
      limit: z.number().int().min(1).max(100).optional(),
    },
    async ({ query, workspace, limit }) => {
      try {
        return jsonResult(
          await engine.assemble({
            query,
            workspace: workspace ?? config.defaultWorkspace,
            limit,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "read",
    "Read one context by its optimal:// URI or id (from search results) at a tier: l0 abstract, l1 overview (default), or full content.",
    {
      target: z.string().min(1).describe("optimal:// URI or context id."),
      workspace: z
        .string()
        .optional()
        .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`),
      tier: z.enum(["l0", "l1", "full"]).optional(),
    },
    async ({ target, workspace, tier }) => {
      const ref = target.startsWith("optimal://")
        ? { uri: target }
        : { id: target };
      try {
        return jsonResult(
          await engine.read({
            ...ref,
            workspace: workspace ?? config.defaultWorkspace,
            tier,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
