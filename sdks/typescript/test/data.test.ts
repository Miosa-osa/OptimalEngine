import { beforeEach, describe, expect, expectTypeOf, it, vi } from "vitest";
import { OptimalEngine } from "../src/client.js";
import {
  DataError,
  defineCollection,
  type RecordOf,
} from "../src/data.js";

function mockFetchSequence(
  responses: { status: number; body: unknown; headers?: Record<string, string> }[],
): void {
  const fn = vi.fn();
  for (const r of responses) {
    fn.mockResolvedValueOnce({
      ok: r.status >= 200 && r.status < 300,
      status: r.status,
      statusText: "",
      headers: new Headers(r.headers ?? {}),
      json: () => Promise.resolve(r.body),
      arrayBuffer: () =>
        Promise.resolve(new TextEncoder().encode(String(r.body)).buffer),
    });
  }
  vi.stubGlobal("fetch", fn);
}

function call(i: number): { url: string; init: RequestInit } {
  const c = vi.mocked(fetch).mock.calls[i];
  if (c === undefined) throw new Error(`fetch call ${i} missing`);
  return { url: c[0] as string, init: c[1] as RequestInit };
}

const tasks = defineCollection({
  name: "tasks",
  fields: [
    { name: "title", type: "string", required: true },
    { name: "done", type: "boolean", default: false },
    { name: "due", type: "datetime" },
    { name: "owner", type: "string" },
  ],
  owner_field: "owner",
  search: { text: ["title"] },
} as const);

type Task = RecordOf<typeof tasks>;

const record = (id: string, version = 1) => ({
  id,
  version,
  created_at: "2026-11-01T00:00:00.000Z",
  updated_at: "2026-11-01T00:00:00.000Z",
  created_by: "api_key:x",
  updated_by: "api_key:x",
  data: { title: "t", done: false, due: null, owner: "user-a" },
});

describe("DataClient", () => {
  beforeEach(() => vi.restoreAllMocks());

  const engine = new OptimalEngine({
    baseUrl: "http://engine.test",
    apiKey: "oe_test_key",
    workspace: "default:todo",
  });

  it("derives record types from a schema", () => {
    expectTypeOf<Task["title"]>().toEqualTypeOf<string>();
    expectTypeOf<Task["done"]>().toEqualTypeOf<boolean | null>();
    expectTypeOf<Task["due"]>().toEqualTypeOf<string | null>();
  });

  it("creates a collection and records in the workspace", async () => {
    mockFetchSequence([
      { status: 201, body: { name: "tasks", schema_version: 1 } },
      { status: 201, body: record("r1") },
    ]);
    const data = engine.data();
    await data.createCollection(tasks);
    const created = await data.collection<Task>("tasks").create({ title: "t" });

    expect(created.id).toBe("r1");
    expect(call(0).url).toBe("http://engine.test/api/data/collections");
    expect(JSON.parse(call(0).init.body as string)).toMatchObject({
      name: "tasks",
      workspace: "default:todo",
    });
    expect(call(1).url).toBe("http://engine.test/api/data/collections/tasks/records");
    expect(JSON.parse(call(1).init.body as string)).toEqual({
      data: { title: "t" },
      workspace: "default:todo",
    });
    expect((call(1).init.headers as Record<string, string>)["Authorization"]).toBe(
      "Bearer oe_test_key",
    );
  });

  it("raises DataError with the server code and details on a version conflict", async () => {
    mockFetchSequence([
      { status: 409, body: { error: "version_conflict", current_version: 3 } },
    ]);
    const err = await engine
      .data()
      .collection<Task>("tasks")
      .update("r1", { done: true }, { version: 2 })
      .catch((e: unknown) => e);

    expect(err).toBeInstanceOf(DataError);
    expect((err as DataError).status).toBe(409);
    expect((err as DataError).code).toBe("version_conflict");
    expect((err as DataError).details["current_version"]).toBe(3);
    expect(call(0).init.method).toBe("PATCH");
    expect(JSON.parse(call(0).init.body as string)).toMatchObject({ version: 2 });
  });

  it("iterates every page by cursor", async () => {
    mockFetchSequence([
      { status: 200, body: { records: [record("a"), record("b")], next_cursor: "c1", has_more: true } },
      { status: 200, body: { records: [record("c")], next_cursor: null, has_more: false } },
    ]);
    const ids: string[] = [];
    for await (const r of engine.data().collection<Task>("tasks").iterate({
      where: { owner: "user-a", done: false },
      sort: ["due"],
      limit: 2,
    })) {
      ids.push(r.id);
    }

    expect(ids).toEqual(["a", "b", "c"]);
    expect(JSON.parse(call(1).init.body as string)).toMatchObject({ cursor: "c1", limit: 2 });
  });

  it("sends a transaction and reports the failing operation", async () => {
    mockFetchSequence([
      {
        status: 422,
        body: { error: "validation_failed", details: ["title is required"], operation_index: 1, committed: false },
      },
    ]);
    const err = (await engine
      .data()
      .transaction([
        { op: "create", collection: "tasks", data: { title: "a" } },
        { op: "create", collection: "tasks", data: {} },
      ])
      .catch((e: unknown) => e)) as DataError;

    expect(err.code).toBe("validation_failed");
    expect(err.details["operation_index"]).toBe(1);
    expect(call(0).url).toBe("http://engine.test/api/data/transactions");
  });

  it("uploads files as base64 and downloads byte ranges", async () => {
    mockFetchSequence([
      { status: 201, body: { id: "file_1", filename: "a.txt", size_bytes: 5 } },
      { status: 206, body: "ell", headers: { "content-range": "bytes 1-3/5" } },
    ]);
    const files = engine.data().collection("tasks");
    await files.uploadFile("r1", { filename: "a.txt", content: "hello", contentType: "text/plain" });
    const part = await files.downloadFile("r1", "file_1", { range: "bytes=1-3" });

    expect(JSON.parse(call(0).init.body as string)).toMatchObject({
      filename: "a.txt",
      content_base64: "aGVsbG8=",
      content_type: "text/plain",
    });
    expect(call(1).url).toBe(
      "http://engine.test/api/data/collections/tasks/records/r1/files/file_1?workspace=default%3Atodo",
    );
    expect((call(1).init.headers as Record<string, string>)["Range"]).toBe("bytes=1-3");
    expect(part.status).toBe(206);
    expect(new TextDecoder().decode(part.bytes)).toBe("ell");
    expect(part.contentRange).toBe("bytes 1-3/5");
  });

  it("needs a workspace", () => {
    expect(() => new OptimalEngine({ baseUrl: "http://engine.test" }).data()).toThrow(/workspace/);
  });
});
