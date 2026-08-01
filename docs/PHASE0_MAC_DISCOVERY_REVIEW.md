# Phase 0 macOS Discovery Review

Reviewer findings append below.

## 2026-07-27 implementation result

Small boundary implemented in `MacCodexProcessDiscovery`:

- LaunchServices enumerates bundle-ID candidates.
- Security validates the selected bundle and extracts signing/team identity.
- `NSRunningApplication` supplies the live bundle and PID.
- `proc_pidinfo` supplies a stable process-start identity.
- App launch targets the exact revalidated bundle URL.

Pure `GuardianCore` policy owns ambiguity and trust decisions. AppKit owns discovery/launch only. SwiftUI state remains in `AppModel`.

Lifecycle fences:

- Missing or multiple candidates fail closed.
- Selected installed path and running path must match.
- Every termination signal rechecks PID plus start identity.
- LaunchServices replacement before launch fails closed.
- Same PID with a new start identity counts as a new epoch only after signature/path attestation.

Live result: installed and running Codex matched bundle/signing `com.openai.codex`, OpenAI team `2DC432GLL2`, and `/Applications/ChatGPT.app`. Gatekeeper accepted its stapled notarized Developer ID signature.
