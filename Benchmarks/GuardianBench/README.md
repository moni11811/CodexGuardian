# GuardianBench

Public, deterministic recovery benchmark.

## Rules

- Run the same supported scenario against pinned releases.
- Record unsupported behavior as `not_available`, never failure.
- Freeze scenario severity and inputs before comparison.
- Report safety, correctness, latency, and operator actions separately.
- Publish trial count, environment, observation window, and confidence bounds.
- Never turn zero observed failures into a claim of zero risk.

## Required result fields

- `scenarioId`
- `implementation`
- `revision`
- `environment`
- `trialCount`
- `correctOutcomes`
- `unsafeRestarts`
- `wrongThreadContinuations`
- `duplicateAcceptedCommands`
- `lostAcceptedCommands`
- `operatorActions`
- `classificationMilliseconds`
- `repairMilliseconds`
- `safePointWaitMilliseconds`
- `finalJournalPhase`
- `evidence`

## Run

```sh
swift run guardian-bench --seed 42 --revision "$(git rev-parse --short HEAD)" --output result.json
```

The runner validates `scenarios.v1.json`, executes registered pure Guardian policy trials, and emits `result-schema.v1.json`-compatible JSON. Same inputs produce identical bytes. It performs no network calls and reads no private project data.

`deterministic_guardian_policy` output proves only the named pure-core invariants. It is not live Guardian, LAN, VPN, TLS, or recovery evidence. Unknown supported scenarios fail. Unsupported scenarios are emitted as `not_available`; unmeasured latency is omitted.
