# Phase 7 local client authentication review

Shared evidence log for the same-user destructive-client threat. Design must preserve fail-closed production behavior.

## Finding

**High — a readable bearer token is treated as the client identity.** The server verifies only that the accepted Unix peer has the daemon's effective UID (`Sources/GuardianDaemon/GuardianDaemonServer.swift:31-69`). It then decodes a caller-supplied credential (`:71-80`). `GuardianDaemonRuntime` hashes that credential, assigns its stored role/capabilities, and validates the command (`Sources/GuardianCore/GuardianDaemonRuntime.swift:73-132`). Therefore any process running as this user that reads or otherwise obtains `mac-ui.token` can claim UI-only `forceRestart`; the same is true for the MCP and CLI roles.

The state directory and token modes are good accidental-disclosure controls, not same-user isolation: install creates a `0700` directory and `0600` files (`script/install_production.sh:97-104`). The registrations grant UI force, MCP hard recovery, and CLI hard recovery/cross-task control (`Sources/GuardianDaemon/GuardianDaemonConfiguration.swift:60-86`). Client-side daemon path checking (`Sources/GuardianClient/GuardianUnixPeerIdentity.swift:35-49`) authenticates the server to the client; it does not authenticate the client to the server.

No destructive daemon implementation is live yet: daemon startup is `shadowOnly` (`Sources/GuardianDaemon/main.swift:18-22`), and accepted non-observe commands currently end as unsupported (`Sources/GuardianCore/GuardianDaemonRuntime.swift:190-201`). This is the safe window to change authentication. Do not enable authoritative mutations first.

## Minimum viable production design

Keep the Unix socket for this phase. Add a mandatory, install-bound peer attestation before the runtime uses a credential.

1. On every accepted socket, read `LOCAL_PEERTOKEN`, not only `LOCAL_PEERPID`. The SDK exposes `LOCAL_PEERTOKEN`; its audit token includes PID version, avoiding a PID-reuse identity check. No PID-only production fallback.
2. Require both `getpeereid` UID and audit-token effective UID to equal the daemon UID.
3. Build a dynamic `SecCodeRef` from the audit token using `SecCodeCopyGuestWithAttributes` plus `kSecGuestAttributeAudit`. Run strict validity with `SecCodeCheckValidity`. Fail closed on every API, decode, or requirement error.
4. Bind the verified code to exactly one registered role. Require all of:
   - fixed code-signing identifier;
   - same pinned Developer ID Team ID as Guardian;
   - exact canonical executable path inside the installed app;
   - valid hardened-runtime signature with library validation intact;
   - role-specific credential and `clientID`.
5. Pass immutable `GuardianVerifiedLocalPeer` evidence into `GuardianDaemonRuntime.handle`. The credential lookup returns a registration containing both the existing client capability record and its required peer policy. A credential match without a peer-policy match returns `unauthorizedClient` before validation or journal mutation.
6. Keep the 32-byte credentials as defense in depth. Do not call them process authentication and never log raw values. Keychain storage may reduce accidental file theft, but a same-user attacker can execute a generally callable signed helper; Keychain alone does not solve that confused-deputy case.

Proposed production identities:

| Role | Signing identifier | Required path | Maximum capability |
|---|---|---|---|
| macUI | `com.moni.codexguardian` | `Contents/MacOS/CodexGuardian` | Existing control set; `forceRestart` additionally requires an explicit local UI action permit |
| mcp | `com.moni.codexguardian.mcp` | `Contents/SharedSupport/codex-guardian-mcp` | Observe and exact-origin recovery only; never force or cross-task |
| cli | `com.moni.codexguardian.cli` | `Contents/SharedSupport/guardianctl` | Observe only by default; privileged commands require a separately designed user-presence flow |
| remoteGateway | none in Phase 7 | no separate local executable | Do not add a wildcard same-team rule |

Use explicit requirement strings equivalent to `anchor apple generic`, expected identifier, and pinned Team ID. Also bind the canonical path. “Any binary signed by our team” is too broad. The daemon should verify its own production signature at startup before deriving the Team ID. A signed manifest in the app bundle can describe role paths/identifiers, but mutable state-directory files must never define trust.

Suggested seams:

- `GuardianLocalPeerTokenReader`: obtains audit token and path via `proc_pidpath_audittoken`.
- `GuardianLocalCodeVerifier`: Security.framework adapter; injectable in tests.
- `GuardianLocalPeerPolicy`: expected identifier, Team ID, canonical path, required flags, role.
- `GuardianLocalPeerAttestor`: returns verified evidence or one generic denial.
- `GuardianLocalClientRegistration`: add peer policy; reject duplicate credentials, client IDs, identifiers, or paths at startup.
- `GuardianDaemonServer`: attest after accept and make verified evidence mandatory for `runtime.handle`.
- `GuardianUnixPeerIdentity`: symmetrically verify the daemon's code requirement, not only its path, so a decoy socket cannot impersonate Guardian.

## Confused-deputy boundary

Code identity blocks a foreign process from writing directly to the daemon socket with a stolen token. It does not stop that process from launching a legitimate signed MCP helper and driving its stdin. Therefore:

- MCP remains incapable of force and cross-task control; preserve the explicit validator denials at `Sources/GuardianCore/GuardianIPCProtocol.swift:149-160`.
- Every MCP recovery mutation must also present and consume the existing exact-task/origin proof. Process identity alone is never mutation authority.
- A local force operation needs a short-lived, single-use permit created by a visible UI action and bound to operation ID, daemon generation, deadline, and UI peer identity.
- Hardened runtime and library validation are required so an attacker cannot make the signed helper load unsigned control code.

This residual must be closed before calling the local boundary high-assurance. Moving the same bearer secret to Keychain without these semantic checks is not closure.

## RED-first test order

Do not change server behavior until the first group fails for the current UID-plus-token implementation.

1. `validMacUITokenFromForeignSameUIDPeerIsRejectedAndJournalUnchanged` — fake/integration peer has correct UID and token but wrong signing identity. Assert no operation, outbox row, sequence, or audit event changes.
2. `validTokenFromCorrectlySignedWrongRoleIsRejected` — MCP peer plus UI token, and UI peer plus MCP token, both fail.
3. `missingOrMalformedLocalPeerAuditTokenFailsClosed` — prove there is no `LOCAL_PEERPID` fallback.
4. `pidReuseCannotChangeAttestedIdentity` — policy consumes audit token/PID version and `proc_pidpath_audittoken`, not a later PID lookup.
5. `movedOrReplacedHelperFailsPathOrRequirement` — valid credential and identifier are insufficient at a noncanonical path; tampered/ad-hoc binaries fail signature validation.
6. `exactProductionRolePeerAndCredentialSucceeds` — only after the denial cases; prove observe still works.
7. `mcpCannotForceOrCrossTaskEvenWhenPeerAndCredentialAreValid` — preserve the existing defense against overprivileged registrations.
8. `genuineMCPDrivenByUntrustedCallerCannotObtainAmbientMutation` — recovery requires valid, unconsumed exact-origin proof; an arbitrary JSON-RPC caller cannot use code signing as authority.
9. `clientRejectsPathCorrectDaemonWithWrongSigningRequirement` — cover the reverse/decoy-server boundary.
10. `authoritativeDaemonRefusesAdHocSelfOrClientSignatures` — development identities may run only shadow/observe mode.
11. Installer tests fail unless every executable has the expected identifier, one non-ad-hoc Team ID, hardened-runtime flags, strict verification, and the same team. Test each nested helper separately, not only `codesign --deep` on the app.

Unit tests should inject attestation evidence so CI does not need a Developer ID key. Add one macOS subprocess test for real `LOCAL_PEERTOKEN` extraction and one signed-package acceptance test in release CI. Do not weaken production requirements to make an ad-hoc unit fixture pass.

## Packaging and cutover risks

- Production currently re-signs every helper and the app ad hoc with `--sign -` (`script/install_production.sh:26-34`). That has no stable Team ID. Install-bound authoritative authentication must remain disabled until the packaging flow uses a real Developer ID identity and unique helper identifiers.
- Current helper executables do not have independently declared identifiers in build packaging (`script/build_and_run.sh:29-50`). Add explicit identifiers during signing and assert them after staging.
- The app swap is transactional, but activation boots the old daemon out only after the new bundle is in place (`script/lib/guardian_install.sh:45-69`, `script/install_production.sh:36-53`). Stop new accepts, drain or deny mutations, replace all binaries, then launch the new daemon. Never temporarily allow credential-only clients.
- A pre-cutover MCP process may remain alive because activation stops UI and daemon but not MCP. It must be rejected if it lacks the new requirement. After the first Developer ID release, version-independent Team-ID/identifier requirements allow N/N+1 overlap safely.
- Bump the local protocol/auth epoch. New clients must recognize explicit authentication-unavailable status; old clients receive denial. No silent downgrade.
- Rollback must restore the whole signed bundle and launch configuration. Requirement policy should live in code/signed bundle, not SQLite, so rollback cannot strand a newer mutable trust record.
- Development socket mode may use injected test requirements, but only with `shadowOnly` and observe-only capabilities. Launchd production startup must reject development overrides and ad-hoc identities.
- Narrow CLI registration now. It is configured for hard recovery and cross-task control even though its current command surface only observes; ambient unused capability increases future blast radius.

## Exit evidence

Phase 7 local authentication is not complete until all RED cases are green, current recovery/capability tests remain green, staged production binaries pass independent Security.framework/code-signing verification, direct same-UID stolen-token probes cannot mutate state, and authoritative startup demonstrably refuses ad-hoc or untrusted peers. Until then: remote listener off, daemon shadow-only, no destructive release.
