# Phase 0 Process Selection Review

Reviewer findings append below.

## 2026-07-27 — design-only review

### Bug theory

`GuardianDesktopProcessIdentity` is durable, but discovery is split in
`AppModel`. `CodexLaunchPlan` admits fixed paths; `didRestart` compares PID
sets only. A renamed valid app can be missed; two verified same-ID installs can
be chosen arbitrarily; recycled PID can be mistaken for restart.

Never use fallback path or PID change as authority. Select exactly one live,
attested process or fail closed. No restart/continuation on failure.

### Proposed pure GuardianCore API

```swift
struct CodexProcessCandidate: Equatable, Sendable {
  let bundleIdentifier: String
  let bundleURLPath: String
  let signingIdentifier: String
  let teamIdentifier: String?
  let processID: Int32
  let processStartIdentity: UInt64
  let isRunning: Bool
}
struct CodexProcessRequirement: Equatable, Sendable {
  let bundleIdentifier: String
  let signingIdentifier: String
  let teamIdentifier: String?
}
enum CodexProcessSelectionFailure: Error, Equatable, Sendable {
  case noCandidate, ambiguous, bundleMismatch, signingMismatch, teamMismatch
  case invalidCandidate, unchangedEpoch, staleControlGeneration
}
struct CodexProcessSelector: Sendable {
  func select(candidates: [CodexProcessCandidate],
              requirement: CodexProcessRequirement) throws -> CodexProcessCandidate
  func verifyRestart(previous: GuardianDesktopProcessIdentity,
                     current: CodexProcessCandidate,
                     requirement: CodexProcessRequirement,
                     serverGeneration: Int64) throws -> GuardianDesktopProcessIdentity
}
```

Selector rules: reject malformed values first. Keep only running exact
bundle/signing/required-team matches. Renamed path is allowed. Require exactly
one; zero/many fail. Same PID + same start identity means unchanged process;
same PID + different start identity is a new OS epoch only after attestation.
Positive newer server generation is additional post-launch control evidence,
never a substitute for OS epoch. Persist full identity after validation only.

macOS adapter boundary: LaunchServices/`NSWorkspace` gets installed URL;
`NSRunningApplication` gets running PID; Security attests signing/team; a
process-start provider gets epoch. It creates candidates. Pure core owns
selection. It must not invent a candidate from `/Applications/ChatGPT.app` or
`/Applications/Codex.app` when attestation disagrees.

### Required red tests

1. Renamed valid bundle: exact ID/signing/team, one live candidate => selected.
2. Stable + beta same exact ID/signing/team => ambiguity, no selection.
3. Wrong signing or team => failure despite matching path/PID.
4. No matching candidate => `noCandidate`; malformed path/PID/epoch/signature => invalid.
5. Previous/current same PID+epoch => `unchangedEpoch`; old PID-set logic must fail.
6. Same PID + new epoch => accepted only after full attestation; persist new epoch.
7. Zero/stale control generation after a selected process => fail closed.

### Evidence boundary

Design only. No controller, adapter, regression test, or live proof added here.
Gate 0 stays open. Remote writes stay disabled.
