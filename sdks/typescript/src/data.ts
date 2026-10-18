import { OptimalEngineError } from "./error.js";
import { HttpClient } from "./http.js";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

export type FieldType =
  | "string"
  | "text"
  | "integer"
  | "float"
  | "boolean"
  | "datetime"
  | "json"
  | "reference";

export interface FieldDefinition {
  readonly name: string;
  readonly type: FieldType;
  readonly required?: boolean;
  readonly unique?: boolean;
  readonly index?: boolean;
  readonly default?: unknown;
  readonly max_length?: number;
  readonly enum?: readonly string[];
  readonly references?: string;
  readonly on_delete?: "restrict" | "set_null" | "cascade";
}

export interface IndexDefinition {
  readonly fields: readonly string[];
  readonly unique?: boolean;
  readonly name?: string;
}

export interface CollectionDefinition {
  readonly name: string;
  readonly fields: readonly FieldDefinition[];
  readonly indexes?: readonly IndexDefinition[];
  readonly owner_field?: string;
  readonly search?: {
    readonly text?: readonly string[];
    readonly semantic?: readonly string[];
  };
}

/** The JSON value type of one field type. */
export type FieldValue<T extends FieldType> = T extends
  | "string"
  | "text"
  | "datetime"
  | "reference"
  ? string
  : T extends "integer" | "float"
    ? number
    : T extends "boolean"
      ? boolean
      : unknown;

/**
 * The record data type of a collection definition declared `as const`:
 * required fields are non-null, every other field may be null.
 *
 *     const tasks = defineCollection({ name: "tasks", fields: [...] } as const);
 *     type Task = RecordOf<typeof tasks>;
 */
export type RecordOf<D extends CollectionDefinition> = {
  [F in D["fields"][number] as F["name"]]: F extends { readonly required: true }
    ? FieldValue<F["type"]>
    : FieldValue<F["type"]> | null;
};

/** Identity helper that keeps a definition's literal types for `RecordOf`. */
export function defineCollection<const D extends CollectionDefinition>(
  definition: D,
): D {
  return definition;
}

export interface Collection {
  id: string;
  name: string;
  workspace: string;
  schema_version: number;
  fields: FieldDefinition[];
  indexes: IndexDefinition[];
  owner_field: string | null;
  search: { text: string[]; semantic: string[] };
  created_by: string | null;
  created_at: string;
  updated_at: string;
  record_count?: number;
}

export type AlterOperation =
  | { op: "add_field"; field: FieldDefinition }
  | { op: "drop_field"; name: string; confirm: true }
  | { op: "set_default"; name: string; default: unknown }
  | { op: "set_required"; name: string; required: boolean }
  | { op: "add_index"; fields: string[]; unique?: boolean; name?: string }
  | { op: "drop_index"; name: string }
  | { op: "set_search"; text?: string[]; semantic?: string[] }
  | { op: "set_owner_field"; name: string | null; confirm?: true };

// ---------------------------------------------------------------------------
// Records and queries
// ---------------------------------------------------------------------------

export type Data = Record<string, unknown>;

export interface DataRecord<T = Data> {
  id: string;
  version: number;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
  data: T;
  included?: Record<string, DataRecord | null>;
  score?: number;
  seq?: number;
}

export type Scalar = string | number | boolean;

export interface FieldOperators {
  eq?: Scalar | null;
  ne?: Scalar | null;
  gt?: Scalar;
  gte?: Scalar;
  lt?: Scalar;
  lte?: Scalar;
  in?: Scalar[];
  nin?: Scalar[];
  contains?: Scalar;
  is_null?: boolean;
}

export type FieldCondition = Scalar | null | FieldOperators;

export interface Where {
  and?: Where[];
  or?: Where[];
  not?: Where;
  [field: string]: FieldCondition | Where | Where[] | undefined;
}

export type SortKey = string | { field: string; dir?: "asc" | "desc" };

export interface QuerySpec {
  where?: Where;
  sort?: SortKey[];
  limit?: number;
  cursor?: string;
  fields?: string[];
  count?: boolean;
  include?: string[];
  search?: string | { text: string; match?: "all" | "any"; prefix?: boolean };
  semantic?: string | { text: string; min_score?: number };
}

export interface QueryResult<T = Data> {
  records: DataRecord<T>[];
  next_cursor: string | null;
  has_more: boolean;
  count?: number;
  model?: string;
}

export type Operation =
  | { op: "create"; collection: string; id?: string; data: Data }
  | { op: "update"; collection: string; id: string; data: Data; version?: number }
  | { op: "delete"; collection: string; id: string; version?: number }
  | {
      op: "upsert";
      collection: string;
      key: string | string[];
      data: Data;
      id?: string;
      version?: number;
    };

export interface TransactionResult {
  committed: true;
  results: (DataRecord & { op: string })[];
  txn_id: string;
  last_seq: number;
}

export interface Change {
  seq: number;
  collection: string;
  record_id: string | null;
  op: "create" | "update" | "delete" | "schema" | "drop";
  version: number | null;
  owner: string | null;
  actor: string | null;
  data: DataRecord | Record<string, unknown> | null;
  txn_id: string | null;
  at: string;
}

export interface ChangesPage {
  changes: Change[];
  next_since: number;
  latest_seq: number;
}

export interface DataFile {
  id: string;
  record_id: string;
  filename: string;
  content_type: string;
  size_bytes: number;
  content_hash: string;
  metadata: Record<string, unknown>;
  created_by: string | null;
  created_at: string;
}

export interface Migration {
  version: number;
  name?: string;
  operations: (
    | { op: "create_collection"; collection: CollectionDefinition }
    | { op: "alter_collection"; name: string; operations: AlterOperation[] }
    | { op: "drop_collection"; name: string; confirm: string }
  )[];
}

export interface DataKeyOptions {
  name: string;
  owner?: string;
  collections?: string[];
  operations?: ("read" | "create" | "update" | "delete")[];
  expires_in?: number;
}

export interface DataKey {
  id: string;
  key: string;
  expires_at: string;
  data_access: {
    workspace: string;
    owner: string | null;
    collections: string[];
    operations: string[];
  };
}

/**
 * Raised for every non-2xx app data response. `code` is the server's error
 * code (for example `version_conflict`, `validation_failed`,
 * `owner_mismatch`); `details` is the full error body.
 */
export class DataError extends OptimalEngineError {
  readonly details: Record<string, unknown>;

  constructor(cause: OptimalEngineError) {
    const error = cause.body["error"];
    super(
      cause.status,
      typeof error === "string" ? error : cause.code,
      cause.message,
      cause.body,
    );
    this.name = "DataError";
    this.details = cause.body;
  }
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

/** App data API for one workspace (`/api/data`). */
export class DataClient {
  private readonly http: HttpClient;
  readonly workspace: string;

  constructor(http: HttpClient, workspace: string) {
    this.http = http;
    this.workspace = workspace;
  }

  /** Typed handle to one collection's records. */
  collection<T = Data>(name: string): CollectionClient<T> {
    return new CollectionClient<T>(this, name);
  }

  listCollections(): Promise<Collection[]> {
    return this.get<{ collections: Collection[] }>("/collections").then(
      (r) => r.collections,
    );
  }

  createCollection(definition: CollectionDefinition): Promise<Collection> {
    return this.send("POST", "/collections", definition);
  }

  describeCollection(name: string): Promise<Collection> {
    return this.get(`/collections/${enc(name)}`);
  }

  alterCollection(name: string, operations: AlterOperation[]): Promise<Collection> {
    return this.send("PATCH", `/collections/${enc(name)}`, { operations });
  }

  dropCollection(name: string): Promise<{ dropped: string }> {
    return this.send("DELETE", `/collections/${enc(name)}`, { confirm: name });
  }

  /** Runs writes that commit or roll back together. */
  transaction(operations: Operation[]): Promise<TransactionResult> {
    return this.send("POST", "/transactions", { operations });
  }

  changes(
    opts: { since?: number | "latest"; collection?: string; limit?: number } = {},
  ): Promise<ChangesPage> {
    return this.get("/changes", {
      since: opts.since,
      collection: opts.collection,
      limit: opts.limit,
    });
  }

  /** Applies an app's ordered migrations; already applied versions are skipped. */
  migrate(
    app: string,
    migrations: Migration[],
  ): Promise<{ applied: number[]; skipped: number[] }> {
    return this.send("POST", "/migrations", { app, migrations });
  }

  migrations(app: string): Promise<{ version: number; name: string; checksum: string }[]> {
    return this.get<{ migrations: { version: number; name: string; checksum: string }[] }>(
      "/migrations",
      { app },
    ).then((r) => r.migrations);
  }

  /** Mints a data key (needs data:admin). The `key` is returned once. */
  mintKey(opts: DataKeyOptions): Promise<DataKey> {
    return this.send("POST", "/keys", opts);
  }

  revokeKey(id: string): Promise<{ revoked: string }> {
    return this.send("DELETE", `/keys/${enc(id)}`, {});
  }

  capabilities(): Promise<Record<string, unknown>> {
    return this.get("/capabilities");
  }

  /** @internal */
  get<T>(path: string, query: Record<string, string | number | boolean | undefined> = {}): Promise<T> {
    const qs = HttpClient.buildQuery({ workspace: this.workspace, ...query });
    return this.wrap(this.http.get<T>(`/api/data${path}${qs}`));
  }

  /** @internal */
  send<T>(method: string, path: string, body: object, headers: Record<string, string> = {}): Promise<T> {
    return this.wrap(
      this.http.request<T>(`/api/data${path}`, {
        method,
        body: { ...body, workspace: this.workspace },
        headers,
      }),
    );
  }

  /** @internal */
  async download(path: string, range?: string): Promise<{ status: number; bytes: Uint8Array; contentRange: string | null }> {
    const qs = HttpClient.buildQuery({ workspace: this.workspace });
    const res = await fetch(`${this.http.baseUrl}/api/data${path}${qs}`, {
      headers: { ...this.http.authHeaders(), ...(range !== undefined ? { Range: range } : {}) },
    });
    if (!res.ok) throw new DataError(await OptimalEngineError.fromResponse(res));
    return {
      status: res.status,
      bytes: new Uint8Array(await res.arrayBuffer()),
      contentRange: res.headers.get("content-range"),
    };
  }

  private async wrap<T>(promise: Promise<T>): Promise<T> {
    try {
      return await promise;
    } catch (err) {
      if (err instanceof OptimalEngineError && !(err instanceof DataError)) {
        throw new DataError(err);
      }
      throw err;
    }
  }
}

export class CollectionClient<T = Data> {
  private readonly client: DataClient;
  readonly name: string;

  constructor(client: DataClient, name: string) {
    this.client = client;
    this.name = name;
  }

  private path(suffix = ""): string {
    return `/collections/${enc(this.name)}${suffix}`;
  }

  create(data: Partial<T>, opts: { id?: string } = {}): Promise<DataRecord<T>> {
    return this.client.send("POST", this.path("/records"), { data, ...opts });
  }

  get(id: string, opts: { fields?: string[]; include?: string[] } = {}): Promise<DataRecord<T>> {
    return this.client.get(this.path(`/records/${enc(id)}`), {
      fields: opts.fields?.join(","),
      include: opts.include?.join(","),
    });
  }

  /** Partial update. With `version`, a stale version is rejected (409 version_conflict). */
  update(id: string, data: Partial<T>, opts: { version?: number } = {}): Promise<DataRecord<T>> {
    return this.client.send("PATCH", this.path(`/records/${enc(id)}`), { data, ...opts });
  }

  delete(id: string, opts: { version?: number } = {}): Promise<{ id: string; version: number; deleted: true }> {
    return this.client.send("DELETE", this.path(`/records/${enc(id)}`), { ...opts });
  }

  /** Creates or updates the record whose `key` (a unique field, field list, or "id") matches. */
  upsert(
    key: string | string[],
    data: Partial<T>,
    opts: { id?: string; version?: number } = {},
  ): Promise<DataRecord<T> & { op: "create" | "update" | "unchanged" }> {
    return this.client.send("POST", this.path("/upsert"), { key, data, ...opts });
  }

  /** Inserts every record or none. */
  bulkCreate(
    records: (Partial<T> | { id?: string; data: Partial<T> })[],
  ): Promise<{ count: number; records: { id: string; version: number }[]; txn_id: string; last_seq: number }> {
    return this.client.send("POST", this.path("/records/bulk"), { records });
  }

  query(spec: QuerySpec = {}): Promise<QueryResult<T>> {
    return this.client.send("POST", this.path("/query"), spec);
  }

  /** Iterates every record matching `spec`, following cursors. */
  async *iterate(spec: QuerySpec = {}): AsyncGenerator<DataRecord<T>> {
    let cursor: string | undefined = spec.cursor;
    for (;;) {
      const page: QueryResult<T> = await this.query(
        cursor !== undefined ? { ...spec, cursor } : spec,
      );
      yield* page.records;
      if (page.next_cursor === null) return;
      cursor = page.next_cursor;
    }
  }

  /** Re-embeds every record's semantic fields now (synchronous). */
  rebuildEmbeddings(): Promise<{
    indexed: number;
    unchanged: number;
    skipped: number;
    failed: number;
    model: string;
  }> {
    return this.client.send("POST", this.path("/embeddings/rebuild"), {});
  }

  uploadFile(
    id: string,
    file: { filename: string; content: Uint8Array | string; contentType?: string; metadata?: Record<string, unknown> },
  ): Promise<DataFile> {
    const bytes = typeof file.content === "string" ? new TextEncoder().encode(file.content) : file.content;
    return this.client.send("POST", this.path(`/records/${enc(id)}/files`), {
      filename: file.filename,
      content_base64: toBase64(bytes),
      ...(file.contentType !== undefined ? { content_type: file.contentType } : {}),
      ...(file.metadata !== undefined ? { metadata: file.metadata } : {}),
    });
  }

  listFiles(id: string): Promise<DataFile[]> {
    return this.client
      .get<{ files: DataFile[] }>(this.path(`/records/${enc(id)}/files`))
      .then((r) => r.files);
  }

  /** Downloads a file; `range` is an HTTP byte range such as `bytes=0-1023`. */
  downloadFile(
    id: string,
    fileId: string,
    opts: { range?: string } = {},
  ): Promise<{ status: number; bytes: Uint8Array; contentRange: string | null }> {
    return this.client.download(this.path(`/records/${enc(id)}/files/${enc(fileId)}`), opts.range);
  }
}

function enc(value: string): string {
  return encodeURIComponent(value);
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}
