#!/usr/bin/env bash
# Resolves the official release version for build_Release.yml.
#
# Priority: workflow input (`INPUT_VERSION`) > repository VERSION file.
# When the workflow runs on a tag push, the tag must equal "v$(cat VERSION)";
# a mismatch fails the run instead of publishing a wrong version.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
V="$(printf '%s' "${INPUT_VERSION:-}" | tr -d '[:space:]')"
if [ -z "$V" ]; then
  V="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
fi
if [ -z "$V" ]; then
  echo "::error::No release version: pass the version input or fill the VERSION file."
  exit 1
fi

if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  EXPECTED="v$V"
  if [ "$GITHUB_REF_NAME" != "$EXPECTED" ]; then
    echo "::error::Tag $GITHUB_REF_NAME does not match VERSION ($V); expected tag $EXPECTED."
    exit 1
  fi
fi

echo "VERSION=$V" >> "$GITHUB_ENV"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "version=$V" >> "$GITHUB_OUTPUT"
fi
echo "Release version: $V"
