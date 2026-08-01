#!/usr/bin/env bash
set -euo pipefail

codex_binary=""
for candidate in \
  "/Applications/Codex.app/Contents/Resources/codex" \
  "/Applications/ChatGPT.app/Contents/Resources/codex" \
  "$(command -v codex 2>/dev/null || true)"
do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    codex_binary="$candidate"
    break
  fi
done

if [[ -z "$codex_binary" ]]; then
  echo "FAIL: installed Codex binary not found" >&2
  exit 1
fi

version="$($codex_binary --version)"
help_text="$($codex_binary app-server --help)"
for expected in "daemon" "proxy" "generate-json-schema" "unix://"; do
  if [[ "$help_text" != *"$expected"* ]]; then
    echo "FAIL: installed app-server missing $expected" >&2
    exit 1
  fi
done

schema_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexguardian-schema.XXXXXX")"
cleanup() {
  case "$(basename "$schema_dir")" in
    codexguardian-schema.*) rm -rf -- "$schema_dir" ;;
  esac
}
trap cleanup EXIT

"$codex_binary" app-server generate-json-schema \
  --out "$schema_dir" \
  --experimental

rg_binary="$(command -v rg 2>/dev/null || true)"
if [[ -z "$rg_binary" ]]; then
  echo "FAIL: rg required for bounded schema validation" >&2
  exit 1
fi

for expected in "thread/resume" "thread/read" "turn/start" \
  "clientUserMessageId" "turn/completed"
do
  if ! "$rg_binary" -Fq "$expected" "$schema_dir"; then
    echo "FAIL: installed schema missing $expected" >&2
    exit 1
  fi
done

echo "PASS: $version exposes exact-thread app-server recovery surface"
