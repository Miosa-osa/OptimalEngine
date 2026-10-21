// An x-optimal-client-outdated header the server cannot read still warns once,
// without echoing the Engine's text. Its own file: the warning is once per process.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "fixture-key-mcp-outdated-5e02";
let engine;
let client;
const stderr = [];
const consoleError = console.error;

before(async () => {
  engine = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, {
        "content-type": "application/json",
        "x-optimal-client-outdated": "client=? engine=unknown-build-from-elsewhere",
      });
      res.end(JSON.stringify({ ok: true }));
    });
  });
  await new Promise((resolve) => engine.listen(0, "127.0.0.1", resolve));

  for (const name of Object.keys(process.env)) {
    if (name.startsWith("OPTIMAL_") || name.startsWith("OE_") || name === "XDG_CONFIG_HOME") {
      delete process.env[name];
    }
  }
  Object.assign(process.env, {
    HOME: mkdtempSync(join(tmpdir(), "optimal-mcp-outdated-")),
    OPTIMAL_ENGINE_URL: `http://127.0.0.1:${engine.address().port}`,
    OPTIMAL_ENGINE_API_KEY: KEY,
    OPTIMAL_WORKSPACE: "default:sales",
  });
  console.error = (...args) => stderr.push(args.join(" "));

  const { createServer } = await import("../dist/server.js");
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { InMemoryTransport } = await import("@modelcontextprotocol/sdk/inMemory.js");
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await createServer().connect(serverSide);
  client = new Client({ name: "optimal-mcp-outdated-test", version: "0.0.0" });
  await client.connect(clientSide);
});

after(async () => {
  console.error = consoleError;
  await client?.close();
  await new Promise((resolve) => engine.close(resolve));
});

test("an unreadable outdated header warns once and is not echoed", async () => {
  await client.callTool({ name: "boot", arguments: {} });
  await client.callTool({ name: "search", arguments: { q: "x" } });
  const warnings = stderr.filter((line) => line.includes("warning"));
  assert.equal(warnings.length, 1, warnings.join("\n"));
  assert.match(warnings[0], /as outdated/);
  assert.equal(warnings[0].includes("unknown-build"), false, warnings[0]);
});
