import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { McpError, ErrorCode } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { engine, EngineError } from "../client.js";
import { engineFailure } from "./result.js";
import { config } from "../config.js";

export function registerForgetMemory(server: McpServer): void {
  server.tool(
    "forget_memory",
    "Soft-forget a memory by id. Optional reason (recorded for audit) and forget_after (ISO timestamp). Memory is marked is_forgotten but row is preserved. Use when the user says to forget something or when info is superseded.",
    {
      id: z.string().min(1).describe("ID of the memory to forget."),
      workspace: z
        .string()
        .optional()
        .describe(
          `Workspace the memory belongs to. Defaults to "${config.defaultWorkspace}".`,
        ),
      reason: z
        .string()
        .optional()
        .describe(
          "Human-readable reason for forgetting. Stored in audit log. Example: 'Superseded by Q3 decision'.",
        ),
      forget_after: z
        .string()
        .optional()
        .describe(
          "ISO 8601 timestamp after which the memory should be treated as forgotten. Omit to forget immediately.",
        ),
    },
    async ({ id, workspace, reason, forget_after }) => {
      try {
        await engine.forgetMemory(id, {
          workspace: workspace ?? config.defaultWorkspace,
          reason,
          forget_after,
        });
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                id,
                reason: reason ?? null,
                forget_after: forget_after ?? null,
              }),
            },
          ],
        };
      } catch (err) {
        if (err instanceof EngineError) {
          if (err.status === 404) {
            throw new McpError(
              ErrorCode.InvalidParams,
              `Memory not found: ${id}`,
            );
          }
        }
        engineFailure(err);
      }
    },
  );
}
