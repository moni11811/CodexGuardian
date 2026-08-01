# Phase 10 Smart Guardian Adviser

## Failure theory

The previous Foundation Models helper returned one free-form continuation string
inside the Mac app. A model failure had a fallback, but there was no typed core
boundary proving that model output could not change state, authorize restart,
invent an ACK, call a tool, or leak supplied secrets.

## Red-first contract

- Restart/control/tool/fake-ACK/secret output is rejected.
- Model unavailable and model failure equal deterministic advice.
- Incomplete evidence refuses diagnostic and continuation.
- Grounded bounded advice may be shown but reports no authority.

The new tests first failed because the typed adviser did not exist. They now pass.

## Implemented

- Codable `GuardianAdvice` with failure family, diagnostic, continuation,
  uncertainty, and source.
- Bounded, redacted verified context before model invocation.
- Family/diagnostic grounding and forbidden-control output validation.
- Deterministic family-to-diagnostic templates.
- `hasAuthority` is always false; the adviser has no journal, transport, tool,
  ACK, or restart-controller dependency.
- The macOS Foundation Models prompt generator now passes its candidate through
  this policy. Unavailable, throwing, or rejected model output uses the same
  deterministic fallback.

## Evidence boundary

Core safety tests are local. A full held-out golden evaluation, blind human
usefulness scoring, latency measurements, and macOS 27 device-model comparison
remain required before Phase 10 exit.
