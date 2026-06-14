#!/usr/bin/env bash
# Validate skills.yaml and confirm every referenced branch/commit exists.
# Read-only: never touches submodules. Reports drift but does not fail on it.
#
# Exit non-zero only on invalid schema or a missing/unreachable ref.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools git yq

[ -f "$SKILLS_FILE" ] || die "skills.yaml not found at $SKILLS_FILE"

count="$(skills_count)"
info "Verifying $count skill(s) in $(basename "$SKILLS_FILE")"

errors=0
declare -A seen_names=()
# desired_sha[name]=sha  — captured here so update/drift can reuse it.
declare -A desired_sha=()
declare -A desired_present=()

name_re='^[A-Za-z0-9._-]+$'
url_re='^git@[A-Za-z0-9._-]+:[A-Za-z0-9._/-]+(\.git)?$'
sha_re='^[0-9a-fA-F]{40}$'

for ((i = 0; i < count; i++)); do
  name="$(skill_field "$i" name)"
  url="$(skill_field "$i" url)"
  branch="$(skill_field "$i" branch)"
  commit="$(skill_field "$i" commit)"

  label="entry #$i"
  [ -n "$name" ] && label="$name"
  printf '\n%s%s%s\n' "$C_DIM" "• $label" "$C_RESET"

  # --- name ---
  if [ -z "$name" ]; then
    fail "missing 'name'"; errors=$((errors + 1)); continue
  elif ! [[ "$name" =~ $name_re ]]; then
    fail "invalid name '$name' (allowed: letters, digits, . _ -)"; errors=$((errors + 1))
  elif [ -n "${seen_names[$name]:-}" ]; then
    fail "duplicate name '$name'"; errors=$((errors + 1))
  else
    seen_names[$name]=1; ok "name '$name'"
  fi

  # --- url ---
  if [ -z "$url" ]; then
    fail "missing 'url'"; errors=$((errors + 1))
  elif ! [[ "$url" =~ $url_re ]]; then
    fail "url '$url' is not an SSH URL (git@host:owner/repo.git)"; errors=$((errors + 1))
  else
    ok "url"
  fi

  # --- exactly one of branch/commit ---
  if [ -n "$branch" ] && [ -n "$commit" ]; then
    fail "set only one of 'branch' / 'commit'"; errors=$((errors + 1)); continue
  elif [ -z "$branch" ] && [ -z "$commit" ]; then
    fail "set one of 'branch' / 'commit'"; errors=$((errors + 1)); continue
  fi

  # --- ref existence (needs a valid url) ---
  [[ "$url" =~ $url_re ]] || continue

  if [ -n "$branch" ]; then
    sha="$(remote_branch_sha "$url" "$branch")"
    if [ -z "$sha" ]; then
      fail "branch '$branch' not found on remote"; errors=$((errors + 1)); continue
    fi
    ok "branch '$branch' → ${sha:0:12}"
  else
    if ! [[ "$commit" =~ $sha_re ]]; then
      fail "commit '$commit' is not a 40-char sha"; errors=$((errors + 1)); continue
    fi
    if ! remote_commit_exists "$url" "$commit"; then
      fail "commit ${commit:0:12} not reachable on remote"; errors=$((errors + 1)); continue
    fi
    sha="$commit"
    ok "commit ${sha:0:12}"
  fi

  desired_sha[$name]="$sha"
  desired_present[$name]=1
done

# --- drift report (informational) ---
printf '\n%sPlanned actions (run `make update` to apply):%s\n' "$C_DIM" "$C_RESET"
drift=0
for name in "${!desired_present[@]}"; do
  path="$(skill_path "$name")"
  want="${desired_sha[$name]}"
  if [ -f "$ROOT_DIR/$path/.git" ] || [ -d "$ROOT_DIR/$path/.git" ]; then
    have="$(git -C "$ROOT_DIR/$path" rev-parse HEAD 2>/dev/null || echo '')"
    if [ "$have" = "$want" ]; then
      ok "$name up to date (${want:0:12})"
    else
      warn "$name update ${have:0:12} → ${want:0:12}"; drift=$((drift + 1))
    fi
  else
    warn "$name add (${want:0:12})"; drift=$((drift + 1))
  fi
done
# orphaned submodules (present but no longer in the YAML) → would be pruned
while IFS= read -r path; do
  [ -z "$path" ] && continue
  pname="${path#skills/}"
  if [ -z "${desired_present[$pname]:-}" ]; then
    warn "$pname prune (removed from skills.yaml)"; drift=$((drift + 1))
  fi
done < <(registered_submodule_paths)
[ "$drift" -eq 0 ] && info "  (nothing to do — submodules match skills.yaml)"

echo
if [ "$errors" -gt 0 ]; then
  die "$errors validation error(s)"
fi
ok "skills.yaml is valid"
