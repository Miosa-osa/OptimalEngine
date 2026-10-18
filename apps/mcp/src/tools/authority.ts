import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

const DATA_CLASSES = ["public", "internal", "confidential", "restricted"] as const;

export function registerAuthority(server: McpServer): void {
  server.tool(
    "authority_decide",
    "Ask Optimal Authority whether an action on a resource is allowed, needs approval (ask), or is denied, before doing it. The subject defaults to this key's identity.",
    {
      action: z
        .string()
        .min(1)
        .describe("e.g. read, search, write, export, or act:<tool>."),
      resource: z
        .string()
        .min(1)
        .describe("optimal://<workspace>/<path> of the data or action."),
      data_class: z.enum(DATA_CLASSES).optional(),
      workspace: z
        .string()
        .optional()
        .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`),
      subject: z
        .string()
        .optional()
        .describe("Evaluate for another subject (policy check only)."),
    },
    async ({ action, resource, data_class, workspace, subject }) => {
      try {
        return jsonResult(
          await engine.authorityDecide({
            workspace_id: workspace ?? config.defaultWorkspace,
            action,
            resource,
            data_class,
            subject,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "authority_effective",
    "What this key's identity may do in the workspace right now: the applicable policy, grants, and pending requests.",
    {
      workspace: z
        .string()
        .optional()
        .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`),
      subject: z
        .string()
        .optional()
        .describe("Another subject; needs the authority:read scope."),
    },
    async ({ workspace, subject }) => {
      try {
        return jsonResult(
          await engine.authorityEffective({
            workspace_id: workspace ?? config.defaultWorkspace,
            subject,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
