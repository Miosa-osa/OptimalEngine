// Reference to-do app on the Optimal Engine app data API.
//
// Build the SDK (npm run build), then run against an Engine:
//
//   OPTIMAL_ENGINE_URL=http://127.0.0.1:4300 OPTIMAL_API_KEY=... \
//   OPTIMAL_WORKSPACE=default:todo-demo node examples/todo-app.ts
//
// Node 22.18+ runs this file directly (type stripping). The key needs
// data:admin (or *) in the workspace; it is never printed.

import { DataError, OptimalEngine, defineCollection } from "../dist/index.js";
import type { RecordOf } from "../dist/index.js";

const baseUrl = process.env["OPTIMAL_ENGINE_URL"] ?? "http://127.0.0.1:4200";
const apiKey = process.env["OPTIMAL_API_KEY"];
const workspace = process.env["OPTIMAL_WORKSPACE"] ?? "default:todo-demo";

const tasks = defineCollection({
  name: "tasks",
  fields: [
    { name: "title", type: "string", required: true, max_length: 200 },
    { name: "done", type: "boolean", default: false },
    { name: "due", type: "datetime" },
    { name: "owner", type: "string" },
  ],
  owner_field: "owner",
  indexes: [{ fields: ["owner", "done", "due"] }],
  search: { text: ["title"], semantic: ["title"] },
} as const);

type Task = RecordOf<typeof tasks>;

let failures = 0;
function check(label: string, ok: boolean, detail = ""): void {
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? `  (${detail})` : ""}`);
}

const engine = new OptimalEngine({ baseUrl, workspace, ...(apiKey ? { apiKey } : {}) });
const data = engine.data();
const todo = data.collection<Task>("tasks");

// 1. The app ships its schema as versioned migrations.
const migrations = [{ version: 1, name: "tasks", operations: [{ op: "create_collection" as const, collection: tasks }] }];
const first = await data.migrate("todo", migrations);
const again = await data.migrate("todo", migrations);
check("migration v1 applies once, then is skipped", first.applied.includes(1) && again.skipped.includes(1));

// 2. 1,000 tasks for two owners.
const titles = ["write the quarterly report", "pay the electricity invoice", "walk the dog", "water the garden", "book flights"];
const records = Array.from({ length: 1000 }, (_, i) => ({
  title: `${titles[i % titles.length]} #${i}`,
  owner: i % 2 === 0 ? "user-a" : "user-b",
  done: i % 5 === 0,
  due: new Date(Date.UTC(2026, 10, 1) + ((i * 7919) % 1000) * 3_600_000).toISOString(),
}));
let created = 0;
for (let i = 0; i < records.length; i += 500) {
  created += (await todo.bulkCreate(records.slice(i, i + 500))).count;
}
check("1,000 tasks created", created === 1000, `${created}`);

// 3. Open tasks for one owner, sorted by due date, paged by cursor.
const expected = records.filter((r) => r.owner === "user-a" && !r.done).map((r) => r.due).sort();
const dues: string[] = [];
let pages = 0;
let cursor: string | undefined;
do {
  const page = await todo.query({
    where: { owner: "user-a", done: false },
    sort: ["due"],
    limit: 100,
    ...(cursor !== undefined ? { cursor } : {}),
  });
  pages += 1;
  dues.push(...page.records.map((r) => r.data.due ?? ""));
  cursor = page.next_cursor ?? undefined;
} while (cursor !== undefined);
const sameOrder = dues.length === expected.length && dues.every((d, i) => d === expected[i]);
check("open tasks for user-a sorted by due, all pages", sameOrder, `${dues.length} tasks in ${pages} pages`);

// 4. An update with a stale version is rejected.
const one = (await todo.query({ where: { owner: "user-a" }, limit: 1 })).records[0];
if (one === undefined) throw new Error("no task to update");
await todo.update(one.id, { done: true }, { version: one.version });
const stale = await todo.update(one.id, { title: "stale write" }, { version: one.version }).catch((e: unknown) => e);
check(
  "update with the wrong version is rejected",
  stale instanceof DataError && stale.status === 409 && stale.code === "version_conflict",
  stale instanceof DataError ? `${stale.status} ${stale.code}, current ${String(stale.details["current_version"])}` : "no error",
);

// 5. A two-write transaction whose second write fails commits nothing.
const failed = await data
  .transaction([
    { op: "create", collection: "tasks", id: "txn-first", data: { title: "first write" } },
    { op: "create", collection: "tasks", id: "txn-second", data: { done: true } },
  ])
  .catch((e: unknown) => e);
const firstWrite = await todo.get("txn-first").catch((e: unknown) => e);
check(
  "two-write transaction with a failing second write commits nothing",
  failed instanceof DataError && failed.details["operation_index"] === 1 && firstWrite instanceof DataError && firstWrite.status === 404,
  failed instanceof DataError ? `${failed.status} ${failed.code} at operation ${String(failed.details["operation_index"])}` : "",
);

// 6. Full-text and semantic search on the title.
const text = await todo.query({ search: "invoice", count: true, limit: 5 });
check("full-text search on title", (text.count ?? 0) === 200 && text.records.every((r) => r.data.title.includes("invoice")), `${text.count} matches`);

const semantic = await todo
  .query({ semantic: "paying bills and money", limit: 3, where: { owner: "user-a" } })
  .catch((e: unknown) => e);
if (semantic instanceof DataError && semantic.code === "semantic_unavailable") {
  console.log(`INFO  semantic search unavailable: ${String(semantic.details["reason"])}`);
} else if (semantic instanceof Error) {
  check("semantic search on title", false, semantic.message);
} else {
  const top = semantic.records.map((r) => r.data.title);
  console.log(`INFO  semantic top 3 for "paying bills and money" (model ${semantic.model}): ${top.join(" | ")}`);
  check("semantic search returns ranked user-a tasks", top.length > 0 && semantic.records.every((r) => r.data.owner === "user-a"));
}

// 7. An end-user key scoped to owner A cannot read owner B's tasks.
const userKey = await data.mintKey({
  name: "user-a session",
  owner: "user-a",
  collections: ["tasks"],
  operations: ["read", "create", "update"],
  expires_in: 600,
});
const asUserA = new OptimalEngine({ baseUrl, workspace, apiKey: userKey.key }).data().collection<Task>("tasks");
const visible = await asUserA.query({ count: true, limit: 1 });
const bTask = (await todo.query({ where: { owner: "user-b" }, limit: 1 })).records[0];
const readB = bTask ? await asUserA.get(bTask.id).catch((e: unknown) => e) : null;
const spoof = await asUserA.create({ title: "spoofed", owner: "user-b" }).catch((e: unknown) => e);
check("end-user key sees only owner A's tasks", visible.count === 501, `${visible.count} visible`);
check("end-user key cannot read owner B's task", readB instanceof DataError && readB.status === 404);
check("end-user key cannot create a task for owner B", spoof instanceof DataError && spoof.code === "owner_mismatch");
await data.revokeKey(userKey.id);
const revoked = await asUserA.query({ limit: 1 }).catch((e: unknown) => e);
check("revoked end-user key is refused", revoked instanceof DataError && revoked.status === 401);

// 8. The change feed resumes from a sequence number.
const mark = await data.changes({ since: "latest" });
await todo.create({ title: "after the mark", owner: "user-b" });
const resumed = await data.changes({ since: mark.latest_seq, collection: "tasks" });
check(
  "change feed resumes after a sequence",
  resumed.changes.length === 1 && resumed.changes[0]?.op === "create" && (resumed.changes[0]?.seq ?? 0) > mark.latest_seq,
);

// 9. A file on a record, downloaded with a byte range.
const file = await todo.uploadFile(one.id, { filename: "notes.txt", content: "0123456789", contentType: "text/plain" });
const part = await todo.downloadFile(one.id, file.id, { range: "bytes=3-6" });
check("file range download", part.status === 206 && new TextDecoder().decode(part.bytes) === "3456", part.contentRange ?? "");

console.log(failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
