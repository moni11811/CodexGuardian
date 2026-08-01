# Phase 7 rejection-audit review

## Bug theory

Guardian durably records accepted remote commands, but forged, replayed, and
revoked-device attempts return early without a durable audit event. An attacker
can therefore probe authentication and replay controls without leaving a
forensic trail.

## Required contract

- Every rejected command attempt that identifies a command/device is recorded
  transactionally as `commandRejected`.
- Use finite reason codes: `command.rejected.invalid_signature`,
  `command.rejected.replayed_nonce`, and `command.rejected.device_revoked`.
- Retain only device ID, command ID, generation, sequence, reason, and time.
- Never retain raw nonce, signature, payload, or prompt text.
- Rejection must not consume the nonce or advance `lastAcceptedSequence`.

Pairing-claim rejection is intentionally excluded from this RED lane because
the current pairing authenticator has no journal dependency. It needs a
separate coordinator-level audit contract rather than hidden persistence in
the cryptographic verifier.

## RED evidence

Focused run exited 1 with the intended missing-event failures for forged,
replayed, and revoked-device attempts. No unrelated failure.

## GREEN evidence

Typed, finite rejection reasons now produce sanitized durable events. The same
five-test pairing/audit run passed 5/5. A separate coordinator regression first
failed, then passed after forged pairing claims gained durable rejection audit.
