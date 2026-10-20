// Tool listing, bearer auth, and key secrecy for the built MCP server.
// Runs against a fake HTTP Engine on a random local port: `npm test`.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "fixture-key-mcp-3c9e51";
const requests = [];
const routes = new Map();
let engine;
let client;
let home;

before(async () => {
  engine = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const url = new URL(req.url, "http://fake");
      requests.push({
        method: req.method,
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        auth: req.headers.authorization ?? null,
        body: raw ? JSON.parse(raw) : null,
      });
      let [status, payload] = routes.get(`${req.method} ${url.pathname}`) ?? [200, { ok: true }];
      if (req.headers.authorization !== `Bearer ${KEY}`) [status, payload] = [401, { error: "missing_api_key" }];
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(payload));
    });
  });
  await new Promise((resolve) => engine.listen(0, "127.0.0.1", resolve));

  home = mkdtempSync(join(tmpdir(), "optimal-mcp-test-"));
  for (const name of Object.keys(process.env)) {
    if (name.startsWith("OPTIMAL_") || name.startsWith("OE_") || name === "XDG_CONFIG_HOME") {
      delete process.env[name];
    }
  }
  Object.assign(process.env, {
    HOME: home,
    OPTIMAL_ENGINE_URL: `http://127.0.0.1:${engine.address().port}`,
    OPTIMAL_ENGINE_API_KEY: KEY,
    OPTIMAL_WORKSPACE: "default:sales",
  });

  const { createServer } = await import("../dist/server.js");
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { InMemoryTransport } = await import("@modelcontextprotocol/sdk/inMemory.js");
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await createServer().connect(serverSide);
  client = new Client({ name: "optimal-mcp-test", version: "0.0.0" });
  await client.connect(clientSide);
});

after(async () => {
  await client?.close();
  await new Promise((resolve) => engine.close(resolve));
});

async function call(name, args) {
  requests.length = 0;
  return client.callTool({ name, arguments: args });
}

test("lists the operating, context, record, and authority tools", async () => {
  const { tools } = await client.listTools();
  const names = tools.map((tool) => tool.name);
  for (const name of [
    "boot", "brief", "loops_list", "loops_add", "loops_close", "protocol", "search",
    "assemble", "read", "capture", "record", "close", "authority_decide", "authority_effective",
    "check_draft", "viability", "action_step", "action_chain",
    "session_commit", "sessions_list", "session_get", "org_policy",
  ]) {
    assert.ok(names.includes(name), `missing tool ${name}`);
  }
});

test("sends the key as a bearer token and the default workspace", async () => {
  const result = await call("search", { q: "renewal" });
  assert.equal(result.isError, undefined);
  assert.deepEqual(
    [requests[0].method, requests[0].path, requests[0].auth],
    ["GET", "/api/search", `Bearer ${KEY}`],
  );
  assert.equal(requests[0].query.workspace, "default:sales");
});

test("maps each tool to its route", async () => {
  const cases = [
    ["boot", {}, "GET", "/api/boot"],
    ["brief", { workspaces: "*" }, "GET", "/api/brief"],
    ["protocol", {}, "GET", "/api/protocol"],
    ["loops_list", { state: "open" }, "GET", "/api/loops"],
    ["loops_add", { title: "Send the deck", due_at: "2026-10-20" }, "POST", "/api/loops"],
    ["loops_close", { id: "loop_1" }, "POST", "/api/loops/loop_1/close"],
    ["assemble", { query: "renewal" }, "POST", "/api/assemble"],
    ["read", { target: "optimal://nodes/sales/a.md", tier: "full" }, "GET", "/api/read"],
    ["read", { target: "ctx123" }, "GET", "/api/read"],
    ["capture", { text: "Call notes", genre: "transcript" }, "POST", "/api/ingest"],
    ["record", { kind: "decision", text: "Ship Friday", owner: "user:jane" }, "POST", "/api/memory/remember"],
    ["close", { summary: "Shipped and verified" }, "POST", "/api/memory/remember"],
    ["authority_decide", { action: "read", resource: "optimal://default:sales/**" }, "POST", "/api/authority/decide"],
    ["authority_effective", {}, "GET", "/api/authority/effective"],
    ["check_draft", { draft: "Can you confirm?", channel: "whatsapp" }, "POST", "/api/signals/check"],
    ["viability", {}, "GET", "/api/viability"],
    ["action_step", { stage: "request", action: "send_email" }, "POST", "/api/agent-actions"],
    ["action_chain", { id: "act_1" }, "GET", "/api/agent-actions/act_1"],
    [
      "session_commit",
      { correlation_id: "chat_1", messages: [{ role: "user", content: "Ship Friday" }] },
      "POST",
      "/api/sessions/commit",
    ],
    ["sessions_list", {}, "GET", "/api/sessions"],
    ["session_get", { id: "ses_1" }, "GET", "/api/sessions/ses_1"],
    ["org_policy", {}, "GET", "/api/org-policy"],
    ["forget_memory", { id: "mem_1" }, "POST", "/api/memory/mem_1/forget"],
  ];
  for (const [name, args, method, path] of cases) {
    const result = await call(name, args);
    assert.equal(result.isError, undefined, `${name}: ${JSON.stringify(result.content)}`);
    assert.deepEqual([requests[0].method, requests[0].path], [method, path], name);
    assert.equal(requests[0].auth, `Bearer ${KEY}`);
  }
});

test("records match the CLI shape and never name an actor", async () => {
  await call("close", { summary: "Shipped and verified" });
  assert.deepEqual(requests[0].body, {
    content: "Close-loop: Shipped and verified",
    workspace: "default:sales",
    force: true,
    metadata: { kind: "close", source: "optimal-mcp" },
  });
  await call("capture", { text: "Call notes" });
  assert.equal(requests[0].body.extract_claims, true);
  await call("read", { target: "optimal://nodes/sales/a.md" });
  assert.equal(requests[0].query.uri, "optimal://nodes/sales/a.md");
  await call("authority_effective", {});
  assert.equal(requests[0].query.workspace_id, "default:sales");
  for (const name of ["loops_add", "authority_decide", "record"]) {
    const args = {
      loops_add: { title: "x" },
      authority_decide: { action: "read", resource: "optimal://x" },
      record: { kind: "task", text: "x" },
    }[name];
    await call(name, args);
    for (const field of ["actor_id", "verifier_id", "created_by", "subject"]) {
      assert.equal(field in requests[0].body, false, `${name} sent ${field}`);
    }
  }
});

test("chat sessions go to the default workspace and never name an actor", async () => {
  await call("session_commit", {
    correlation_id: "chat_1",
    title: "Launch",
    messages: [{ role: "user", content: "We decided to ship Friday.", at: "2026-10-18T09:00:00Z" }],
    learned: [{ content: "Send the deck", category: "task", owner: "user:jane", due: "2026-10-23" }],
  });
  assert.deepEqual(requests[0].body, {
    workspace: "default:sales",
    source: "optimal-mcp",
    correlation_id: "chat_1",
    title: "Launch",
    messages: [{ role: "user", content: "We decided to ship Friday.", at: "2026-10-18T09:00:00Z" }],
    learned: [{ content: "Send the deck", category: "task", owner: "user:jane", due: "2026-10-23" }],
  });
  await call("session_get", { id: "ses_1", include_transcript: true });
  assert.deepEqual(requests[0].query, { workspace: "default:sales", include: "transcript" });
  await call("org_policy", {});
  assert.equal(requests[0].query.workspace, "default:sales");
  await call("forget_memory", { id: "mem_1", reason: "superseded" });
  assert.deepEqual(requests[0].body, { workspace: "default:sales", reason: "superseded" });
  const refused = await call("session_commit", {
    correlation_id: "chat_1",
    messages: [{ role: "robot", content: "x" }],
  });
  assert.equal(refused.isError, true);
  assert.equal(requests.length, 0);
});

test("refusals carry the error code and never the key", async () => {
  routes.set("POST /api/ingest", [403, { error: "permission_scope_denied", echo: KEY }]);
  routes.set("GET /api/boot", [401, { error: "invalid_api_key", echo: `Bearer ${KEY}` }]);
  routes.set("GET /api/protocol", [400, { error: "workspace_required" }]);
  try {
    const denied = await call("capture", { text: "x" });
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /HTTP 403: permission_scope_denied/);
    const rejected = await call("boot", {});
    assert.match(rejected.content[0].text, /HTTP 401: invalid_api_key/);
    const scoped = await call("protocol", {});
    assert.match(scoped.content[0].text, /workspace_required/);
    for (const result of [denied, rejected, scoped]) {
      assert.equal(JSON.stringify(result).includes(KEY), false);
    }
  } finally {
    routes.clear();
  }
});

test("configuration follows the CLI rules", async () => {
  const { loadConfig } = await import("../dist/config.js");
  const dir = join(home, ".config", "optimal");
  mkdirSync(join(dir, "profiles"), { recursive: true });
  const profile = join(dir, "profile");
  writeFileSync(profile, "url=https://engine.example.invalid/\nkey=\"profile-key\"\nworkspace=default:ops\n");
  chmodSync(profile, 0o600);

  const fromProfile = loadConfig({ HOME: home });
  assert.equal(fromProfile.engineUrl, "https://engine.example.invalid");
  assert.equal(fromProfile.apiKey, "profile-key");
  assert.equal(fromProfile.defaultWorkspace, "default:ops");

  // A profile key never goes to another URL.
  const otherUrl = loadConfig({ HOME: home, OPTIMAL_ENGINE_URL: "http://127.0.0.1:9" });
  assert.equal(otherUrl.engineUrl, "http://127.0.0.1:9");
  assert.equal(otherUrl.apiKey, null);

  writeFileSync(join(dir, "profiles", "cloud"), "OPTIMAL_ENGINE_URL=https://cloud.example.invalid\nOPTIMAL_ENGINE_API_KEY=cloud-key\n");
  const named = loadConfig({ HOME: home, OPTIMAL_PROFILE: "cloud", OPTIMAL_ENGINE_URL: "http://127.0.0.1:9", OPTIMAL_ENGINE_API_KEY: "env-key" });
  assert.equal(named.engineUrl, "https://cloud.example.invalid");
  assert.equal(named.apiKey, "cloud-key");

  const keyFile = join(home, "key");
  writeFileSync(keyFile, "file-key\n");
  const fromFile = loadConfig({ HOME: home, OE_API: "http://127.0.0.1:9", OPTIMAL_ENGINE_API_KEY_FILE: keyFile });
  assert.equal(fromFile.engineUrl, "http://127.0.0.1:9");
  assert.equal(fromFile.apiKey, "file-key");
  assert.equal(fromFile.defaultWorkspace, "default:ops");

  assert.throws(() => loadConfig({ HOME: home, OPTIMAL_PROFILE: "missing" }), /profile not found/);

  // key_file= is read when the key is used, so a rotated file takes effect.
  writeFileSync(join(dir, "profiles", "filed"), `url=https://filed.example.invalid\nkey_file=${keyFile}\n`);
  assert.equal(loadConfig({ HOME: home, OPTIMAL_PROFILE: "filed" }).apiKey, "file-key");
  writeFileSync(keyFile, "rotated-key\n");
  assert.equal(loadConfig({ HOME: home, OPTIMAL_PROFILE: "filed" }).apiKey, "rotated-key");

  // A key_file for another URL is never read, so a missing one is no error.
  const other = mkdtempSync(join(tmpdir(), "optimal-mcp-other-"));
  mkdirSync(join(other, ".config", "optimal"), { recursive: true });
  writeFileSync(
    join(other, ".config", "optimal", "profile"),
    `url=https://elsewhere.example.invalid\nkey_file=${join(other, "missing")}\n`,
  );
  const elsewhere = loadConfig({ HOME: other, OPTIMAL_ENGINE_URL: "http://127.0.0.1:9" });
  assert.equal(elsewhere.engineUrl, "http://127.0.0.1:9");
  assert.equal(elsewhere.apiKey, null);
});
