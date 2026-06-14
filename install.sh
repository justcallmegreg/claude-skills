#!/usr/bin/env bash
# Install the skills collected in this repository onto the local machine.
#
#   ./install.sh [--dir <target>] [--help]
#
# - syncs the git submodules under skills/
# - discovers skills (SKILL.md) inside them
# - shows a plan: NEW / UPGRADE / UP-TO-DATE / SKIP
# - checks write permissions first (fails before any change)
# - copies only after you type `approve`
# - never removes a skill

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

# ---- colors (disabled when not a TTY) ----
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Install collected Claude skills onto this machine.

Usage: ./install.sh [--dir <target>] [--help]

  --dir <target>   Where to install skills (default: ~/.claude/skills,
                   or \$CLAUDE_SKILLS_DIR if set).
  --help           Show this help.

Skills are copied, never symlinked. Existing skills are upgraded in place;
nothing is ever removed. Targets that are symlinks (e.g. dev working copies)
are skipped, not overwritten.
EOF
}

# ---- args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; TARGET_DIR="$2"; shift 2 ;;
    --dir=*) TARGET_DIR="${1#--dir=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }
require git
require rsync

cd "$REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository ($REPO_DIR)"

# ---- 1. sync submodules ----
printf '%s==>%s Syncing submodules…\n' "$C_BLUE" "$C_RESET"
git submodule sync --recursive >/dev/null 2>&1 || true
git submodule update --init --recursive || die "failed to update submodules"

# ---- 2. discover skills ----
# Populate parallel arrays: names[i] -> install name, srcs[i] -> source dir.
names=(); srcs=()
declare -A name_seen=()

add_skill() {
  local name="$1" src="$2"
  if [ -n "${name_seen[$name]:-}" ]; then
    printf '  %s!%s %s: duplicate name (also in %s) — %sSKIP%s\n' \
      "$C_YELLOW" "$C_RESET" "$name" "${name_seen[$name]}" "$C_YELLOW" "$C_RESET" >&2
    return
  fi
  name_seen[$name]="$src"
  names+=("$name"); srcs+=("$src")
}

discover_in_submodule() {
  local sub="$1" base; base="$(basename "$sub")"
  if [ -f "$sub/SKILL.md" ]; then
    add_skill "$base" "$sub"
    return
  fi
  # Collect every SKILL.md, shallowest first, and keep only topmost (non-nested).
  local -a roots=()
  while IFS= read -r dir; do
    local nested=0 r
    for r in "${roots[@]:-}"; do
      [ -n "$r" ] || continue
      case "$dir/" in "$r/"*) nested=1; break ;; esac
    done
    [ "$nested" -eq 0 ] && roots+=("$dir")
  done < <(
    find "$sub" -name SKILL.md -not -path '*/.git/*' -print 2>/dev/null \
      | while IFS= read -r f; do d="$(dirname "$f")"; printf '%s\t%s\n' "$(awk -F/ '{print NF}' <<<"$d")" "$d"; done \
      | sort -n -k1,1 | cut -f2-
  )
  local d
  for d in "${roots[@]:-}"; do
    [ -n "$d" ] && add_skill "$(basename "$d")" "$d"
  done
}

# Submodule paths under skills/ (fall back to scanning skills/* dirs).
mapfile -t submods < <(
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | grep '^skills/' || true
)
if [ "${#submods[@]}" -eq 0 ]; then
  while IFS= read -r d; do submods+=("$d"); done < <(find skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi
[ "${#submods[@]}" -gt 0 ] || die "no submodules found under skills/ — is skills.yaml populated?"

for sub in "${submods[@]}"; do
  [ -d "$sub" ] || continue
  discover_in_submodule "$sub"
done
[ "${#names[@]}" -gt 0 ] || { printf '%sNo skills found to install.%s\n' "$C_DIM" "$C_RESET"; exit 0; }

# ---- 3. build the plan ----
# status[i]: NEW | UPGRADE | UPTODATE | SYMLINK ; detail[i]: counts/notes
status=(); detail=()
changed_targets=()   # NEW/UPGRADE target paths that will be written

for i in "${!names[@]}"; do
  name="${names[$i]}"; src="${srcs[$i]}"; dst="$TARGET_DIR/$name"
  if [ -L "$dst" ]; then
    status[$i]="SYMLINK"; detail[$i]="→ $(readlink "$dst")"
  elif [ ! -e "$dst" ]; then
    status[$i]="NEW"; detail[$i]=""; changed_targets+=("$dst")
  else
    # itemized dry-run, excluding .git; '>' marks a transfer (add or change)
    out="$(rsync -ain --exclude='.git' "$src/" "$dst/" 2>/dev/null || true)"
    added=$(grep -c '^>f+' <<<"$out" || true)
    changed=$(grep -E '^>f' <<<"$out" | grep -vc '^>f+' || true)
    if [ "$((added + changed))" -eq 0 ]; then
      status[$i]="UPTODATE"; detail[$i]=""
    else
      status[$i]="UPGRADE"; detail[$i]="+${added} added, ~${changed} changed"
      changed_targets+=("$dst")
    fi
  fi
done

# ---- 4. permission preflight (fails first) ----
writable_dir() { [ -w "$1" ]; }
nearest_existing() { local p="$1"; while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done; printf '%s' "$p"; }

perm_error() {
  local path="$1"
  printf '\n%s✗ Cannot write to %s%s\n' "$C_RED" "$path" "$C_RESET" >&2
  printf '  Fix: %schmod u+w "%s"%s   (or take ownership: %ssudo chown -R "$(whoami)" "%s"%s)\n' \
    "$C_BOLD" "$path" "$C_RESET" "$C_BOLD" "$path" "$C_RESET" >&2
  printf '  Or install elsewhere: %s./install.sh --dir /some/writable/dir%s\n' "$C_BOLD" "$C_RESET" >&2
  exit 1
}

if [ "${#changed_targets[@]}" -gt 0 ]; then
  base_check="$(nearest_existing "$TARGET_DIR")"
  writable_dir "$base_check" || perm_error "$base_check"
  for dst in "${changed_targets[@]}"; do
    if [ -e "$dst" ]; then
      writable_dir "$dst" || perm_error "$dst"
    else
      parent="$(nearest_existing "$dst")"
      writable_dir "$parent" || perm_error "$parent"
    fi
  done
fi

# ---- 5. show the plan ----
n_new=0; n_up=0; n_ok=0; n_skip=0
printf '\n%sInstall plan%s  (target: %s%s%s)\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$TARGET_DIR" "$C_RESET"
for i in "${!names[@]}"; do
  name="${names[$i]}"; d="${detail[$i]}"
  case "${status[$i]}" in
    NEW)      printf '  %s+ NEW%s        %s\n' "$C_GREEN" "$C_RESET" "$name"; n_new=$((n_new+1)) ;;
    UPGRADE)  printf '  %s^ UPGRADE%s    %s %s(%s)%s\n' "$C_BLUE" "$C_RESET" "$name" "$C_DIM" "$d" "$C_RESET"; n_up=$((n_up+1)) ;;
    UPTODATE) printf '  %s= UP-TO-DATE%s %s\n' "$C_DIM" "$C_RESET" "$name"; n_ok=$((n_ok+1)) ;;
    SYMLINK)  printf '  %s~ SKIP%s       %s %s(dev symlink %s)%s\n' "$C_YELLOW" "$C_RESET" "$name" "$C_DIM" "$d" "$C_RESET"; n_skip=$((n_skip+1)) ;;
  esac
done
printf '\n%s%d new · %d upgrade · %d up-to-date · %d skipped%s\n' \
  "$C_BOLD" "$n_new" "$n_up" "$n_ok" "$n_skip" "$C_RESET"

if [ "${#changed_targets[@]}" -eq 0 ]; then
  printf '\n%sNothing to install — everything is up to date.%s\n' "$C_GREEN" "$C_RESET"
  exit 0
fi

# ---- 6. approval gate ----
printf '\nType %sapprove%s to install the %d change(s), anything else to cancel: ' "$C_BOLD" "$C_RESET" "${#changed_targets[@]}"
read -r reply || true
reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [ "$reply" != "approve" ]; then
  printf '%sAborted — no changes made.%s\n' "$C_YELLOW" "$C_RESET"
  exit 0
fi

# ---- 7. install ----
printf '\n%s==>%s Installing…\n' "$C_BLUE" "$C_RESET"
for i in "${!names[@]}"; do
  case "${status[$i]}" in NEW|UPGRADE) ;; *) continue ;; esac
  name="${names[$i]}"; src="${srcs[$i]}"; dst="$TARGET_DIR/$name"
  mkdir -p "$dst"
  rsync -a --exclude='.git' "$src/" "$dst/"
  printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$name"
done
printf '\n%sDone.%s Installed/updated %d skill(s) into %s\n' "$C_GREEN" "$C_RESET" "${#changed_targets[@]}" "$TARGET_DIR"
