# claude-skills

A curated collector of [Claude](https://claude.com/claude-code) skills worth
installing almost everywhere — a mix of open-source skills from the community
and my own.

Each skill is vendored as a **git submodule** pinned to a known commit, so the
set is reproducible. A single file, [`skills.yaml`](skills.yaml), is the source
of truth. You edit it; CI keeps the submodules under [`skills/`](skills/) in
sync.

## How it works

```
 edit skills.yaml ──▶ open PR ──▶ verify (CI) ──▶ merge
                                                    │
                                                    ▼
                                  update (CI) ──▶ auto-merge PR with
                                                  the new submodule pointers
```

- **`skills.yaml`** lists the skills you want, by SSH URL and either a branch or
  a pinned commit.
- **`make verify`** validates the file and confirms every referenced ref exists
  on its remote. It runs on every PR.
- **`make update`** reconciles the submodules in `skills/` to match the file
  (add / move / prune) and commits the result. It runs automatically after a
  merge, on a daily schedule, and on demand.

## Adding or changing a skill

1. Edit `skills.yaml`:

   ```yaml
   skills:
     - name: superpowers                        # → skills/superpowers
       url: git@github.com:obra/superpowers.git
       branch: main                             # track a branch ...

     - name: pinned-skill
       url: git@github.com:someone/skill.git
       commit: 3f9a1c2e4b5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f   # ... or pin a commit
   ```

   Each entry needs a unique `name`, an SSH `url`, and **exactly one** of
   `branch` or `commit`.

2. Open a pull request. The **verify** check confirms the file is valid and
   every ref is reachable.

3. Merge it. The **update** workflow opens a follow-up PR with the updated
   submodule pointers, which auto-merges once verify passes again.

To **remove** a skill, delete its entry — `update` prunes the orphaned submodule
automatically.

## Make targets

| Command | What it does |
| --- | --- |
| `make verify` | Validate `skills.yaml`; check each branch/commit exists; print the actions `update` would take. Read-only. |
| `make update` | Add/move/prune submodules to match the file, then commit. |
| `make help` | List targets. |

Requirements for running locally: `git`, [`yq`](https://github.com/mikefarah/yq)
(v4, mikefarah), and `make`. With your own SSH keys, the SSH URLs work directly.

## SSH URLs, HTTPS in CI

`skills.yaml` and `.gitmodules` store **SSH** URLs (`git@github.com:owner/repo.git`).
In CI there are no SSH keys, so the workflows rewrite SSH to HTTPS on the fly:

```sh
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

This means **public** skill repos need no secrets at all. Private skill repos are
out of scope (they would require a deploy key).

## One-time setup

The **update** workflow opens its PR with a token so that the `verify` check runs
on that PR and auto-merge can complete. GitHub does not trigger workflows for PRs
opened with the default `GITHUB_TOKEN`, so a real token is required:

1. Create a **fine-grained PAT** (or GitHub App token) with `contents: write`
   and `pull-requests: write` on this repo. (Classic PAT equivalent: `repo` +
   `workflow`.)
2. Add it as the repository secret **`SKILLS_BOT_TOKEN`**.
3. In **Settings → General**, enable **Allow auto-merge**.
4. Protect `main` with the `verify` status check required (recommended).

## Using the collected skills

Point your Claude skills/plugins setup at the `skills/` directory (each
subdirectory is the upstream skill repo at its pinned commit). Clone with
submodules:

```sh
git clone --recurse-submodules git@github.com:<you>/claude-skills.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Repository layout

```
skills.yaml                 source of truth — you edit this
Makefile                    make verify / make update
scripts/
  lib.sh                    shared bash helpers
  verify.sh                 validation + ref-existence + drift report
  update.sh                 reconcile submodules, prune, commit
skills/                     submodules live here (one per entry)
.github/workflows/
  verify.yml                runs on PRs
  update.yml                runs after merge, daily, and on demand
docs/superpowers/specs/     design docs
```
