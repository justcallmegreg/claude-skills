#!/usr/bin/env bash
# Shared helpers for the skills collector scripts.
# Source this file; it does not run anything on its own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_FILE="${SKILLS_FILE:-$ROOT_DIR/skills.yaml}"

# Colors (disabled when not a TTY).
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_RESET=''
fi

ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
info()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is required but not installed"
  done
}

# Number of entries in skills.yaml (0 when key is absent/null/empty).
skills_count() {
  local n
  n="$(yq '.skills | length' "$SKILLS_FILE" 2>/dev/null || echo 0)"
  [ "$n" = "null" ] && n=0
  echo "$n"
}

# Read .skills[$1].$2, returning "" for missing/null.
skill_field() {
  yq ".skills[$1].$2 // \"\"" "$SKILLS_FILE"
}

# Resolve the path a named entry maps to.
skill_path() { echo "skills/$1"; }

# Paths currently registered as submodules under skills/ (from .gitmodules).
registered_submodule_paths() {
  [ -f "$ROOT_DIR/.gitmodules" ] || return 0
  git -C "$ROOT_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | grep '^skills/' || true
}

# Latest commit sha for a branch on a remote (empty if missing).
remote_branch_sha() {
  local url=$1 branch=$2
  git ls-remote --heads "$url" "$branch" 2>/dev/null | awk 'NR==1 {print $1}'
}

# True if an arbitrary commit exists on a remote (fetch-by-sha; works on GitHub).
remote_commit_exists() {
  local url=$1 sha=$2 tmp
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  local rc=0
  git -C "$tmp" fetch -q --depth 1 "$url" "$sha" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  return $rc
}
