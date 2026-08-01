# Phase 8 background reconnect review

Date: 2026-07-27. Sources: Apple documentation only.

## Finding

iOS cannot provide an always-on local-network Guardian client. Make foreground reconnect authoritative. Treat background execution as best-effort cache refresh, never as a recovery deadline or command-delivery guarantee.

## Current implementation

- The root observes `scenePhase`. One supervisor runs only while active and is
  cancelled by SwiftUI when the phase changes.
- The supervisor retries transient transport loss with capped exponential
  backoff and resets after authenticated success.
- Pairing, TLS/authentication, malformed protocol, and corrupt storage failures
  stop instead of repeating unchanged.
- Every retry enters the durable `PhoneRemoteClient`, which reconciles pending
  immutable packets, ACK debt, cursor, generation, event batches, and a full
  snapshot before returning UI state.
- Prompt and restart remain unavailable because no production semantic adapter
  can prove those effects yet.
- `Phone/project.yml` declares local-network usage text. It still has no
  background-fetch identifier, remote-notification mode, or push entitlement.

Evidence: 30 phone-core tests pass across 9 suites. The iOS app and its lifecycle
tests compile with generic Simulator `build-for-testing`. No simulator is
installed, so lifecycle tests have not executed on an Apple runtime.

## Apple limits

### App lifecycle

Apple says an app entering `ScenePhase.background` should expect termination soon. Background is for cleanup, not a durable socket. Observe aggregate `scenePhase`; connect only while active, cancel timers/network work when inactive or backgrounded, and persist protocol state before suspension.

Source: [ScenePhase](https://developer.apple.com/documentation/SwiftUI/ScenePhase)

### Foreground reconnect — required path

On every transition to active:

1. Start one idempotent connection supervisor.
2. Reconcile durable pairing, cursor, pending immutable packets, ACK debt, and server generation before enabling commands.
3. Retry transient connection loss with capped exponential backoff plus jitter. Reset after a successful authenticated exchange.
4. Cancel the loop when no scene is active. Resume immediately when active again.
5. On authorization, identity, cursor, or inventory mismatch, fail closed and require a full snapshot; never keep retrying a destructive packet.

This is the only suitable interactive-control path. Network.framework should report connection state; local TCP should use `NWConnection`.

Sources: [ScenePhase](https://developer.apple.com/documentation/SwiftUI/ScenePhase), [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

### `BGAppRefreshTask` — optional observation only

Apple defines app refresh as a short content update. The system chooses launch time, provides up to about 30 seconds, and does not guarantee `earliestBeginDate`. Therefore:

- Use it only to perform one bounded authenticated observe/reconciliation and persist the result.
- Never use it for periodic heartbeats, guaranteed stuck-agent detection, prompt submission, restart, or waiting on a Mac.
- Register the handler before launch completes; enable `fetch`; declare a permitted identifier; resubmit; install an expiration handler that cancels transport; always call `setTaskCompleted`.
- Require a previously granted Local Network privilege. Apple says an undetermined local-network request made in background is denied without showing the permission alert.
- Do not keep the connection open after the refresh completes.

Sources: [Choosing Background Strategies for Your App](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app), [Using background tasks to update your app](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app), [`earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

### Push — optional wake hint, not correctness path

Silent push is low priority, may be delayed, discarded, coalesced, or throttled, and is not guaranteed. Apple gives a delivered background notification up to 30 seconds. Use push only if a properly authenticated APNs provider exists.

- Payload carries an opaque “state changed” hint only. No prompt, task text, credentials, authorization, or restart instruction.
- Wake performs one bounded observe. It cannot authorize a mutation.
- A visible notification may invite the user to open Guardian. After open, foreground reconciliation must prove exact task, generation, complete inventory, and capability before any destructive action.
- Do not misuse PushKit; Guardian is not a VoIP app.
- Do not embed APNs provider credentials in the iPhone app or public repository.

Source: [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

### Local-network work

- Existing `NSLocalNetworkUsageDescription` is correct for direct TCP.
- Pair and trigger the first local-network access in foreground so iOS can present consent.
- QR-provided IP/port needs no Bonjour declaration. Add `NSBonjourServices` only if service browsing/registration is introduced.
- Local Network permission authorizes access; it grants no background runtime.
- Detect `NWConnection` waiting with `localNetworkDenied`; expose a permission-specific disconnected state instead of retrying blindly.

Source: [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Recommended implementation order

1. RED lifecycle tests: active starts exactly one supervisor; inactive/background cancels; reactivation reconciles before commands.
2. Implement injectable foreground supervisor with deterministic clock, capped jittered backoff, cancellation, and single-flight load.
3. RED tests for network denial, TLS/auth failure, cursor gap, stale generation, and pending packet replay. Deterministic failures open their scoped circuit; only transient transport errors back off.
4. Add optional BG refresh behind an adapter. It observes only, respects expiration, persists atomically, and never changes command authorization.
5. Add push only after an APNs provider and privacy/security design exist. Keep correctness independent of delivery.

## Proof boundary

Can prove without simulator/device:

- Pure supervisor state-machine tests using injected clock, random jitter, scene phase, connectivity, and transport.
- Single-flight, cancellation, backoff cap/reset, immutable replay, cursor/full-snapshot fallback, and command-disable invariants.
- Static validation of `Info.plist`, background modes, permitted identifier, registration wiring, push entitlement absence/presence, and secret scan.
- SwiftPM tests and generic iOS build-for-testing.

Cannot prove without a physical device:

- Local Network prompt, denial/regrant behavior, and real LAN reachability.
- Suspension, termination, foreground resume, Wi-Fi changes, lock/unlock, and power behavior.
- System-selected BG refresh launch or expiration. Apple’s background-task sample explicitly requires a physical device.
- APNs delivery, throttling, coalescing, force-quit behavior, and notification action launch.
- End-to-end pinned TLS exchange with the production Mac Guardian.

Source: [Refreshing and Maintaining Your App Using Background Tasks](https://developer.apple.com/documentation/BackgroundTasks/refreshing-and-maintaining-your-app-using-background-tasks)

## Phase 8 exit evidence

Do not claim background reconnect complete until deterministic tests and generic build pass, then a physical-device evidence run proves: foreground permission; suspend/resume reconciliation; Wi-Fi loss/recovery; expiry cancellation; no duplicated command; exact packet replay; and mutations disabled until fresh authoritative inventory arrives. BG refresh and push remain availability enhancements, not safety evidence.
