#!/usr/bin/env node
/**
 * Optimal Engine MCP server — stdio entry point.
 *
 * Reads the Engine URL, API key and default workspace the same way as the
 * optimal client CLI (see config.ts): OPTIMAL_ENGINE_URL,
 * OPTIMAL_ENGINE_API_KEY (sent as a Bearer token, never logged),
 * OPTIMAL_WORKSPACE, or a profile.
 *
 * Connects via stdio so MCP-capable agent clients can spawn this binary
 * directly. Tool surface is registered in server.ts.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./server.js";
import { config, maskUrl } from "./config.js";

async function main() {
  // MCP servers communicate over stdout; diagnostics go to stderr.
  console.error(
    `[optimal-engine-mcp] engine ${maskUrl(config.engineUrl)} (from ${config.urlSource}), ` +
      `key ${config.keySource ? `from ${config.keySource}` : "not configured"}, ` +
      `workspace ${config.defaultWorkspace}`,
  );
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Graceful shutdown on SIGINT / SIGTERM when an MCP host disconnects.
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      void transport.close();
      process.exit(0);
    });
  }
}

main().catch((err) => {
  // MCP servers communicate over stdout — error logs MUST go to stderr.
  console.error("[optimal-engine-mcp] fatal:", err);
  process.exit(1);
});
