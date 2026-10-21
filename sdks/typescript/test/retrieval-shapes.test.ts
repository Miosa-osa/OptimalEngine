import { beforeEach, describe, expect, expectTypeOf, it, vi } from "vitest";
import type { z } from "zod";
import { optimalEngineTools } from "../src/adapters/ai-sdk.js";
import { optimalEngineAgentTools } from "../src/adapters/openai-agents.js";
import { OptimalEngine } from "../src/client.js";
import type {
  AskOptions,
  AskResult,
  Bandwidth,
  GrepHit,
  GrepOptions,
  GrepResult,
  OrgPolicyBlock,
  ProfileOptions,
  RagBandwidth,
  RagFormat,
  RecallResult,
  SearchHit,
  SearchOptions,
  SearchResult,
} from "../src/types.js";

// ---------------------------------------------------------------------------
// Fixtures: the response bodies exactly as the Engine serves them.
// ---------------------------------------------------------------------------

const GREP_BODY = {
  query: "renewal",
  workspace_id: "ws1",
  results: [
    {
      slug: "accounts/acme-renewal",
      scale: "paragraph",
      intent: "decision",
      sn_ratio: 0.82,
      modality: "text",
      snippet: "We decided to renew Acme for two years.",
      score: 0.91,
      uri: "optimal://ws1/accounts/acme-renewal",
    },
    {
      slug: "notes/misc",
      scale: "chunk",
      intent: null,
      sn_ratio: null,
      modality: null,
      snippet: "renewal mentioned in passing",
      score: 0.2,
      uri: null,
    },
  ],
  pagination: { offset: 0, limit: 25, total: 2, has_more: false },
} satisfies GrepResult;

const SEARCH_BODY = {
  query: "retention policy",
  results: [
    {
      id: "ctx-1",
      title: "Retention policy",
      node: "policy",
      genre: "spec",
      uri: "optimal://ws1/policy/retention",
      content: "Keep records for seven years.",
      l0_abstract: "Seven-year retention.",
      sn_ratio: 0.7,
      score: 0.88,
      workspace_id: "ws1",
      metadata: { kind: "memory" },
      inherited: false,
      source_workspace_id: "ws1",
    },
    {
      id: "ctx-2",
      title: null,
      node: null,
      genre: null,
      uri: null,
      content: null,
      l0_abstract: null,
      sn_ratio: null,
      score: null,
      workspace_id: "ws1",
      metadata: null,
      inherited: true,
      source_workspace_id: "org-root",
    },
  ],
  pagination: { offset: 20, limit: 10, total: 31, has_more: true },
} satisfies SearchResult;

const ORG_POLICY: OrgPolicyBlock = {
  org_workspace_id: "org-root",
  inherited: true,
  count: 1,
  memories: [
    {
      id: "mem-9",
      uri: "optimal://org-root/memory/mem-9",
      content: "Never share customer data outside the tenant.",
      version: 2,
      audience: "internal",
      citation_uri: null,
      metadata: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-02-01T00:00:00Z",
      source_workspace_id: "org-root",
      inherited: true,
    },
  ],
  withheld: 3,
  withheld_reason: "audience",
};

const RAG_BODY = {
  source: "wiki",
  envelope: {
    body: "The auth flow uses refresh-token rotation.",
    format: "markdown",
    sources: ["optimal://ws1/wiki/auth-flow"],
    warnings: [],
  },
  trace: {
    intent: { type: "decision" },
    "wiki_hit?": true,
    n_candidates: 12,
    n_delivered: 3,
    "truncated?": false,
    elapsed_ms: 41,
  },
  org_policy: ORG_POLICY,
} satisfies AskResult;

const RECALL_BODY = {
  ...RAG_BODY,
  recall_query: "what actions, decisions, or commitments about auth",
} satisfies RecallResult;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function mockFetch(body: unknown): void {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      statusText: "OK",
      headers: new Headers(),
      json: () => Promise.resolve(body),
    }),
  );
}

function lastCall(): { url: URL; body: Record<string, unknown> | undefined } {
  const calls = vi.mocked(fetch).mock.calls;
  const call = calls[calls.length - 1];
  if (call === undefined) throw new Error("fetch was never called");
  const init = call[1] as RequestInit | undefined;
  const rawBody = init?.body;
  return {
    url: new URL(call[0] as string),
    body:
      typeof rawBody === "string"
        ? (JSON.parse(rawBody) as Record<string, unknown>)
        : undefined,
  };
}

const TOOL_CTX = { toolCallId: "call-1", messages: [] };

// ---------------------------------------------------------------------------
// grep
// ---------------------------------------------------------------------------

describe("grep response shape", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should expose slug, snippet, scale, intent, score on each hit", async () => {
    mockFetch(GREP_BODY);
    const client = new OptimalEngine();

    const result = await client.grep("renewal", { workspace: "ws1" });

    const hit = result.results[0];
    expect(hit?.slug).toBe("accounts/acme-renewal");
    expect(hit?.snippet).toBe("We decided to renew Acme for two years.");
    expect(hit?.scale).toBe("paragraph");
    expect(hit?.intent).toBe("decision");
    expect(hit?.sn_ratio).toBe(0.82);
    expect(hit?.modality).toBe("text");
    expect(hit?.score).toBe(0.91);
    expect(hit?.uri).toBe("optimal://ws1/accounts/acme-renewal");
  });

  it("should keep null intent, sn_ratio and modality as null", async () => {
    mockFetch(GREP_BODY);
    const client = new OptimalEngine();

    const result = await client.grep("renewal");

    const hit = result.results[1];
    expect(hit?.intent).toBeNull();
    expect(hit?.sn_ratio).toBeNull();
    expect(hit?.modality).toBeNull();
    expect(hit?.uri).toBeNull();
  });

  it("should expose query, workspace_id and pagination", async () => {
    mockFetch(GREP_BODY);
    const client = new OptimalEngine();

    const result = await client.grep("renewal");

    expect(result.query).toBe("renewal");
    expect(result.workspace_id).toBe("ws1");
    expect(result.pagination).toEqual({
      offset: 0,
      limit: 25,
      total: 2,
      has_more: false,
    });
  });

  it("should forward offset, path and asOf alongside the existing filters", async () => {
    mockFetch(GREP_BODY);
    const client = new OptimalEngine();

    await client.grep("renewal", {
      workspace: "ws1",
      intent: "decision",
      scale: "paragraph",
      modality: "text",
      limit: 25,
      offset: 50,
      literal: true,
      path: "accounts/",
      asOf: "2026-10-20T12:00:00Z",
    });

    const { url } = lastCall();
    expect(url.pathname).toBe("/api/grep");
    expect(url.searchParams.get("q")).toBe("renewal");
    expect(url.searchParams.get("offset")).toBe("50");
    expect(url.searchParams.get("path")).toBe("accounts/");
    expect(url.searchParams.get("limit")).toBe("25");
    expect(url.searchParams.get("literal")).toBe("true");
    expect(url.searchParams.get("as_of")).toBe("2026-10-20T12:00:00Z");
  });

  it("should type scale as the four Engine scales and hits without id or content", () => {
    expectTypeOf<GrepOptions["scale"]>().toEqualTypeOf<
      "document" | "section" | "paragraph" | "chunk" | undefined
    >();
    expectTypeOf<GrepHit["scale"]>().toEqualTypeOf<
      "document" | "section" | "paragraph" | "chunk"
    >();
    expectTypeOf<GrepHit["slug"]>().toEqualTypeOf<string>();
    expectTypeOf<GrepHit["snippet"]>().toEqualTypeOf<string>();
    expectTypeOf<GrepHit["intent"]>().toEqualTypeOf<string | null>();
    expectTypeOf<GrepHit["sn_ratio"]>().toEqualTypeOf<number | null>();
    expectTypeOf<GrepHit["score"]>().toEqualTypeOf<number>();
    expectTypeOf<GrepHit["uri"]>().toEqualTypeOf<string | null>();
    expectTypeOf<GrepHit>().not.toHaveProperty("id");
    expectTypeOf<GrepHit>().not.toHaveProperty("content");
  });
});

// ---------------------------------------------------------------------------
// search
// ---------------------------------------------------------------------------

describe("search response shape", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should expose inherited and source_workspace_id on each hit", async () => {
    mockFetch(SEARCH_BODY);
    const client = new OptimalEngine();

    const result = await client.search("retention policy");

    const own = result.results[0];
    const inherited = result.results[1];
    expect(own?.inherited).toBe(false);
    expect(own?.source_workspace_id).toBe("ws1");
    expect(own?.l0_abstract).toBe("Seven-year retention.");
    expect(inherited?.inherited).toBe(true);
    expect(inherited?.source_workspace_id).toBe("org-root");
  });

  it("should keep nullable hit fields as null", async () => {
    mockFetch(SEARCH_BODY);
    const client = new OptimalEngine();

    const result = await client.search("retention policy");

    const sparse = result.results[1];
    expect(sparse?.title).toBeNull();
    expect(sparse?.content).toBeNull();
    expect(sparse?.score).toBeNull();
    expect(sparse?.metadata).toBeNull();
  });

  it("should expose query and pagination", async () => {
    mockFetch(SEARCH_BODY);
    const client = new OptimalEngine();

    const result = await client.search("retention policy");

    expect(result.query).toBe("retention policy");
    expect(result.pagination.has_more).toBe(true);
    expect(result.pagination.total).toBe(31);
  });

  it("should forward offset, type=memory, asOf and mode", async () => {
    mockFetch(SEARCH_BODY);
    const client = new OptimalEngine();

    await client.search("retention policy", {
      workspace: "ws1",
      limit: 10,
      offset: 20,
      type: "memory",
      asOf: new Date("2026-10-20T12:00:00Z"),
      mode: "lexical",
    });

    const { url } = lastCall();
    expect(url.pathname).toBe("/api/search");
    expect(url.searchParams.get("limit")).toBe("10");
    expect(url.searchParams.get("offset")).toBe("20");
    expect(url.searchParams.get("type")).toBe("memory");
    expect(url.searchParams.get("as_of")).toBe("2026-10-20T12:00:00.000Z");
    expect(url.searchParams.get("mode")).toBe("lexical");
  });

  it("should not send offset, type, as_of or mode when they are not given", async () => {
    mockFetch(SEARCH_BODY);
    const client = new OptimalEngine();

    await client.search("retention policy");

    const { url } = lastCall();
    expect(url.searchParams.has("offset")).toBe(false);
    expect(url.searchParams.has("type")).toBe(false);
    expect(url.searchParams.has("as_of")).toBe(false);
    expect(url.searchParams.has("mode")).toBe(false);
  });

  it("should type hits with the real nullable fields and no audience", () => {
    expectTypeOf<SearchHit["id"]>().toEqualTypeOf<string>();
    expectTypeOf<SearchHit["inherited"]>().toEqualTypeOf<boolean>();
    expectTypeOf<SearchHit["source_workspace_id"]>().toEqualTypeOf<
      string | null
    >();
    expectTypeOf<SearchHit["content"]>().toEqualTypeOf<string | null>();
    expectTypeOf<SearchHit["metadata"]>().toEqualTypeOf<Record<
      string,
      unknown
    > | null>();
    expectTypeOf<SearchHit>().not.toHaveProperty("audience");
    expectTypeOf<SearchOptions["type"]>().toEqualTypeOf<"memory" | undefined>();
  });
});

// ---------------------------------------------------------------------------
// ask
// ---------------------------------------------------------------------------

describe("ask response shape", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should expose envelope.body and envelope.sources", async () => {
    mockFetch(RAG_BODY);
    const client = new OptimalEngine();

    const result = await client.ask("What did we decide about auth?");

    expect(result.source).toBe("wiki");
    expect(result.envelope.body).toBe(
      "The auth flow uses refresh-token rotation.",
    );
    expect(result.envelope.sources).toEqual(["optimal://ws1/wiki/auth-flow"]);
    expect(result.envelope.format).toBe("markdown");
    expect(result.trace.n_delivered).toBe(3);
    expect(result.trace["wiki_hit?"]).toBe(true);
  });

  it("should expose the org policy block with inherited memories", async () => {
    mockFetch(RAG_BODY);
    const client = new OptimalEngine();

    const result = await client.ask("q");

    expect(result.org_policy.inherited).toBe(true);
    expect(result.org_policy.count).toBe(1);
    expect(result.org_policy.withheld).toBe(3);
    expect(result.org_policy.withheld_reason).toBe("audience");
    expect(result.org_policy.memories[0]?.source_workspace_id).toBe("org-root");
    expect(result.org_policy.memories[0]?.audience).toBe("internal");
  });

  it("should forward bandwidth small and a rag format", async () => {
    mockFetch(RAG_BODY);
    const client = new OptimalEngine();

    await client.ask("q", {
      workspace: "ws1",
      audience: "internal",
      format: "claude",
      bandwidth: "small",
    });

    const { url, body } = lastCall();
    expect(url.pathname).toBe("/api/rag");
    expect(body?.["bandwidth"]).toBe("small");
    expect(body?.["format"]).toBe("claude");
    expect(body?.["audience"]).toBe("internal");
  });

  it("should split the rag bandwidth type from the profile bandwidth type", () => {
    expectTypeOf<RagBandwidth>().toEqualTypeOf<"small" | "medium" | "large">();
    expectTypeOf<RagFormat>().toEqualTypeOf<
      "plain" | "markdown" | "claude" | "openai"
    >();
    expectTypeOf<Bandwidth>().toEqualTypeOf<"l0" | "l1" | "full">();
    expectTypeOf<AskOptions["bandwidth"]>().toEqualTypeOf<
      RagBandwidth | undefined
    >();
    expectTypeOf<ProfileOptions["bandwidth"]>().toEqualTypeOf<
      Bandwidth | undefined
    >();
  });

  it("should not declare answer or citations", () => {
    expectTypeOf<AskResult>().not.toHaveProperty("answer");
    expectTypeOf<AskResult>().not.toHaveProperty("citations");
    expectTypeOf<AskResult["envelope"]["body"]>().toEqualTypeOf<string>();
    expectTypeOf<AskResult["envelope"]["sources"]>().toEqualTypeOf<string[]>();
  });
});

// ---------------------------------------------------------------------------
// profile keeps its own bandwidth set
// ---------------------------------------------------------------------------

describe("profile bandwidth", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should still send l0, l1 or full to /api/profile", async () => {
    mockFetch({});
    const client = new OptimalEngine();

    await client.profile({ workspace: "ws1", bandwidth: "l0" });

    const { url } = lastCall();
    expect(url.pathname).toBe("/api/profile");
    expect(url.searchParams.get("bandwidth")).toBe("l0");
  });
});

// ---------------------------------------------------------------------------
// recall
// ---------------------------------------------------------------------------

describe("recall response shape", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should expose recall_query and the rag envelope", async () => {
    mockFetch(RECALL_BODY);
    const client = new OptimalEngine();

    const result = await client.recall.actions({ topic: "auth" });

    expect(result.recall_query).toBe(
      "what actions, decisions, or commitments about auth",
    );
    expect(result.envelope.body).toBe(
      "The auth flow uses refresh-token rotation.",
    );
    expect(result.envelope.sources).toEqual(["optimal://ws1/wiki/auth-flow"]);
    expect(result.org_policy.count).toBe(1);
  });

  it("should return the same shape from who, when, where and owns", async () => {
    const client = new OptimalEngine();
    const calls = [
      () => client.recall.who({ topic: "deploys" }),
      () => client.recall.when({ event: "launch" }),
      () => client.recall.where({ thing: "runbook" }),
      () => client.recall.owns({ actor: "alice" }),
    ];

    for (const run of calls) {
      mockFetch(RECALL_BODY);
      const result = await run();
      expect(result.recall_query).toContain("auth");
      expect(result.envelope.body.length).toBeGreaterThan(0);
    }
  });

  it("should not declare an items array", () => {
    expectTypeOf<RecallResult>().not.toHaveProperty("items");
    expectTypeOf<RecallResult["recall_query"]>().toEqualTypeOf<string>();
    expectTypeOf<RecallResult["envelope"]>().toEqualTypeOf<
      AskResult["envelope"]
    >();
  });
});

// ---------------------------------------------------------------------------
// adapters
// ---------------------------------------------------------------------------

describe("ai-sdk adapter", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("should accept the rag bandwidths and reject the profile ones for askEngine", () => {
    const tools = optimalEngineTools(new OptimalEngine());
    const schema = tools.askEngine.inputSchema as unknown as z.ZodType;

    expect(
      schema.safeParse({ query: "q", bandwidth: "small" }).success,
    ).toBe(true);
    expect(
      schema.safeParse({ query: "q", bandwidth: "large" }).success,
    ).toBe(true);
    expect(schema.safeParse({ query: "q", bandwidth: "l1" }).success).toBe(
      false,
    );
    expect(
      schema.safeParse({ query: "q", format: "openai" }).success,
    ).toBe(true);
  });

  it("should keep the profile bandwidths for getProfile", () => {
    const tools = optimalEngineTools(new OptimalEngine());
    const schema = tools.getProfile.inputSchema as unknown as z.ZodType;

    expect(schema.safeParse({ bandwidth: "l0" }).success).toBe(true);
    expect(schema.safeParse({ bandwidth: "small" }).success).toBe(false);
  });

  it("should forward bandwidth small and return the envelope from askEngine", async () => {
    mockFetch(RAG_BODY);
    const tools = optimalEngineTools(new OptimalEngine(), { workspace: "ws1" });

    const result = (await tools.askEngine.execute?.(
      { query: "q", bandwidth: "small", format: "plain" },
      TOOL_CTX,
    )) as AskResult;

    const { body } = lastCall();
    expect(body?.["bandwidth"]).toBe("small");
    expect(body?.["format"]).toBe("plain");
    expect(body?.["workspace"]).toBe("ws1");
    expect(result.envelope.body).toBe(
      "The auth flow uses refresh-token rotation.",
    );
    expect(result.envelope.sources).toEqual(["optimal://ws1/wiki/auth-flow"]);
  });

  it("should forward offset and type from searchMemory and return inherited hits", async () => {
    mockFetch(SEARCH_BODY);
    const tools = optimalEngineTools(new OptimalEngine());

    const result = (await tools.searchMemory.execute?.(
      { query: "retention", limit: 10, offset: 20, type: "memory" },
      TOOL_CTX,
    )) as SearchResult;

    const { url } = lastCall();
    expect(url.searchParams.get("offset")).toBe("20");
    expect(url.searchParams.get("type")).toBe("memory");
    expect(result.results[1]?.inherited).toBe(true);
    expect(result.results[1]?.source_workspace_id).toBe("org-root");
  });

  it("should forward offset and path from grepMemory and return slug and snippet", async () => {
    mockFetch(GREP_BODY);
    const tools = optimalEngineTools(new OptimalEngine());

    const result = (await tools.grepMemory.execute?.(
      { query: "renewal", scale: "paragraph", offset: 5, path: "accounts/" },
      TOOL_CTX,
    )) as GrepResult;

    const { url } = lastCall();
    expect(url.searchParams.get("scale")).toBe("paragraph");
    expect(url.searchParams.get("offset")).toBe("5");
    expect(url.searchParams.get("path")).toBe("accounts/");
    expect(result.results[0]?.slug).toBe("accounts/acme-renewal");
    expect(result.results[0]?.snippet).toContain("renew Acme");
  });

  it("should reject a grep scale outside the four Engine scales", () => {
    const tools = optimalEngineTools(new OptimalEngine());
    const schema = tools.grepMemory.inputSchema as unknown as z.ZodType;

    expect(schema.safeParse({ query: "q", scale: "chunk" }).success).toBe(true);
    expect(schema.safeParse({ query: "q", scale: "micro" }).success).toBe(
      false,
    );
  });

  it("should return recall_query and envelope from recallActions", async () => {
    mockFetch(RECALL_BODY);
    const tools = optimalEngineTools(new OptimalEngine());

    const result = (await tools.recallActions.execute?.(
      { topic: "auth" },
      TOOL_CTX,
    )) as RecallResult;

    expect(result.recall_query).toContain("auth");
    expect(result.envelope.body).toContain("refresh-token");
  });
});

describe("openai-agents adapter", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  function find(name: string) {
    const tool = optimalEngineAgentTools(new OptimalEngine(), {
      workspace: "ws1",
    }).find((t) => t.name === name);
    if (tool === undefined) throw new Error(`tool ${name} missing`);
    return tool;
  }

  it("should accept the rag bandwidths and reject the profile ones for ask_engine", () => {
    const { parameters } = find("ask_engine");

    expect(
      parameters.safeParse({ query: "q", bandwidth: "medium" }).success,
    ).toBe(true);
    expect(parameters.safeParse({ query: "q", bandwidth: "full" }).success).toBe(
      false,
    );
  });

  it("should keep the profile bandwidths for get_profile", () => {
    const { parameters } = find("get_profile");

    expect(parameters.safeParse({ bandwidth: "full" }).success).toBe(true);
    expect(parameters.safeParse({ bandwidth: "large" }).success).toBe(false);
  });

  it("should forward bandwidth small and return the envelope from ask_engine", async () => {
    mockFetch(RAG_BODY);

    const result = (await find("ask_engine").execute({
      query: "q",
      bandwidth: "small",
    })) as AskResult;

    const { body } = lastCall();
    expect(body?.["bandwidth"]).toBe("small");
    expect(result.envelope.body).toContain("refresh-token");
    expect(result.envelope.sources).toHaveLength(1);
  });

  it("should forward offset and type from search_memory", async () => {
    mockFetch(SEARCH_BODY);

    await find("search_memory").execute({
      query: "retention",
      offset: 10,
      type: "memory",
    });

    const { url } = lastCall();
    expect(url.searchParams.get("offset")).toBe("10");
    expect(url.searchParams.get("type")).toBe("memory");
  });

  it("should forward offset and path from grep_memory and return slug and snippet", async () => {
    mockFetch(GREP_BODY);

    const result = (await find("grep_memory").execute({
      query: "renewal",
      offset: 5,
      path: "accounts/",
    })) as GrepResult;

    const { url } = lastCall();
    expect(url.searchParams.get("offset")).toBe("5");
    expect(url.searchParams.get("path")).toBe("accounts/");
    expect(result.results[0]?.slug).toBe("accounts/acme-renewal");
  });
});
