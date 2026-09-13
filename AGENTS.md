# Sena Repo Agent Rules

Project rules for coding agents working in this repository. `CLAUDE.md` is a symlink to this
file; keep a single copy of the rules here and long-form documentation under `Documentation/`.

## Iron Rules

1. Plan first; execute only on an explicit instruction. When the user raises a requirement —
   including pasting an issue link or asking whether something is feasible — investigate
   read-only, then present a concrete plan: what will change, which files, and the decisions
   the user still needs to make. Then stop. Only an explicit instruction to act ("做", "改",
   "开始", or an unambiguous equivalent) authorizes editing files, committing, or pushing.
   Presenting a plan, receiving "继续", being asked an unrelated question, or silence is not
   authorization. Never start part of a plan while other decisions in it are still open.
2. Keep project rules in this root `AGENTS.md`. Do not duplicate them into user-level skills or
   into `CLAUDE.md` (that file is a symlink to this one).
3. Follow the Commit Messages section below before drafting, amending, or creating any Git
   commit message. Commit messages must be pure English Conventional Commits.
4. Do not leak secrets in logs, errors, release notes, or commit messages. Redact passwords,
   tokens, API keys, authorization headers, signatures, account identifiers, and OpenList
   credentials.
5. Preserve user and unrelated workspace changes. Do not run destructive Git commands, broad
   cleanup, branch switching, reset, rebase, stash, prune, or repository-wide commits unless
   explicitly requested.
6. Do not use `git add -A` for commits in this repository. Stage explicit paths that belong to
   the current task.
7. The user has authorized automatic GitHub submission after requested changes are complete:
   run the available checks, follow the Commit Messages section, push to `origin/dev`, and
   track the required GitHub Actions checks unless the user says not to commit or push.
8. HTML design mockups and UI draft files are local-only working artifacts unless the user
   explicitly asks to commit or publish them; do not stage, commit, or push them by default.

## Repository Shape

- Treat `client/` as the Flutter/Dart app and `server/` as the FastAPI/Python backend.
- Follow existing local style before adding new patterns. Prefer nearby helpers, naming,
  logging style, theme constants, and API conventions.
- Keep changes scoped to the user's requested problem. Avoid opportunistic rewrites or broad
  refactors.
- When modifying workflows under `.github/workflows/`, preserve the established release split
  between dev pre-release and release workflows.
- Reference projects under `参考项目/` are comparison material, not code to edit unless the
  user explicitly asks.
- Long-form user, technical, and troubleshooting documentation lives in `Documentation/zh-CN/`.
  Keep this file to rules and pointers rather than duplicating full guides.

## Client-Server Contracts

- Verify Flutter models, FastAPI schemas, SQLAlchemy models, and JSON field names agree whenever
  API response/request shapes change.
- Check both producer and consumer for renamed, added, optional, or nullable fields.
- Prefer explicit backwards-compatible handling for existing clients and stored data.
- For user-visible workflows, inspect the UI call site and backend endpoint together before
  declaring a change complete.

## Logging

- Use the project's logger abstraction instead of `print` or ad hoc debug output.
- Log meaningful lifecycle events, failures, retries, and cross-boundary operations without
  logging raw request bodies or credentials.
- Redact sensitive values before logging URLs, headers, query strings, exception messages, or
  command arguments.
- When adding network code in the Flutter client, route ordinary HTTP calls through the logged
  HTTP wrapper when practical.

## Comments

- Default to no comments for self-explanatory code.
- Add short English comments only for migrations, non-obvious external constraints, required
  ordering, upstream bugs, or traps already observed during debugging/review.
- Do not add comments that restate the code, section banners, ownerless TODOs, or doc comments
  that only repeat an identifier.
- Preserve machine-semantic comments and directives such as generated-file markers, build
  directives, ignore directives, and lints.

## Database And Migrations

- Treat SQLAlchemy models, Pydantic schemas, and database initialization/migration logic as a
  single contract.
- If a change alters persisted schema, indexes, constraints, or stored field semantics,
  explicitly tell the user at handoff whether migration or data backfill is required.
- Include the relevant command or manual action when a migration/backfill is needed. If the
  repository has no migration path for the change, say that clearly.
- Do not silently rely on deployment to fix database shape.

## Verification

- Run the narrowest reliable checks available for the touched area.
- For server Python changes, prefer at least `python -m py_compile` on edited Python files; run
  tests when the environment has the required dependencies.
- For Flutter changes, local `flutter analyze` is optional when Flutter/Dart is unavailable or
  the user has accepted relying on CI. Do not block commit/push solely because the local
  machine lacks Flutter/Dart; state that local analyze was skipped because the toolchain is
  unavailable.
- After pushing Flutter/client changes, always track the GitHub Actions analyze check for the
  pushed commit. Find the run for the pushed SHA, confirm the `Flutter analyze` job and the
  `Analyze Flutter client` step complete, and report the result. If analyze fails, inspect the
  action logs, fix the issue, commit, push, and track analyze again.
- Do not treat the broader packaging/build workflow as a substitute for analyze. The client
  build workflow may still be running; the required CI signal for this rule is the analyze
  job/step.
- Report unavailable toolchains or skipped checks in the final response.

## Release Notes

- Git commit messages stay English. Release notes, changelogs, GitHub release bodies, and
  CI-generated pre-release text may be Chinese when the user or workflow requires Chinese
  output.
- Keep generated release text user-facing and concise; do not expose internal secrets, raw
  tokens, or signed download URLs.

## Dependency Awareness

- Do not invent installed toolchains. Check local availability before claiming a build or test
  can run.
- Current project builds rely on Flutter/Dart, FastAPI/Python dependencies, Android SDK/NDK for
  Android, Linux GTK tooling for Linux desktop, Docker Buildx/QEMU for server images, and
  Windows/Inno Setup tooling for Windows packaging.
- If a requested verification depends on missing local tooling, provide the exact missing
  dependency and the closest check that did run.

## Commit Messages

Write every Git commit message in pure English Conventional Commits style:

```text
<type>: <concise English summary>
```

Use a plain commit subject, not Markdown. Do not include Chinese text, bold markers, links,
brackets, emojis, or a trailing period in the actual commit message.

Before drafting or creating a commit:

1. Inspect the staged diff, or the relevant unstaged diff if nothing is staged.
2. Choose the type that best represents the actual change.
3. Write the subject in imperative mood, describing what the commit changes.
4. Keep the first line as a single English subject unless the user explicitly asks for a body.
5. If the change spans unrelated domains, prefer asking whether to split commits unless the
   user already asked for a single commit.

Types:

- `feat`: user-facing feature or capability
- `fix`: bug fix or broken behavior correction
- `docs`: documentation-only change
- `refactor`: code restructuring without intended behavior change
- `perf`: performance improvement
- `test`: test-only change
- `build`: dependency, packaging, or build system change
- `ci`: CI workflow change
- `chore`: maintenance, tooling, or repository housekeeping
- `style`: formatting-only code style change

Style constraints:

- Use lowercase type followed by `: `.
- Start the summary with a lowercase imperative verb unless a proper noun or API name is
  required.
- Preserve exact product, class, method, and API names when they are the clearest summary.
- Keep the summary concise and specific; prefer under 100 characters when practical.
- Do not fabricate issue numbers, scopes, co-authors, or breaking-change notes.
- Use an optional scope only when it is helpful and obvious, e.g. `fix(api): ...`.
- Do not use commit bodies unless the change is complex or the user requests one.

Good examples:

```text
feat: add CreateDBBackupForShutdown method and update automatic backup logic
fix: update Hikarinagi API base URL
ci: use Chinese dev pre-release notes
chore: configure global git commit identity
```

Bad examples:

```text
更新 Hikarinagi API 地址
**feat: add CreateDBBackupForShutdown method**
[feat: add backup logic](https://example.com)
Fix bug.
```

This section governs Git commit messages only. Release notes, changelog entries, GitHub release
bodies, and CI-generated pre-release text may be Chinese when the repository workflow or user
request calls for Chinese output.
