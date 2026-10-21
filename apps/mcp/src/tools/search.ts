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
      as_of: z
        .string()
        .optional()
        .describe(
          "ISO 8601 instant the time decay measures age against, for reproducible comparisons (e.g. 2026-10-20T12:00:00Z). Defaults to now.",
        ),
      mode: z
        .enum(["lexical", "hybrid", "auto"])
        .optional()
        .describe(
          "Retrieval mode. 'lexical' is full text only; 'hybrid' requires the vector hop and fails when the embedder cannot serve it; 'auto' takes the vector hop when the embedder answers and full text otherwise. Defaults to auto.",
        ),
    },
    async ({ q, workspace, limit, as_of, mode }) => {
      try {
        const result = await engine.search({
          q,
          workspace: workspace ?? config.defaultWorkspace,
          limit,
          as_of,
          mode,
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
