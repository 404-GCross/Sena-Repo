#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="${RELEASE_NOTES_OUTPUT:-release_notes_auto.md}"
TITLE="${RELEASE_NOTES_TITLE:-更新内容}"
RANGE="${RELEASE_NOTES_RANGE:-}"
LIMIT="${RELEASE_NOTES_LIMIT:-20}"
REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
MANUAL_NOTES_SOURCE="${RELEASE_NOTES_MANUAL_SOURCE:-}"
MANUAL_NOTES_TITLE="${RELEASE_NOTES_MANUAL_TITLE:-手动说明}"
FALLBACK_MESSAGE="${RELEASE_NOTES_FALLBACK:-暂无可列出的提交。}"

CATEGORIES_DIR="$(mktemp -d)"
trap 'rm -rf "$CATEGORIES_DIR"' EXIT

: > "$CATEGORIES_DIR/features.md"
: > "$CATEGORIES_DIR/fixes.md"
: > "$CATEGORIES_DIR/optimizations.md"
: > "$CATEGORIES_DIR/docs.md"
: > "$CATEGORIES_DIR/build.md"
: > "$CATEGORIES_DIR/others.md"

printf '## %s\n\n' "$TITLE" > "$OUTPUT_FILE"

log_args=(--no-merges --format='%H%x09%s')
if [ -n "$RANGE" ]; then
  log_args+=("$RANGE")
else
  log_args+=(-n "$LIMIT")
fi

while IFS=$'\t' read -r sha subject; do
  [ -n "$sha" ] || continue
  lower="$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')"
  line="- [**${subject}**](https://github.com/${REPOSITORY}/commit/${sha})"
  case "$lower" in
    feat:*|feat\(*|feature:*|feature\(*|新增*|*新增*)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/features.md"
      ;;
    fix:*|fix\(*|bugfix:*|bugfix\(*|修复*|*修复*)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/fixes.md"
      ;;
    perf:*|perf\(*|refactor:*|refactor\(*|optimize:*|optimize\(*|style:*|style\(*|优化*|调整*|改进*|*优化*|*调整*|*改进*)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/optimizations.md"
      ;;
    docs:*|docs\(*|doc:*|doc\(*|文档*|*文档*)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/docs.md"
      ;;
    build:*|build\(*|ci:*|ci\(*|chore:*|chore\(*|构建*|发布*|*构建*|*发布*)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/build.md"
      ;;
    *)
      printf '%s\n' "$line" >> "$CATEGORIES_DIR/others.md"
      ;;
  esac
done < <(git log "${log_args[@]}")

append_section() {
  local title="$1"
  local file="$2"
  if [ -s "$file" ]; then
    printf '### %s\n\n' "$title" >> "$OUTPUT_FILE"
    cat "$file" >> "$OUTPUT_FILE"
    printf '\n' >> "$OUTPUT_FILE"
  fi
}

append_section "新增" "$CATEGORIES_DIR/features.md"
append_section "修复" "$CATEGORIES_DIR/fixes.md"
append_section "优化" "$CATEGORIES_DIR/optimizations.md"
append_section "文档" "$CATEGORIES_DIR/docs.md"
append_section "构建" "$CATEGORIES_DIR/build.md"
append_section "其他" "$CATEGORIES_DIR/others.md"

if ! grep -q '^- ' "$CATEGORIES_DIR"/*.md; then
  printf -- '- %s\n\n' "$FALLBACK_MESSAGE" >> "$OUTPUT_FILE"
fi

if [ -n "$MANUAL_NOTES_SOURCE" ] && [ -s "$MANUAL_NOTES_SOURCE" ]; then
  if grep -q '[^[:space:]]' "$MANUAL_NOTES_SOURCE"; then
    printf '\n## %s\n\n' "$MANUAL_NOTES_TITLE" >> "$OUTPUT_FILE"
    cat "$MANUAL_NOTES_SOURCE" >> "$OUTPUT_FILE"
    printf '\n' >> "$OUTPUT_FILE"
  fi
fi
