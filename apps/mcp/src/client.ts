/**
 * Thin HTTP wrapper around the Optimal Engine REST API.
 * All tools use these helpers — nothing calls fetch directly.
 *
 * The key from config goes out as `Authorization: Bearer` and is redacted
 * from every error message. Identity comes from the key: no request names
 * an actor.
 */

import { config, maskUrl, redact } from "./config.js";
import { MCP_VERSION, upgradeHint, versionLower } from "./version.js";

type HttpMethod = "GET" | "POST";

interface RequestOptions {
  method?: HttpMethod;
  params?: Record<string, string | number | boolean | undefined>;
  body?: unknown;
}

export class EngineError extends Error {
  constructor(
    public readonly status: number,
    message: string,
    /** The Engine's error code, for example "permission_scope_denied". */
    public readonly code: string | null = null,
  ) {
    super(redact(message));
    this.name = "EngineError";
  }
}

/** A message an agent can act on, for an Engine refusal or failure. */
export function describeEngineError(err: EngineError): string {
  const code = err.code ? `: ${err.code}` : "";
  switch (err.status) {
    case 0:
      return err.message;
    case 401:
      return config.apiKey
        ? `Engine rejected the key from ${config.keySource} (HTTP 401${code})`
        : `Engine requires an API key (HTTP 401${code}); set OPTIMAL_ENGINE_API_KEY for the MCP server`;
    case 403:
      return `Engine denied the request (HTTP 403${code})${
        err.code === "workspace_scope_denied"
          ? "; the key is not scoped to that workspace"
          : err.code === "permission_scope_denied"
            ? "; the key lacks the scope for this operation"
            : ""
      }`;
    case 426:
      return `${err.message} (HTTP 426${code})`;
    case 400:
      if (err.code === "workspace_required") {
        return "Engine needs a workspace (HTTP 400: workspace_required); pass workspace or set OPTIMAL_WORKSPACE";
      }
      return `Engine rejected the request (HTTP 400${code})`;
    default:
      return `Engine error ${err.status}${code || `: ${err.message}`}`;
  }
}

function buildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
    "User-Agent": `optimal-mcp/${MCP_VERSION}`,
  };
  if (config.apiKey) {
    headers["Authorization"] = `Bearer ${config.apiKey}`;
  }
  return headers;
}

function buildUrl(
  path: string,
  params?: Record<string, string | number | boolean | undefined>,
): string {
  const url = new URL(`${config.engineUrl}${path}`);
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }
  return url.toString();
}

// The Engine releases this process has warned about ("unreadable" for a header without one).
const warnedFor = new Set<string>();

/**
 * One stderr line per Engine release when the Engine marks this server as
 * another minor release (`x-optimal-client-outdated: client=<v> engine=<v>`),
 * so an Engine upgraded while the server runs is reported again. The request
 * still succeeds; the warning only says to upgrade.
 */
function warnOutdated(header: string): void {
  const engineVersion = /engine=(\d+\.\d+\.\d+)/.exec(header)?.[1] ?? null;
  const key = engineVersion ?? "unreadable";
  if (warnedFor.has(key)) return;
  warnedFor.add(key);
  const detail = !engineVersion
    ? // The header is the Engine's text; an unreadable one is not echoed.
      `the Engine marks MCP server ${MCP_VERSION} as outdated; ${upgradeHint(null)}`
    : versionLower(MCP_VERSION, engineVersion)
      ? `MCP server ${MCP_VERSION} is outdated for Engine ${engineVersion}; ${upgradeHint(engineVersion)}`
      : `MCP server ${MCP_VERSION} is newer than Engine ${engineVersion}; tools the Engine does not have yet will fail`;
  console.error(`[optimal-engine-mcp] warning: ${redact(detail)}`);
}

async function request<T>(
  path: string,
  options: RequestOptions = {},
): Promise<T> {
  const { method = "GET", params, body } = options;
  const url = buildUrl(path, params);

  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: buildHeaders(),
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new EngineError(
      0,
      `cannot reach the Engine at ${maskUrl(config.engineUrl)}: ${reason}`,
    );
  }

  const outdated = response.headers.get("x-optimal-client-outdated");
  if (outdated) warnOutdated(outdated);

  if (!response.ok) {
    let message: string = response.statusText;
    let code: string | null = null;
    let engineVersion: string | null = null;
    try {
      const err = (await response.json()) as {
        error?: unknown;
        message?: unknown;
        engine?: unknown;
      };
      if (typeof err.error === "string") code = err.error;
      if (typeof err.engine === "string") engineVersion = err.engine;
      const text = err.error ?? err.message;
      if (typeof text === "string") message = text;
    } catch {
      // Non-JSON error body; keep the status text.
    }
    if (response.status === 426) {
      // Another major release: every tool fails the same way until the server
      // is replaced, so the message says which one to install.
      message = `the Engine${engineVersion ? ` (${engineVersion})` : ""} refuses MCP server ${MCP_VERSION}; ${upgradeHint(engineVersion)}`;
    }
    throw new EngineError(response.status, message, code);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

// ---------------------------------------------------------------------------
// Typed API surface
// ---------------------------------------------------------------------------

export type JsonObject = Record<string, unknown>;

export interface RagResponse {
  source: string;
  envelope: unknown;
  trace: unknown;
}

export interface SearchResult {
  query: string;
  results: unknown[];
}

export interface GrepResult {
  query: string;
  workspace_id: string;
  results: unknown[];
}

export interface ProfileResponse {
  [key: string]: unknown;
}

export interface MemoryResponse {
  [key: string]: unknown;
}

export interface WikiPage {
  [key: string]: unknown;
}

export interface Workspace {
  [key: string]: unknown;
}

export interface WorkspaceList {
  workspaces?: Workspace[];
  [key: string]: unknown;
}

export interface RecallResponse {
  [key: string]: unknown;
}

export interface RenderContextResponse {
  spec: {
    name: string;
    title: string;
    audience: string;
    genre: string;
    bandwidth: string;
    constraints: Record<string, string>;
    html_hints: Record<string, unknown>;
    modalities: string[];
  };
  context: {
    body: string;
    format: string;
    sources: string[];
    warnings: string[];
  };
  prompt_guidance: string;
  trace: unknown;
}

export interface RenderSpecsResponse {
  specs: Array<{
    name: string;
    title: string;
    audience: string;
    genre: string;
    bandwidth: string;
    constraints: Record<string, string>;
    html_hints: Record<string, unknown>;
    modalities: string[];
  }>;
}

// ---------------------------------------------------------------------------
// API calls — one function per engine endpoint
// ---------------------------------------------------------------------------

export const engine = {
  ask(body: {
    query: string;
    workspace: string;
    audience?: string;
  }): Promise<RagResponse> {
    return request<RagResponse>("/api/rag", { method: "POST", body });
  },

  search(params: {
    q: string;
    workspace: string;
    limit?: number;
  }): Promise<SearchResult> {
    return request<SearchResult>("/api/search", { params });
  },

  grep(params: {
    q: string;
    workspace: string;
    intent?: string;
    scale?: string;
  }): Promise<GrepResult> {
    return request<GrepResult>("/api/grep", { params });
  },

  profile(params: {
    workspace: string;
    audience?: string;
    bandwidth?: string;
  }): Promise<ProfileResponse> {
    return request<ProfileResponse>("/api/profile", { params });
  },

  addMemory(body: {
    content: string;
    workspace: string;
    is_static?: boolean;
    audience?: string;
    citation_uri?: string;
    source_chunk_id?: string;
  }): Promise<MemoryResponse> {
    return request<MemoryResponse>("/api/memory", { method: "POST", body });
  },

  forgetMemory(
    id: string,
    body: { workspace: string; reason?: string; forget_after?: string },
  ): Promise<void> {
    return request<void>(`/api/memory/${encodeURIComponent(id)}/forget`, {
      method: "POST",
      body,
    });
  },

  recall(
    action: "actions" | "who" | "when" | "where" | "owns",
    params: {
      topic?: string;
      workspace: string;
      event?: string;
      thing?: string;
      actor?: string;
    },
  ): Promise<RecallResponse> {
    return request<RecallResponse>(`/api/recall/${action}`, { params });
  },

  wikiGet(
    slug: string,
    params: { workspace: string; audience?: string },
  ): Promise<WikiPage> {
    return request<WikiPage>(`/api/wiki/${encodeURIComponent(slug)}`, {
      params,
    });
  },

  workspaces(params?: { tenant?: string }): Promise<WorkspaceList> {
    return request<WorkspaceList>("/api/workspaces", { params });
  },

  renderContext(body: {
    source: string;
    spec: string;
    workspace: string;
  }): Promise<RenderContextResponse> {
    return request<RenderContextResponse>("/api/render/context", {
      method: "POST",
      body,
    });
  },

  renderSpecs(params: { workspace: string }): Promise<RenderSpecsResponse> {
    return request<RenderSpecsResponse>("/api/render/specs", { params });
  },

  // -- operating layer -------------------------------------------------------

  boot(params: { workspace: string; timezone?: string }): Promise<JsonObject> {
    return request<JsonObject>("/api/boot", { params });
  },

  brief(params: {
    workspace?: string;
    workspaces?: string;
    limit?: number;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/brief", { params });
  },

  protocol(params: { workspace: string }): Promise<JsonObject> {
    return request<JsonObject>("/api/protocol", { params });
  },

  listLoops(params: {
    workspace?: string;
    workspaces?: string;
    state?: string;
    owner?: string;
    kind?: string;
    due_before?: string;
    limit?: number;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/loops", { params });
  },

  addLoop(body: {
    workspace: string;
    title: string;
    kind?: string;
    owner?: string;
    counterparty?: string;
    due_at?: string;
    source_uri?: string;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/loops", { method: "POST", body });
  },

  transitionLoop(
    id: string,
    action: "close" | "drop" | "reopen",
    body: { workspace: string; reason?: string; source_uri?: string },
  ): Promise<JsonObject> {
    return request<JsonObject>(
      `/api/loops/${encodeURIComponent(id)}/${action}`,
      { method: "POST", body },
    );
  },

  // -- context ---------------------------------------------------------------

  assemble(body: {
    query: string;
    workspace: string;
    limit?: number;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/assemble", { method: "POST", body });
  },

  read(params: {
    uri?: string;
    id?: string;
    workspace: string;
    tier?: string;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/read", { params });
  },

  capture(body: {
    text: string;
    workspace: string;
    genre?: string;
    title?: string;
    node?: string;
    extract_claims: boolean;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/ingest", { method: "POST", body });
  },

  remember(body: {
    content: string;
    workspace: string;
    force: boolean;
    metadata?: Record<string, string>;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/memory/remember", {
      method: "POST",
      body,
    });
  },

  // -- chat sessions and org policy -------------------------------------------

  commitSession(body: {
    workspace: string;
    correlation_id: string;
    messages: Array<{ role: string; content: string; at?: string }>;
    title?: string;
    summary?: string;
    source?: string;
    learned?: Array<{
      content: string;
      category?: string;
      owner?: string;
      due?: string;
    }>;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/sessions/commit", {
      method: "POST",
      body,
    });
  },

  listSessions(params: {
    workspace: string;
    correlation_id?: string;
    limit?: number;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/sessions", { params });
  },

  getSession(
    id: string,
    params: { workspace: string; include?: string },
  ): Promise<JsonObject> {
    return request<JsonObject>(`/api/sessions/${encodeURIComponent(id)}`, {
      params,
    });
  },

  orgPolicy(params: { workspace: string }): Promise<JsonObject> {
    return request<JsonObject>("/api/org-policy", { params });
  },

  // -- authority -------------------------------------------------------------

  authorityDecide(body: {
    workspace_id: string;
    action: string;
    resource: string;
    data_class?: string;
    subject?: string;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/authority/decide", {
      method: "POST",
      body,
    });
  },

  authorityEffective(params: {
    workspace_id: string;
    subject?: string;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/authority/effective", { params });
  },

  // -- signal quality, viability, agent action chains -------------------------

  checkDraft(body: {
    workspace: string;
    draft: string;
    receiver: { channel?: string; bandwidth?: string };
    genre?: string;
    type?: string;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/signals/check", { method: "POST", body });
  },

  viability(params: { workspace?: string; workspaces?: string }): Promise<JsonObject> {
    return request<JsonObject>("/api/viability", { params });
  },

  recordActionStep(body: {
    workspace: string;
    stage: string;
    correlation_id?: string;
    action?: string;
    resource?: string;
    summary?: string;
    detail?: JsonObject;
  }): Promise<JsonObject> {
    return request<JsonObject>("/api/agent-actions", { method: "POST", body });
  },

  actionChain(id: string, params: { workspace: string }): Promise<JsonObject> {
    return request<JsonObject>(`/api/agent-actions/${encodeURIComponent(id)}`, { params });
  },
};
