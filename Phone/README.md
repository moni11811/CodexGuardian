# Codex Guardian for iPhone — experimental

This target is a development preview, not a shipped remote controller.

Implemented: iOS 17 UI, pairing foundations, pinned-TLS observation, reconnect projections, task/history presentation, and fail-closed capability controls.

Unavailable in the production service: sending prompts and restarting agents. The buttons remain disabled or return `transportUnavailable` until the Mac adapter can prove exact effects safely.

Generate and build:

```bash
xcodegen generate
xcodebuild -project CodexGuardianPhone.xcodeproj \
  -scheme CodexGuardianPhone \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Run these commands from the `Phone` directory. A simulator build is not live-device, network, TestFlight, or App Store proof.

See [Remote and iPhone status](../docs/REMOTE_ACCESS.md).
