// Release compatibility between the MCP server and the Engine: the server names
// itself in User-Agent, warns once on stderr when the Engine marks it as
// another minor release (x-optimal-client-outdated), and turns a 426 into a
// tool error with the upgrade hint. Runs against a fake HTTP Engine: `npm test`.
// Its own file, so the once-per-process warning starts unset.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "fixture-key-mcp-compat-41d7";
const PACKAGE_VERSION = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
).version;
const [MAJOR, MINOR] = PACKAGE_VERSION.split(".").map(Number);
const NEXT_MINOR = `${MAJOR}.${MINOR + 1}.0`;
const NEXT_MAJOR = `${MAJOR + 1}.0.0`;

const requests = [];
const routes = new Map();
let headers = {};
let engine;
let client;
const stderr = [];
const consoleError = console.error;

before(async () => {
  engine = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      const url = new URL(req.url, "http://fake");
      requests.push({ path: url.pathname, userAgent: req.headers["user-agent"] ?? null });
      const [status, payload] = routes.get(`${req.method} ${url.pathname}`) ?? [200, { ok: true }];
      res.writeHead(status, { "content-type": "application/json", ...headers });
      res.end(JSON.stringify(payload));
    });
  });
  await new Promise((resolve) => engine.listen(0, "127.0.0.1", resolve));

  for (const name of Object.keys(process.env)) {
    if (name.startsWith("OPTIMAL_") || name.startsWith("OE_") || name === "XDG_CONFIG_HOME") {
      delete process.env[name];
    }
  }
  Object.assign(process.env, {
    HOME: mkdtempSync(join(tmpdir(), "optimal-mcp-compat-")),
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
  client = new Client({ name: "optimal-mcp-compat-test", version: "0.0.0" });
  await client.connect(clientSide);
});

after(async () => {
  console.error = consoleError;
  await client?.close();
  await new Promise((resolve) => engine.close(resolve));
});

const call = (name, args) => client.callTool({ name, arguments: args });
const warnings = () => stderr.filter((line) => line.includes("warning"));

test("names itself and its version in User-Agent", async () => {
  const { MCP_VERSION } = await import("../dist/version.js");
  assert.equal(MCP_VERSION, PACKAGE_VERSION);
  requests.length = 0;
  await call("search", { q: "renewal" });
  assert.equal(requests[0].userAgent, `optimal-mcp/${PACKAGE_VERSION}`);
});

test("a matching Engine prints nothing", async () => {
  await call("boot", {});
  assert.deepEqual(warnings(), []);
});

test("an Engine of another minor release gets one warning per Engine release", async () => {
  headers = { "x-optimal-client-outdated": `client=${PACKAGE_VERSION} engine=${NEXT_MINOR}` };
  try {
    for (const [name, args] of [["boot", {}], ["search", { q: "x" }], ["capture", { text: "x" }]]) {
      const result = await call(name, args);
      assert.equal(result.isError, undefined, `${name}: ${JSON.stringify(result.content)}`);
    }
    let lines = warnings();
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], new RegExp(`MCP server ${PACKAGE_VERSION} is outdated for Engine ${NEXT_MINOR}`));
    assert.match(lines[0], new RegExp(`upgrade the MCP server to ${NEXT_MINOR}`));

    // The Engine is upgraded while the server runs: one more line, for the new release.
    const later = `${MAJOR}.${MINOR + 2}.0`;
    headers = { "x-optimal-client-outdated": `client=${PACKAGE_VERSION} engine=${later}` };
    await call("boot", {});
    await call("boot", {});
    lines = warnings();
    assert.equal(lines.length, 2, lines.join("\n"));
    assert.match(lines[1], new RegExp(`outdated for Engine ${later}`));
  } finally {
    headers = {};
  }
});

test("a refused client becomes a tool error with the upgrade hint", async () => {
  const refusal = [
    426,
    {
      error: "client_incompatible",
      message: `This client (optimal-mcp/${PACKAGE_VERSION}) is not compatible with this Engine (${NEXT_MAJOR}).`,
      client: `optimal-mcp/${PACKAGE_VERSION}`,
      engine: NEXT_MAJOR,
      required: `major:${MAJOR + 1}`,
    },
  ];
  routes.set("GET /api/boot", refusal);
  routes.set("GET /api/search", refusal);
  try {
    // One tool reports through describeEngineError, one through its own handler.
    for (const [name, args] of [["boot", {}], ["search", { q: "x" }]]) {
      const result = await call(name, args);
      assert.equal(result.isError, true, name);
      const text = result.content[0].text;
      assert.match(text, /426/, name);
      assert.match(text, new RegExp(`the Engine \\(${NEXT_MAJOR}\\) refuses MCP server ${PACKAGE_VERSION}`), name);
      assert.match(text, new RegExp(`upgrade the MCP server to ${NEXT_MAJOR}`), name);
      assert.equal(JSON.stringify(result).includes(KEY), false);
    }
    const boot = await call("boot", {});
    assert.match(boot.content[0].text, /HTTP 426: client_incompatible/);
  } finally {
    routes.clear();
  }
});
