# Phases 8–11 Gap Audit

Current repository evidence only. Live/device/release claims remain open.

| Phase | Present | Missing before exit |
| --- | --- | --- |
| 8 Phone | Signed remote protocol, pairing, replay/snapshot, durable outcomes, ACK/key destruction, opaque push type | Native iOS target/UI, Keychain client identity, background reconnect, offline queue UI, fresh impact confirmation, real loss/reconnect drill, Mac/phone history parity |
| 9 Agents | Codex action/capability concepts and abstract remote execution adapter | ACP semantic adapter policy, capability mapper, task/worktree/process ownership, observe-only PTY boundary, adapter contract tests, one real supported adapter proof |
| 10 Adviser | macOS Foundation Models prompt generator and deterministic prompt fallback | Core typed adviser boundary, bounded/redacted evidence model, no-authority contract, availability gate, golden set, secret/state/tool/fake-ACK adversarial suite, disabled-equivalence proof |
| 11 Production | Transactional install scripts, launchd plist, public-repo scan, crash harness | Signed/notarized artifact, SBOM/provenance, migration/compatibility rollback matrix, sleep/wake/login/reboot/Codex-update drills, accessibility audit, completed security scan, 100 supervised recoveries, public benchmark results |

## Dependency order

1. Finish Phase 7 ACK/reconnect atomicity and local deterministic benchmark.
2. Add Phase 9 pure capability/ownership policy; no destructive adapter until
   Gate 0 supplies semantic Desktop authority.
3. Build Phase 10 adviser as suggestion-only core with injected model boundary.
4. Build iOS client against the stable observe/pair/replay/ACK contract; keep
   mutating actions hidden while production adapters are unavailable.
5. Perform live TLS/LAN/VPN/device drills, then security review.
6. Only after all prior gates: signing/notarization, supervised beta, benchmark.

## Hard blockers

- Installed Codex Desktop exposes no supported external listener for exact live
  same-task control. Gate 0 write authority remains unavailable.
- The repository has no iOS application target or signing configuration.
- No production remote TLS identity has been provisioned.
- Security-scan setup stalled; remote is not security-cleared.
