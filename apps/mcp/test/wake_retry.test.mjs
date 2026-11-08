// A paused managed Engine: MIOSA's proxy answers 503 ENGINE_WAKING with Retry-After
// while the Engine boots, and the server asks again within OPTIMAL_WAKE_TIMEOUT.
// Its own file: the wake timeout is read once, when the server starts.
import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "fixture-key-mcp-wake-81b4";
const WAKE_TIMEOUT = 3;
const requests = [];
// "METHOD /path" -> answers served once each, in order, before the default 200.
const queued = new Map();
const always = new Map();
let engine;
let client;
const stderr = [];
const consoleError = console.error;

function waking(retryAfter = "1") {
  return [
    503,
    { error: { code: "ENGINE_WAKING", message: "the Engine is starting" } },
    retryAfter === null ? {} : { "retry-after": retryAfter },
  ];
}

before(async () => {
  engine = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const url = new URL(req.url, "http://fake");
      const route = `${req.method} ${url.pathname}`;
      requests.push({ method: req.method, path: url.pathname, auth: req.headers.authorization, body: raw });
      const [status, payload, headers = {}] =
        queued.get(route)?.shift() ?? always.get(route) ?? [200, { ok: true, path: url.pathname }];
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
    HOME: mkdtempSync(join(tmpdir(), "optimal-mcp-wake-")),
    OPTIMAL_ENGINE_URL: `http://127.0.0.1:${engine.address().port}`,
    OPTIMAL_ENGINE_API_KEY: KEY,
    OPTIMAL_WORKSPACE: "default:sales",
    OPTIMAL_WAKE_TIMEOUT: String(WAKE_TIMEOUT),
  });
  console.error = (...args) => stderr.push(args.join(" "));

  const { createServer } = await import("../dist/server.js");
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { InMemoryTransport } = await import("@modelcontextprotocol/sdk/inMemory.js");
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await createServer().connect(serverSide);
  client = new Client({ name: "optimal-mcp-wake-test", version: "0.0.0" });
  await client.connect(clientSide);
});

after(async () => {
  console.error = consoleError;
  await client?.close();
  await new Promise((resolve) => engine.close(resolve));
});

beforeEach(() => {
  requests.length = 0;
  queued.clear();
  always.clear();
  stderr.length = 0;
});

function call(name, args) {
  return client.callTool({ name, arguments: args }, undefined, { timeout: 60_000 });
}

test("a GET waits for a waking Engine, honoring Retry-After", async () => {
  queued.set("GET /api/boot", [waking(), waking()]);
  always.set("GET /api/boot", [200, { day: "today" }]);
  const started = Date.now();
  const result = await call("boot", {});
  assert.equal(result.isError, undefined, JSON.stringify(result.content));
  assert.match(result.content[0].text, /today/);
  assert.ok(Date.now() - started >= 2000, "Retry-After was not honored");
  assert.equal(requests.length, 3);
  const notes = stderr.filter((line) => line.includes("waking"));
  assert.equal(notes.length, 1, stderr.join("\n"));
  assert.equal(stderr.join("\n").includes(KEY), false);
});

test("a POST is sent again, with the same body, when the Engine was waking", async () => {
  queued.set("POST /api/ingest", [waking()]);
  const result = await call("capture", { text: "Customer moved the date" });
  assert.equal(result.isError, undefined, JSON.stringify(result.content));
  assert.deepEqual(requests.map((r) => r.method), ["POST", "POST"]);
  assert.equal(requests[0].body, requests[1].body);
  assert.equal(JSON.parse(requests[1].body).text, "Customer moved the date");
  assert.equal(requests[1].auth, `Bearer ${KEY}`);
});

test("a waking answer without Retry-After still waits", async () => {
  queued.set("GET /api/boot", [waking(null)]);
  const result = await call("boot", {});
  assert.equal(result.isError, undefined, JSON.stringify(result.content));
  assert.equal(requests.length, 2);
});

test("a plain 503 or 429 with Retry-After is asked again for a GET only", async () => {
  queued.set("GET /api/boot", [
    [503, { error: "unavailable" }, { "retry-after": "1" }],
    [429, { error: "rate_limited" }, { "retry-after": "1" }],
  ]);
  const ok = await call("boot", {});
  assert.equal(ok.isError, undefined, JSON.stringify(ok.content));
  assert.equal(requests.length, 3);

  for (const status of [503, 429]) {
    requests.length = 0;
    queued.set("POST /api/ingest", [[status, { error: "busy" }, { "retry-after": "1" }]]);
    const result = await call("capture", { text: "not twice" });
    assert.equal(result.isError, true, `${status}`);
    assert.equal(requests.length, 1, `a ${status} POST was sent again`);
    assert.match(result.content[0].text, new RegExp(`${status}`));
  }
});

test("a 503 without Retry-After is not asked again", async () => {
  always.set("GET /api/boot", [503, { error: "unavailable" }]);
  const result = await call("boot", {});
  assert.equal(result.isError, true);
  assert.equal(requests.length, 1);
});

test("the wait is bounded by OPTIMAL_WAKE_TIMEOUT", async () => {
  always.set("GET /api/boot", waking("30"));
  const started = Date.now();
  const result = await call("boot", {});
  const elapsed = Date.now() - started;
  assert.equal(result.isError, true);
  assert.ok(elapsed >= WAKE_TIMEOUT * 1000 && elapsed < 10_000, `${elapsed}ms`);
  assert.equal(requests.length, 2);
  assert.match(result.content[0].text, /still waking after 3s/);
  assert.match(result.content[0].text, /ENGINE_WAKING/);
  assert.match(result.content[0].text, /OPTIMAL_WAKE_TIMEOUT/);
});

test("the wake timeout is read from the environment and checked", async () => {
  const { loadConfig } = await import("../dist/config.js");
  const home = mkdtempSync(join(tmpdir(), "optimal-mcp-wake-cfg-"));
  assert.equal(loadConfig({ HOME: home }).wakeTimeoutSeconds, 90);
  assert.equal(loadConfig({ HOME: home, OPTIMAL_WAKE_TIMEOUT: "0" }).wakeTimeoutSeconds, 0);
  assert.equal(loadConfig({ HOME: home, OPTIMAL_WAKE_TIMEOUT: "120" }).wakeTimeoutSeconds, 120);
  assert.throws(() => loadConfig({ HOME: home, OPTIMAL_WAKE_TIMEOUT: "soon" }), /OPTIMAL_WAKE_TIMEOUT/);
});
