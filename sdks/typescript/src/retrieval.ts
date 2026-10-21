import { HttpClient } from "./http.js";
import type {
  AskOptions,
  AskResult,
  GrepOptions,
  GrepResult,
  ProfileOptions,
  ProfileResult,
  SearchOptions,
  SearchResult,
} from "./types.js";

/** Serialize an as-of instant: a Date becomes ISO 8601, a string is sent as given. */
function asOfParam(asOf: string | Date | undefined): string | undefined {
  return asOf instanceof Date ? asOf.toISOString() : asOf;
}

export class RetrievalClient {
  constructor(
    private readonly http: HttpClient,
    private readonly defaultWorkspace: string | undefined,
  ) {}

  private ws(override: string | undefined): string | undefined {
    return override ?? this.defaultWorkspace;
  }

  ask(query: string, opts: AskOptions = {}): Promise<AskResult> {
    const workspace = this.ws(opts.workspace);
    const asOf = asOfParam(opts.asOf);
    return this.http.post<AskResult>("/api/rag", {
      query,
      ...(workspace !== undefined ? { workspace } : {}),
      ...(opts.audience !== undefined ? { audience: opts.audience } : {}),
      ...(opts.format !== undefined ? { format: opts.format } : {}),
      ...(opts.bandwidth !== undefined ? { bandwidth: opts.bandwidth } : {}),
      ...(asOf !== undefined ? { as_of: asOf } : {}),
    });
  }

  search(query: string, opts: SearchOptions = {}): Promise<SearchResult> {
    const workspace = this.ws(opts.workspace);
    const asOf = asOfParam(opts.asOf);
    const qs = HttpClient.buildQuery({
      q: query,
      ...(workspace !== undefined ? { workspace } : {}),
      ...(opts.limit !== undefined ? { limit: opts.limit } : {}),
      ...(opts.offset !== undefined ? { offset: opts.offset } : {}),
      ...(opts.type !== undefined ? { type: opts.type } : {}),
      ...(asOf !== undefined ? { as_of: asOf } : {}),
      ...(opts.mode !== undefined ? { mode: opts.mode } : {}),
    });
    return this.http.get<SearchResult>(`/api/search${qs}`);
  }

  grep(query: string, opts: GrepOptions = {}): Promise<GrepResult> {
    const workspace = this.ws(opts.workspace);
    const asOf = asOfParam(opts.asOf);
    const qs = HttpClient.buildQuery({
      q: query,
      ...(workspace !== undefined ? { workspace } : {}),
      ...(opts.intent !== undefined ? { intent: opts.intent } : {}),
      ...(opts.scale !== undefined ? { scale: opts.scale } : {}),
      ...(opts.modality !== undefined ? { modality: opts.modality } : {}),
      ...(opts.limit !== undefined ? { limit: opts.limit } : {}),
      ...(opts.offset !== undefined ? { offset: opts.offset } : {}),
      ...(opts.literal !== undefined ? { literal: opts.literal } : {}),
      ...(opts.path !== undefined ? { path: opts.path } : {}),
      ...(asOf !== undefined ? { as_of: asOf } : {}),
    });
    return this.http.get<GrepResult>(`/api/grep${qs}`);
  }

  profile(opts: ProfileOptions = {}): Promise<ProfileResult> {
    const workspace = this.ws(opts.workspace);
    const qs = HttpClient.buildQuery({
      ...(workspace !== undefined ? { workspace } : {}),
      ...(opts.audience !== undefined ? { audience: opts.audience } : {}),
      ...(opts.bandwidth !== undefined ? { bandwidth: opts.bandwidth } : {}),
      ...(opts.node !== undefined ? { node: opts.node } : {}),
    });
    return this.http.get<ProfileResult>(`/api/profile${qs}`);
  }
}
