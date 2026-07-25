#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

tracked_and_untracked=$(git ls-files --cached --others --exclude-standard)

if printf '%s\n' "$tracked_and_untracked" | grep -Eq '(^|/)(\.env($|\.)|.*\.(pem|p12|key)$|id_(rsa|ed25519)$)'; then
  echo "Public-safety check failed: sensitive filename detected."
  exit 1
fi

scan_files=$(printf '%s\n' "$tracked_and_untracked" | grep -v '^script/check_public_repo\.sh$' || true)
if [ -n "$scan_files" ] && printf '%s\n' "$scan_files" | xargs rg -n \
  '/Users/[^/]+/|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}'; then
  echo "Public-safety check failed: personal path or credential pattern detected."
  exit 1
fi

echo "Public-safety check passed."
