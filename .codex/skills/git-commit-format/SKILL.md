---
name: git-commit-format
description: Enforce the user's Git commit message standard for this repository. Use whenever Codex drafts, reviews, amends, creates, squashes, or recommends Git commit messages; whenever the user asks about commit text, commit format, or commit identity conventions; and before running any git commit command in this repository.
---

# Git Commit Format

## Core Rule

Write every Git commit message in pure English Conventional Commits style:

```text
<type>: <concise English summary>
```

Use a plain commit subject, not Markdown. Do not include Chinese text, bold markers, links, brackets, emojis, or a trailing period in the actual commit message.

## Required Workflow

Before drafting or creating a commit:

1. Inspect the staged diff, or the relevant unstaged diff if nothing is staged.
2. Choose the type that best represents the actual change.
3. Write the subject in imperative mood, describing what the commit changes.
4. Keep the first line as a single English subject unless the user explicitly asks for a body.
5. If the change spans unrelated domains, prefer asking whether to split commits unless the user already asked for a single commit.

## Types

Use these types by default:

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

## Style Constraints

- Use lowercase type followed by `: `.
- Start the summary with a lowercase imperative verb unless a proper noun or API name is required.
- Preserve exact product, class, method, and API names when they are the clearest summary.
- Keep the summary concise and specific; prefer under 100 characters when practical.
- Do not fabricate issue numbers, scopes, co-authors, or breaking-change notes.
- Use an optional scope only when it is helpful and obvious, e.g. `fix(api): ...`.
- Do not use commit bodies unless the change is complex or the user requests one.

## Examples

Good:

```text
feat: add CreateDBBackupForShutdown method and update automatic backup logic
fix: update Hikarinagi API base URL
ci: use Chinese dev pre-release notes
chore: configure global git commit identity
```

Bad:

```text
更新 Hikarinagi API 地址
**feat: add CreateDBBackupForShutdown method**
[feat: add backup logic](https://example.com)
Fix bug.
```

## Release Notes Exception

This skill governs Git commit messages only. Release notes, changelog entries, GitHub release bodies, and CI-generated pre-release text may be Chinese when the repository workflow or user request calls for Chinese output.
