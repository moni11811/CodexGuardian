# Phase 0 Process Controller Review

Date: 2026-07-27

## Bug theory

Restart discovery is split across `AppModel`: LaunchServices resolves one URL, running applications are matched only by bundle identifier, and restart proof compares PID sets. This can target the wrong same-bundle installation, accept a signing-identity change, or mistake PID reuse for the intended process epoch.

## Required red proof

- A renamed but correctly signed Codex bundle is resolved without a hard-coded product name.
- Multiple matching stable installations fail closed as ambiguous.
- A signing-identifier or team-identifier mismatch fails closed.
- Reused PID with a different start identity is not the captured process.
- Missing candidates fail closed.

## Review lanes

- Pure `GuardianCore` selection and process-epoch contract.
- Narrow macOS LaunchServices and Security-framework discovery boundary.
- `AppModel` integration after focused regressions pass.

## Evidence

- Red compile failures proved the selector/controller/adapter APIs were absent before implementation.
- `CodexProcessSelectionPolicy` now rejects missing, malformed, mismatched, or ambiguous applications/processes.
- `CodexProcessController` re-resolves before launch, revalidates PID plus start identity before every signal, requires the running bundle path to match the selected application, and accepts an already-stopped Desktop only after a newly attested process appears.
- `MacCodexProcessDiscovery` uses LaunchServices, strict Security-framework validation, `NSRunningApplication`, and `proc_pidinfo` start time. No `ChatGPT.app` fallback is used by the restart path.
- `AppModel` now performs one exact-path launch request, polls only for proof, and keeps continuation blocked unless the same signed bundle returns with a new process epoch and a new app-server settle window.
- `guardianctl codex-process` live proof selected `/Applications/ChatGPT.app`, signing identifier `com.openai.codex`, team `2DC432GLL2`, PID `22091`, and a nonzero start identity.
- `codesign` reported hardened Developer ID signature plus stapled notarization; `spctl` accepted the app as Notarized Developer ID.
- `swift test`: 345 tests in 12 suites passed.
- Generic iOS Simulator `build-for-testing`: succeeded. No simulator runtime/device claim.

Gate 0 remains open: the installed Desktop child app-server still has no supported attachable semantic listener. Process safety is proven; exact live thread read/write is not.
