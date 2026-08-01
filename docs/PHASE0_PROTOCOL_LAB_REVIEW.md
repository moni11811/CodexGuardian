# Phase 0 Protocol Lab Review

Date: 2026-07-27

Review findings append below.

## 2026-07-27 bounded read-only parser design

### Observed gap

`CodexAppServerProcessPolicy` accepts `pid command` text only. It cannot prove
the app-server belongs to the selected Desktop process. It cannot distinguish
stdio from a Unix listener. It also silently treats a truncated or duplicate
`ps` row set as ordinary absence. This is unsafe for control discovery.

### Proposed pure API

Keep `ps` collection outside this type. Collector must request only:

```
ps -axo pid=,ppid=,command=
```

and cap raw bytes before parsing. The parser accepts already-bounded text and
never launches a process, opens a socket, sends JSON-RPC, or changes Desktop.

```swift
struct CodexAppServerProcessRow: Equatable, Sendable {
    let processID: Int32
    let parentProcessID: Int32
    let command: String
}

enum CodexAppServerTransport: Equatable, Sendable {
    case stdio
    case unixSocket(path: String)
    case unsupportedListener(argument: String)
}

enum CodexProtocolLabInventory: Equatable, Sendable {
    case complete
    case truncated
}

enum CodexAppServerProbeResult: Equatable, Sendable {
    case exact(row: CodexAppServerProcessRow,
               transport: CodexAppServerTransport)
    case unavailable(CodexAppServerProbeUnavailableReason)
}

enum CodexAppServerProbeUnavailableReason: Equatable, Sendable {
    case inventoryTruncated
    case malformedRow
    case noDesktopChildAppServer
    case ambiguousDesktopChildAppServers
    case malformedAppServerInvocation
    case unsupportedTransport
}

struct CodexAppServerProcessParser: Sendable {
    // Reject any row outside a fixed byte/character budget.
    // Require PID > 0, PPID > 0, and exactly two leading integer fields.
    func parse(psOutput: String,
               inventory: CodexProtocolLabInventory)
        -> Result<[CodexAppServerProcessRow], CodexAppServerProbeUnavailableReason>

    // Select only: exact verified Desktop PID parent; selected verified bundle
    // resource executable; `-c features.code_mode_host=true`; `app-server`.
    // Require exactly one candidate. Classify listener flags only; do not dial.
    func probe(rows: [CodexAppServerProcessRow],
               desktopProcessID: Int32,
               verifiedApplicationPath: String)
        -> CodexAppServerProbeResult
}
```

`app-server` with no explicit listener is `.stdio`. `--listen unix://PATH`
is `.unixSocket(path:)` only after later socket owner and filesystem checks.
TCP, inherited-FD, malformed `--listen`, and unknown listener syntax are
`.unsupportedListener`; control policy maps all to unavailable. A socket path
alone is never proof that it belongs to the chosen Desktop child.

### Required red tests before implementation

| Test | Expected fail-closed result |
| --- | --- |
| `desktopChildAppServerWithNoListenFlagIsStdio` | exact + `.stdio`; policy unavailable |
| `desktopChildAppServerWithUnixListenClassifiesPathOnly` | exact + `.unixSocket`; no control authorization |
| `nonDesktopParentNeverMatchesEvenWithTrustedCodexCommand` | `.noDesktopChildAppServer` |
| `twoMatchingDesktopChildrenAreAmbiguous` | `.ambiguousDesktopChildAppServers` |
| `truncatedPsInventoryNeverFallsBackToAbsence` | `.inventoryTruncated` |
| `malformedPidOrPPIDFailsRatherThanSkippingRow` | `.malformedRow` |
| `lookalikeAppServerArgumentDoesNotMatch` | `.noDesktopChildAppServer` |
| `missingFeatureFlagDoesNotMatch` | `.noDesktopChildAppServer` |
| `tcpOrMalformedListenFlagIsUnsupported` | `.unsupportedTransport` |
| `rowLongerThanParserBudgetFailsClosed` | `.malformedRow` |

### Threats fenced

- PID reuse: parser input must use the pre-verified Desktop PID/start epoch;
  process controller rechecks before a restart signal.
- Stable/beta collision: only selected verified bundle resource path matches.
- Command-line spoofing: no command text authorizes control; signing, parent,
  path, socket-owner, schema, inventory, UI sync, and persistence stay gates.
- Partial `ps`: explicit truncation result; never infer no app-server.
- Ambiguous children: no arbitrary first-row selection.
- Socket confusion: classify only. Later ownership must equal selected child PID.
- Output DoS: capture cap occurs before parsing; parser has row/line limits.

### Evidence boundary

This parser only produces a discovery report. It cannot close Gate 0. A later
read-only protocol lab still must prove: socket ownership by exact app-server,
schema compatibility, complete task inventory, and Desktop-visible correlated
message persistence. Until then `CodexDesktopControlPolicy` remains unavailable
or observe-only; no Guardian mutation is enabled.

## Independent coverage review

Current red cases cover exact path/parent, default stdio, one Unix listener,
detached/ambiguous children, malformed PID, conflicting transports, and a
lookalike bundle path. Add fail-closed cases before relying on the probe:

- Capture truncation, over-budget rows, duplicate rows/PIDs, and a missing
  Desktop row. A clipped `ps` snapshot can hide a second child.
- Revalidate Desktop PID **and start epoch** before and after collection. PPID
  equality alone cannot fence PID reuse.
- Require the actual `app-server` command position and intended Desktop feature
  configuration. Reject `app-server` appearing as a config value, management
  subcommands, repeated command tokens, `--`, and unknown positional tokens.
- Test missing/empty/duplicate `--listen`, duplicate `--stdio`, `stdio://`,
  `ws://`, `off`, empty/relative Unix paths, and Unix paths containing spaces.
  Whitespace-splitting `ps command=` is not lossless argv evidence.
- Test invalid Desktop/child IDs and `desktopPID == appServerPID` in policy.
  Every process/socket identity needs a start epoch, not PID only.

Evidence remains discovery-only. `Transport.unixSocket` carries no endpoint,
inode/device, owner epoch, or freshness. Policy booleans can currently combine
schema, inventory, UI-sync, and persistence observations from different times.
Gate 0 therefore also needs one immutable, timestamped evidence snapshot tying
the signed running executable, Desktop/child epochs, socket identity, negotiated
schema revision, complete inventory cursor, exact task ID, and correlated
message nonce/persistence event together. Until that exists, Unix detection may
justify protocol probing only; it cannot authorize writes or restart recovery.

## Implemented read-only slice — 2026-07-27

- Added `CodexDesktopProcessProbe`: exact signed-bundle resource path, exact
  Desktop parent PID, command-position parsing, and fail-closed transport
  classification.
- Red first: missing APIs failed compilation. A second red proved `-c
  app-server` was falsely accepted as the subcommand; option-aware parsing fixed
  it.
- Twelve focused tests pass. Full SwiftPM suite passes 357 tests in 12 suites.
- `guardianctl codex-control` uses a capped wide `ps` snapshot and revalidates
  the Desktop PID/start epoch before reporting.
- Live result: Desktop child PID `22468`, parent PID `22091`, transport `stdio`,
  mode `unavailable:noSupportedControlListener`; inventory unavailable; UI and
  correlated persistence proof false.
- No listener was opened, no app-server daemon was launched, and no mutation or
  restart occurred. Gate 0 remains open.
