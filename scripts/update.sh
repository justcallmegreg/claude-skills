#!/usr/bin/env bash
# Reconcile the submodules under skills/ to match skills.yaml, then commit.
#
# - adds entries that are missing
# - moves existing entries to the desired commit (branch tip or pinned sha)
# - prunes submodules no longer listed in skills.yaml
# - commits .gitmodules + skills/* (idempotent: no changes => no commit)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools git yq
cd "$ROOT_DIR"

# Fail fast on an invalid file or unreachable ref.
bash "$SCRIPT_DIR/verify.sh"

count="$(skills_count)"
printf '\n%sReconciling submodules…%s\n' "$C_DIM" "$C_RESET"

declare -A desired_present=()
declare -a changes=()

# Detach a submodule's working tree onto a specific ref or sha.
checkout_ref() {
  local path=$1 ref=$2
  git -C "$path" fetch -q origin "$ref" 2>/dev/null || git -C "$path" fetch -q origin
  if git -C "$path" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then
    git -C "$path" checkout -q --detach "$ref"
  else
    git -C "$path" checkout -q --detach FETCH_HEAD
  fi
}

for ((i = 0; i < count; i++)); do
  name="$(skill_field "$i" name)"
  url="$(skill_field "$i" url)"
  branch="$(skill_field "$i" branch)"
  commit="$(skill_field "$i" commit)"
  path="$(skill_path "$name")"
  desired_present[$name]=1

  ref="$branch"; [ -z "$ref" ] && ref="$commit"

  added=0
  before="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo '')"
  if [ ! -e "$path/.git" ]; then
    info "  add $name"
    git submodule add --force "$url" "$path" >/dev/null
    added=1
  fi

  # Record (or clear) the tracked branch in .gitmodules.
  if [ -n "$branch" ]; then
    git submodule set-branch --branch "$branch" "$path" >/dev/null 2>&1 || true
  else
    git submodule set-branch --default "$path" >/dev/null 2>&1 || true
  fi

  checkout_ref "$path" "$ref"
  after="$(git -C "$path" rev-parse HEAD)"

  if [ "$added" = 1 ]; then
    git add "$path"
    changes+=("$name: added @ ${after:0:12}")
    ok "$name added @ ${after:0:12}"
  elif [ "$before" != "$after" ]; then
    git add "$path"
    changes+=("$name: ${before:0:12} -> ${after:0:12}")
    ok "$name @ ${after:0:12}"
  else
    info "  $name unchanged (${after:0:12})"
  fi
done
git add .gitmodules 2>/dev/null || true

# --- prune submodules no longer in skills.yaml ---
while IFS= read -r path; do
  [ -z "$path" ] && continue
  pname="${path#skills/}"
  if [ -z "${desired_present[$pname]:-}" ]; then
    info "  prune $pname"
    git submodule deinit -f "$path" >/dev/null 2>&1 || true
    git rm -f "$path" >/dev/null 2>&1 || true
    rm -rf ".git/modules/$path"
    changes+=("$pname: removed")
  fi
done < <(registered_submodule_paths)

# --- commit if anything changed ---
if git diff --cached --quiet; then
  printf '\n'; ok "already up to date — nothing to commit"
  exit 0
fi

body=""
for c in "${changes[@]}"; do body+="- $c"$'\n'; done
git commit -q -m "chore: update skills submodules" -m "$body"
printf '\n'; ok "committed submodule update:"
printf '%s' "$body" | sed 's/^/    /'
