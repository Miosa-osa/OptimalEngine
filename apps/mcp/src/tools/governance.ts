import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { engine } from "../client.js";
import { config } from "../config.js";
import { engineFailure, jsonResult } from "./result.js";

const workspaceParam = z
  .string()
  .optional()
  .describe(`Workspace id. Defaults to "${config.defaultWorkspace}".`);

const STAGES = ["request", "approval", "denial", "action", "result", "reply"] as const;

export function registerGovernance(server: McpServer): void {
  server.tool(
    "check_draft",
    "Check a draft against its receiver before sending it: flags bandwidth overload (with a shorter version), genre mismatch, a request with no ask, and a missing receiver. Suggests; sending stays with the approval policy.",
    {
      draft: z.string().min(1).describe("The text you are about to send."),
      channel: z
        .string()
        .optional()
        .describe("sms, whatsapp, chat, slack, email, brief, or document."),
      bandwidth: z.enum(["low", "medium", "high"]).optional(),
      genre: z.string().optional().describe("The genre the draft is meant to be, e.g. email or brief."),
      type: z
        .enum(["direct", "inform", "commit", "decide", "express"])
        .optional()
        .describe("What the draft does; direct means it asks for something."),
      workspace: workspaceParam,
    },
    async ({ draft, channel, bandwidth, genre, type, workspace }) => {
      try {
        return jsonResult(
          await engine.checkDraft({
            workspace: workspace ?? config.defaultWorkspace,
            draft,
            receiver: { channel, bandwidth },
            genre,
            type,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "viability",
    "How healthy a workspace (or the org, with workspaces '*') is: the five VSM systems with evidence and predicted failures, the six Signal Theory metrics, the variety ratio, and trajectory alerts. Cite the evidence lines when answering.",
    {
      workspace: workspaceParam,
      workspaces: z.literal("*").optional().describe("'*' for the org view."),
    },
    async ({ workspace, workspaces }) => {
      try {
        return jsonResult(
          await engine.viability(
            workspaces ? { workspaces } : { workspace: workspace ?? config.defaultWorkspace },
          ),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "action_step",
    "Record a step of an agent action (request first, then approval or denial, action, result, reply). Steps are linked, signed, and readable as Signals. Approval and denial need a key with authority:enforce.",
    {
      stage: z.enum(STAGES),
      correlation_id: z
        .string()
        .optional()
        .describe("The chain id returned by the request step; required after it."),
      action: z.string().optional().describe("e.g. send_email."),
      resource: z.string().optional().describe("What the action touches, e.g. mailto:customer."),
      summary: z.string().optional(),
      request_id: z.string().optional().describe("An Engine approval request id this step belongs to."),
      jti: z.string().optional().describe("An Engine grant id this step acts under."),
      workspace: workspaceParam,
    },
    async ({ stage, correlation_id, action, resource, summary, request_id, jti, workspace }) => {
      try {
        const detail: Record<string, string> = {};
        if (request_id) detail["request_id"] = request_id;
        if (jti) detail["jti"] = jti;
        return jsonResult(
          await engine.recordActionStep({
            workspace: workspace ?? config.defaultWorkspace,
            stage,
            correlation_id,
            action,
            resource,
            summary,
            detail,
          }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );

  server.tool(
    "action_chain",
    "Read an agent action's chain by correlation id, Engine approval request id, or grant id: ordered steps, whether it is complete, whether every step verifies against the signed evidence, and gaps.",
    {
      id: z.string().min(1),
      workspace: workspaceParam,
    },
    async ({ id, workspace }) => {
      try {
        return jsonResult(
          await engine.actionChain(id, { workspace: workspace ?? config.defaultWorkspace }),
        );
      } catch (err) {
        engineFailure(err);
      }
    },
  );
}
