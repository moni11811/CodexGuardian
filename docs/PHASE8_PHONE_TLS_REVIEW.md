# Phase 8 phone TLS review

Independent bounded review. Findings append below.

## 2026-07-27 bounded transport review

Evidence boundary: source inventory/design review only. No compile, live TLS, device, or runtime proof claimed.

### Current seam

- `PhonePairingCoordinator.Exchange` already isolates transport at `Sources/GuardianPhoneCore/GuardianPhonePairingCoordinator.swift:69-84`; pairing builds the complete length-prefixed request, calls the exchange once, validates request ID/device/capabilities/epochs, then persists at lines 91-134.
- `PhoneRemotePairingWireCodec` owns the shared wire contract: 4-byte big-endian payload length, nonzero payload, 512 KiB payload maximum, exact frame length.
- The Mac peer is intentionally one-shot. `GuardianRemoteTLSConnectionServer` receives one frame, routes it, sends one framed response, then cancels the connection. Client connection reuse is therefore wrong for pairing.
- The Mac listener fixes minimum and maximum protocol to TLS 1.3 and serves the exact certificate whose SHA-256 is carried in the signed invitation.
- `ProductionGuardianPhoneService.pair` is still a fail-closed stub. The phone target has no Local Network usage description.

### Exact production implementation

Add a `PhonePinnedTLSFrameExchange` in `GuardianPhoneCore`; preserve the existing injected closure for deterministic tests. Prefer evolving the exchange input to include one absolute deadline, so DNS, TLS handshake, send, header receive, and body receive share one budget.

For each call:

1. Revalidate endpoint host as private/local, port nonzero, and pin exactly 32 bytes. `PhonePinnedEndpoint.isValid` currently accepts any nonempty host; persisted state therefore needs the same private-host policy as QR decoding.
2. Build `NWProtocolTLS.Options`; set both TLS min and max to `.TLSv13`.
3. Install `sec_protocol_options_set_verify_block`. Obtain the `SecTrust`, take certificate index 0, hash `SecCertificateCopyData(leaf)` with SHA-256, and complete `true` only for the exact invitation pin. Every unavailable-trust/certificate/malformed-pin path completes `false`. Pin-only verification is required for the Guardian-owned certificate; do not silently fall back to system trust or cleartext.
4. Build TCP/TLS `NWParameters`, disable cellular, create `NWConnection(host:port:)`, register handlers, then start it. Await `.ready` before sending; `.ready` proves the TLS verify callback accepted the leaf.
5. Send the already-framed request exactly once. Read exactly 4 header bytes, parse big-endian length, reject zero or greater than 512 KiB before allocating, then read exactly that payload and return `header + payload` to the existing codec.
6. Use one guarded terminal state so timeout, task cancellation, state failure, send completion, and receive callbacks cannot resume a continuation twice. Cancel the connection and clear handlers on every exit. Late callbacks must become no-ops.
7. Wire `ProductionGuardianPhoneService.pair` to `PhonePairingCoordinator(storage: PhoneKeychainPairingStorage(), exchange: productionExchange)`. Add `NSLocalNetworkUsageDescription` to the iOS target. Keep all other production actions fail closed until authenticated reconnect/observe exists.

### Highest-risk RED tests before implementation

1. Wrong leaf pin rejects during handshake and sends zero application bytes; exact pin succeeds. Certificate rotation with the old pin also rejects.
2. TLS-1.2-only peer rejects. This must exercise real Network TLS options, not only a policy value test.
3. Header and body fragmented at every boundary reconstruct one frame. EOF after 0-3 header bytes, zero length, 512 KiB + 1, and partial body all reject without oversized allocation.
4. Timeout/cancellation during connect, TLS verify, send, header, and body cancels once and completes once. Inject late success/failure callbacks to prove no double resume or hang.
5. `.failed`/`.cancelled` before `.ready` sends nothing. A callback carrying final content together with `isComplete == true` must still preserve that content.
6. Matching TLS response with wrong request ID, device ID, capabilities, zero pairing epoch, or malformed body never writes paired Keychain state. Existing test covers only success.
7. Stored public/empty/invalid endpoint fails before `NWConnection` creation. No cellular, cleartext, system-trust, or public-network fallback occurs after Local Network denial.
8. Real loopback integration uses the actual Mac `GuardianRemoteTLSConnectionServer` and a real `SecIdentity`: correct pin completes pairing; wrong pin leaves the Mac pairing challenge unconsumed; exact 512 KiB boundary agrees on both sides.

### Secondary risk

The phone privately duplicates remote wire DTOs. Existing cross-module pairing tests catch current drift, but every new response/request case needs a Mac-encoded/phone-decoded compatibility test before production use.
