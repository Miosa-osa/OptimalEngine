/**
 * The MCP server's release, which is the Engine release it ships with.
 *
 * It goes to the Engine as `User-Agent: optimal-mcp/<version>`, so the Engine
 * can mark a server of another minor release (`x-optimal-client-outdated`) or
 * refuse one of another major release (426). Keep it equal to `version` in
 * package.json and `@version` in the Engine's mix.exs.
 */

export const MCP_VERSION = "0.3.10";

/** True when release `a` is lower than release `b` (numeric major.minor.patch). */
export function versionLower(a: string, b: string): boolean {
  const parse = (version: string): number[] | null => {
    const match = /^(\d+)\.(\d+)\.(\d+)/.exec(version);
    return match ? match.slice(1, 4).map(Number) : null;
  };
  const left = parse(a);
  const right = parse(b);
  if (!left || !right) return false;
  for (let i = 0; i < 3; i++) {
    if (left[i] !== right[i]) return left[i] < right[i];
  }
  return false;
}

/** What to do about an MCP server that does not match Engine release `engine`. */
export function upgradeHint(engine: string | null): string {
  if (!engine) return "install the MCP server release that matches the Engine";
  return versionLower(MCP_VERSION, engine)
    ? `upgrade the MCP server to ${engine}`
    : `install MCP server ${engine} to match the Engine`;
}
