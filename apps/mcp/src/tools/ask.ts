import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { engineFailure } from "./result.js";
import { config } from "../config.js";

export function registerAsk(server: McpServer): void {
  server.tool(
    "ask",
    "Ask Optimal Engine a workspace-scoped question. Returns governed retrieval/context output with evidence, memory, and projection metadata when available. Use this when an agent needs authorized context before answering or acting.",
    {
      query: z.string().min(1).describe("The question to ask the engine."),
      workspace: z
        .string()
        .optional()
        .describe(
          `Workspace to query. Defaults to "${config.defaultWorkspace}".`,
        ),
      audience: z
        .string()
        .optional()
        .describe(
          "Audience lens that shapes the response (e.g. engineering, sales, legal, exec). Omit for default.",
        ),
      as_of: z
        .string()
        .optional()
        .describe(
          "ISO 8601 instant the time decay measures age against, for reproducible comparisons (e.g. 2026-10-20T12:00:00Z). Defaults to now.",
        ),
    },
    async ({ query, workspace, audience, as_of }) => {
      try {
        const result = await engine.ask({
          query,
          workspace: workspace ?? config.defaultWorkspace,
          audience,
          as_of,
        });
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
