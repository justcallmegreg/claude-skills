# install.sh — Design

## Purpose

A standalone `install.sh` at the repo root that installs the skills collected in
this repository onto the local machine. It syncs the git submodules, discovers
the skills inside them, shows the user a clear plan (new / upgrade / up-to-date /
skip), validates write permissions up front, and only copies after the user
types `approve`. It never removes a skill.

This script *consumes* the submodules; the Makefile and CI *manage* them. The two
are independent.

## Flow

1. **Sync submodules** — `git submodule update --init --recursive`. Must run from
   the repo root (the script `cd`s there based on its own location).
2. **Discover skills** (auto SKILL.md):
   - If a submodule has `SKILL.md` at its root → one skill, named after the
     submodule directory (e.g. `class-builder`).
   - Otherwise → every `SKILL.md` inside it marks a skill, named by its containing
     directory (e.g. superpowers → `brainstorming`, `systematic-debugging`, …).
   - **Topmost SKILL.md wins:** a `SKILL.md` nested inside an already-claimed
     skill directory (e.g. under `references/`) is ignored, so no bogus skills.
   - **Name collisions** across repos → the later one is `SKIP (duplicate)` with a
     warning; first wins.
3. **Build the plan** — for each discovered skill, compare its source dir against
   `<target>/<name>`:
   - **NEW** — target missing.
   - **UPGRADE** — target exists and differs; counts `+N added, ~M changed` from
     an `rsync -ain` dry-run (excluding `.git`).
   - **UP-TO-DATE** — identical; skipped.
   - **SKIP (dev symlink)** — target is a symlink; never touched.
4. **Permission preflight (fails first)** — before the approval prompt and before
   any write: verify the target base dir is writable or creatable, and every
   NEW/UPGRADE target path is writable. On failure, print the offending path, a
   remediation tip, and exit non-zero.
5. **Show the plan** — colored, grouped, with a summary line
   (`3 new · 2 upgrade · 10 up-to-date · 1 skipped`).
6. **Approval gate** — proceed only if the user types exactly `approve`
   (case-insensitive, trimmed). Anything else aborts with zero changes.
7. **Install** — `rsync -a --exclude=.git "$src/" "$dst/"`. No `--delete`; only
   skills found in the repo are ever written. Upgrades overlay; unrelated local
   skills are untouched.

## Interface

```
./install.sh [--dir <target>] [--help]
```

- `--dir <target>` — install destination (default `~/.claude/skills`).
- `--help` — usage.

No `--yes`/non-interactive flag: the `approve` prompt is always required.

## Requirements

Checked up front; missing tool → clear error and exit:
- `git` (submodule sync)
- `rsync` (diff counts + copy)

## Error handling

- Not inside a git work tree / submodule sync fails → error, exit.
- No skills discovered → report and exit 0 (nothing to do).
- Permission failure → path + tip + non-zero exit, before any change.
- Non-`approve` input → "aborted", exit 0, no changes.

Permission tip shown, e.g.:

```
✗ Cannot write to /Users/greg/.claude/skills/foo
  Fix: chmod u+w "<path>"   (or take ownership: sudo chown -R "$(whoami)" "<path>")
  Or install elsewhere:     ./install.sh --dir /some/writable/dir
```

## Non-goals

- Removing or pruning skills (install only adds/overlays).
- Replacing dev symlinks (always skipped + warned).
- Symlink-based install (copy only, per request).
- Plugin/marketplace registration (plain skill-dir copy into the target).
