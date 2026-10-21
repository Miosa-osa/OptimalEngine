import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { engineFailure } from "./result.js";
import { config } from "../config.js";

export function registerProfile(server: McpServer): void {
  server.tool(
    "profile",
    "Get a workspace profile for session start: topology, stable context, current state, recent activity, and projection summaries when available. Use before an agent starts work in a workspace.",
    {
      workspace: z
        .string()
        .optional()
        .describe(
          `Workspace to profile. Defaults to "${config.defaultWorkspace}".`,
        ),
      audience: z
        .string()
        .optional()
        .describe(
          "Audience lens (engineering, sales, legal, exec). Shapes which facts are surfaced.",
        ),
      bandwidth: z
        .enum(["full", "summary", "minimal"])
        .optional()
        .describe(
          "Response density. 'full' returns all tiers; 'summary' condenses; 'minimal' is one-liners.",
        ),
    },
    async ({ workspace, audience, bandwidth }) => {
      try {
        const result = await engine.profile({
          workspace: workspace ?? config.defaultWorkspace,
          audience,
          bandwidth,
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
