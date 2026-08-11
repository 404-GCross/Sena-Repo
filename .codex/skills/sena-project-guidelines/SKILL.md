---
name: sena-project-guidelines
description: Project-specific engineering rules for Sena Repo. Use whenever Codex changes or reviews Sena Repo code, tests, build workflows, release automation, project skills, logging, client-server contracts, database models/schemas, or Git operations in this repository.
---

# Sena Project Guidelines

## Iron Rules

1. Keep project skills inside this repository under `.codex/skills/`; do not create or update user-level skills for Sena Repo unless the user explicitly asks for that.
2. Use `$git-commit-format` before drafting, amending, or creating any Git commit message. Commit messages must be pure English Conventional Commits.
3. Do not leak secrets in logs, errors, release notes, or commit messages. Redact passwords, tokens, API keys, authorization headers, signatures, account identifiers, and OpenList credentials.
4. Preserve user and unrelated workspace changes. Do not run destructive Git commands, broad cleanup, branch switching, reset, rebase, stash, prune, or repository-wide commits unless explicitly requested.
5. Do not use `git add -A` for commits in this repository. Stage explicit paths that belong to the current task.
6. The user has authorized automatic GitHub submission after requested changes are complete: run the available checks, commit with `$git-commit-format`, push to `origin/dev`, and track the required GitHub Actions checks unless the user says not to commit or push.

## Repository Shape

- Treat `client/` as the Flutter/Dart app and `server/` as the FastAPI/Python backend.
- Follow existing local style before adding new patterns. Prefer nearby helpers, naming, logging style, theme constants, and API conventions.
- Keep changes scoped to the user's requested problem. Avoid opportunistic rewrites or broad refactors.
- When modifying workflows under `.github/workflows/`, preserve the established release split between dev pre-release and release workflows.
- Reference projects under `参考项目/` are comparison material, not code to edit unless the user explicitly asks.

## Client-Server Contracts

- Verify Flutter models, FastAPI schemas, SQLAlchemy models, and JSON field names agree whenever API response/request shapes change.
- Check both producer and consumer for renamed, added, optional, or nullable fields.
- Prefer explicit backwards-compatible handling for existing clients and stored data.
- For user-visible workflows, inspect the UI call site and backend endpoint together before declaring a change complete.

## Logging

- Use the project's logger abstraction instead of `print` or ad hoc debug output.
- Log meaningful lifecycle events, failures, retries, and cross-boundary operations without logging raw request bodies or credentials.
- Redact sensitive values before logging URLs, headers, query strings, exception messages, or command arguments.
- When adding network code in the Flutter client, route ordinary HTTP calls through the logged HTTP wrapper when practical.

## Comments

- Default to no comments for self-explanatory code.
- Add short English comments only for migrations, non-obvious external constraints, required ordering, upstream bugs, or traps already observed during debugging/review.
- Do not add comments that restate the code, section banners, ownerless TODOs, or doc comments that only repeat an identifier.
- Preserve machine-semantic comments and directives such as generated-file markers, build directives, ignore directives, and lints.

## Database And Migrations

- Treat SQLAlchemy models, Pydantic schemas, and database initialization/migration logic as a single contract.
- If a change alters persisted schema, indexes, constraints, or stored field semantics, explicitly tell the user at handoff whether migration or data backfill is required.
- Include the relevant command or manual action when a migration/backfill is needed. If the repository has no migration path for the change, say that clearly.
- Do not silently rely on deployment to fix database shape.

## Verification

- Run the narrowest reliable checks available for the touched area.
- For server Python changes, prefer at least `python -m py_compile` on edited Python files; run tests when the environment has the required dependencies.
- For Flutter changes, local `flutter analyze` is optional when Flutter/Dart is unavailable or the user has accepted relying on CI. Do not block commit/push solely because the local machine lacks Flutter/Dart; state that local analyze was skipped because the toolchain is unavailable.
- After pushing Flutter/client changes, always track the GitHub Actions analyze check for the pushed commit. Find the run for the pushed SHA, confirm the `Flutter analyze` job and the `Analyze Flutter client` step complete, and report the result. If analyze fails, inspect the action logs, fix the issue, commit, push, and track analyze again.
- Do not treat the broader packaging/build workflow as a substitute for analyze. The client build workflow may still be running; the required CI signal for this rule is the analyze job/step.
- For project skills, run `quick_validate.py` on each changed skill folder.
- Report unavailable toolchains or skipped checks in the final response.

## Release Notes

- Git commit messages stay English. Release notes, changelogs, GitHub release bodies, and CI-generated pre-release text may be Chinese when the user or workflow requires Chinese output.
- Keep generated release text user-facing and concise; do not expose internal secrets, raw tokens, or signed download URLs.

## Dependency Awareness

- Do not invent installed toolchains. Check local availability before claiming a build or test can run.
- Current project builds rely on Flutter/Dart, FastAPI/Python dependencies, Android SDK/NDK for Android, Linux GTK tooling for Linux desktop, Docker Buildx/QEMU for server images, and Windows/Inno Setup tooling for Windows packaging.
- If a requested verification depends on missing local tooling, provide the exact missing dependency and the closest check that did run.
