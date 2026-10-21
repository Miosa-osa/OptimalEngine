import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { engineFailure } from "./result.js";
import { config } from "../config.js";

export function registerSearch(server: McpServer): void {
  server.tool(
    "search",
    "Hybrid search across signals in a workspace. Returns ranked context results with metadata. Use when ask returned 'empty' or you want to browse rather than synthesize.",
    {
      q: z.string().min(1).describe("Search query string."),
      workspace: z
        .string()
        .optional()
        .describe(
          `Workspace to search. Defaults to "${config.defaultWorkspace}".`,
        ),
      limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .optional()
        .describe(
          "Maximum number of results to return. Default decided by engine.",
        ),
    },
    async ({ q, workspace, limit }) => {
      try {
        const result = await engine.search({
          q,
          workspace: workspace ?? config.defaultWorkspace,
          limit,
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
