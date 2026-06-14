# Claude Skills Collector — Design

## Purpose

A curated "collector" repository for Claude skills the owner wants installed in
almost all cases — a mix of open-source skills from others and the owner's own.
Skills are vendored as **git submodules** so each stays pinned to a known
commit. A single YAML file is the source of truth; a `verify`/`update` Makefile
and GitHub Actions reconcile the submodules to match it.

## Workflow (the happy path)

1. A user edits `skills.yaml` (adds/removes/repins an entry) and opens a PR.
2. `verify.yml` runs on the PR: validates the YAML and confirms every referenced
   branch/commit exists on its remote. This is a required check.
3. On merge to `main`, `update.yml` runs `make update`, which reconciles the
   submodules and, if anything changed, opens an **auto-merge PR** with the
   updated submodule pointers.
4. A daily cron also runs `update` to bump branch-tracked skills to their latest
   upstream tip, opening an auto-merge PR when something moved.

## Repo layout

```
.
├── skills.yaml                    # source of truth — humans edit this
├── Makefile                       # `make verify`, `make update`
├── scripts/
│   ├── verify.sh                  # validation + ref-existence + drift report
│   └── update.sh                  # reconcile submodules, prune, commit
├── skills/                        # submodules land here, one per entry
│   └── <name>/
├── .github/workflows/
│   ├── verify.yml                 # runs on PRs
│   └── update.yml                 # push-to-main(skills.yaml) + daily cron + manual
├── .gitmodules                    # managed by update
└── README.md
```

The Makefile is a thin entrypoint; real logic lives in `scripts/*.sh` (bash)
so it is readable and testable. Dependencies: `git`, `yq` (mikefarah), `gh` —
all present on GitHub runners.

## `skills.yaml` schema

```yaml
skills:
  - name: superpowers                          # required, unique → skills/superpowers
    url: git@github.com:obra/superpowers.git    # SSH URL
    branch: main                                # EITHER branch ...
  - name: some-pinned-skill
    url: git@github.com:someone/skill.git
    commit: 3f9a1c2e4b5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f   # ... OR commit (exactly one)
```

Rules:
- `name` — required, unique, becomes the path `skills/<name>`.
- `url` — required, SSH form (`git@github.com:owner/repo.git`).
- Exactly one of `branch:` / `commit:` per entry. No sha-vs-branch guessing.

## URL handling: SSH in YAML, HTTPS in CI

`.gitmodules` records the SSH URL (as authored). CI configures:

```
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

so clones/fetches go over HTTPS — **public submodules need no secrets**. Local
developers with SSH keys use SSH transparently.

## `make verify`

Read-only. For each entry:
1. **Schema validation** — `name` present/unique, `url` SSH form, exactly one of
   `branch`/`commit`.
2. **Ref existence** — branch via `git ls-remote --heads <url> <branch>`; commit
   via a shallow `git fetch <url> <sha>` (GitHub permits fetch-by-sha). No full
   clone.
3. **Drift report (informational)** — what `update` would create/update/prune.

Exit non-zero **only** on invalid schema or a missing/unreachable ref. Drift is
not a failure — a PR that edits the YAML is expected to show drift.

## `make update`

Runs `verify` first, then reconciles `skills/` to the YAML:
- **Add** missing entries (`git submodule add`, then checkout the branch tip or
  pinned commit).
- **Update** existing entries to the desired commit (branch → latest tip at run
  time; commit → that exact sha).
- **Prune** submodules absent from the YAML (`git submodule deinit -f`,
  `git rm -f`, clean `.git/modules/<name>`).
- **Commit** `.gitmodules` + `skills/*` as `chore: update skills submodules`
  with a body listing the changes. Idempotent — no changes means no commit.

## Workflows

### `verify.yml`
- Trigger: `pull_request` touching `skills.yaml`, `Makefile`, or `scripts/**`.
- Steps: checkout, install `yq`, configure `insteadOf` HTTPS rewrite, `make verify`.
- This is the required status check for auto-merge.

### `update.yml`
- Triggers:
  - `push` to `main` **filtered to `skills.yaml`** (fires when a YAML-changing PR
    merges).
  - `schedule:` daily cron (bumps branch-tracked skills).
  - `workflow_dispatch` (manual button).
- `concurrency` group to prevent overlapping runs.
- Steps: checkout with submodules + bot token, set git bot identity, configure
  `insteadOf`, install `yq`, `make update`. If a commit was produced, open an
  auto-merge PR via `peter-evans/create-pull-request`.

### Loop avoidance
The push trigger is filtered to `skills.yaml`. The bot's update PR only changes
`skills/*` + `.gitmodules` (never `skills.yaml`), so merging it does **not**
retrigger `update`. Upstream drift on branch entries is handled by the cron.

## Required secret: `SKILLS_BOT_TOKEN`

GitHub deliberately does not fire workflows on PRs opened with the default
`GITHUB_TOKEN`. Without a real token, `verify` would never run on the bot's PR
and auto-merge would hang. A PAT (or GitHub App token) with `repo` + `workflow`
scope, stored as `SKILLS_BOT_TOKEN`, is used by `create-pull-request` so the
bot's PR triggers checks and can auto-merge. No SSH key is needed (public repos
clone over HTTPS).

## README contents

- What the repo is (curated collector of must-have Claude skills).
- How to add a skill: edit `skills.yaml` → open PR.
- The verify/update lifecycle and what each Make target does.
- `SKILLS_BOT_TOKEN` setup and the one branch-protection assumption.
- How to consume the collected skills.

## Out of scope (YAGNI)

- Private skill repositories (would need an SSH deploy key in CI).
- Non-GitHub remotes.
- Tag-pinned entries (only branch or commit for now).
