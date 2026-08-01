#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

tracked_and_untracked=$(git ls-files --cached --others --exclude-standard \
  | while IFS= read -r path; do
      if [ -f "$path" ]; then
        printf '%s\n' "$path"
      fi
    done)

if printf '%s\n' "$tracked_and_untracked" | grep -Eq '(^|/)(\.env($|\.)|.*\.(pem|p12|key)$|id_(rsa|ed25519)$)'; then
  echo "Public-safety check failed: sensitive filename detected."
  exit 1
fi

scan_files=$(printf '%s\n' "$tracked_and_untracked" \
  | grep -v -E '^script/(check_public_repo|test_release_metadata)\.sh$' || true)
if [ -n "$scan_files" ]; then
  set +e
  findings=$(printf '%s\n' "$scan_files" | xargs rg -n \
    '/Users/[^/]+/|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}' 2>&1)
  scan_status=$?
  set -e
  if [ "$scan_status" -eq 0 ]; then
    printf '%s\n' "$findings"
    echo "Public-safety check failed: personal path or credential pattern detected."
    exit 1
  fi
  if [ "$scan_status" -ne 1 ]; then
    printf '%s\n' "$findings" >&2
    echo "Public-safety check failed: scanner error." >&2
    exit 1
  fi
fi

echo "Public-safety check passed."
