---
name: sena-repo-ci
description: Use when committing or pushing changes in Sena Repo and deciding which GitHub Actions checks to track. Covers the required CI signal (Flutter analyze, Server checks), how to look up checks by commit SHA, and the documentation-only exemption where no CI tracking is needed.
---

# Sena Repo CI tracking

## What to track

After pushing a commit, track exactly these two checks for the pushed SHA:

- `Flutter analyze` — required for any `client/` change (Dart code, assets, pubspec)
- `Server checks` — required for any `server/` change (Python)

Look them up directly by SHA instead of waiting on the whole workflow:

```bash
gh api "repos/404-GCross/Sena-Repo/commits/<sha>/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.name=="Server checks" or .name=="Flutter analyze") | "\(.name)\t\(.status)\t\(.conclusion)"'
```

The packaging/build workflow (`build-android`, `build-windows`, `build-linux`, `build-server`,
dev pre-release) is **not** the required signal and does not need to be tracked.

## Documentation-only exemption

When the change is purely documentation — `README*.md`, `docs/`, `AGENTS.md`, `CONTRIBUTING.md`,
skill files, comments-only edits, or other Markdown-only changes with no code or asset changes —
**do not track GitHub Actions at all**. Commit and push, then report without waiting on CI.

Everything else keeps the normal rule: push, track `Flutter analyze` and `Server checks` for the
pushed SHA, and report the result.

## When a check fails

1. Inspect the failing job's logs (`gh run view --log-failed` or the job URL from `gh pr checks`).
2. Fix the issue, commit, push.
3. Track the same two checks again for the new SHA.

## Reporting

State the tracked checks and their results (e.g. `Flutter analyze ✅, Server checks ✅`), and
mention skipped local checks and missing toolchains (the local machine has no usable Flutter/Dart
toolchain; rely on CI).
