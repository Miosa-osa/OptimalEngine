import { McpError, ErrorCode } from "@modelcontextprotocol/sdk/types.js";
import { EngineError, describeEngineError } from "../client.js";

/** A tool result carrying one JSON document. */
export function jsonResult(value: unknown): {
  content: Array<{ type: "text"; text: string }>;
} {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

/** Rethrows an Engine refusal as an MCP error an agent can act on. */
export function engineFailure(err: unknown): never {
  if (err instanceof EngineError) {
    throw new McpError(ErrorCode.InternalError, describeEngineError(err));
  }
  throw err;
}
