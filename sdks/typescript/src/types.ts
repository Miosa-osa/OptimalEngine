// ---------------------------------------------------------------------------
// Branded primitives
// ---------------------------------------------------------------------------

export type MemoryId = string & { readonly __brand: "MemoryId" };
export type WorkspaceId = string & { readonly __brand: "WorkspaceId" };
export type SubscriptionId = string & { readonly __brand: "SubscriptionId" };
export type WikiSlug = string & { readonly __brand: "WikiSlug" };

export function asMemoryId(v: string): MemoryId {
  return v as MemoryId;
}
export function asWorkspaceId(v: string): WorkspaceId {
  return v as WorkspaceId;
}
export function asSubscriptionId(v: string): SubscriptionId {
  return v as SubscriptionId;
}
export function asWikiSlug(v: string): WikiSlug {
  return v as WikiSlug;
}

// ---------------------------------------------------------------------------
// Shared enums / literals
// ---------------------------------------------------------------------------

/**
 * Bandwidth of `GET /api/profile`: l0 headline, l1 summary, full all tiers.
 * `ask` uses a different set, see {@link RagBandwidth}.
 */
export type Bandwidth = "l0" | "l1" | "full";
/** Bandwidth of `POST /api/rag`: how much context the envelope may carry. */
export type RagBandwidth = "small" | "medium" | "large";
/** Envelope format of `POST /api/rag`. */
export type RagFormat = "plain" | "markdown" | "claude" | "openai";
export type Audience = string; // workspace-defined; e.g. "public" | "internal"
export type RecallScope = "workspace" | "topic" | "actor" | "global";
export type SubscriptionCategory = string;

// ---------------------------------------------------------------------------
// Client config
// ---------------------------------------------------------------------------

export interface OptimalEngineConfig {
  /** Base URL of the Optimal Engine HTTP API. Defaults to http://localhost:4200 */
  baseUrl?: string;
  /** Optional API key - sent as Bearer token when provided. */
  apiKey?: string;
  /** Default workspace applied to every call unless overridden per-call. */
  workspace?: string;
}

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

export interface OptimalEngineErrorBody {
  error?: string;
  message?: string;
  code?: string;
}

// ---------------------------------------------------------------------------
// Pagination (search, grep)
// ---------------------------------------------------------------------------

export interface Pagination {
  offset: number;
  limit: number;
  total: number;
  has_more: boolean;
}

// ---------------------------------------------------------------------------
// RAG / retrieval (POST /api/rag, GET /api/recall/*)
// ---------------------------------------------------------------------------

export interface AskOptions {
  workspace?: string;
  audience?: Audience;
  format?: RagFormat;
  bandwidth?: RagBandwidth;
}

/** Where the answer context came from. */
export type RagSource =
  | "wiki"
  | "chunks"
  | "memory"
  | "empty"
  | "context_package";

/** The receiver-shaped context an agent reads. `body` is the text to use. */
export interface RagEnvelope {
  body: string;
  format: RagFormat;
  /** `optimal://` URIs of the contexts the body was built from. */
  sources: string[];
  warnings: unknown[];
}

/** Retrieval trace. The `?` in two key names is part of the wire format. */
export interface RagTrace {
  intent: Record<string, unknown>;
  "wiki_hit?": boolean;
  n_candidates: number;
  n_delivered: number;
  "truncated?": boolean;
  elapsed_ms: number;
}

/** A durable org policy memory inherited from the tenant's org section. */
export interface OrgPolicyMemory {
  id: string;
  uri: string;
  content: string;
  version: number;
  audience: Audience;
  citation_uri: string | null;
  metadata: Record<string, unknown> | null;
  created_at: string;
  updated_at: string;
  /** Workspace the policy was authored in. */
  source_workspace_id: string;
  inherited: boolean;
}

export interface OrgPolicyBlock {
  org_workspace_id: string | null;
  inherited: boolean;
  count: number;
  memories: OrgPolicyMemory[];
  /** Policies the caller's audience may not see. */
  withheld: number;
  withheld_reason: string | null;
}

export interface AskResult {
  source: RagSource;
  envelope: RagEnvelope;
  trace: RagTrace;
  org_policy: OrgPolicyBlock;
  /** Present when `source` is `"context_package"`. */
  context_package?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Search (GET /api/search)
// ---------------------------------------------------------------------------

export interface SearchOptions {
  workspace?: string;
  limit?: number;
  offset?: number;
  /** `"memory"` restricts results to durable memories. */
  type?: "memory";
}

export interface SearchResult {
  query: string;
  results: SearchHit[];
  pagination: Pagination;
}

export interface SearchHit {
  id: string;
  title: string | null;
  node: string | null;
  genre: string | null;
  uri: string | null;
  content: string | null;
  l0_abstract: string | null;
  sn_ratio: number | null;
  score: number | null;
  workspace_id: string | null;
  metadata: Record<string, unknown> | null;
  /** True for an org policy memory inherited from the tenant's org section. */
  inherited: boolean;
  /** Workspace the hit came from. Equals the hit's own workspace unless inherited. */
  source_workspace_id: string | null;
}

// ---------------------------------------------------------------------------
// Grep (GET /api/grep)
// ---------------------------------------------------------------------------

export type GrepScale = "document" | "section" | "paragraph" | "chunk";

export interface GrepOptions {
  workspace?: string;
  /**
   * One of the Engine's canonical intents: request_info, propose_decision,
   * record_fact, express_concern, commit_action, reference, narrate, reflect,
   * specify, measure. Other values are ignored by the Engine.
   */
  intent?: string;
  scale?: GrepScale;
  modality?: string;
  limit?: number;
  offset?: number;
  literal?: boolean;
  /** Restrict to a node slug or slug prefix. */
  path?: string;
}

export interface GrepResult {
  query: string;
  workspace_id: string;
  results: GrepHit[];
  pagination: Pagination;
}

/** One matching chunk, with the signal trace of the chunk. */
export interface GrepHit {
  /** Slug of the node the chunk belongs to. */
  slug: string;
  scale: GrepScale;
  intent: string | null;
  sn_ratio: number | null;
  modality: string | null;
  snippet: string;
  score: number;
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

export interface ProfileOptions {
  workspace?: string;
  audience?: Audience;
  bandwidth?: Bandwidth;
  node?: string;
}

export interface ProfileResult {
  static?: Record<string, unknown>;
  dynamic?: Record<string, unknown>;
  curated?: Record<string, unknown>;
  activity?: Record<string, unknown>;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Recall
// ---------------------------------------------------------------------------

export interface RecallActionsOptions {
  topic: string;
  actor?: string;
  since?: string;
  workspace?: string;
}

export interface RecallWhoOptions {
  topic: string;
  role?: string;
  workspace?: string;
}

export interface RecallWhenOptions {
  event: string;
  workspace?: string;
}

export interface RecallWhereOptions {
  thing: string;
  workspace?: string;
}

export interface RecallOwnsOptions {
  actor: string;
  workspace?: string;
}

/** Same object as {@link AskResult}, plus the question the Engine asked. */
export interface RecallResult extends AskResult {
  recall_query: string;
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

export interface CreateMemoryInput {
  content: string;
  workspace?: string;
  isStatic?: boolean;
  audience?: Audience;
  citationUri?: string;
  metadata?: Record<string, unknown>;
}

export interface ListMemoriesOptions {
  workspace?: string;
  audience?: Audience;
  includeForgotten?: boolean;
  limit?: number;
}

export interface ForgetMemoryInput {
  reason?: string;
  forgetAfter?: string;
}

export interface UpdateMemoryInput {
  content: string;
  [key: string]: unknown;
}

export interface ExtendMemoryInput {
  content: string;
  [key: string]: unknown;
}

export interface DeriveMemoryInput {
  content: string;
  [key: string]: unknown;
}

export interface Memory {
  id: MemoryId;
  content: string;
  workspace?: string;
  is_static?: boolean;
  audience?: Audience;
  citation_uri?: string;
  metadata?: Record<string, unknown>;
  forgotten_at?: string;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

export interface MemoryVersion {
  id: string;
  memory_id: MemoryId;
  content: string;
  inserted_at: string;
  [key: string]: unknown;
}

export interface MemoryRelation {
  id: string;
  source_id: MemoryId;
  target_id: MemoryId;
  type: string;
  [key: string]: unknown;
}

export interface MemoryListResult {
  memories: Memory[];
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Workspaces
// ---------------------------------------------------------------------------

export interface ListWorkspacesOptions {
  tenant?: string;
}

export interface CreateWorkspaceInput {
  slug: string;
  name: string;
  description?: string;
  tenant?: string;
}

export interface Workspace {
  id: WorkspaceId;
  slug: string;
  name: string;
  description?: string;
  tenant?: string;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

export interface WorkspaceConfig {
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Wiki
// ---------------------------------------------------------------------------

export interface ListWikiOptions {
  workspace?: string;
}

export interface GetWikiOptions {
  workspace?: string;
  audience?: Audience;
  format?: string;
}

export interface WikiArticle {
  slug: WikiSlug;
  title?: string;
  content?: string;
  audience?: Audience;
  [key: string]: unknown;
}

export interface WikiContradiction {
  id: string;
  memory_ids: MemoryId[];
  description?: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Subscriptions / surface
// ---------------------------------------------------------------------------

export interface ListSubscriptionsOptions {
  workspace?: string;
}

export interface CreateSubscriptionInput {
  workspace: string;
  scope: RecallScope;
  scopeValue?: string;
  categories?: SubscriptionCategory[];
}

export interface Subscription {
  id: SubscriptionId;
  workspace: string;
  scope: RecallScope;
  scope_value?: string;
  categories?: SubscriptionCategory[];
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Status / architectures
// ---------------------------------------------------------------------------

export interface StatusResult {
  status: "ok" | "degraded" | "down";
  version?: string;
  [key: string]: unknown;
}

export interface ArchitectureEntry {
  id: string;
  name: string;
  description?: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Render pipeline
// ---------------------------------------------------------------------------

export interface RenderSpec {
  name: string;
  title: string;
  audience: string;
  genre: string;
  bandwidth: string;
  constraints: Record<string, string>;
  html_hints: Record<string, unknown>;
  modalities: string[];
}

export interface RenderContextOptions {
  workspace?: string;
}

export interface RenderContextResult {
  spec: RenderSpec;
  context: {
    body: string;
    format: string;
    sources: string[];
    warnings: string[];
  };
  prompt_guidance: string;
  trace: Record<string, unknown>;
}

export interface ListRenderSpecsOptions {
  workspace?: string;
}

export interface RenderSpecsResult {
  specs: RenderSpec[];
}
