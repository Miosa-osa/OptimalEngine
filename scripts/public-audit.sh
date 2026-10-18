#!/usr/bin/env bash
set -euo pipefail

fail=0

say() {
  printf '%s\n' "$*"
}

check_tracked_paths() {
  local matches
  matches="$(git ls-files | rg '(^|/)node_modules/|(^|/)\.env(\.|$)|\.(db|sqlite|sqlite3)$|(^|/)tmp/|(^|/)\.optimal/' || true)"

  if [[ -n "$matches" ]]; then
    say "Tracked generated/private runtime paths found:"
    say "$matches"
    fail=1
  fi
}

check_private_workspace_paths() {
  local matches
  matches="$(git ls-files | rg '(^|/)nodes/|(^|/)\.system/|(^|/)packages/|(^|/)rhythm/' | rg -v '^sample-workspace/nodes/' || true)"

  if [[ -n "$matches" ]]; then
    say "Tracked private workspace paths found:"
    say "$matches"
    fail=1
  fi
}

check_sidecars() {
  local matches
  matches="$(git ls-files | rg '\.(abstract|overview)\.md$|(^|/)\.DS_Store$' || true)"

  if [[ -n "$matches" ]]; then
    say "Tracked generated sidecars found:"
    say "$matches"
    fail=1
  fi
}

check_secret_shapes() {
  local matches
  matches="$(
    git grep -nE \
      '(sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
      -- . ':(exclude)deps/**' ':(exclude)_build/**' ':(exclude)**/node_modules/**' || true
  )"

  if [[ -n "$matches" ]]; then
    say "Possible secret material found:"
    say "$matches"
    fail=1
  fi
}

# Private names (people, clients, companies, internal workspaces) are never
# listed in this public script. They live in a private terms file outside the
# repo: one extended regex per line, "#" comments allowed, matched without
# case. Attribution files (copyright and code owners) are exempt.
check_private_terms() {
  local terms_file="${OPTIMAL_PRIVATE_TERMS:-$HOME/.config/optimal-engine/private-terms.txt}"

  if [[ ! -f "$terms_file" ]]; then
    say "Private terms check skipped: no terms file at $terms_file (set OPTIMAL_PRIVATE_TERMS)."
    return
  fi

  # \< and \> mark word edges. PCRE (\b) is fast and used when git supports
  # it; otherwise they become portable POSIX classes for git grep -E.
  local terms grep_mode pattern
  terms="$(grep -vE '^[[:space:]]*(#|$)' "$terms_file" || true)"

  if git grep -qP 'x' -- scripts/public-audit.sh 2>/dev/null; then
    grep_mode=-P
    pattern="$(printf '%s\n' "$terms" | sed -e 's/\\</\\b/g' -e 's/\\>/\\b/g' | paste -sd '|' -)"
  else
    grep_mode=-E
    pattern="$(
      printf '%s\n' "$terms" |
        sed -e 's/\\</(^|[^[:alnum:]_])/g' -e 's/\\>/($|[^[:alnum:]_])/g' |
        paste -sd '|' -
    )"
  fi

  if [[ -z "$pattern" ]]; then
    return
  fi

  local matches
  matches="$(
    git grep -ni "$grep_mode" "($pattern)" \
      -- . ':(exclude)NOTICE' ':(exclude)LICENSE' ':(exclude).github/CODEOWNERS' \
      ':(exclude)deps/**' ':(exclude)_build/**' ':(exclude)**/node_modules/**' || true
  )"

  if [[ -n "$matches" ]]; then
    say "Private names still present:"
    say "$matches"
    fail=1
  fi
}

check_tracked_paths
check_private_workspace_paths
check_sidecars
check_secret_shapes
check_private_terms

if [[ "$fail" -eq 0 ]]; then
  say "Public audit passed."
else
  say "Public audit failed."
fi

exit "$fail"
