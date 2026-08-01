# Phase 7 Remote Attack Surface Review

Bounded independent review. No implementation authority.

## Durable journal insertion map

Current anchors: migrations end at `guardian-journal-v12-readiness-manifest` in `GuardianJournal.swift:234-250`; public projection APIs begin at `:259`, readiness APIs occupy `:289-343`, client cursor CAS is `:725-780`, and row quarantine helper is `:2104-2125`.

- Add v13 after line 250: `guardian_remote_devices` (`device_id` PK, unique 32-byte public key, capabilities, active/revoked status, pairing/revocation epochs, last accepted sequence, paired/last-seen times) and `guardian_pairing_challenges` (32-byte `nonce_hash` PK, 32-byte Guardian identity hash, created/expires/consumed times). Never delete revoked devices; retain identity and increment revocation epoch.
- Add v14 after v13: `guardian_remote_replay_nonces` (`nonce_hash` PK, device/command IDs, consumed/expires times), `guardian_remote_commands` (command ID PK, immutable device/generation/sequence/revocation epoch/thread/action/force/payload digest/times), `guardian_remote_command_receipts` (command ID PK/FK, device, payload digest, generation, sequence, accepted time), and append-only `guardian_remote_audit_events` (auto index, device/command IDs, event/reason codes, generation/sequence, evidence ID, time). Unique `(device_id, sequence)`, command ID, and nonce hash fence duplicates.
- Add public APIs near line 343: `issuePairingChallenge`, `pairDevice` (consume challenge + insert device + audit in one `database.write`), `remoteDevice(s)`, `revokeRemoteDevice` (epoch CAS + audit), `reconcileRemoteCommand` (validate + consume nonce + insert immutable command/receipt + advance device sequence + audit in one transaction), `remoteReceipt`, and bounded `remoteAuditEvents`.
- Add fetch/decode helpers beside capability/client decoders around lines 1538/1775. Authentication/trust rows must throw on corruption; do not use observational `scanRows` quarantine for device, nonce, receipt, or revocation state.
- Extend `GuardianJournalError` and `GuardianJournalFaultPoint`; inject after nonce insert, receipt insert, device-sequence update, challenge consume, and revocation update. Each injected failure must roll back the entire transaction.

## Red-test conventions and required cases

Follow existing Swift Testing style: deterministic UUIDs/dates, unique temporary SQLite directory, `defer` cleanup, explicit `#expect(throws:)`, reopen the journal to prove durability (`GuardianProjectionJournalTests.swift:5-38`), CAS assertions (`:42-76`), and one-audit/idempotent replay checks (`GuardianAuthorityCutoverTests.swift:109-147`). Add concurrent multi-handle cases following `GuardianJournalConcurrencyTests` and crash-worker rollback/committed-replay scenarios.

Required red cases: pairing nonce expires/consumes once across reopen; concurrent pairing admits one device; replay nonce survives reopen; same command returns the original receipt exactly once; same command ID with changed immutable fields conflicts; sequence gap/stale generation requests snapshot without consuming nonce; revoked device and stale revocation epoch reject; concurrent same nonce/sequence yields one acceptance; corruption of any trust row fails closed; every fault point leaves neither partial receipt nor advanced cursor/audit.

## Security invariants

- Pairing nonce stored only as SHA-256; identity pin, expiry, one-time consume, device creation, and audit are atomic.
- Remote acceptance is single-writer and crash durable. Receipt exists iff nonce consumption, command record, sequence advance, and acceptance audit all committed.
- Duplicate identity is canonical immutable command equality plus payload digest, never command ID alone.
- Revocation check precedes capability evaluation; revocation epoch is monotonic and closes all sessions. No delete/re-pair shortcut.
- Remote capability bits never encode force bypass. Journal rejects `force == true` even if callers skipped policy validation.
- Generation and per-device sequence are exact fences. UInt64 values must be range-checked before SQLite Int64 conversion.
- Persist no raw prompt, approval text, file content, terminal content, private key, or live pairing nonce. Audit stores sanitized codes/IDs/digests only.

- RED proof: focused Swift test compile failed exactly because `GuardianRemoteSessionHub` is missing; dependent cursor/result/session types therefore cannot infer. No unrelated build error blocked the regression.
