# Phase 7 pairing validation review

Owner: pairing validation regression lane.

RED: public endpoint invitations and claims timestamped before invitation
issuance both authenticated. Focused run failed 2/2 for those exact symptoms.

GREEN: verifier now requires a private/loopback literal endpoint and binds claim
time to invitation issuance. Focused run passed 2/2.

## Bug theory

- Invitation signature verification checks only that `endpointHost` is nonempty. A correctly signed payload can direct the phone to a public network endpoint.
- Claim verification checks only an upper clock-skew bound. A correctly signed claim dated before its invitation can be accepted.

## Required fail-closed invariants

- A signed invitation with a public endpoint is rejected before trust or connection.
- A signed claim whose `issuedAt` predates the invitation is rejected.

## RED evidence

Command:

```sh
env SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codexguardian-swift-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/codexguardian-swift-cache \
  swift test --filter 'pairingInvitationRejectsPublicEndpointBeforeTrust|pairingClaimRejectsTimestampBeforeInvitationIssuance'
```

Result: exit 1. Build succeeded. Both selected tests failed for the intended missing checks:

- `pairingInvitationRejectsPublicEndpointBeforeTrust`: actual `.authenticated(...)` for `203.0.113.9`; expected `.rejected(.invalidPayload)`.
- `pairingClaimRejectsTimestampBeforeInvitationIssuance`: actual `.authenticated(...)` for claim issued one second before invitation; expected `.rejected(.invalidClaim)`.

No production file changed in this lane.
