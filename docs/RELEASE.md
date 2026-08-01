# Release checklist

Codex Guardian currently supports local source installation. A public source push and a downloadable Mac binary are separate releases with different gates.

## Public source gate

- [ ] Working tree scope reviewed; unrelated user files excluded.
- [ ] Every tracked and untracked file inspected.
- [ ] `./script/check_public_repo.sh` passes.
- [ ] `git diff --check` passes.
- [ ] Git history and proposed archive scanned for secrets and personal data.
- [ ] No `.env`, credentials, keys, databases, WAL, rollouts, logs, screenshots, or local config included.
- [ ] README capability claims match current source and live evidence.
- [ ] License, contribution terms, third-party notice, changelog, and security policy included.
- [ ] `Package.resolved` reviewed and dependency revision pinned.
- [ ] Full test and relevant packaging lanes pass from a clean checkout.

## Local app gate

- [ ] Release configuration builds.
- [ ] Candidate bundle contains app, daemon, MCP, CLI, and shield icon.
- [ ] Transactional installer and rollback tests pass.
- [ ] Production install verifier passes.
- [ ] Both launchd services run with clean environments.
- [ ] Installed MCP smoke passes.
- [ ] Codex loads `guardian_status` live after restart.
- [ ] Disposable same-task native continuation reaches the exact task.
- [ ] No hard restart is triggered while Desktop is healthy or inventory is incomplete.

## Downloadable binary gate — not yet satisfied

- [ ] Stable semantic version and bundle version source.
- [ ] Clean immutable release commit and tag.
- [ ] Developer ID Application signing.
- [ ] Hardened runtime and minimal entitlements reviewed.
- [ ] Apple notarization and stapling.
- [ ] Checksums for all downloadable artifacts.
- [ ] SPDX SBOM and provenance generated from clean source.
- [ ] Project license and third-party notice included in the bundle/archive.
- [ ] Clean-machine installation, upgrade, rollback, and uninstall proven.
- [ ] Supported macOS/Codex compatibility matrix published.
- [ ] Security update and revocation process documented.

## Generate metadata

From a clean immutable revision:

```bash
release_dir="$(mktemp -d /tmp/codexguardian-release.XXXXXX)"
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)" \
  ./script/generate_release_metadata.sh "$release_dir"
./script/test_release_metadata.sh
```

The generated SPDX and provenance describe inputs. They do not replace signing, notarization, reproducibility, or independent verification.

## Claims

Release notes must separate:

- source committed
- source pushed
- tests passed
- local production app installed
- live task continuation proven
- binary signed/notarized
- public artifact uploaded

Never call one proof another.
