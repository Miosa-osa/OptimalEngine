/**
 * Runtime configuration. The same sources as the `optimal` client CLI:
 *
 *   OPTIMAL_PROFILE      profile name (~/.config/optimal/profiles/<name>) or path
 *   OPTIMAL_ENGINE_URL   Engine URL (then OE_API, OPTIMAL_ENGINE_API_URL)
 *   OPTIMAL_ENGINE_API_KEY  bearer key (then OPTIMAL_ENGINE_API_KEY_FILE, OPTIMAL_API_KEY)
 *   OPTIMAL_WORKSPACE    default workspace
 *   ~/.config/optimal/profile  url=, key= or key_file=, workspace= when nothing else is set
 *
 * A profile's key is only ever sent to that profile's own url.
 * All tools import from here rather than touching process.env directly.
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_ENGINE_URL = "http://127.0.0.1:4200";

export interface EngineConfig {
  /** Base URL of the Optimal Engine HTTP API, without a trailing slash. */
  engineUrl: string;
  urlSource: string;
  /** Bearer key, or null for an Engine in trusted local mode. Never logged. */
  apiKey: string | null;
  keySource: string | null;
  /** Workspace used when a tool call names none. */
  defaultWorkspace: string;
}

interface Profile {
  path: string;
  url?: string;
  key?: string;
  /**
   * A file holding the key. loadConfig reads it once, at start, and only when the
   * profile's key is the one used.
   */
  keyFile?: string;
  workspace?: string;
}

const PROFILE_FIELDS: Record<string, keyof Omit<Profile, "path">> = {
  url: "url",
  OPTIMAL_ENGINE_URL: "url",
  key: "key",
  OPTIMAL_ENGINE_API_KEY: "key",
  key_file: "keyFile",
  OPTIMAL_ENGINE_API_KEY_FILE: "keyFile",
  workspace: "workspace",
  OPTIMAL_WORKSPACE: "workspace",
};

export function parseProfile(path: string, text: string): Profile {
  const profile: Profile = { path };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#") || !line.includes("=")) continue;
    const at = line.indexOf("=");
    const field = PROFILE_FIELDS[line.slice(0, at).trim()];
    let value = line.slice(at + 1).trim();
    if (/^(".*"|'.*')$/.test(value)) value = value.slice(1, -1);
    if (field && value !== "") profile[field] = value;
  }
  return profile;
}

function readProfile(path: string): Profile {
  return parseProfile(path, readFileSync(path, "utf8"));
}

const trimSlash = (url: string): string => url.replace(/\/+$/, "");

const firstLine = (path: string): string =>
  (readFileSync(path, "utf8").split(/\r?\n/)[0] ?? "").trim();

export function loadConfig(env: NodeJS.ProcessEnv = process.env): EngineConfig {
  const configHome =
    env["XDG_CONFIG_HOME"] ?? join(env["HOME"] ?? "", ".config");
  const named = env["OPTIMAL_PROFILE"];
  let explicit: Profile | null = null;
  let fallback: Profile | null = null;

  if (named) {
    const path = named.includes("/")
      ? named
      : join(configHome, "optimal", "profiles", named);
    if (!existsSync(path)) throw new Error(`profile not found: ${path}`);
    explicit = readProfile(path);
  } else {
    const path = join(configHome, "optimal", "profile");
    if (existsSync(path)) fallback = readProfile(path);
  }
  const profile = explicit ?? fallback;

  const urlCandidates: Array<[string | undefined, string]> = [
    [explicit?.url, `profile ${explicit?.path}`],
    [env["OPTIMAL_ENGINE_URL"], "OPTIMAL_ENGINE_URL"],
    [env["OE_API"], "OE_API"],
    [env["OPTIMAL_ENGINE_API_URL"], "OPTIMAL_ENGINE_API_URL"],
    [fallback?.url, `profile ${fallback?.path}`],
  ];
  const [url, urlSource] = urlCandidates.find(([value]) => value) ?? [
    DEFAULT_ENGINE_URL,
    "default",
  ];
  const engineUrl = trimSlash(url as string);
  if (!/^https?:\/\/./.test(engineUrl)) {
    throw new Error(`Engine URL must start with http:// or https:// (from ${urlSource})`);
  }

  // A profile's key, inline or from its key_file, only for the profile's own URL.
  const profileKeyApplies = Boolean(profile?.url && trimSlash(profile.url) === engineUrl);
  const profileKey = (): string | undefined => {
    if (!profileKeyApplies) return undefined;
    if (profile?.key) return profile.key;
    return profile?.keyFile ? firstLine(profile.keyFile) : undefined;
  };
  const keyFile = env["OPTIMAL_ENGINE_API_KEY_FILE"];
  const keyCandidates: Array<[() => string | undefined, string]> = [
    [() => (explicit ? profileKey() : undefined), `profile ${profile?.path}`],
    [() => env["OPTIMAL_ENGINE_API_KEY"], "OPTIMAL_ENGINE_API_KEY"],
    [() => (keyFile ? firstLine(keyFile) : undefined), "OPTIMAL_ENGINE_API_KEY_FILE"],
    [() => env["OPTIMAL_API_KEY"], "OPTIMAL_API_KEY"],
    [() => (fallback ? profileKey() : undefined), `profile ${profile?.path}`],
  ];
  let apiKey: string | null = null;
  let keySource: string | null = null;
  for (const [read, source] of keyCandidates) {
    const value = read()?.trim();
    if (value) {
      apiKey = value;
      keySource = source;
      break;
    }
  }
  if (apiKey && /[\r\n]/.test(apiKey)) {
    throw new Error(`the API key from ${keySource} contains a line break`);
  }

  const defaultWorkspace =
    explicit?.workspace ??
    env["OPTIMAL_WORKSPACE"] ??
    fallback?.workspace ??
    "default";

  return { engineUrl, urlSource, apiKey, keySource, defaultWorkspace };
}

export const config: EngineConfig = loadConfig();

/** The URL with any user:password@ part hidden, safe to log. */
export function maskUrl(url: string): string {
  return url.replace(/^([a-z]+:\/\/)[^/@]*@/i, "$1[redacted]@");
}

/** Replaces every occurrence of the configured key with [redacted]. */
export function redact(text: string, key: string | null = config.apiKey): string {
  return key ? text.split(key).join("[redacted]") : text;
}
