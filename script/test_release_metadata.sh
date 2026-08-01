#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guardian-release-metadata.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

SOURCE_DATE_EPOCH=1785120000 "$ROOT_DIR/script/generate_release_metadata.sh" "$TEST_ROOT/first"
SOURCE_DATE_EPOCH=1785120000 "$ROOT_DIR/script/generate_release_metadata.sh" "$TEST_ROOT/second"

/usr/bin/cmp "$TEST_ROOT/first/codexguardian.spdx.json" "$TEST_ROOT/second/codexguardian.spdx.json"
/usr/bin/cmp "$TEST_ROOT/first/codexguardian.provenance.json" "$TEST_ROOT/second/codexguardian.provenance.json"

/usr/bin/jq -e '
  .spdxVersion == "SPDX-2.3"
  and (.packages | any(.name == "GRDB.swift" and .versionInfo == "7.11.1"))
  and (.packages | any(.name == "CodexGuardian"))
' "$TEST_ROOT/first/codexguardian.spdx.json" >/dev/null

/usr/bin/jq -e '
  ._predicateType == "https://slsa.dev/provenance/v1"
  and .subject[0].digest.gitCommit != null
  and .predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit == "b83108d10f42680d78f23fe4d4d80fc88dab3212"
' "$TEST_ROOT/first/codexguardian.provenance.json" >/dev/null

RG_BIN="$(command -v rg)"
if [[ -z "$RG_BIN" ]]; then
  echo "Release metadata test requires rg" >&2
  exit 1
fi
if "$RG_BIN" -n '/Users/[^/]+/|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}' "$TEST_ROOT"; then
  echo "Release metadata leaked a personal path or credential pattern" >&2
  exit 1
fi

echo "Release metadata regression passed"
